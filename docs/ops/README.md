# ABCore v2 运维文档索引（docs/ops/）

本目录是 ABCore v2 从节点部署、二进制升级、共识切换到 testnet/mainnet 升级编排的全部运维文档。先看下面的**场景路由**找到你要的文档。

## 场景路由：什么情况用哪篇

| 你要做的事 | 看这篇 |
|---|---|
| 部署一个全新节点（RPC 或 validator）/ 把 v1 裸机节点迁移到 v2 Docker / v2 换 tag | [node-and-validator-deployment.md](node-and-validator-deployment.md) |
| 激活 Parlia 共识（把 `ParliaGenesisBlock` 从 nil 设成 N，Phase 2 cutover） | [fork-cutover-runbook.md](fork-cutover-runbook.md) |
| Parlia 切换失败 / 链卡死，需要全网协调回滚到 Clique | [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md) |
| **以 devops 视角把 testnet（之后 mainnet）走完整 6 步升级** | [testnet-upgrade-plan.md](testnet-upgrade-plan.md) |
| 查 fork 顺序 / 参数选址规则 / devnet 实测值 / 升级路径全貌（**SoT**） | [devnet-upgrade-plan.md](devnet-upgrade-plan.md) |

## 阶段关系

```
node-and-validator-deployment.md        （部署 + Phase 1：v1→v2 binary，仍 Clique）
        │
        ▼
fork-cutover-runbook.md                 （Phase 2：激活 Parlia，PGB=nil → N，必须 rolling）
        │
        ├── 成功 → 链运行 Parlia
        └── 失败 → consensus-switch-rollback-runbook.md（协调式回滚到 Clique）

testnet-upgrade-plan.md   = devops 操作编排，串起以上全部，逐步推 testnet → mainnet
devnet-upgrade-plan.md    = SoT，fork 参数 / 顺序 / 验收标准 / devnet 执行历史（dev 拥有）
```

## 术语表

| 术语 | 含义 |
|---|---|
| **Phase 1** | v1.13.15 → abcore-v2 的二进制/部署升级，共识仍是 Clique（`ParliaGenesisBlock = nil`）。纯滚动二进制替换。 |
| **Phase 2** | 共识激活：在 chain config 写入 `ParliaGenesisBlock = N`，从块 N 起由 Parlia 取代 Clique。必须 rolling cutover。 |
| **PGB / N** | `ParliaGenesisBlock`，Clique→Parlia 的分叉块高。dev team 定值。 |
| **M** | London + 13 个 BSC block fork 的激活块高（Upgrade 2）。dev team 定值。 |
| **T3–T6** | Upgrade 3–6 的时间戳激活点（已硬编码进 binary）。dev team 定值。 |
| **rolling（滚动）** | 逐个 validator 停→升级→等健康出块→下一个；任意时刻在线验证节点不低于出块门槛。 |
| **seal-race / stop-window race** | 同时重启过多 validator 触发的 `Recents` 死锁；Phase 2 的特例会永久卡链。见 [部署手册 §5](node-and-validator-deployment.md#5-seal-race-死锁recents-机制所有路径通用) 与 [fork-cutover §2](fork-cutover-runbook.md#2-stop-window-race必须了解的故障模式)。 |
| **epoch** | Parlia 把 active validator 集合写入 header 的节奏（块数）。 |
| **breathe block** | Go 层每 24h（UTC 对齐）触发一次的 validator 选举块；Feynman 激活后相关。 |
| **SoT** | Single Source of Truth，升级计划权威来源 = [devnet-upgrade-plan.md](devnet-upgrade-plan.md)。 |

## 网络

| 网络 | Chain ID |
|---|---|
| Mainnet | 36888 |
| Testnet | 26888 |
| DevNet | 17140 |
