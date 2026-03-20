# abcore-v2 节点部署手册（Docker）

**文档版本**: 1.1
**适用版本**: abcore-v2
**支持网络**: ABCore 测试网（Chain ID 26888）/ ABCore 主网（Chain ID 36888）

> **快速设置环境变量**：执行以下命令将路径变量写入 `~/.bashrc`，重新登录后仍然有效。根据实际环境修改后执行：
>
> ```bash
> cat >> ~/.bashrc << 'EOF'
> export NETWORK="testnet"              # testnet 或 mainnet
> export DATADIR="/data/abcore/testnet" # 节点数据目录（含 keystore 和链数据）
> export TAG="vX.Y.Z"                   # abcore-v2 镜像 tag
> EOF
> source ~/.bashrc
> ```

---

## 1. 概述

本手册介绍如何在生产环境中使用 Docker 部署 abcore-v2 节点，涵盖两种角色：

| 角色 | 说明 | 出块 |
|------|------|------|
| **普通节点**（RPC 节点） | 同步链数据，提供 RPC/WS 接口 | 否 |
| **验证者节点** | 在普通节点基础上解锁账户、参与 Clique PoA 出块 | 是 |

两种角色使用**相同的镜像**，通过环境变量区分。Bootstrap 节点、创世区块、链配置均已**硬编码进二进制**（`--abcore.testnet` / `--abcore` flag），**无需任何配置文件**即可启动。

### 1.1 端口说明

| 端口 | 协议 | 用途 | 对外开放 |
|------|------|------|---------|
| 8545 | HTTP | JSON-RPC | 按需（默认仅本机） |
| 8546 | WS | WebSocket RPC | 按需（默认仅本机） |
| 33333 | TCP+UDP | P2P 节点发现与同步 | **必须** |

### 1.2 高级配置覆盖

默认无需配置文件。如需调整 TxPool 限额、矿工 gas、RPC 超时等参数，可挂载 TOML 配置文件。仓库已提供现成模板：

```bash
# 以 testnet 模板为基础（mainnet 同理）
-v /path/to/abcore-v2/script/release/configs/testnet/node.toml:/bsc/config/config.toml:ro
```

节点启动时会自动加载该文件；`NETWORK` flag 优先级高于文件内容，网络标识始终正确。

如需挂载到其他路径，用 `BSC_CONFIG` 环境变量指定容器内路径：

```bash
-e BSC_CONFIG=/data/my-node.toml
```

### 1.3 宿主机数据目录布局

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
| 磁盘 | 200 GB+ SSD（`/data` 挂载点） |
| 网络 | 固定公网 IP，33333 端口 TCP+UDP 可达 |

```bash
# 安装 Docker Engine 24+
curl -fsSL https://get.docker.com | sh
```

---

## 3. 获取镜像

### 方式 A：从 GitHub Release 加载（推荐）

```bash
gh release download $TAG -R ABFoundationGlobal/abcore-v2 \
  --pattern "abcore-v2-${TAG}-linux-amd64.tar.gz" -D /tmp/

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
docker run --rm abfoundationglobal/abcore-v2:$TAG geth version
```

---

## 4. 普通节点（RPC 节点）部署

### 4.1 直接 docker run（最简，无需任何配置文件）

Bootstrap 节点和创世块已硬编码在二进制中，只需挂载数据目录：

```bash
# 准备数据目录权限（容器内 bsc 用户 uid=1000）
mkdir -p $DATADIR
docker run --rm -v "$DATADIR:/data" --user root busybox chown 1000:1000 /data

# 启动测试网节点（NETWORK 默认为 testnet，可省略）
docker run -d \
  --name abcore-testnet \
  --restart unless-stopped \
  -v $DATADIR:/data \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  -p 0.0.0.0:33333:33333 \
  -p 0.0.0.0:33333:33333/udp \
  -e NETWORK=testnet \
  -e NAT=extip:$(curl -s ifconfig.me) \
  abfoundationglobal/abcore-v2:$TAG

# 查看启动日志
docker logs -f abcore-testnet
```

启动主网节点只需改 `NETWORK=mainnet` 和容器名：

```bash
docker run -d \
  --name abcore-mainnet \
  --restart unless-stopped \
  -v /data/abcore/mainnet:/data \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  -p 0.0.0.0:33333:33333 \
  -p 0.0.0.0:33333:33333/udp \
  -e NETWORK=mainnet \
  -e NAT=extip:$(curl -s ifconfig.me) \
  abfoundationglobal/abcore-v2:$TAG
```

### 4.2 使用 Docker Compose

```bash
# 进入对应网络的配置目录
cd /path/to/abcore-v2/script/release/configs/$NETWORK

cp .env.example .env
# 修改 TAG、DATADIR、NAT

docker compose up -d
docker compose logs -f --tail=50
```

### 4.3 使用 launch.sh

```bash
cd /path/to/abcore-v2/script/release

./launch.sh \
  --image abfoundationglobal/abcore-v2:$TAG \
  --network $NETWORK \
  --datadir $DATADIR \
  --external-ip $(curl -s ifconfig.me)
```

### 4.4 验证同步

```bash
docker exec abcore-testnet geth attach \
  --exec 'console.log("block:", eth.blockNumber, "peers:", admin.peers.length)' \
  /data/geth.ipc

# 区块高度持续增长，peers >= 1 即为正常
```

---

## 5. 验证者节点部署

验证者节点在普通节点基础上持有 keystore 账户，解锁后参与 Clique PoA 签名出块。

> **前提**：验证者地址须已经过现有授权验证者 `clique.propose` 投票并写入 checkpoint，才能实际出块。建议先以普通节点模式同步至链头，再切换为验证者模式。

### 5.1 生成验证者账户

```bash
docker run --rm -it \
  -v $DATADIR:/data \
  abfoundationglobal/abcore-v2:$TAG \
  geth account new --datadir /data

# 记录输出的地址（0x...），后续填入 MINER_ADDR
# keystore 文件自动生成在 $DATADIR/keystore/UTC--...
```

### 5.2 准备密码文件

```bash
echo "YOUR_KEYSTORE_PASSWORD" > $DATADIR/password.txt
chmod 600 $DATADIR/password.txt
```

### 5.3 修复数据目录权限

```bash
docker run --rm -v "$DATADIR:/data" --user root busybox chown -R 1000:1000 /data
```

### 5.4 直接 docker run（最简）

密码文件放在数据目录，通过 `PASSWORD_FILE` 指定容器内路径：

```bash
docker run -d \
  --name abcore-testnet-validator \
  --restart unless-stopped \
  -v $DATADIR:/data \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  -p 0.0.0.0:33333:33333 \
  -p 0.0.0.0:33333:33333/udp \
  -e NETWORK=testnet \
  -e NAT=extip:$(curl -s ifconfig.me) \
  -e MINE=true \
  -e MINER_ADDR=0xYourValidatorAddress \
  -e PASSWORD_FILE=/data/password.txt \
  abfoundationglobal/abcore-v2:$TAG
```

### 5.5 使用 Docker Compose

将 `password.txt` 放入配置目录（已在 `.gitignore` 中），编辑 `.env`：

```bash
cp $DATADIR/password.txt /path/to/abcore-v2/script/release/configs/$NETWORK/password.txt
chmod 600 /path/to/abcore-v2/script/release/configs/$NETWORK/password.txt
```

```bash
# .env
TAG=vX.Y.Z
DATADIR=/data/abcore/testnet
NAT=extip:1.2.3.4
MINE=true
MINER_ADDR=0xYourValidatorAddress
```

```bash
cd /path/to/abcore-v2/script/release/configs/$NETWORK
docker compose up -d
```

### 5.6 使用 launch.sh

```bash
./launch.sh \
  --image abfoundationglobal/abcore-v2:$TAG \
  --network $NETWORK \
  --mode validator \
  --datadir $DATADIR \
  --address 0xYourValidatorAddress \
  --password $DATADIR/password.txt \
  --external-ip $(curl -s ifconfig.me)
```

### 5.7 验证出块

```bash
docker exec -it abcore-testnet-validator geth attach /data/geth.ipc

> eth.mining                               # 应为 true
> clique.getSnapshot("latest").signers     # 确认本节点地址在列表中
> clique.getSnapshot("latest").recents     # 出块后应出现本节点地址
```

### 5.8 提案成为新签名者

```bash
# 在已授权验证者节点的 geth console 中执行：
> clique.propose("0xNewValidatorAddress", true)
```

超过半数签名者投票通过，并在下一个 epoch checkpoint（每 30,000 块）写入链上后生效。

---

## 6. 常用运维命令

```bash
# 查看实时日志
docker logs -f abcore-testnet

# 进入 geth JavaScript console
docker exec -it abcore-testnet geth attach /data/geth.ipc

# 查看区块高度
docker exec abcore-testnet geth attach --exec 'eth.blockNumber' /data/geth.ipc

# 手动添加 peer（P2P 长时间为 0 时）
docker exec -it abcore-testnet geth attach /data/geth.ipc
> admin.addPeer("enode://...")

# 停止节点（数据完整保留）
docker stop abcore-testnet

# 重启节点
docker restart abcore-testnet

# 升级镜像
docker stop abcore-testnet && docker rm abcore-testnet
# 重新执行 docker run，将 TAG 替换为新版本

# 查看容器资源使用
docker stats abcore-testnet

# 查看节点版本
docker exec abcore-testnet geth version
```

---

## 7. 故障排查

### 容器启动后立即退出

```bash
docker logs abcore-testnet
```

| 错误信息 | 原因 | 解决方法 |
|---------|------|---------|
| `NETWORK must be testnet or mainnet` | NETWORK 值不合法 | 检查 `-e NETWORK=` 参数 |
| `MINE=true but MINER_ADDR is not set` | 验证者模式缺少地址 | 添加 `-e MINER_ADDR=0x...` |
| `could not unlock account` | keystore 地址或密码错误 | 检查 `MINER_ADDR` 与 keystore 文件名末尾地址是否一致，以及 `password.txt` 内容 |

### 节点有 peers 但不出块

```bash
docker exec -it abcore-testnet geth attach /data/geth.ipc
> eth.mining                           # 若为 false 检查 MINE 环境变量
> clique.getSnapshot("latest").signers # 确认本节点地址是否在授权列表中
```

### P2P 连接数为 0

1. 确认 33333 端口（TCP + UDP）在防火墙/安全组中已开放
2. 确认 `-e NAT=extip:<PUBLIC_IP>` 已正确设置
3. 手动添加 bootstrap 节点（测试网）：
   ```
   > admin.addPeer("enode://b132ddb...@13.112.97.231:33333")
   ```

### 数据目录权限错误

```bash
docker run --rm -v "$DATADIR:/data" --user root busybox chown -R 1000:1000 /data
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
