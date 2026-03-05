# 验证节点升级操作手册

## v1.13.15（Supervisor + 裸机）→ abcore-v2（Docker Compose）

**文档版本**: 1.0
**适用网络**: ABCore 主网（Chain ID 36888）
**共识机制**: Clique PoA

---

## 1. 升级概述

### 1.1 变更内容

| 维度 | 当前（v1） | 升级后（v2） |
|------|-----------|-------------|
| 客户端版本 | v1.13.15 | abcore-v2 |
| 进程管理 | Supervisor | Docker Compose |
| 部署方式 | 裸机二进制 | 容器镜像 |
| 数据目录 | `/opt/abcore/data`（或自定义路径） | Docker named volume 或 bind mount |
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
/opt/abcore/bin/geth attach --exec \
  'console.log("head:", eth.blockNumber, "peers:", admin.peers.length)' \
  /opt/abcore/data/geth.ipc

# 确认节点在 Clique 签名者列表中
/opt/abcore/bin/geth attach --exec \
  'console.log(JSON.stringify(clique.getSnapshot("latest").signers, null, 2))' \
  /opt/abcore/data/geth.ipc
```

### 2.2 备份

```bash
# 备份 keystore（最重要，不可恢复）
BACKUP_DIR="/opt/backup/abcore-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp -r /opt/abcore/data/keystore "$BACKUP_DIR/"
cp /opt/abcore/config/config.toml  "$BACKUP_DIR/"
cp /opt/abcore/config/password.txt "$BACKUP_DIR/"   # 如有独立密码文件

# 验证备份完整性
ls -la "$BACKUP_DIR/keystore/"
echo "Backup location: $BACKUP_DIR"
```

> **注意**：chaindata 不需要备份——v2 可直接使用现有链数据。

### 2.3 收集节点信息

在升级前记录以下信息，回滚时需要：

```bash
# 记录验证节点地址
cat /opt/abcore/data/address.txt
# 或从 keystore 文件名获取
ls /opt/abcore/data/keystore/

# 记录当前 enode
/opt/abcore/bin/geth attach --exec \
  'console.log(admin.nodeInfo.enode)' \
  /opt/abcore/data/geth.ipc

# 记录当前 block number（升级后用于验证同步）
/opt/abcore/bin/geth attach --exec \
  'console.log(eth.blockNumber)' \
  /opt/abcore/data/geth.ipc
```

---

## 3. Docker 环境准备

### 3.1 构建 abcore-v2 镜像

在部署机（或 CI）上执行一次，产出的镜像分发到各验证机：

```bash
# 方式 A：在验证机上直接构建（约 10 分钟）
cd /opt/abcore-v2-repo
docker build -t abcore:v2 .

# 方式 B：导出镜像，传输后导入（推荐用于多台验证机）
# 构建机执行：
docker build -t abcore:v2 .
docker save abcore:v2 | gzip > abcore-v2.tar.gz

# 验证机执行：
scp builder:/path/abcore-v2.tar.gz /tmp/
docker load < /tmp/abcore-v2.tar.gz
docker images | grep abcore
```

验证镜像：

```bash
docker run --rm abcore:v2 geth version
# 应输出 v2.x.x 版本信息
```

### 3.2 准备 Docker 目录结构

为每台验证机创建以下目录布局：

```
/opt/abcore-docker/
├── config/
│   ├── config.toml      ← 从现有节点迁移并调整
│   ├── genesis.json     ← 生产环境 genesis 文件
│   └── password.txt     ← 解锁密码（权限设为 600）
├── data/                ← 将现有 datadir bind mount 到此处
│   ├── keystore/        ← 来自原 v1 datadir
│   └── geth/            ← 来自原 v1 datadir（链数据）
└── docker-compose.yml
```

```bash
mkdir -p /opt/abcore-docker/{config,data}
```

### 3.3 准备 config.toml

从现有节点配置迁移，关键修改项：

```toml
# /opt/abcore-docker/config/config.toml

[Eth]
NetworkId = 36888          # ABCore 主网 Chain ID
SyncMode = "full"
NoPruning = false
DatabaseCache = 2048       # 根据实际内存调整
TrieCleanCache = 512
TrieDirtyCache = 512
TrieTimeout = 360000000000
EnablePreimageRecording = false

[Eth.Miner]
GasCeil = 40000000
GasPrice = 1000000000
Recommit = 10000000000

[Node]
DataDir = "/data"          # 容器内固定路径，对应 Docker volume
# 生产验证节点需要 InsecureUnlockAllowed 以支持 --mine 账户解锁
# 仅在隔离网络或防火墙保护下使用
InsecureUnlockAllowed = true
NoUSB = true
IPCPath = "geth.ipc"
HTTPHost = "0.0.0.0"
HTTPPort = 8545
HTTPVirtualHosts = ["127.0.0.1", "localhost"]   # 生产环境限制访问
HTTPModules = ["eth", "net", "web3", "debug", "clique", "parlia", "admin"]
WSHost = "0.0.0.0"
WSPort = 8546
WSModules = ["eth", "net", "web3", "debug", "clique", "parlia", "admin"]

[Node.P2P]
MaxPeers = 50
NoDiscovery = false
ListenAddr = ":30303"
EnableMsgEvents = false

[Node.HTTPTimeouts]
ReadTimeout = 30000000000
WriteTimeout = 30000000000
IdleTimeout = 120000000000
```

> **与本地开发配置的差异**：`NetworkId = 36888`，`HTTPVirtualHosts` 限制为已知 IP，`DatabaseCache` 根据服务器内存调整。

### 3.4 准备 docker-compose.yml

```yaml
# /opt/abcore-docker/docker-compose.yml

services:
  validator:
    image: abcore:v2
    container_name: abcore-validator
    restart: unless-stopped
    environment:
      MINE: "true"
      MINER_ADDR: "${VALIDATOR_ADDR}"       # 从 .env 读取
      NAT: "extip:${PUBLIC_IP}"             # 宿主机公网 IP
    volumes:
      - ./config:/bsc/config:ro             # config.toml + genesis.json + password.txt
      - ./data:/data                        # keystore + chain state（bind mount）
    ports:
      - "127.0.0.1:8545:8545"              # HTTP RPC（仅本机，通过 nginx/代理暴露）
      - "127.0.0.1:8546:8546"              # WebSocket
      - "0.0.0.0:30303:30303"              # P2P TCP（必须对外开放）
      - "0.0.0.0:30303:30303/udp"          # P2P UDP
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
```

### 3.5 准备 .env 文件

```bash
# /opt/abcore-docker/.env
VALIDATOR_ADDR=0x<你的验证节点地址>
PUBLIC_IP=<宿主机公网IP>
```

```bash
chmod 600 /opt/abcore-docker/.env
chmod 600 /opt/abcore-docker/config/password.txt
```

---

## 4. 单节点升级步骤（滚动升级）

**每次只对一台验证机执行此章节的完整流程，确认出块后再继续下一台。**

### 步骤 1：暂停 Supervisor 管理的 v1 进程

```bash
# 记录停机前的 block number
STOP_BLOCK=$(
  /opt/abcore/bin/geth attach --exec 'eth.blockNumber' \
  /opt/abcore/data/geth.ipc
)
echo "Stopping at block: $STOP_BLOCK"

# 停止 v1 进程（graceful shutdown）
supervisorctl stop abcore

# 确认进程已退出（等待 geth.ipc 消失）
timeout 30 bash -c 'while [ -e /opt/abcore/data/geth.ipc ]; do sleep 1; done'
echo "v1 process stopped"
```

### 步骤 2：迁移数据目录

v2 与 v1 的数据格式完全兼容。将原 v1 datadir 中的全部数据迁移到 `./data/`，与 docker-compose.yml 中 `./data:/data` 的 bind mount 保持一致：

```bash
cd /opt/abcore-docker

# 创建数据目录（如尚未创建）
mkdir -p ./data

# 将 v1 datadir 完整同步过来（含 keystore 和链数据）
rsync -av --progress /opt/abcore/data/ ./data/
```

### 步骤 3：启动 Docker 容器

```bash
cd /opt/abcore-docker

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
/opt/abcore/bin/geth attach --exec \
  'JSON.stringify(clique.getSnapshot("latest").recents)' \
  /opt/abcore/data/geth.ipc
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
cd /opt/abcore-docker
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
/opt/abcore/bin/geth attach --exec \
  'console.log(eth.blockNumber, admin.peers.length)' \
  /opt/abcore/data/geth.ipc
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
- `config/genesis.json` 缺失 → `geth init` 失败
- keystore 地址或密码错误 → `could not unlock account`

### 节点有 peers 但不出块

```bash
docker exec -it abcore-validator geth attach /data/geth.ipc
> eth.mining             # 若为 false，执行 miner.start()
> clique.getSnapshot("latest").signers  # 确认本节点地址在列表中
```

### P2P 连接数为 0

检查 `NAT` 环境变量是否设置为宿主机公网 IP（`extip:x.x.x.x`），并确认 30303 端口（TCP + UDP）在防火墙和安全组中开放。

### genesis.json 不匹配

若日志显示 `incompatible genesis`，说明 `config/genesis.json` 与链数据中的 genesis 不符。必须使用**与现有链数据对应的原始 genesis 文件**（Chain ID 36888），不可使用本地 devnet 的测试 genesis（Chain ID 7140）。

---

## 9. 常用运维命令

```bash
# 查看实时日志
docker compose -f /opt/abcore-docker/docker-compose.yml logs -f

# 进入 geth console
docker exec -it abcore-validator geth attach /data/geth.ipc

# 重启节点
docker compose -f /opt/abcore-docker/docker-compose.yml restart validator

# 停止节点
docker compose -f /opt/abcore-docker/docker-compose.yml down

# 强制重建镜像并重启
docker build -t abcore:v2 /opt/abcore-v2-repo
docker compose -f /opt/abcore-docker/docker-compose.yml up -d

# 查看容器资源使用
docker stats abcore-validator
```
