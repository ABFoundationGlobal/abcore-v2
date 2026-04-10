# 验证节点升级操作手册

## v1.13.15（Supervisor + 裸机）→ abcore-v2（Docker Compose）

**文档版本**: 1.2
**适用网络**: ABCore 测试网（Chain ID 26888）
**共识机制**: Clique PoA

> **快速设置环境变量**：执行以下命令将路径变量写入 `~/.bashrc`，重新登录后仍然有效。根据实际部署环境修改路径后执行：

```bash
cat >> ~/.bashrc << 'EOF'
export NODE_DIR="/data/abcore/testnet"        # v1 裸机节点根目录
export DOCKER_DIR="/data/abcore-docker"       # v2 Docker 部署根目录
export TAG="vX.Y.Z"                           # abcore-v2 目标 Release tag
EOF
source ~/.bashrc
```

---

## 1. 升级概述

### 1.1 变更内容

| 维度 | 当前（v1） | 升级后（v2） |
|------|-----------|-------------|
| 客户端版本 | v1.13.15 | abcore-v2 |
| 进程管理 | Supervisor | Docker Compose |
| 部署方式 | 裸机二进制 | 容器镜像 |
| 数据目录 | `$NODE_DIR/nodedata`（或自定义路径） | bind mount 到容器 `/data` |
| 配置文件 | 独立 `config.toml` | 启动参数直接传入，可选 `node.toml` 调优 |
| Genesis / Bootstrap | 独立文件 | **已内置于二进制**，无需外部文件 |

### 1.2 兼容性保证

v2 二进制与 v1 **数据目录完全兼容**——同一个 datadir 可以直接被 v2 读取，无需数据迁移或重新同步。这是滚动升级的基础。

> **补充说明**：本手册处理的是“链仍处于 Clique 阶段”的 v1 → v2 二进制/部署升级。
> 若已经启用 `ParliaGenesisBlock = N` 且链在共识切换时或切换后失败，需要使用
> [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md) 中的协调式回滚流程。

### 1.3 Clique 滚动升级约束

Clique PoA 要求超过半数签名者（`floor(N/2) + 1`）在线才能继续出块。升级策略必须确保**任何时刻在线验证节点数量不低于出块门槛**。

| 总签名者数 N | 最小在线数 | 每次最多同时停机 |
|------------|-----------|----------------|
| 3 | 2 | 1 |
| 4 | 3 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

> **关键原则**：每次只升级一个节点，等它重新出块后再升级下一个。

---

## 2. 升级前准备

### 2.1 前提条件

**操作机要求**
- Docker Engine 24+
- Docker Compose v2（`docker compose` 子命令，非 `docker-compose`）
- 对宿主机有 sudo/root 权限
- 已克隆 abcore-v2 仓库并能构建镜像（或已有预构建镜像）

**验证机要求**
- 当前 supervisor 管理的 geth 进程正常出块
- 至少 3 小时内无重组 / 告警

**检查当前状态**（在每台验证机上执行）

```bash
# 检查 v1 节点是否正常运行
supervisorctl status abcore

# 确认当前 head
$NODE_DIR/bin/geth attach --exec \
  'console.log("head:", eth.blockNumber, "peers:", admin.peers.length)' \
  $NODE_DIR/nodedata/geth.ipc

# 确认节点在 Clique 签名者列表中
$NODE_DIR/bin/geth attach --exec \
  'console.log(JSON.stringify(clique.getSnapshot("latest").signers, null, 2))' \
  $NODE_DIR/nodedata/geth.ipc
```

### 2.2 备份

```bash
# 备份 keystore（最重要，不可恢复）
BACKUP_DIR="/data/backup/abcore-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp -r $NODE_DIR/nodedata/keystore "$BACKUP_DIR/"
cp $NODE_DIR/password.txt "$BACKUP_DIR/"   # 如有独立密码文件

# 验证备份完整性
ls -la "$BACKUP_DIR/keystore/"
echo "Backup location: $BACKUP_DIR"
```

> **注意**：chaindata 不需要备份——v2 可直接使用现有链数据。

### 2.3 收集节点信息

在升级前记录以下信息，回滚时需要：

```bash
# 记录验证节点地址
ls $NODE_DIR/nodedata/keystore/

# 记录当前 enode
$NODE_DIR/bin/geth attach --exec \
  'console.log(admin.nodeInfo.enode)' \
  $NODE_DIR/nodedata/geth.ipc

# 记录当前 block number（升级后用于验证同步）
$NODE_DIR/bin/geth attach --exec \
  'console.log(eth.blockNumber)' \
  $NODE_DIR/nodedata/geth.ipc

# 记录当前 peers（含 enode 地址，升级后 peers 减少时可手动添加）
$NODE_DIR/bin/geth attach --exec \
  'admin.peers.forEach(function(p){ console.log(p.enode) })' \
  $NODE_DIR/nodedata/geth.ipc
```

> **注意**：v2 容器首次启动时 peers 缓存为空，连接数可能短暂低于 v1。这是正常现象——节点发现需要一段时间。若长时间（>10 分钟）peers 仍为 0，可通过以下命令手动添加上面记录的 enode：
>
> ```bash
> docker exec -it abcore-validator geth attach /data/geth.ipc
> > admin.addPeer("enode://...")
> ```

---

## 3. Docker 环境准备

### 3.1 构建 abcore-v2 镜像

在部署机（或 CI）上执行一次，产出的镜像分发到各验证机：

```bash
# REPO_DIR 为 abcore-v2 代码仓库路径，根据实际情况修改
export REPO_DIR=/opt/abcore-v2-repo

# 方式 A：在验证机上直接构建（约 10 分钟）
docker build -t abfoundationglobal/abcore-v2:$TAG $REPO_DIR

# 方式 B：导出镜像，传输后导入（适用于多台验证机且无法访问 GitHub 的环境）
# 构建机执行：
docker build -t abfoundationglobal/abcore-v2:$TAG $REPO_DIR
docker save abfoundationglobal/abcore-v2:$TAG | gzip > abcore-v2.tar.gz

# 验证机执行：
scp builder:/path/abcore-v2.tar.gz /tmp/
docker load < /tmp/abcore-v2.tar.gz
docker images | grep abfoundationglobal

# 方式 C：从 GitHub Release 下载预构建镜像（推荐，无需本地构建环境）
gh release download $TAG -R ABFoundationGlobal/abcore-v2 \
  --pattern "abcore-v2-${TAG}-linux-amd64.tar.gz" -D /tmp/

docker load < /tmp/abcore-v2-${TAG}-linux-amd64.tar.gz
docker images | grep abfoundationglobal
```

验证镜像：

```bash
docker run --rm --entrypoint geth abfoundationglobal/abcore-v2:$TAG version
```

### 3.2 准备 Docker 目录结构

```
$DOCKER_DIR/
├── docker-compose.yml
└── nodedata/            ← 将现有 datadir 迁移至此（bind mount → 容器 /data）
    ├── keystore/        ← 来自原 v1 datadir（容器自动检测，启用验证者模式）
    ├── geth/            ← 来自原 v1 datadir（链数据）
    └── password.txt     ← 解锁密码（权限设为 600）
```

```bash
mkdir -p $DOCKER_DIR/nodedata

# 拷贝密码文件到数据目录
cp $NODE_DIR/password.txt $DOCKER_DIR/nodedata/password.txt
chmod 600 $DOCKER_DIR/nodedata/password.txt
```

### 3.3 准备 docker-compose.yml

容器启动时自动检测：若 `/data/keystore/` 有 keystore 文件且 `/data/password.txt` 存在，则自动启用验证者模式（`--mine`）；公网 IP 也自动探测，无需手动配置。

```bash
cat > $DOCKER_DIR/docker-compose.yml << 'EOF'
services:
  validator:
    image: abfoundationglobal/abcore-v2:${TAG}
    container_name: abcore-validator
    restart: unless-stopped
    environment:
      NETWORK: testnet
      # 高级调优（可选）：将 node.toml 放入 $DOCKER_DIR/nodedata，取消下行注释
      # BSC_CONFIG: /data/node.toml
    volumes:
      - ./nodedata:/data
    ports:
      - "127.0.0.1:8545:8545"
      - "127.0.0.1:8546:8546"
      - "0.0.0.0:33333:33333"
      - "0.0.0.0:33333:33333/udp"
    command:
      - --port=33333
      - --http
      - --http.addr=0.0.0.0
      - --http.port=8545
      - --http.vhosts=localhost
      - --http.api=debug,txpool,net,web3,eth
      - --ws
      - --ws.addr=0.0.0.0
      - --ws.port=8546
      - --ws.api=debug,txpool,net,web3,eth
      - --syncmode=full
      - --gcmode=archive
    healthcheck:
      test:
        - CMD-SHELL
        - >
          curl -sf -X POST
          -H 'Content-Type: application/json'
          -d '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}'
          http://localhost:8545 || exit 1
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 30s
    logging:
      driver: "json-file"
      options:
        max-size: "500m"
        max-file: "5"
EOF
```

### 3.4 启动容器

keystore 和 password.txt 就位后直接启动，容器自动检测并开启验证者模式：

```bash
cd $DOCKER_DIR
docker compose up -d

# 查看启动日志
docker compose logs -f --tail=50
```

启动日志中会打印自动检测结果：

```
INFO: keystore and password found, enabling validator mode automatically
INFO: using validator address 0x...
INFO: detected public IP x.x.x.x, setting NAT automatically
```

---

## 4. 单节点升级步骤（滚动升级）

**每次只对一台验证机执行此章节的完整流程，确认出块后再继续下一台。**

### 步骤 1：暂停 Supervisor 管理的 v1 进程

```bash
# 记录停机前的 block number
STOP_BLOCK=$(
  $NODE_DIR/bin/geth attach --exec 'eth.blockNumber' \
  $NODE_DIR/nodedata/geth.ipc
)
echo "Stopping at block: $STOP_BLOCK"

# 停止 v1 进程（graceful shutdown）
supervisorctl stop abcore

# 确认进程已退出（等待 geth.ipc 消失）
timeout 30 bash -c "while [ -e $NODE_DIR/nodedata/geth.ipc ]; do sleep 1; done"
echo "v1 process stopped"
```

### 步骤 2：迁移数据目录

v2 与 v1 的数据格式完全兼容。将原 v1 datadir 中的全部数据迁移到 `./nodedata/`：

```bash
cd $DOCKER_DIR

# 将 v1 datadir 完整同步过来（含 keystore 和链数据）
rsync -av --progress $NODE_DIR/nodedata/ ./nodedata/

# 确保密码文件在 nodedata 目录中
cp $NODE_DIR/password.txt ./nodedata/password.txt
chmod 600 ./nodedata/password.txt
```

### 步骤 3：启动 Docker 容器

```bash
cd $DOCKER_DIR
docker compose up -d

# 查看启动日志
docker compose logs -f --tail=50

# 确认容器状态
docker compose ps
```

正常启动日志中应包含：

```
INFO: keystore and password found, enabling validator mode automatically
INFO: using validator address 0x...
INFO: detected public IP x.x.x.x, setting NAT automatically
INFO [xx:xx:xx] Starting peer-to-peer node  ...
INFO [xx:xx:xx] IPC endpoint opened  ...
INFO [xx:xx:xx] Unlocked account  ...
INFO [xx:xx:xx] Commit new sealing work  ...
```

### 步骤 4：验证节点同步与出块

```bash
# 通过 docker exec 连接 geth console
docker exec -it abcore-validator geth attach /data/geth.ipc

# 在 geth console 中执行：
> eth.blockNumber        # 应大于停机时记录的 $STOP_BLOCK
> admin.peers.length     # 应 >= 1
> clique.getSnapshot("latest").recents  # 出几个块后应出现本节点地址
> eth.mining             # 应为 true
```

**在任意其他仍运行 v1 的节点上确认出块**：

```bash
$NODE_DIR/bin/geth attach --exec \
  'JSON.stringify(clique.getSnapshot("latest").recents)' \
  $NODE_DIR/nodedata/geth.ipc
# 应看到升级后节点的地址出现在 recents 中
```

### 步骤 5：停用 Supervisor 配置

观察至少 10 分钟、确认持续出块后，禁用 supervisor 配置以防止意外重启 v1：

```bash
mv /etc/supervisor/conf.d/abcore.conf \
   /etc/supervisor/conf.d/abcore.conf.disabled
supervisorctl update
```

---

## 5. 滚动升级顺序（3 节点示例）

```
初始状态:  [V1 v1] [V2 v1] [V3 v1]   → 出块正常

第 1 轮:   停止 V1，启动 Docker
           [V1 v2↑]  [V2 v1] [V3 v1]  ← V2+V3 维持出块
           确认 V1 出块后继续

第 2 轮:   停止 V2，启动 Docker
           [V1 v2]  [V2 v2↑] [V3 v1]  ← V1+V3 维持出块
           确认 V2 出块后继续

第 3 轮:   停止 V3，启动 Docker
           [V1 v2]  [V2 v2]  [V3 v2↑] ← V1+V2 维持出块
           确认 V3 出块后：升级完成 ✓
```

> **4 节点特别说明**：Clique 4 签名者出块门槛为 3，**任何时刻必须保证至少 3 个验证节点在线**，即最多只允许 1 台离线。4 节点场景同样应逐台滚动升级（每次仅停 1 台，待其恢复出块后再升级下一台），切勿同时停止多台。

---

## 6. 升级后验证清单

在**所有节点**升级完毕后执行：

```bash
# 1. 各节点 block number 一致
docker exec -it abcore-validator geth attach \
  --exec 'eth.blockNumber' /data/geth.ipc

# 2. 各节点 peers 数量正常
docker exec -it abcore-validator geth attach \
  --exec 'admin.peers.length' /data/geth.ipc

# 3. 确认 clique snapshot 中所有签名者地址正确
docker exec -it abcore-validator geth attach \
  --exec 'JSON.stringify(Object.keys(clique.getSnapshot("latest").signers))' \
  /data/geth.ipc

# 4. 确认 v2 版本号
docker exec abcore-validator geth version

# 5. 链持续推进（每 ~3 秒递增）
for i in 1 2 3; do
  docker exec abcore-validator geth attach \
    --exec 'eth.blockNumber' /data/geth.ipc
  sleep 4
done
```

**完成检查点**

- [ ] 所有验证节点升级至 abcore-v2 Docker 部署
- [ ] 全网 block number 一致，无停链
- [ ] 各节点 `clique.getSnapshot` 签名者集合正确
- [ ] Supervisor v1 进程已停用
- [ ] keystore 备份安全存储
- [ ] 监控告警指向 Docker 容器（更新 Prometheus / 健康检查端点）

---

## 7. 回滚方案（仅适用于仍处于 Clique 阶段的 v1 ↔ v2 部署回退）

若 v2 容器启动后出现同步异常或停止出块：

```bash
# 1. 停止 Docker 容器
cd $DOCKER_DIR
docker compose down

# 2. 检查错误日志
docker compose logs --tail=100

# 3. 重新启动 v1（supervisor）
mv /etc/supervisor/conf.d/abcore.conf.disabled \
   /etc/supervisor/conf.d/abcore.conf
supervisorctl update
supervisorctl start abcore

# 4. 确认 v1 重新出块
supervisorctl status abcore
$NODE_DIR/bin/geth attach --exec \
  'console.log(eth.blockNumber, admin.peers.length)' \
  $NODE_DIR/nodedata/geth.ipc
```

> v2 与 v1 使用同一 datadir 格式，v2 写入的块数据对 v1 完全可读，回滚后 v1 会从当前 head 继续同步。

> **重要**：若链已经跨过 `ParliaGenesisBlock`，不要直接套用本章节。
> 此时应停下所有验证节点与关键 RPC 节点，按
> [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md)
> 执行“回退到 `N-1` 并恢复 pure Clique”的协调式回滚。

---

## 8. 故障排查

### 容器启动后立即退出

```bash
docker compose logs --tail=50
```

| 错误信息 | 原因 | 解决方法 |
|---------|------|---------|
| `no keystore file found in /data/keystore/` | keystore 目录为空 | 确认 keystore 文件已放入 `./nodedata/keystore/` |
| `could not unlock account` | keystore 与密码不匹配 | 检查 keystore 文件名末尾地址与 `password.txt` 是否对应 |
| `password file not found` | 密码文件缺失 | 确认 `./nodedata/password.txt` 存在且权限为 600 |
| `NETWORK must be testnet or mainnet` | NETWORK 值不合法 | 检查 `docker-compose.yml` 中 `NETWORK:` 配置 |

### 节点有 peers 但不出块

```bash
docker exec -it abcore-validator geth attach /data/geth.ipc
> eth.mining             # 若为 false，检查 keystore/password.txt 是否存在于 ./nodedata/
> clique.getSnapshot("latest").signers  # 确认本节点地址是否在授权列表中
```

### P2P 连接数为 0

1. 确认 33333 端口（TCP + UDP）在防火墙/安全组中已开放
2. 检查启动日志中是否有 `detected public IP` — 若无，手动指定：在 `docker-compose.yml` 的 `environment` 中添加 `NAT: "extip:<PUBLIC_IP>"`
3. 手动添加已知节点：
   ```bash
   docker exec -it abcore-validator geth attach /data/geth.ipc
   > admin.addPeer("enode://...")
   ```

---

## 9. 常用运维命令

```bash
# 查看实时日志
docker compose -f $DOCKER_DIR/docker-compose.yml logs -f

# 进入 geth console
docker exec -it abcore-validator geth attach /data/geth.ipc

# 重启节点
docker compose -f $DOCKER_DIR/docker-compose.yml restart validator

# 停止节点
docker compose -f $DOCKER_DIR/docker-compose.yml down

# 升级镜像
docker compose -f $DOCKER_DIR/docker-compose.yml pull   # 或重新 build/load
docker compose -f $DOCKER_DIR/docker-compose.yml up -d

# 查看容器资源使用
docker stats abcore-validator
```
