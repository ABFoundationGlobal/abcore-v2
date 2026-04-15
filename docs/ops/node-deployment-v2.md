# abcore-v2 节点部署手册（Docker）

**文档版本**: 1.3
**适用版本**: abcore-v2
**支持网络**: ABCore 测试网（Chain ID 26888）/ ABCore 主网（Chain ID 36888）

> **快速设置环境变量**：执行以下命令将路径变量写入 `~/.bashrc`，重新登录后仍然有效。根据实际环境修改后执行：
>
> ```bash
> cat >> ~/.bashrc << 'EOF'
> export NETWORK="testnet"                 # testnet 或 mainnet
> export DATADIR="/data/abcore-v2/testnet" # 节点数据目录（含 keystore 和链数据）
> export TAG="vX.Y.Z"                      # abcore-v2 镜像 tag
> EOF
> source ~/.bashrc
> ```

---

## 1. 概述

本手册介绍如何在生产环境中使用 Docker 部署 abcore-v2 节点，涵盖两种角色：

| 角色 | 说明 | 出块 |
|------|------|------|
| **RPC 节点** | 同步链数据，提供 RPC/WS 接口 | 否 |
| **验证者节点** | 在 RPC 节点基础上解锁账户、参与 Clique PoA 出块 | 是 |

两种角色使用**相同的镜像**，通过数据目录内容自动区分：

- **公网 IP**：启动时自动检测，无需手动设置
- **验证者模式**：检测到 `/data/keystore/` 有文件且 `/data/password.txt` 存在时自动启用，地址从 keystore 文件名提取

Bootstrap 节点、创世区块、链配置均已**硬编码进二进制**（`--abcore.testnet` / `--abcore` flag）。

### 1.1 端口说明

| 端口 | 协议 | 用途 | 对外开放 |
|------|------|------|---------|
| 8545 | HTTP | JSON-RPC | 按需（默认仅本机） |
| 8546 | WS | WebSocket RPC | 按需（默认仅本机） |
| 33333 | TCP+UDP | P2P 节点发现与同步 | **必须** |

> **安全提示**：`debug` RPC 命名空间包含 `debug_setHead`（可远程回滚链头）等高危接口，**不得对外网暴露**。默认启动命令不包含 `debug`；仅归档节点在内网/受信环境下按需开启（见 4.1 节说明）。

### 1.2 宿主机数据目录布局

```
$DATADIR/              ← bind mount → 容器 /data
├── keystore/          ← 验证者 keystore（验证者节点必须）
│   └── UTC--...
├── geth/              ← 链数据（首次启动自动初始化）
└── password.txt       ← keystore 解锁密码（验证者节点必须）
```

---

## 2. 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Ubuntu 24.04 LTS x86_64 |
| CPU | 2 核以上 |
| 内存 | 16 GB RAM |
| 磁盘（归档节点） | 500 GB+ SSD（`/data` 挂载点） |
| 磁盘（同步节点） | 200 GB+ SSD（`/data` 挂载点） |
| 网络 | 固定公网 IP，33333 端口 TCP+UDP 可达 |

```bash
# 安装 Docker Engine 24+
curl -fsSL https://get.docker.com | sh
```

---

## 3. 获取镜像

### 方式 A：从 GitHub Release 加载（推荐）

```bash
curl -L -o /tmp/abcore-v2-${TAG}-linux-amd64.tar.gz \
  https://github.com/ABFoundationGlobal/abcore-v2/releases/download/${TAG}/abcore-v2-${TAG}-linux-amd64.tar.gz

docker load < /tmp/abcore-v2-${TAG}-linux-amd64.tar.gz
```

### 方式 B：本地构建

```bash
docker build -t abfoundationglobal/abcore-v2:$TAG .
```

### 方式 C：离线导入

```bash
# 构建机导出
docker save abfoundationglobal/abcore-v2:$TAG | gzip > abcore-v2.tar.gz
# 目标机导入
docker load < abcore-v2.tar.gz
```

验证镜像：

```bash
docker run --rm --entrypoint geth abfoundationglobal/abcore-v2:$TAG version
```

---

## 4. RPC 节点部署

### 4.1 归档节点（full sync，全量历史状态）

存储完整历史状态，支持任意区块高度的 `eth_call` / `debug_traceTransaction` 等查询。

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
  abfoundationglobal/abcore-v2:$TAG \
  --port 33333 \
  --http --http.addr 0.0.0.0 --http.port 8545 \
         --http.vhosts localhost \
         --http.api 'txpool,net,web3,eth' \
  --ws   --ws.addr 0.0.0.0   --ws.port 8546 \
         --ws.api 'txpool,net,web3,eth' \
  --syncmode full \
  --gcmode archive
```

> **如需 `debug_traceTransaction` 等调试接口**（区块链浏览器、链上分析等场景）：确认 8545/8546 端口**不对外网暴露**后，将上述命令中的 `--http.api` 和 `--ws.api` 改为 `'debug,txpool,net,web3,eth'`。`debug` 命名空间包含 `debug_setHead` 等高危接口，对外暴露将允许任意方远程回滚节点链头。

### 4.2 同步节点（snap sync，剪枝模式）

仅保留近期状态，磁盘占用更小、同步更快，适合一般 RPC 服务。不支持历史状态查询（`debug_traceTransaction` 等）。
在归档节点的基础上去掉 `--syncmode full --gcmode archive` 两个参数：

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
  abfoundationglobal/abcore-v2:$TAG \
  --port 33333 \
  --http --http.addr 0.0.0.0 --http.port 8545 \
         --http.vhosts localhost \
         --http.api 'txpool,net,web3,eth' \
  --ws   --ws.addr 0.0.0.0   --ws.port 8546 \
         --ws.api 'txpool,net,web3,eth'
```

### 4.3 验证同步

```bash
docker exec abcore-$NETWORK geth attach \
  --exec 'console.log("block:", eth.blockNumber, "peers:", admin.peers.length)' \
  /data/geth.ipc

# 区块高度持续增长，peers >= 1 即为正常
```

### 4.4 高级调优（node.toml，可选）

如需调整 TxPool 限额、gas、RPC 超时、MaxPeers 等细项参数，可使用配置文件覆盖。
仓库提供现成模板：`script/release/configs/{testnet,mainnet}/node.toml`。

```bash
cp /path/to/abcore-v2/script/release/configs/$NETWORK/node.toml $DATADIR/node.toml
# 按需编辑 $DATADIR/node.toml
```

启动时加上 `-e BSC_CONFIG=/data/node.toml`（其余参数不变）：

```bash
docker run -d \
  ... \
  -e BSC_CONFIG=/data/node.toml \
  abfoundationglobal/abcore-v2:$TAG \
  --port 33333 \
  ...
```

> **注意**：命令行参数优先级高于配置文件。`--syncmode` / `--gcmode` 等在命令行中显式传入的参数，配置文件中的同名项不会生效。

### 4.5 使用 Docker Compose

确认 `TAG`、`DATADIR` 已设置（见文档顶部），直接启动：

```bash
cd /path/to/abcore-v2/script/release/configs/$NETWORK
docker compose up -d
docker compose logs -f --tail=50
```

---

## 5. 验证者节点部署

验证者节点在 RPC 节点基础上持有 keystore 账户，解锁后参与 Clique PoA 签名出块。

> **前提**：验证者地址须已经过现有授权验证者 `clique.propose` 投票并写入 checkpoint，才能实际出块。建议先以 RPC 节点模式同步至链头，再切换为验证者模式。

### 5.1 准备验证者账户

根据情况选择其中一种：

**情况 A：已有 keystore**

```bash
mkdir -p $DATADIR/keystore
cp /path/to/UTC--...  $DATADIR/keystore/
cp /path/to/password.txt $DATADIR/password.txt
chmod 600 $DATADIR/password.txt
```

**情况 B：新建账户**

```bash
mkdir -p $DATADIR
docker run --rm -it \
  --entrypoint geth \
  -v $DATADIR:/data \
  abfoundationglobal/abcore-v2:$TAG \
  account new --datadir /data
# keystore 文件自动生成在 $DATADIR/keystore/UTC--...

echo "YOUR_KEYSTORE_PASSWORD" > $DATADIR/password.txt
chmod 600 $DATADIR/password.txt
```

### 5.2 启动验证者节点

keystore 和 password.txt 就位后直接启动，容器自动检测并开启验证者模式：

```bash
docker run -d \
  --name abcore-$NETWORK-validator \
  --restart unless-stopped \
  -v $DATADIR:/data \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  -p 0.0.0.0:33333:33333 \
  -p 0.0.0.0:33333:33333/udp \
  -e NETWORK=$NETWORK \
  abfoundationglobal/abcore-v2:$TAG \
  --port 33333 \
  --http --http.addr 0.0.0.0 --http.port 8545 \
         --http.vhosts localhost \
         --http.api 'txpool,net,web3,eth' \
  --ws   --ws.addr 0.0.0.0   --ws.port 8546 \
         --ws.api 'txpool,net,web3,eth' \
  --syncmode full \
  --gcmode archive
```

启动日志中会打印自动检测结果：

```
INFO: keystore and password found, enabling validator mode automatically
INFO: using validator address 0x...
INFO: detected public IP x.x.x.x, setting NAT automatically
```

### 5.3 使用 Docker Compose

keystore 和 password.txt 就位后直接启动：

```bash
cd /path/to/abcore-v2/script/release/configs/$NETWORK
docker compose up -d
```

### 5.4 验证出块

```bash
docker exec -it abcore-$NETWORK-validator geth attach /data/geth.ipc

> eth.mining                               # 应为 true
> clique.getSnapshot("latest").signers     # 确认本节点地址在列表中
> clique.getSnapshot("latest").recents     # 出块后应出现本节点地址
```

### 5.5 提案成为新签名者

```bash
# 在已授权验证者节点的 geth console 中执行：
> clique.propose("0xNewValidatorAddress", true)
```

超过半数签名者投票通过，并在下一个 epoch checkpoint（每 30,000 块）写入链上后生效。

---

## 6. 常用运维命令

```bash
# 查看实时日志
docker logs -f abcore-$NETWORK

# 进入 geth JavaScript console
docker exec -it abcore-$NETWORK geth attach /data/geth.ipc

# 查看区块高度
docker exec abcore-$NETWORK geth attach --exec 'eth.blockNumber' /data/geth.ipc

# 手动添加 peer（P2P 长时间为 0 时）
docker exec -it abcore-$NETWORK geth attach /data/geth.ipc
> admin.addPeer("enode://...")

# 停止节点（数据完整保留）
docker stop abcore-$NETWORK

# 重启节点
docker restart abcore-$NETWORK

# 升级镜像
docker stop abcore-$NETWORK && docker rm abcore-$NETWORK
# 重新执行 docker run，将 TAG 替换为新版本

# 查看容器资源使用
docker stats abcore-$NETWORK

# 查看节点版本
docker exec abcore-$NETWORK geth version
```

---

## 7. 故障排查

### 容器启动后立即退出

```bash
docker logs abcore-$NETWORK
```

| 错误信息 | 原因 | 解决方法 |
|---------|------|---------|
| `NETWORK must be testnet or mainnet` | NETWORK 值不合法 | 检查 `-e NETWORK=` 参数 |
| `no keystore file found in /data/keystore/` | keystore 目录为空 | 确认 keystore 文件已放入 `$DATADIR/keystore/` |
| `password file not found` | 密码文件缺失 | 确认 `$DATADIR/password.txt` 存在且权限为 600 |
| `could not unlock account` | keystore 与密码不匹配 | 检查 keystore 文件名末尾地址与密码是否对应 |
| `mkdir /data/geth: permission denied` | 数据目录权限不足 | `sudo chown -R $(id -u):$(id -g) $DATADIR` |

### 节点有 peers 但不出块

```bash
docker exec -it abcore-$NETWORK geth attach /data/geth.ipc
> eth.mining                           # 若为 false，检查 keystore/password.txt 是否存在
> clique.getSnapshot("latest").signers # 确认本节点地址是否在授权列表中
```

### P2P 连接数为 0

1. 确认 33333 端口（TCP + UDP）在防火墙/安全组中已开放
2. 检查启动日志中是否有 `detected public IP` — 若无，手动指定：`-e NAT=extip:<PUBLIC_IP>`
3. 手动添加 bootstrap 节点（测试网）：
   ```
   > admin.addPeer("enode://b132ddb...@13.112.97.231:33333")
   ```

---

## 8. 备份建议

| 文件 | 重要性 | 说明 |
|------|--------|------|
| `$DATADIR/keystore/` | **极高**（不可恢复） | 验证者私钥 |
| `$DATADIR/password.txt` | 高 | keystore 解锁密码 |
| `$DATADIR/geth/` | 低 | 链数据可从网络重新同步 |

```bash
BACKUP_DIR="/data/backup/abcore-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r $DATADIR/keystore "$BACKUP_DIR/"
cp $DATADIR/password.txt "$BACKUP_DIR/"
echo "Backup saved to: $BACKUP_DIR"
```
