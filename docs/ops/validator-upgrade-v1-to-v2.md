# 验证节点升级操作手册

## v1.13.15（Supervisor + 裸机）→ abcore-v2（Docker Compose）

**文档版本**: 1.0
**适用网络**: ABCore 测试网（Chain ID 26888）
**共识机制**: Clique PoA

> **快速设置环境变量**：执行以下命令将路径变量写入 `~/.bashrc`，重新登录后仍然有效。根据实际部署环境修改路径后执行：
>
> ```bash
> cat >> ~/.bashrc << 'EOF'
> export NODE_DIR="/data/abcore/testnet"        # v1 裸机节点根目录
> export DOCKER_DIR="/data/abcore-docker"       # v2 Docker 部署根目录
> EOF
> source ~/.bashrc
> ```

---

## 1. 升级概述

### 1.1 变更内容

| 维度 | 当前（v1） | 升级后（v2） |
|------|-----------|-------------|
| 客户端版本 | v1.13.15 | abcore-v2 |
| 进程管理 | Supervisor | Docker Compose |
| 部署方式 | 裸机二进制 | 容器镜像 |
| 数据目录 | `$NODE_DIR/nodedata`（或自定义路径） | Docker named volume 或 bind mount |
| 配置文件 | 独立 `config.toml` | 容器内 `/bsc/config/config.toml` |

### 1.2 兼容性保证

v2 二进制与 v1 **数据目录完全兼容**——同一个 datadir 可以直接被 v2 读取，无需数据迁移或重新同步。这是滚动升级的基础。

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
# 注意原配置文件可能叫node.toml
cp $NODE_DIR/conf/node.toml  "$BACKUP_DIR/"
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
cat $NODE_DIR/nodedata/address.txt
# 或从 keystore 文件名获取
ls $NODE_DIR/nodedata/keystore/

# 记录当前 enode
$NODE_DIR/bin/geth attach --exec \
  'console.log(admin.nodeInfo.enode)' \
  $NODE_DIR/nodedata/geth.ipc

# 记录当前 block number（升级后用于验证同步）
$NODE_DIR/bin/geth attach --exec \
  'console.log(eth.blockNumber)' \
  $NODE_DIR/nodedata/geth.ipc
```

---

## 3. Docker 环境准备

### 3.1 构建 abcore-v2 镜像

在部署机（或 CI）上执行一次，产出的镜像分发到各验证机：

```bash
# REPO_DIR 为 abcore-v2 代码仓库路径，根据实际情况修改
export REPO_DIR=/opt/abcore-v2-repo

# 方式 A：在验证机上直接构建（约 10 分钟）
docker build -t abcore-v2:<tag> $REPO_DIR

# 方式 B：导出镜像，传输后导入（推荐用于多台验证机）
# 构建机执行：
docker build -t abcore-v2:<tag> $REPO_DIR
docker save abcore-v2:<tag> | gzip > abcore-v2.tar.gz

# 验证机执行：
scp builder:/path/abcore-v2.tar.gz /tmp/
docker load < /tmp/abcore-v2.tar.gz
docker images | grep abcore
```

验证镜像：

```bash
docker run --rm abcore-v2:<tag> geth version
# 应输出 v2.x.x 版本信息
```

### 3.2 准备 Docker 目录结构

为每台验证机创建以下目录布局：

```
$DOCKER_DIR/
├── conf/
│   ├── config.toml      ← 从现有节点迁移并调整
│   ├── genesis.json     ← 生产环境 genesis 文件
│   └── password.txt     ← 解锁密码（权限设为 600）
├── nodedata/            ← 将现有 datadir bind mount 到此处
│   ├── keystore/        ← 来自原 v1 datadir
│   └── geth/            ← 来自原 v1 datadir（链数据）
└── docker-compose.yml
```

```bash
mkdir -p $DOCKER_DIR/{conf,nodedata}

# 拷贝 config 文件（必须与现有链数据匹配,注意原节点可能用的是node.toml）
cp $NODE_DIR/conf/node.toml $DOCKER_DIR/conf/config.toml
# 拷贝 genesis 文件（必须与现有链数据匹配）
cp $NODE_DIR/conf/abcore-testnet-genesis.json $DOCKER_DIR/conf/genesis.json

# 拷贝解锁密码文件
cp $NODE_DIR/password.txt $DOCKER_DIR/conf/password.txt
chmod 600 $DOCKER_DIR/conf/password.txt

# 修复 conf 目录权限（容器内 bsc 用户 uid=1000 需要读取权限）
docker run --rm -v "$DOCKER_DIR/conf:/conf" busybox chown -R 1000:1000 /conf
```

### 3.3 准备 config.toml

> **重要**：以下仅展示**需要修改或新增的字段**，不是完整配置文件。必须以第 3.2 节中 `cp $NODE_DIR/conf/node.toml $DOCKER_DIR/conf/config.toml` 迁移过来的完整配置为基础进行修改，保留其中的 `[Eth]`（含 `NetworkId = 26888`、`SyncMode` 等）、`[Node.P2P]`（含 `StaticNodes`）等原有字段，否则节点将连错网络或丢失对等节点配置。

关键修改项如下：

```toml
# $DOCKER_DIR/conf/config.toml（在现有配置基础上修改下列字段）

# ⚠️  DataDir 必须是 [Node] 段落下的第一个字段（不可在它之前插入注释或空行）。
# 容器 entrypoint 通过 grep -A1 '\[Node\' 解析此值，若 DataDir 不是第一行则解析失败，
# 导致 genesis 在错误路径初始化。
[Node]
DataDir = "/data"              # 容器内固定路径，与 Dockerfile 一致（已 chown bsc 用户）
NoUSB = true
HTTPHost = "0.0.0.0"
HTTPVirtualHosts = ["127.0.0.1", "localhost"]   # 生产环境限制访问
HTTPModules = ["eth", "net", "web3", "debug", "clique", "parlia", "txpool"]
WSHost = "0.0.0.0"
WSModules = ["eth", "net", "web3", "debug", "clique", "parlia", "txpool"]

[Node.P2P]
ListenAddr = ":33333"
```

> **说明**：`--allow-insecure-unlock` 标志由容器 entrypoint 在 `MINE=true` 时自动追加，无需在 config.toml 中重复设置 `InsecureUnlockAllowed`。
>
> **注意**：若 v1 配置中存在 `NewPayloadTimeout = 2000000000`，必须将其注释掉或删除。v2 的 `minerConfig` 中未定义该字段，保留会导致启动时 fatal error。

> **与本地开发配置的差异**：`NetworkId = 26888`，`HTTPVirtualHosts` 限制为已知 IP，`DatabaseCache` 根据服务器内存调整。

### 3.4 准备 docker-compose.yml

```bash
cat > $DOCKER_DIR/docker-compose.yml << 'EOF'
services:
  validator:
    # 无需指定 command：镜像 ENTRYPOINT（docker-entrypoint.sh）会自动读取
    # /bsc/config/config.toml，初始化 genesis（首次），然后启动 geth。
    image: abcore-v2:<tag>
    container_name: abcore-validator
    restart: unless-stopped
    environment:
      MINE: "true"
      MINER_ADDR: "${VALIDATOR_ADDR}"
      NAT: "extip:${PUBLIC_IP}"
    volumes:
      - ./conf:/bsc/config:ro
      - ./nodedata:/data
    ports:
      - "127.0.0.1:8545:8545"
      - "127.0.0.1:8546:8546"
      - "0.0.0.0:33333:33333"
      - "0.0.0.0:33333:33333/udp"
    healthcheck:
      test:
        - CMD-SHELL
        - >
          wget -qO-
          --post-data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}'
          --header 'Content-Type: application/json'
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

### 3.5 准备 .env 文件

从 keystore 文件名自动提取验证者地址和公网 IP，确认输出正确后写入：

```bash
# 自动获取验证者地址（从 keystore 文件名提取）和公网 IP
VALIDATOR_ADDR=0x$(ls $DOCKER_DIR/nodedata/keystore/ | head -1 | grep -oP '[0-9a-fA-F]{40}$')
PUBLIC_IP=$(curl -s ifconfig.me)

echo "VALIDATOR_ADDR=${VALIDATOR_ADDR}"
echo "PUBLIC_IP=${PUBLIC_IP}"

# 确认上面输出正确后执行写入
cat > $DOCKER_DIR/.env << EOF
VALIDATOR_ADDR=${VALIDATOR_ADDR}
PUBLIC_IP=${PUBLIC_IP}
EOF

chmod 600 $DOCKER_DIR/.env
cat $DOCKER_DIR/.env   # 验证内容
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

v2 与 v1 的数据格式完全兼容。将原 v1 datadir 中的全部数据迁移到 `./nodedata/`，与 docker-compose.yml 中 `./nodedata:/data` 的 bind mount 保持一致：

```bash
cd $DOCKER_DIR

# 创建数据目录（如尚未创建）
mkdir -p ./nodedata

# 将 v1 datadir 完整同步过来（含 keystore 和链数据）
rsync -av --progress $NODE_DIR/nodedata/ ./nodedata/

# rsync 完成后修复权限（容器内 bsc 用户 uid=1000 需要读写权限）
docker run --rm -v "$DOCKER_DIR/nodedata:/nodedata" busybox chown -R 1000:1000 /nodedata
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

## 7. 回滚方案

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

---

## 8. 故障排查

### 容器启动后立即退出

```bash
docker compose logs --tail=50
```

常见原因：

- `MINE=true` 但 `MINER_ADDR` 未设置 → entrypoint 打印明确错误并退出
- `conf/genesis.json` 缺失 → `geth init` 失败
- keystore 地址或密码错误 → `could not unlock account`

### 节点有 peers 但不出块

```bash
docker exec -it abcore-validator geth attach /data/geth.ipc
> eth.mining             # 若为 false，执行 miner.start()
> clique.getSnapshot("latest").signers  # 确认本节点地址在列表中
```

### P2P 连接数为 0

检查 `NAT` 环境变量是否设置为宿主机公网 IP（`extip:x.x.x.x`），并确认 33333 端口（TCP + UDP）在防火墙和安全组中开放。

### genesis.json 不匹配

若日志显示 `incompatible genesis`，说明 `conf/genesis.json` 与链数据中的 genesis 不符。必须使用**与现有链数据对应的原始 genesis 文件**（Chain ID 26888），不可使用本地 devnet 的测试 genesis（Chain ID 7140）。

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

# 强制重建镜像并重启
docker build -t abcore-v2:<tag> $REPO_DIR
docker compose -f $DOCKER_DIR/docker-compose.yml up -d

# 查看容器资源使用
docker stats abcore-validator
```