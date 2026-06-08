# ABCore v2 节点部署与升级手册（Docker）

**文档版本**: 2.0
**适用版本**: abcore-v2
**支持网络**: ABCore 测试网（Chain ID 26888）/ ABCore 主网（Chain ID 36888）
**受众**: ops / devops

> 本手册合并了原 `node-deployment-v2.md`（全新部署）与 `validator-upgrade-v1-to-v2.md`（v1 → v2 在线迁移），按**起点**分情况组织。本手册仅覆盖**纯 Clique 阶段**的部署与二进制升级（Phase 1）。
> - **Phase 2 共识激活**（写入 `ParliaGenesisBlock = N` 切换到 Parlia）：见 [fork-cutover-runbook.md](fork-cutover-runbook.md)。
> - **Phase 2 失败回滚**：见 [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md)。
> - **testnet / mainnet 整体升级编排（devops）**：见 [testnet-upgrade-plan.md](testnet-upgrade-plan.md)。

> **快速设置环境变量**：执行以下命令将路径变量写入 `~/.bashrc`，重新登录后仍然有效。根据实际环境修改后执行：
>
> ```bash
> cat >> ~/.bashrc << 'EOF'
> export NETWORK="testnet"                 # testnet 或 mainnet
> export DATADIR="/data/abcore-v2/testnet" # v2 节点数据目录（含 keystore 和链数据）
> export DOCKER_DIR="/data/abcore-docker"  # v2 Docker Compose 部署根目录（仅迁移场景用）
> export NODE_DIR="/data/abcore/testnet"   # v1 裸机节点根目录（仅 v1 迁移场景用）
> export TAG="vX.Y.Z"                      # abcore-v2 镜像 tag
> EOF
> source ~/.bashrc
> ```

---

## 0. 你的起点是什么？（决策路由）

根据当前节点状态选择路径。先用下面的命令判定：

```bash
# 当前用的什么 binary / 进程管理器？
geth version 2>/dev/null || docker ps --format '{{.Image}}' | grep abcore   # v1 裸机会有本地 geth；v2 是容器镜像
systemctl is-active supervisor 2>/dev/null; ls /etc/supervisor/conf.d/ 2>/dev/null   # 有 supervisor conf → v1 裸机

# 链是否已切到 Parlia？（任意节点 geth console / attach）
# 期望 null = 仍是纯 Clique；非 null = 已配置 PGB，本手册不适用，转 fork-cutover / rollback runbook
admin.nodeInfo.protocols.eth.config.parliaGenesisBlock
```

| 你的起点 | 走哪一节 |
|---|---|
| **A. 全新节点**（无现存数据，要新建 RPC 或 validator） | → [§2 全新节点部署](#2-全新节点部署greenfield) |
| **B. 现存 v1.13.15 裸机 + Supervisor** | → [§3 v1 → v2 在线迁移](#3-v11315-裸机--v2-docker-在线迁移phase-1仍-clique) |
| **C. 已是某 v2 Docker（PGB=nil）**，只需换 tag | → [§4 v2 Docker 滚动换 tag](#4-已是-v2-docker滚动换-tag) |

> 所有涉及多 validator 重启的操作（§3 / §4）都必须**滚动**进行，绝不同时重启超过 `floor(V/2)` 个 validator——原因见 [§5 Seal-race 死锁](#5-seal-race-死锁recents-机制所有路径通用)。

---

## 1. 概述与通用约定

ABCore v2 节点有两种角色，使用**相同镜像**，通过数据目录内容自动区分：

| 角色 | 说明 | 出块 |
|------|------|------|
| **RPC 节点** | 同步链数据，提供 RPC/WS 接口 | 否 |
| **验证者节点** | 在 RPC 节点基础上解锁账户、参与 Clique PoA 出块 | 是 |

- **公网 IP**：启动时自动检测，无需手动设置（如需手动指定见 [§6.3](#63-p2p-连接数为-0)）。
- **验证者模式**：检测到 `/data/keystore/` 有文件且 `/data/password.txt` 存在时自动启用，地址从 keystore 文件名提取。
- Bootstrap 节点、创世区块、链配置均已**硬编码进二进制**（`--abcore.testnet` / `--abcore` flag），无需外部文件。

### 1.1 端口说明

| 端口 | 协议 | 用途 | 对外开放 |
|------|------|------|---------|
| 8545 | HTTP | JSON-RPC | 按需（默认仅本机） |
| 8546 | WS | WebSocket RPC | 按需（默认仅本机） |
| 33333 | TCP+UDP | P2P 节点发现与同步 | **必须** |

> **安全提示**：`debug` RPC 命名空间包含 `debug_setHead`（可远程回滚链头）等高危接口，**不得对外网暴露**。默认启动命令不包含 `debug`；仅归档节点在内网/受信环境下按需开启（见 [§2.6](#26-rpc-节点启动)）。

### 1.2 宿主机数据目录布局

```
$DATADIR/              ← bind mount → 容器 /data
├── keystore/          ← 验证者 keystore（验证者节点必须）
│   └── UTC--...
├── geth/              ← 链数据（首次启动自动初始化）
└── password.txt       ← keystore 解锁密码（验证者节点必须，权限 600）
```

---

## 2. 全新节点部署（greenfield）

### 2.1 节点角色与类型

- **RPC 归档节点**（full sync + archive）：存储完整历史状态，支持任意高度的 `eth_call` / `debug_traceTransaction`。
- **RPC 同步节点**（snap sync，剪枝）：仅保留近期状态，磁盘小、同步快，不支持历史状态查询。
- **验证者节点**：在 RPC 节点基础上持有 keystore 并解锁，参与 Clique 出块（见 [§2.7](#27-验证者节点启动)）。

### 2.2 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Ubuntu 24.04 LTS x86_64 |
| CPU | 2 核以上 |
| 内存 | 16 GB RAM |
| 磁盘（归档节点） | 500 GB+ SSD（`/data` 挂载点） |
| 磁盘（同步节点） | 200 GB+ SSD（`/data` 挂载点） |
| 网络 | 固定公网 IP，33333 端口 TCP+UDP 可达 |

```bash
# 安装 Docker Engine 24+（含 Compose v2 子命令 docker compose）
curl -fsSL https://get.docker.com | sh
```

### 2.3 获取镜像

```bash
# 方式 A：从 Docker Hub 拉取（推荐）
docker pull abfoundation/abcore-v2:${TAG}

# 方式 B：本地构建（REPO_DIR 为代码仓库路径）
docker build -t abfoundation/abcore-v2:$TAG $REPO_DIR

# 方式 C：离线导入（多机且无法访问 GitHub 时）
docker save abfoundation/abcore-v2:$TAG | gzip > abcore-v2.tar.gz   # 构建机导出
docker load < abcore-v2.tar.gz                                      # 目标机导入
```

验证镜像：

```bash
docker run --rm --entrypoint geth abfoundation/abcore-v2:$TAG version
```

> **升级换 tag 时**：始终重新 `docker pull`，不要凭 `docker images | grep` 判断已存在就跳过——同名 tag 被重推后旧镜像仍在本地缓存会导致跑到旧 binary。

### 2.4 RPC 节点启动

**归档节点**（full sync，全量历史状态）：

```bash
mkdir -p $DATADIR

docker run -d \
  --name abcore-$NETWORK \
  --restart unless-stopped \
  -v $DATADIR:/data \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  -p 0.0.0.0:33333:33333 \
  -p 0.0.0.0:33333:33333/udp \
  -e NETWORK=$NETWORK \
  abfoundation/abcore-v2:$TAG \
  --port 33333 \
  --http --http.addr 0.0.0.0 --http.port 8545 \
         --http.vhosts localhost \
         --http.api 'txpool,net,web3,eth' \
  --ws   --ws.addr 0.0.0.0   --ws.port 8546 \
         --ws.api 'txpool,net,web3,eth' \
  --syncmode full \
  --gcmode archive
```

**同步节点**（snap sync，剪枝模式）：在归档命令基础上**去掉** `--syncmode full --gcmode archive` 两个参数即可。

> **如需 `debug_traceTransaction` 等调试接口**（区块链浏览器、链上分析等场景）：确认 8545/8546 端口**不对外网暴露**后，将 `--http.api` / `--ws.api` 改为 `'debug,txpool,net,web3,eth'`。`debug` 命名空间含 `debug_setHead` 等高危接口，对外暴露将允许任意方远程回滚节点链头。

**验证同步**：

```bash
docker exec abcore-$NETWORK geth attach \
  --exec 'console.log("block:", eth.blockNumber, "peers:", admin.peers.length)' \
  /data/geth.ipc
# 区块高度持续增长、peers >= 1 即为正常
```

### 2.5 keystore 准备（验证者节点）

**情况 A：已有 keystore**

```bash
mkdir -p $DATADIR/keystore
cp /path/to/UTC--...      $DATADIR/keystore/
cp /path/to/password.txt  $DATADIR/password.txt
chmod 600 $DATADIR/password.txt
```

**情况 B：新建账户**

```bash
mkdir -p $DATADIR
docker run --rm -it --entrypoint geth \
  -v $DATADIR:/data \
  abfoundation/abcore-v2:$TAG \
  account new --datadir /data
# keystore 文件自动生成在 $DATADIR/keystore/UTC--...

echo "YOUR_KEYSTORE_PASSWORD" > $DATADIR/password.txt
chmod 600 $DATADIR/password.txt
```

### 2.6 验证者节点启动

> **前提**：验证者地址须已经过现有授权验证者 `clique.propose` 投票并写入 checkpoint 才能实际出块。建议先以 RPC 节点模式同步至链头，再切换为验证者模式。

keystore 与 password.txt 就位后，用 [§2.4](#24-rpc-节点启动) 的归档节点命令直接启动（容器自动检测并开启验证者模式，建议容器名加 `-validator` 后缀）。启动日志会打印：

```
INFO: keystore and password found, enabling validator mode automatically
INFO: using validator address 0x...
INFO: detected public IP x.x.x.x, setting NAT automatically
```

**验证出块**：

```bash
docker exec -it abcore-$NETWORK-validator geth attach /data/geth.ipc
> eth.mining                               # 应为 true
> clique.getSnapshot("latest").signers     # 确认本节点地址在列表中
> clique.getSnapshot("latest").recents     # 出块后应出现本节点地址
```

### 2.7 高级调优（node.toml，可选）

如需调整 TxPool 限额、gas、RPC 超时、MaxPeers 等细项，可用配置文件覆盖。仓库提供模板 `script/release/configs/{testnet,mainnet}/node.toml`：

```bash
cp /path/to/abcore-v2/script/release/configs/$NETWORK/node.toml $DATADIR/node.toml
# docker run 时加 -e BSC_CONFIG=/data/node.toml（其余参数不变）
```

> **注意**：命令行参数优先级高于配置文件。`--syncmode` / `--gcmode` 等命令行显式参数会覆盖配置文件同名项。

### 2.8 使用 Docker Compose

确认 `TAG`、`DATADIR` 已设置后：

```bash
cd /path/to/abcore-v2/script/release/configs/$NETWORK
docker compose up -d
docker compose logs -f --tail=50
```

### 2.9 提案成为新签名者（Clique 阶段）

```bash
# 在已授权验证者节点的 geth console 中执行：
> clique.propose("0xNewValidatorAddress", true)
```

超过半数签名者投票通过，并在下一个 epoch checkpoint（每 30,000 块）写入链上后生效。

---

## 3. v1.13.15 裸机 → v2 Docker 在线迁移（Phase 1，仍 Clique）

将现存 v1（Supervisor + 裸机）验证节点迁移到 v2（Docker Compose），链仍处于纯 Clique 阶段（`ParliaGenesisBlock = nil`）。

### 3.1 变更内容与兼容性

| 维度 | 当前（v1） | 升级后（v2） |
|------|-----------|-------------|
| 客户端版本 | v1.13.15 | abcore-v2 |
| 进程管理 | Supervisor | Docker Compose |
| 部署方式 | 裸机二进制 | 容器镜像 |
| 数据目录 | `$NODE_DIR/nodedata` | bind mount 到容器 `/data` |
| 配置文件 | 独立 `config.toml` | 启动参数直接传入，可选 `node.toml` 调优 |
| Genesis / Bootstrap | 独立文件 | **已内置于二进制** |

**兼容性保证**：v2 二进制与 v1 **数据目录完全兼容**——同一个 datadir 可直接被 v2 读取，无需数据迁移或重新同步。这是滚动升级的基础。chaindata 不需要备份（可从网络重新同步）；keystore 必须备份。

### 3.2 Clique 滚动升级约束

Clique PoA 要求超过半数签名者（`floor(N/2) + 1`）在线才能继续出块。升级策略必须确保**任何时刻在线验证节点数量不低于出块门槛**：

| 总签名者数 N | 最小在线数 | 每次最多同时停机 |
|------------|-----------|----------------|
| 3 | 2 | 1 |
| 4 | 3 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

> **关键原则**：每次只升级一个节点，等它重新出块后再升级下一个。详见 [§5 Seal-race 死锁](#5-seal-race-死锁recents-机制所有路径通用)。

### 3.3 升级前检查与备份

**前提条件**：操作机 Docker Engine 24+ / Compose v2，宿主机有 sudo/root，已克隆 abcore-v2 仓库或有预构建镜像。验证机当前 supervisor 管理的 geth 正常出块，至少 3 小时内无重组/告警。

**检查当前状态 + 收集回滚信息**（在每台验证机执行，全部为只读）：

```bash
# v1 进程状态
supervisorctl status abcore

# 当前 head / peers / 签名者集合
$NODE_DIR/bin/geth attach --exec \
  'console.log("head:", eth.blockNumber, "peers:", admin.peers.length)' \
  $NODE_DIR/nodedata/geth.ipc
$NODE_DIR/bin/geth attach --exec \
  'console.log(JSON.stringify(clique.getSnapshot("latest").signers, null, 2))' \
  $NODE_DIR/nodedata/geth.ipc

# 记录验证节点地址、enode、当前 block（回滚 / 手动加 peer 时用）
ls $NODE_DIR/nodedata/keystore/
$NODE_DIR/bin/geth attach --exec 'console.log(admin.nodeInfo.enode)' $NODE_DIR/nodedata/geth.ipc
$NODE_DIR/bin/geth attach --exec 'admin.peers.forEach(function(p){ console.log(p.enode) })' \
  $NODE_DIR/nodedata/geth.ipc
```

**备份 keystore（最重要，不可恢复）**：

```bash
BACKUP_DIR="/data/backup/abcore-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r $NODE_DIR/nodedata/keystore "$BACKUP_DIR/"
cp $NODE_DIR/password.txt "$BACKUP_DIR/"   # 如有独立密码文件
ls -la "$BACKUP_DIR/keystore/"
echo "Backup location: $BACKUP_DIR"
```

### 3.4 准备 Docker 环境

镜像获取见 [§2.3](#23-获取镜像)。准备目录结构与 compose 文件：

```bash
mkdir -p $DOCKER_DIR/nodedata
cp $NODE_DIR/password.txt $DOCKER_DIR/nodedata/password.txt
chmod 600 $DOCKER_DIR/nodedata/password.txt

cat > $DOCKER_DIR/docker-compose.yml << 'EOF'
services:
  validator:
    image: abfoundation/abcore-v2:${TAG}
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

### 3.5 单节点迁移步骤（滚动）

**每次只对一台验证机执行完整流程，确认出块后再继续下一台。**

```bash
# 步骤 1：暂停 Supervisor 管理的 v1 进程
STOP_BLOCK=$($NODE_DIR/bin/geth attach --exec 'eth.blockNumber' $NODE_DIR/nodedata/geth.ipc)
echo "Stopping at block: $STOP_BLOCK"
supervisorctl stop abcore
timeout 30 bash -c "while [ -e $NODE_DIR/nodedata/geth.ipc ]; do sleep 1; done"
echo "v1 process stopped"

# 步骤 2：迁移数据目录（v2 与 v1 数据格式完全兼容）
cd $DOCKER_DIR
rsync -av --progress $NODE_DIR/nodedata/ ./nodedata/
cp $NODE_DIR/password.txt ./nodedata/password.txt
chmod 600 ./nodedata/password.txt

# 步骤 3：启动 Docker 容器
docker compose up -d
docker compose logs -f --tail=50
docker compose ps

# 步骤 4：验证同步与出块
docker exec -it abcore-validator geth attach /data/geth.ipc
#   > eth.blockNumber        # 应大于停机时记录的 $STOP_BLOCK
#   > admin.peers.length     # 应 >= 1
#   > clique.getSnapshot("latest").recents  # 出几个块后应出现本节点地址
#   > eth.mining             # 应为 true

# 步骤 5：观察 ≥10 分钟持续出块后，停用 supervisor 配置防止意外重启 v1
mv /etc/supervisor/conf.d/abcore.conf /etc/supervisor/conf.d/abcore.conf.disabled
supervisorctl update
```

### 3.6 多节点滚动顺序（3 节点示例）

```
初始状态:  [V1 v1] [V2 v1] [V3 v1]   → 出块正常
第 1 轮:   停 V1 → 起 Docker → 确认出块    [V1 v2↑] [V2 v1] [V3 v1]
第 2 轮:   停 V2 → 起 Docker → 确认出块    [V1 v2] [V2 v2↑] [V3 v1]
第 3 轮:   停 V3 → 起 Docker → 确认出块    [V1 v2] [V2 v2] [V3 v2↑]  ✓
```

> **4 节点特别说明**：Clique 4 签名者出块门槛为 3，任何时刻必须至少 3 个验证节点在线（最多 1 台离线），同样逐台滚动。

### 3.7 迁移后验证清单

在**所有节点**迁移完毕后执行：

```bash
docker exec abcore-validator geth attach --exec 'eth.blockNumber' /data/geth.ipc       # 各节点一致
docker exec abcore-validator geth attach --exec 'admin.peers.length' /data/geth.ipc    # 数量正常
docker exec abcore-validator geth attach \
  --exec 'JSON.stringify(Object.keys(clique.getSnapshot("latest").signers))' /data/geth.ipc  # 签名者正确
docker exec abcore-validator geth version                                              # v2 版本号
# 链持续推进（每 ~3 秒递增）
for i in 1 2 3; do docker exec abcore-validator geth attach --exec 'eth.blockNumber' /data/geth.ipc; sleep 4; done
```

**完成检查点**

- [ ] 所有验证节点升级至 abcore-v2 Docker 部署
- [ ] 全网 block number 一致，无停链
- [ ] 各节点 `clique.getSnapshot` 签名者集合正确
- [ ] Supervisor v1 进程已停用
- [ ] keystore 备份安全存储
- [ ] 监控告警指向 Docker 容器（更新 Prometheus / 健康检查端点）

### 3.8 回滚到 v1（仅适用于仍处于 Clique 阶段）

若 v2 容器启动后出现同步异常或停止出块：

```bash
cd $DOCKER_DIR
docker compose down
docker compose logs --tail=100                # 检查错误日志
mv /etc/supervisor/conf.d/abcore.conf.disabled /etc/supervisor/conf.d/abcore.conf
supervisorctl update && supervisorctl start abcore
supervisorctl status abcore
$NODE_DIR/bin/geth attach --exec \
  'console.log(eth.blockNumber, admin.peers.length)' $NODE_DIR/nodedata/geth.ipc
```

> v2 与 v1 使用同一 datadir 格式，v2 写入的块数据对 v1 完全可读，回滚后 v1 从当前 head 继续同步。
>
> **重要**：若链已经跨过 `ParliaGenesisBlock`，**不要**套用本节。此时应停下所有验证节点与关键 RPC 节点，按 [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md) 执行“回退到 `N-1` 并恢复 pure Clique”的协调式回滚。

---

## 4. 已是 v2 Docker：滚动换 tag

链仍处于纯 Clique 阶段、节点已是 v2 Docker，仅需统一/升级到新 binary tag。

```bash
# 1. 确认仍是纯 Clique（每个节点）
docker exec abcore-validator geth attach \
  --exec 'admin.nodeInfo.protocols.eth.config.parliaGenesisBlock' /data/geth.ipc
# 期望 null

# 2. 拉新镜像（始终强制 pull，勿凭 grep 跳过，见 §2.3 提示）
docker pull abfoundation/abcore-v2:$TAG

# 3. 逐个 validator 滚动替换（遵守 §3.2 滚动约束）：停一个 → up -d 新 tag → 等健康出块 → 下一个
cd $DOCKER_DIR
docker compose up -d        # compose 内 image tag 取自 $TAG
docker compose logs -f --tail=50
# 健康判据同 §3.5 步骤 4
```

> validator 仍按 [§3.2](#32-clique-滚动升级约束) / [§5](#5-seal-race-死锁recents-机制所有路径通用) 的滚动约束逐台进行，绝不批量重启。RPC 节点无出块约束，可随时单独替换，但建议保持 ≥1 个 RPC 在线对外服务。

---

## 5. Seal-race 死锁（Recents 机制，所有路径通用）

> 本节是 ABCore 全部升级路径（二进制升级、共识切换、回滚、配置变更）共用的 `Recents` 机制权威说明。Phase 2 共识激活那一步的**致命特例**（Clique-form 块 N 被 Parlia 引擎拒绝导致永久死锁）见 [fork-cutover-runbook.md §2](fork-cutover-runbook.md#2-stop-window-race必须了解的故障模式)。

### 5.1 什么是 seal-race deadlock

Clique（以及 Parlia）通过 `Recents` 滑动窗口防止双签：签署了 block N 的验证节点在 block `N + floor(V/2) + 1` 之前不能再次签署（V = 验证节点数量）。

当至少 `floor(V/2) + 1` 个验证节点**从相同的链顶端同时重启**时，它们都会在看到对方出块之前尝试签署下一个块。竞争性签署会污染内存中的 `Recents` 缓存——每个验证节点都认为自己"刚签过"而拒绝继续出块，形成**永久性死锁**。

### 5.2 触发条件

**同时重启的验证节点数量 >= floor(V/2) + 1** 时触发：

| 验证节点数量 | 触发死锁的阈值 | 风险等级 |
|---|---|---|
| 3 | 2 个同时重启 | **高** — 非常容易触发 |
| 5 | 3 个同时重启 | 中等 |
| 21（BSC 主网） | 11 个同时重启 | 可忽略 |
| 45 | 23 个同时重启 | 可忽略 |

验证节点越少越脆弱。3 节点网络极其容易触发。

### 5.3 恢复方法

**方法 1（推荐）：逐个重启。** 停止所有验证节点，逐一启动。第一个独自开始出块，第二个从第一个同步、获得干净 `Recents` 后出块，以此类推。此方法总是成功。

**方法 2：全部停止、全部重启。** 重启后验证节点从磁盘加载 snapshot（非被污染的内存缓存），新链顶端改变 Clique 轮次使不同节点获得优先出块权。通常首次重试即可恢复，可能需要 2-3 次。

### 5.4 受影响的所有路径

`Recents` 机制存在于 Clique 和 Parlia 两种引擎中：

| 升级步骤 | 共识引擎 | 受影响？ |
|---|---|---|
| v1 二进制 → v2 二进制（PGB=nil，纯 Clique） | Clique | 是 |
| v2（PGB=nil）→ v2（PGB=N，block N 之前仍为 Clique） | Clique | 是 |
| v2（PGB=N，block N 之后为 Parlia），后续二进制升级 | Parlia | 是 |
| 从 Parlia 回滚到 Clique | Clique | 是 |

**通用约束：永远不要同时重启超过 `floor(V/2)` 个验证节点。** 始终滚动重启：停一个 → 起新版本 → 确认成功出块 → 下一个。若不得不批量重启（如紧急回滚），做好链停滞后用方法 1 恢复的准备。

---

## 6. 故障排查 & 常用运维命令

> 容器名按部署方式不同：`docker run` 部署为 `abcore-$NETWORK` / `abcore-$NETWORK-validator`；Docker Compose 部署为 `abcore-validator`。下文以实际部署为准替换。

### 6.1 容器启动后立即退出

```bash
docker logs --tail=100 <container>            # 或 docker compose logs --tail=100
```

| 错误信息 | 原因 | 解决方法 |
|---------|------|---------|
| `NETWORK must be testnet or mainnet` | NETWORK 值不合法 | 检查 `-e NETWORK=` / compose `NETWORK:` 配置 |
| `no keystore file found in /data/keystore/` | keystore 目录为空 | 确认 keystore 文件已放入数据目录 `keystore/` |
| `password file not found` | 密码文件缺失 | 确认数据目录 `password.txt` 存在且权限 600 |
| `could not unlock account` | keystore 与密码不匹配 | 检查 keystore 文件名末尾地址与密码是否对应 |
| `mkdir /data/geth: permission denied` | 数据目录权限不足 | `sudo chown -R $(id -u):$(id -g) $DATADIR` |

### 6.2 节点有 peers 但不出块

```bash
docker exec -it <container> geth attach /data/geth.ipc
> eth.mining                            # 若为 false，检查 keystore/password.txt 是否存在于数据目录
> clique.getSnapshot("latest").signers  # 确认本节点地址是否在授权列表中
```

### 6.3 P2P 连接数为 0

1. 确认 33333 端口（TCP + UDP）在防火墙/安全组中已开放。
2. 检查启动日志是否有 `detected public IP` — 若无，手动指定：`docker run` 加 `-e NAT=extip:<PUBLIC_IP>`，compose 在 `environment` 加 `NAT: "extip:<PUBLIC_IP>"`。
3. 手动添加 bootstrap / 已知节点：
   ```bash
   docker exec -it <container> geth attach /data/geth.ipc
   > admin.addPeer("enode://...")
   ```
   > v2 容器首次启动 peers 缓存为空，连接数可能短暂偏低，属正常。若 >10 分钟仍为 0 再手动加 peer。

### 6.4 常用命令

```bash
# 实时日志
docker logs -f <container>                        # 或 docker compose -f $DOCKER_DIR/docker-compose.yml logs -f
# geth console
docker exec -it <container> geth attach /data/geth.ipc
# 区块高度
docker exec <container> geth attach --exec 'eth.blockNumber' /data/geth.ipc
# 停止 / 重启（数据完整保留）
docker stop <container>;  docker restart <container>
# 升级镜像（run 部署）：docker stop && docker rm，再以新 TAG 重新 docker run
# 升级镜像（compose 部署）：docker compose pull && docker compose up -d
# 资源使用 / 版本
docker stats <container>;  docker exec <container> geth version
```

### 6.5 备份建议

| 文件 | 重要性 | 说明 |
|------|--------|------|
| `keystore/` | **极高**（不可恢复） | 验证者私钥 |
| `password.txt` | 高 | keystore 解锁密码 |
| `geth/`（链数据） | 低 | 可从网络重新同步 |

```bash
BACKUP_DIR="/data/backup/abcore-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r $DATADIR/keystore "$BACKUP_DIR/"
cp $DATADIR/password.txt "$BACKUP_DIR/"
echo "Backup saved to: $BACKUP_DIR"
```

> 升级前的**全量 datadir 快照**（含链数据，用于硬分叉回滚）规程见 [devnet-upgrade-plan.md 快照规程](devnet-upgrade-plan.md) 与 [testnet-upgrade-plan.md](testnet-upgrade-plan.md)。本节备份仅覆盖 keystore/密码这类不可恢复物。
