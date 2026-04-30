# 共识切换回滚操作手册

## Clique → Parlia 切换失败时的协调式回滚 Runbook

**文档版本**: 1.0
**适用版本**: abcore-v2
**适用网络**: ABCore 测试网（Chain ID 26888）/ ABCore 主网（Chain ID 36888）
**适用场景**: 所有验证节点均已部署 abcore-v2，且 `ParliaGenesisBlock = N` 已启用；链在切换到 Parlia 时或切换后发生停链、持续无法恢复、需全网回退到 Clique

> **适用范围说明**
>
> - 本手册处理的是“**共识切换已经触发或已跨过分叉块**”后的回滚。
> - 若只是 v1 → v2 二进制升级失败，但链仍处于纯 Clique 阶段，请使用 [validator-upgrade-v1-to-v2.md](validator-upgrade-v1-to-v2.md) 中的回滚章节。
> - 本手册对应本地演练脚本 `script/transition-test/96-run-rollback-drill.sh`，即 T-1.6 场景。

---

## 1. 结论先行

### 1.1 能否回滚到原来的 validators

可以，但必须是**全网协调式回滚**，不能靠单个节点改配置完成。

回滚后的 validators 集合，以分叉前最后一个 Clique canonical block（通常为 `N-1`）所对应的 Clique signer 集合为准。

### 1.2 回滚的核心原则

1. 所有验证节点和所有关键 RPC 节点必须同时进入维护窗口。
2. 全网必须回退到同一个高度，推荐为 `N-1`。
3. 回退完成后，所有节点必须去掉 `ParliaGenesisBlock = N` 配置，以 pure Clique 方式重新启动。
4. 不要尝试只回滚部分节点，否则高概率造成永久分叉或继续停链。

### 1.3 什么时候该执行本手册

满足以下任一条件即可进入回滚判断：

- 已到达或已经跨过 `ParliaGenesisBlock`，但链长时间不再增长。
- 多数验证节点持续报 `unauthorized validator`、`errExtraSigners`、签名不匹配、无法继续 sealing。
- 重启后仍无法形成稳定 canonical head。
- 已确认不继续推进 Parlia，需撤回切换并恢复 Clique 出块。

---

## 2. 前置假设与术语

| 名称 | 含义 |
|---|---|
| `N` | 生产环境配置的 `ParliaGenesisBlock` |
| `N-1` | 推荐回滚锚点，即最后一个 Clique canonical block |
| 验证节点 | 负责 sealing / mining 的节点 |
| 关键 RPC 节点 | 为验证节点、监控、交易入口提供链视图的节点 |

> **为什么回到 `N-1` 而不是更高或更低？**
>
> - 回到 `N-1`，可以保留全部已确认的 Clique 历史。
> - 分叉块 `N` 会被重新以 Clique 规则产出，逻辑最清晰。
> - 这也是 T-1.6 演练验证过的路径。

---

## 3. 执行前检查清单

在宣布回滚前，先完成以下核对：

- [ ] 已确认本次故障发生在 `ParliaGenesisBlock` 切换窗口或其后
- [ ] 已确认所有验证节点当前运行的是同一版本的 abcore-v2
- [ ] 已确认生产 `ParliaGenesisBlock = N`
- [ ] 已确认能够在维护窗口内同时停止所有验证节点和关键 RPC 节点
- [ ] 已记录每个节点当前 head、高度 `N-1` 的块哈希、以及当前 peers 情况
- [ ] 已确认 keystore / password 文件安全可用

推荐记录命令：

```bash
# 先填写本次切换配置中的 ParliaGenesisBlock 高度
N=<实际ParliaGenesisBlock高度>
TARGET=$((N-1))
TARGET_HEX="0x$(printf '%x' "$TARGET")"

# 记录当前 head
docker exec -it abcore-validator geth attach \
  --exec 'eth.blockNumber' /data/geth.ipc

# 记录 N-1 的块哈希
docker exec -it abcore-validator geth attach \
  --exec "eth.getBlock(${TARGET}).hash" /data/geth.ipc

# 记录当前 Clique signer 集合（若节点仍能正确响应）
docker exec -it abcore-validator geth attach \
  --exec "JSON.stringify(clique.getSigners(\"${TARGET_HEX}\"))" \
  /data/geth.ipc
```

---

## 4. 回滚步骤

### 步骤 1：冻结变更并宣布维护窗口

1. 停止继续发布新镜像、新配置、新节点。
2. 通知所有验证节点与关键 RPC 节点进入维护窗口。
3. 确认没有节点仍在使用旧配置自动重启。

---

### 步骤 2：停止所有验证节点和关键 RPC 节点

如果使用 Docker Compose：

```bash
cd $DOCKER_DIR
docker compose down
```

如果使用 `docker run`：

```bash
docker stop abcore-$NETWORK-validator
docker stop abcore-$NETWORK
```

> **必须停止关键 RPC 节点**
>
> 若 RPC 节点继续保留 Parlia 视图，外部系统会同时看到两条不同的链视图，放大事故面。

---

### 步骤 3：以 maintenance 模式启动节点

目标是让节点只打开 IPC / RPC，**不挖矿**，以便执行 `debug.setHead`。

由于容器 entrypoint 默认会在检测到 keystore 后自动启用 validator 模式，回滚时必须显式关闭：`MINE=false`。

示例：

```bash
docker run -d \
  --name abcore-maintenance \
  --restart no \
  -e NETWORK=$NETWORK \
  -e MINE=false \
  -v $DATADIR:/data \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  abfoundation/abcore-v2:$TAG \
  --http --http.addr 0.0.0.0 --http.port 8545 \
         --http.api 'debug,net,web3,eth,clique' \
  --ws   --ws.addr 0.0.0.0   --ws.port 8546 \
         --ws.api 'debug,net,web3,eth,clique' \
  --syncmode full
```

若使用 Compose，可临时在 `environment` 中加入：

```yaml
MINE: "false"
```

并确保命令行参数里没有 `--mine`。

---

### 步骤 4：对每个节点执行 `debug.setHead('0x...')`

以目标高度 `N-1` 为例：

```bash
TARGET=$((N-1))
TARGET_HEX=$(printf '0x%x' "$TARGET")

docker exec -it abcore-maintenance geth attach \
  --exec "debug.setHead('${TARGET_HEX}')" \
  /data/geth.ipc
```

> **注意**
>
> - 这里必须传十六进制字符串，如 `debug.setHead('0x13')`。
> - 直接传十进制整数会报参数格式错误。

执行后立即检查：

```bash
docker exec -it abcore-maintenance geth attach \
  --exec 'eth.blockNumber' /data/geth.ipc

docker exec -it abcore-maintenance geth attach \
  --exec "eth.getBlock(${TARGET}).hash" /data/geth.ipc
```

对**所有验证节点**和**所有关键 RPC 节点**重复此步骤，直到全部回到同一高度。

---

### 步骤 5：确认所有节点回到了同一个 canonical anchor

在每个节点上确认（`TARGET` 沿用步骤 4 中定义的变量）：

```bash
docker exec -it abcore-maintenance geth attach \
  --exec 'eth.blockNumber' /data/geth.ipc

docker exec -it abcore-maintenance geth attach \
  --exec "eth.getBlock(${TARGET}).hash" /data/geth.ipc
```

要求：

1. 所有节点 `eth.blockNumber == N-1`
2. 所有节点 `eth.getBlock(N-1).hash` 完全一致

若任一节点不满足，不得进入下一步。

---

### 步骤 6：停止 maintenance 进程，移除 PGB 配置

停止 maintenance 容器：

```bash
docker rm -f abcore-maintenance
```

然后移除或禁用生产配置中的 `ParliaGenesisBlock = N`。

如果你是通过 `node.toml` / override 配置启用分叉，必须将其恢复为 pure Clique 配置。

如果你是通过特定镜像或特定环境变量启用，请确保所有节点都切回同一份 pure Clique 配置。

**原则**：重启后所有节点必须一致地认为当前链仍处于 Clique 阶段。

---

### 步骤 7：按 pure Clique 方式恢复全网

先启动验证节点，再启动关键 RPC 节点。

```bash
cd $DOCKER_DIR
docker compose up -d
docker compose logs -f --tail=50
```

或：

```bash
docker run -d \
  --name abcore-$NETWORK-validator \
  --restart unless-stopped \
  -e NETWORK=$NETWORK \
  -v $DATADIR:/data \
  ...
```

观察日志，确认重新开始 sealing 的是 Clique，而非 Parlia 切换逻辑。

---

## 5. 回滚后验证清单

所有验证节点恢复后，执行以下检查（`N` 和 `TARGET` 沿用第 3 节中定义的变量）：

```bash
# 1. 当前 head 持续增长
docker exec -it abcore-validator geth attach \
  --exec 'eth.blockNumber' /data/geth.ipc

# 2. N-1 哈希保持不变
docker exec -it abcore-validator geth attach \
  --exec "eth.getBlock(${TARGET}).hash" /data/geth.ipc

# 3. block N 已被重新产出
docker exec -it abcore-validator geth attach \
  --exec "eth.getBlock(${N}).hash" /data/geth.ipc

# 4. Clique signer 集合正确
docker exec -it abcore-validator geth attach \
  --exec 'JSON.stringify(clique.getSigners())' /data/geth.ipc

# 5. 回滚后的 block N 不应存在 ValidatorSet 合约代码
docker exec -it abcore-validator geth attach \
  --exec "eth.getCode(\"0x0000000000000000000000000000000000001000\", ${N})" \
  /data/geth.ipc
```

验证标准：

- [ ] 所有节点 head 持续增长
- [ ] 所有节点在 `N-1` 的 hash 一致且与回滚前记录一致
- [ ] 所有节点在 `N` 的 hash 一致，但**不同于**故障时的 Parlia block hash
- [ ] `clique.getSigners()` 与回滚前记录的 validator 集合一致
- [ ] `eth.getCode(ValidatorSet, N) == 0x`

---

## 6. 决策建议

### 6.1 何时优先“重启恢复”而不是“回滚”

若满足以下条件，优先尝试简单重启，而不是直接回滚：

- 尚未形成稳定的 post-fork canonical chain
- 问题看起来是单节点未升级、局部配置错误、短暂 seal-race
- 多数节点重启后能重新推进 head

### 6.2 何时应直接执行本手册

若满足以下条件，应直接进入回滚：

- 多数节点已跨过 `N`，但全网长期无法继续出块
- 已出现持续性的签名/validator 不匹配错误
- 重启无效，或重启后反复回到同样故障点
- 运营决策明确要求先恢复 Clique，再重新安排下一次切换窗口

---

## 7. 常见错误与注意事项

### 错误 1：只回滚一个节点

后果：节点视图与其他节点不一致，链分叉不会消失。

### 错误 2：回滚到 `N` 而不是 `N-1`

后果：`N` 已是切换块，可能残留 Parlia 相关状态与判断路径，不适合作为恢复锚点。

### 错误 3：maintenance 模式仍在自动挖矿

后果：节点可能在尚未统一 rewind 之前继续出块，破坏维护窗口。

解决：显式设置 `MINE=false`，并确认日志中没有 validator auto-detect + `--mine` 生效。

### 错误 4：`debug.setHead` 传了十进制参数

后果：console 调用失败，返回参数类型错误。

正确示例：

```bash
debug.setHead('0x13')
```

---

## 8. 本地演练建议

在生产执行前，建议至少完成一次本地或测试环境彩排：

```bash
GETH=./build/bin/geth bash script/transition-test/96-run-rollback-drill.sh
```

该脚本验证：

1. 先成功跨过 `ParliaGenesisBlock`
2. 再统一回退到 `N-1`
3. 重新以 Clique 方式产出 block `N`
4. 恢复原 validator 集合
5. 确认回滚后的 `ValidatorSet` 合约代码为空

---

## 9. 回滚完成后的后续动作

回滚成功后，建议按以下顺序推进：

1. 冻结新的切换时间，先恢复链稳定运行。
2. 导出并归档本次故障期的日志、`N-1` / `N` 的 hash、错误消息。
3. 复盘根因：配置错误、节点未统一升级、签名集合异常、StakeHub 注册缺失、还是其他实现问题。
4. 在测试环境重新演练切换与回滚，确认问题已修复，再安排下一次窗口。
