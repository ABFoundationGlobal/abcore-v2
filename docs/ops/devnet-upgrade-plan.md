# ABCore DevNet 建设 + 分阶段升级路径计划

> 本文档用于指导 DevNet 搭建、升级演练，以及后续 Testnet / Mainnet 的推进策略。
> **本文档是升级计划的 single source of truth。** drill 脚本 README（`script/test/upgrade-drill/README.md`）是工程验证视角，不等于运营计划；以本文档为准。
> **Last updated**: 2026-06-15

---

## 背景与目标

当前生产网络（Testnet 和 Mainnet）运行 abcore-v1（Clique PoA，geth v1.13.15）。目标是升级到 abcore-v2（BSC v1.7.x base，geth v1.16.x）并逐步激活最新 EVM 特性。

> **客户端说明**：升级目标不是 upstream geth，而是 abcore-v2（fork 自 bnb-chain/bsc，包含 Parlia 共识引擎、DualConsensus wrapper、ABCore 专属链配置）。upstream geth v1.14+ 已移除 Clique，无法执行 ABCore 链。

尽量减少 Testnet 上的升级次数，因此先建立 DevNet 完整演练整个升级路径，确认可行后再推 Testnet，最后推 Mainnet。

**升级总路径（6 次升级，另有真正可选的 fork 见附录）：**

```
abcore-v1 (Clique PoA, geth v1.13.15)
    ↓ Upgrade 1
v0.2.0 — Parlia 共识切换（ParliaGenesisBlock = N）
    ↓ Upgrade 2
v0.3.0 — London + 13 BSC block forks（EIP-1559 + 解锁 timestamp forks）
    ↓ Upgrade 3
v0.4.0 — Shanghai + Kepler + Feynman + FeynmanFix（PUSH0 + staking + 选举生效）
    ↓ Upgrade 4
v0.5.0 — Cancun + Haber + HaberFix（EIP-4844 blob 交易）
    ↓ Upgrade 5
v0.6.0 — Prague + Pascal + Lorentz + Maxwell + Bohr（账户抽象 + epoch 变化 + TurnLength）
    ↓ Upgrade 6
v0.7.0 — Fermi + Osaka + Mendel（BSC 主网 2026 最新 fork）
```

> **路径选择说明**：Feynman（validator 注册操作）和 Cancun（blob 交易）分开，出问题时更容易定位。若 DevNet 演练中 Feynman 注册已完全自动化，可合并 Upgrade 3+4 回到 5 次。
>
> **关于 Bohr / Fermi / Osaka / Mendel**：上游 Bohr 改 TurnLength、Fermi 把出块间隔 750ms→450ms，但 **ABCore 永久维持 3 秒出块**（`params/protocol_params.go` 把 `Lorentz/Maxwell/FermiBlockInterval` 全 override 为 `3000ms`），这些 fork 对出块速度无影响。并入 v0.6.0/v0.7.0 是为跟上 BSC fork 顺序，免去未来 sync upstream patch 踩坑。详见 §三。

> **Mainnet 不可逆性**：每次硬分叉激活后，已处理的外部交易、RPC 状态、外部依赖（dApp、indexer）都已基于新链前进。Mainnet 激活后的"回滚"实质上是链级重置，涉及 tx 丢失和外部方协调，代价极高。请在 DevNet + Testnet 充分验证后再推 Mainnet，不要依赖 Mainnet 回滚作为保险。

---

## 一、DevNet 架构设计

### 节点分布

| 服务器 | 节点 | 角色 |
|--------|------|------|
| server-1 | val-0, val-1 | Validator（出块） |
| server-2 | val-2, val-3 | Validator（出块） |
| server-3 | val-4 | Validator（出块） |
| server-4 | rpc-0 | RPC 节点（只读，不出块，独立服务器） |

5 个 Validator + 1 个 RPC 节点，RPC 节点独立于所有 validator 服务器。

### 机器配置推荐

最小要求（DevNet 演练环境，流量极低，需覆盖 6 次升级周期）：双 validator 机（server-1/2）16 核 / 32 GB；单 validator + RPC 机（server-3/4）8 核 / 16 GB。磁盘统一 500 GB NVMe SSD（顺序 ≥ 500 MB/s、4K IOPS ≥ 8000、延迟 < 1ms；500 GB 足够演练 + 多次快照）。节点间延迟 < 100ms，公网出口 ≥ 10 Mbps。

> **拓扑说明**：server-1/2 各跑 2 个 validator，单机故障失去 40% signer，剩余 3/5 仍构成多数派，链不中断。DevNet 拓扑与生产（每 validator 独立服务器）不同，HA 结果不可直接推广到 Mainnet。RPC（server-4）必须独立：RPC 的 IO/CPU 负载与出块共享会影响出块稳定性。

### 滚动升级原则

多 validator 服务器不整台下线，**逐个 validator 进程停止/替换/启动/验证重连**（如 server-1：先 val-0 后 val-1）。任意时刻最多 1 个 validator 离线，始终保持 4/5 在线（远超多数派 3/5），链不中断，slot 最多 1 个 missed block。

每次 Upgrade 的建议替换顺序：
1. server-3 val-4（单节点，验证新 binary 启动无问题）
2. server-1 val-0 → server-1 val-1（逐个）
3. server-2 val-2 → server-2 val-3（逐个）
4. server-4 rpc-0（非出块，最后替换）

### 链参数

| 参数 | 值 |
|------|-----|
| Chain ID | 17140（区别于本地 devnet 7140）|
| 共识（初始）| Clique PoA |
| Clique Period | 3s（与 mainnet 一致）|
| Clique Epoch | 30000 |
| ParliaGenesisBlock | 演练时设定；**2026-06-15 re-run 单档 v0.2.0：PGB = 4400**（fresh v1 reset 后，距 15:00 UTC ~2h，200-grid 对齐）。历史 2026-05-28 reset re-run 用 PGB=2400（见 §十）|

### 系统合约字节码路由

| 环境 | bytecode 目录 | 自动路由依据 |
|------|--------------|-------------|
| DevNet (chain 17140) | `parliagenesis/devnet/` | genesis hash = ABCoreDevnetGenesisHash（PR #90 起）|
| Testnet (chain 26888) | `parliagenesis/testnet/` | genesis hash = ABCoreTestGenesisHash |
| Mainnet (chain 36888) | `parliagenesis/mainnet/` | genesis hash = ABCoreMainGenesisHash |
| Local self-test | `parliagenesis/default/` | genesis hash 不匹配任何 ABCore 网络 → fallthrough |

路由由 `core/systemcontracts/upgrade.go` 的 `applyParliaGenesisUpgrade` 在 PGB cutover 执行，无需 flag；链 ID / genesis hash 不同自动隔离，bytecode 不跨链泄漏。

<a id="one-shot-bytecode"></a>
### 一次性字节码部署（One-shot bytecode deployment）—— ABCore 关键设计

**结论**：`parliagenesis/{mainnet,testnet,devnet}/` 嵌入的是**最终版 bytecode**（含 Luban `getMiningValidators()`、vote address 存储、Feynman StakeHub 接口 / `updateValidatorSetV2` 等全部 post-Hertz 特性）。PGB 那一刻一次性部署到位，**后续所有 BSC fork（Ramanujan…Hertzfix、Feynman、Bohr、Lorentz、Maxwell…）对系统合约 bytecode 都是 no-op**。`upgradeBuildInSystemContract` 在函数入口对 ABCore 网络 early-return（PR #99 起），跳过 14 个 `*Upgrade[network]` map lookup。

与 BSC 上游不同：BSC 在 ParliaGenesis 部署早期 bytecode，之后每个 fork 通过 `*Upgrade[network]` map 增量替换。ABCore 没有这种历史包袱，一次部署减少出错面（BSC 漏一个 fork 的 bytecode 升级会让该 fork 引擎层失灵）。bytecode 由 `abcore-v2-genesis-contract` 编译，validator 地址 / chain ID / 治理合约地址已 baked-in，**不能**拿 BSC mainnet/chapel bytecode 增量升级。

**chain config gate 仍按 fork 顺序逐个激活**：`IsLuban(block)` 从 LubanBlock 起生效，引擎层（`Prepare`/`verifyValidators`/extraData layout/EIP-1559 schema/vote attestation）按 fork 边界切换。「合约 bytecode 不变 + chain config 按时激活」是 ABCore 标准工作模型。

**运维含义**：
- 每次升级**只需改 `params/config.go` 启用 fork**，不需要在 `upgrade.go` 注册 `*Upgrade[abcoreXxx]` 条目；任何往 `upgrade.go` 加 `lubanUpgrade[abcoreDevNet]` 之类条目的 PR 都是错的（除非 PGB bytecode 漏装功能 —— 走 `abcore-v2-genesis-contract` 重编译，而非后置 hardfork upgrade）
- PR #99 之前日志有 `Empty upgrade config network=Default height=N`（每 fork 一行 INFO，落 defaultNet 分支调 `applySystemContractUpgrade(nil, ...)` 的噪音，是预期行为不是 bug）；PR #99 起 early-return 消除

### 混版本兼容性

abcore-v1 和 abcore-v2 可以在同一网络中混合运行（切换前）。此兼容性已由 `script/compat-clique-v1-v2/` 验证（Phase 1 工作）：v2 节点可以 peer、同步、出块，v1 节点可以接受 v2 出的 Clique 块。DevNet 搭建时可逐节点替换 binary，不需要全网同步停机。**所有节点（包括 v1 节点）必须在激活块高 N 到达前完成替换**，v1 binary 无法处理 Parlia block，N 后未完成替换的 v1 节点将脱离主链。

### 数据库兼容性

abcore-v2 的 DB schema 是 additive：只新增 key prefix（Parlia snapshot、blob sidecar 等），不迁移现有 key，已验证的升级路径（v1 pre-fork 状态）可直接复用 datadir。不保证跨版本降级或任意 ancients/snapshot 元数据无条件兼容。

### 快照内容清单

每次升级前必须对所有节点做全量备份，包括：

```
- datadir/chaindata/        # 链数据（包括 ancients/freezer）
- datadir/keystore/         # 账户密钥
- nodekey                   # P2P 节点密钥
- static-nodes.json         # 静态节点配置
- jwt.secret（如有）        # Engine API JWT
- 启动脚本 / 环境变量      # 完整启动配置
```

### 代码现状：block interval 永久 3 秒

ABCore 在 `params/protocol_params.go` 把 Parlia 的 4 个 block interval 常量全部 override 为 `3000ms`：

```go
// params/protocol_params.go:200-203
DefaultBlockInterval uint64 = 3000   // 3000 ms
LorentzBlockInterval uint64 = 3000   // 上游 BSC 是 1500ms
MaxwellBlockInterval uint64 = 3000   // 上游 BSC 是 750ms
FermiBlockInterval   uint64 = 3000   // 上游 BSC 是 450ms
```

`consensus/parlia/snapshot.go:351-358` 的 BlockInterval switch 按 `IsLorentz / IsMaxwell / IsFermi` 切换 snapshot 里的 `BlockInterval` 字段；因为四个常量都是 3000，**激活与否不改变出块速度**。

**这是 devnet / testnet / mainnet 三网共同承诺**。后续若需要改变出块速度，必须定义新 fork（已激活 fork 的 BlockInterval 不可追溯修改，历史 snapshot 已固化）。

### 代码现状：EpochLength 统一为 Parlia defaultEpochLength = 200

`Clique.Epoch = 30000`（Clique snapshot 校验点间隔）和 Parlia `defaultEpochLength = 200`（把 active mining set 写入 `header.Extra` 的节奏，validator set 链上检查点）是**两个独立、不同语义**的常量。Parlia epoch 长度随 fork 变化：`defaultEpochLength=200` → `lorentzEpochLength=500` → `maxwellEpochLength=1000`（`consensus/parlia/parlia.go:58-60`）。

**PGB 时 `snap.EpochLength` 来源**（v0.3.0 retro 修复后，`parlia.go:956-967`）：读取顺序 `ChainConfig.Parlia.Epoch`（显式覆盖）→ `defaultEpochLength=200`（fallback），**不再从 `Clique.Epoch` 拷贝**。

v0.3.0 踩坑根因（详见 §十 retro）：LubanBlock 选址按 Parlia `defaultEpochLength=200` 假设（`165400 % 200 == 0`），但运行时 `snap.EpochLength=30000`（PGB 从 Clique 拷贝），`165400 % 30000 ≠ 0` → 165400 不是 epoch block → Luban-form validator list 没写进 extraData。PGB 自身不受影响（`IsOnParliaGenesis` 强制视为 epoch boundary）；问题只在 PGB 之后依赖 `number % epochLength == 0` 的**普通** fork block。

ABCore 三网显式设 `Parlia: &ParliaConfig{Epoch: 200}`，对齐 BSC 上游（100→200→Lorentz 500→Maxwell 1000）。**`snapshot.go:362-372` 的自动 promotion 要求起点必须是 `defaultEpochLength=200`，否则 Lorentz/Maxwell 激活时 epoch 切换永不触发。**

**fork × epoch 切换对照**：

| fork | 激活前 epoch | 激活后 epoch | 切换触发条件 |
|---|---|---|---|
| (起点) | — | 200 | PGB 时 reseed |
| Lorentz | 200 | 500 | 第一个 `block.Number % 500 == 0` 且 `IsLorentz(time)` |
| Maxwell | 500 | 1000 | 第一个 `block.Number % 1000 == 0` 且 `IsMaxwell(time)` |
| Fermi/Osaka/... | 1000 | 1000（不变） | — |

测试覆盖：`transition_snapshot_test.go` 的 `TestSnapshotGenesisPathRespectsParliaEpoch`（N=600）。

### 代码现状：one-shot system contract bytecode

见上方[一次性字节码部署](#one-shot-bytecode)。要点：bytecode 源自 `abcore-v2-genesis-contract`（init commit `bnb-chain/bsc-genesis-contract 34618f6`，已含 Luban / Plato / Feynman / Bohr 等全部 fork 改动），PGB 一次性部署最终版；`core/systemcontracts/upgrade.go:1453-1475` 对 ABCore 网络 early-return，所有 `*Upgrade[mainNet/chapelNet]` map（含 bohr/pascal/lorentz/maxwell/fermi）永不触发。

---

## 二、Fork 依赖关系与合并策略

### 关键依赖链

```
【代码层真实依赖】
ParliaGenesisBlock
    ↓ 必须先于 LondonBlock（IsParlia 前置）
LondonBlock
    ↓ IsShanghai/IsCancun/IsFeynman/IsLorentz/IsMaxwell/IsPrague/IsBohr/IsFermi/IsOsaka/IsMendel 全部仅依赖 IsLondon()
13 个 BSC block forks（Ramanujan → Hertzfix，须严格升序，可全设同一块高）
    ↓ CheckConfigForkOrder 要求 block forks 先于 timestamp forks
（以下 timestamp forks 代码层仅依赖 IsLondon()，彼此无强制顺序依赖）
KeplerTime + ShanghaiTime                                — v0.4.0 (T3)
FeynmanTime + FeynmanFixTime                              — v0.4.0 (T3)
CancunTime + HaberTime + HaberFixTime                     — v0.5.0 (T4)
PascalTime + PragueTime + LorentzTime + MaxwellTime + BohrTime  — v0.6.0 (T5)
FermiTime + OsakaTime + MendelTime                        — v0.7.0 (T6)
```

> **Bohr / Fermi 在 ABCore 上 no-op**（详见 §一 / §三）：Fermi 不改变出块速度（BlockInterval override 3000ms），Bohr TurnLength 默认 1，唯一可见变化是 header.extra 末尾追加 1 字节 turnLength（值 1）。

> **演练推荐顺序**（非代码依赖，基于风险隔离）：Shanghai/Feynman → Cancun → Prague+Lorentz+Maxwell+Bohr → Fermi+Osaka+Mendel。

### 关于"13 个 BSC block forks 是 no-op"的说明

**两层影响要分清（PR #99 加入校准）**：

**Layer 1 — 系统合约 bytecode**：因[一次性字节码部署](#one-shot-bytecode)，13 个 BSC block fork 对 bytecode **全是 no-op**，fork block 上无任何 bytecode upgrade 日志（PR #99 之前会有 `Empty upgrade config` INFO，是预期行为，PR #99 起消除）。

**Layer 2 — Parlia 引擎层 / chain-config gate**：每个 fork 仍按 chain config 顺序激活引擎层行为：

| Fork | 引擎层实际影响 | bytecode 升级（对 ABCore）|
|------|---------|---|
| Ramanujan, Niels | 出块 backoff 逻辑改进 | no-op |
| MirrorSync, Bruno, Euler, Gibbs, Nano, Moran, Planck | gas/内存调整、少量系统合约调用方式变化 | no-op |
| **Luban** | **非 no-op**：epoch block extraData 从 20B/validator → 68B/validator（20B 地址 + 48B 零值 BLS 公钥）；vote-attestation 字段引入；引擎调 `getMiningValidators()` 替代 `getValidators()` 读 validator set | no-op（合约 bytecode 从 PGB 起就支持 Luban 接口）|
| Plato | Parlia `IsOnPlato` 路径，fast-finality 投票 precompile 启用（无 vote address 时是 no-op）| no-op |
| Hertz, Hertzfix | EIP gas 调整 | no-op（无 upgrade map）|

**Parlia epoch 长度**：`Parlia.Epoch = 200`，PGB reseed 读 `chainConfig.Parlia.Epoch` fallback 200，不再从 `Clique.Epoch` 拷贝（详见 §一 EpochLength 小节 + §十 v0.3.0 retro）。

**v0.3.0 真正验证**：✓ EIP-1559 header schema（`baseFeePerGas=0x0`）✓ 第一个 Parlia epoch block 写 Luban-form 438B extraData（M 选 200 倍数则 M 本身即是，否则等 `ceil(M/200)*200`）✓ 无 errExtraSigners / errInvalidSpanValidators。**不要误判**：M off-grid 时 M 自身 97B 是正确行为；`lubanUpgrade[abcoreDevNet]` 故意不注册。

### 可合并的 fork

| 合并包 | 理由 |
|--------|------|
| 13 个 BSC block forks + LondonBlock 全设同一块高 M | CheckConfigForkOrder 允许同值；减少升级次数 |
| KeplerTime = ShanghaiTime | BSC 官方惯例 |
| FeynmanTime = FeynmanFixTime | BSC 官方惯例 |
| CancunTime = HaberTime = HaberFixTime | BSC 官方惯例 |
| PascalTime = PragueTime | 无互相依赖 |

### 必须分开的 fork

| 分隔点 | 理由 |
|--------|------|
| Upgrade 1（Parlia）和 Upgrade 2（London）分两批 | 先稳定 Parlia 共识（≥1 Parlia epoch）再引入 basefee |
| Upgrade 3（Feynman）和 Upgrade 4（Cancun）分开 | Feynman 有手动 validator 注册，独立后出问题更容易定位 |
| Upgrade 6（Fermi+Osaka+Mendel）和 Upgrade 5 分开 | Osaka 需要 `blobSchedule.osaka` 配置，与 Cancun blob schedule 解耦后更容易验证 |
| LorentzTime / MaxwellTime 在 Upgrade 5 内部各留 1 天 / 7 天偏移 | epoch 长度变化影响 validator rotation，需逐步验证 |

---

## 三、6 次升级详细内容

> **T 编号约定**：T1 / T2 不存在，因 Upgrade 1（Parlia）和 Upgrade 2（London）按**块高 N / M** 激活；从 Upgrade 3 起按**时间戳**激活，依次为 T3 (v0.4.0)、T4 (v0.5.0)、T5 (v0.6.0)、T6 (v0.7.0)。

### 每批次标准激活前 Checklist

```
□ 1. 确认当前块高/时间戳，验证激活点仍有足够操作窗口（块高 fork：距 N 至少剩余 500 块；时间戳 fork：T 已硬编码于 binary，确认 T 距当前时间仍有足够替换窗口）
□ 2. Observer 节点（非 validator）先运行新 binary，验证同步无崩溃（canary 检查）
□ 3. 验证所有节点 NTP 偏差（chronyc tracking）< 1s
□ 4. 验证节点间 peer count 稳定（每个节点至少 2 个已连接 peer）
□ 5. 发送测试交易，确认链正在出块
□ 6. 停机前做全量 datadir 快照（clean shutdown 后再复制，见快照规程）
□ 7. 按顺序替换 binary：
      server-3（val-4，单节点）→ server-1（val-0/1）→ server-2（val-2/3）→ server-4（rpc-0）
      每台替换后验证重连正常，peer count 恢复
□ 8. 所有节点在激活时间戳 T 到达前完成 binary 替换：
      T 已硬编码于 binary（params/config.go），与块高激活对称。发布时 T 选距发布 ≥ 48h 的 UTC 整点（Mainnet ≥ 1 周）。
      发布后立即 release freeze：记录 sha256 + fork 时间戳；冻结 artifact/config/checksum 不允许修改；
      若 T 前发现 critical bug，发布新 binary（T 推迟或设 maxUint64）全网替换后重排；不允许 T 临近(<1h)或已过后改 config。
□ 9. 等待激活点到达
□ 10. 执行对应 Upgrade 的验证清单
□ 11. 观察 2-3 个 epoch（确认 proposer rotation 正常、无 consensus 错误）再宣布成功
```

### 快照规程（一致性要求）

```
1. 停止节点（clean shutdown，等待日志输出"stopped"）
2. 记录当前块高（快照基准高度）
3. 复制 datadir 到备份目录（若使用 --datadir.ancient 外置 freezer，需一并备份）：
   cp -a /data/validator-N /backup/validator-N-pre-upgradeX-blockH
   # 若有外置 ancient 目录：
   cp -a /data/validator-N-ancient /backup/validator-N-ancient-pre-upgradeX-blockH
4. 计算校验和：
   find /backup/validator-N-pre-upgradeX-blockH -type f | sort | xargs sha256sum > /backup/manifest-N.txt
5. 快照前验证所有节点的 canonical head 一致（滚动替换下各节点可能差几个块，允许偏差 ≤ 5 块；若差异更大则先排查）：
   cast rpc eth_getBlockByNumber latest true --rpc-url http://rpc-0:8545 | jq '{number:.number,hash:.hash,stateRoot:.stateRoot}'
   # 所有节点返回的 hash/stateRoot 若有分叉（相同块高不同 hash），先解决分叉再快照
```

---

### Upgrade 1：v0.2.0 — 共识切换（Clique → Parlia）

> **⚠️ 块高为演练示例值，不是预设的真实值。** N、M 及所有后续块高/时间戳均须在执行前根据实际环境重新设定：DevNet 可选较小值（如 N=500）缩短等待；Testnet/Mainnet 的具体值在 DevNet 演练通过后才确定。

> **⚠️ Cutover 操作步骤参考 [fork-cutover-runbook.md](fork-cutover-runbook.md)。** 该 runbook 详述了"为什么 Phase 2 必须 rolling 升级（不能 stop-all）"、安全余量计算、abort 标准、后置验证。本节只列 N 的设定与块 N 自动行为，不重复 cutover 流程。

<a id="blockscout-pre-cutover-checklist"></a>
**Blockscout pre-cutover checklist：**

任何下游 indexer 都要在 cutover 之前完成共识切换适配。Blockscout 的具体动作：确认 `BLOCK_TRANSFORMER=base`（默认值）而**不是** `clique`。

**根因**：`eth_getBlockByNumber` 的 `miner` 字段直接 marshal `header.Coinbase`（[`internal/ethapi/api.go:1459`](../../internal/ethapi/api.go#L1459)），不走 `engine.Author()`。Clique 阶段 `header.Coinbase` 恒为 `0x0`（协议规定，signer 在 extraData 末尾 65 字节签名）；Parlia 阶段 `Prepare()` 把 validator 地址写进 `header.Coinbase`（[`parlia.go:1296`](../../consensus/parlia/parlia.go#L1296)）。`base` transformer 直接用 RPC `miner`，两阶段都正确。`clique` transformer 忽略 RPC `miner`、自己拿 extraData 末尾 65 字节 ecrecover —— Parlia extraData 布局是 `vanity(32)+validators(N×20)+vote_attestation+seal(65)`，ecrecover 的是 Parlia 域签名，得到**确定性但无意义的伪地址**，每块一个污染 `addresses` 表。Blockscout 启动时一次性读 `BLOCK_TRANSFORMER`，不支持按块号切换，所以唯一可行策略是从头用 `base`。

**Cutover 前的操作步骤（在 Blockscout 部署服务器上）：**

```bash
# 1. 查看当前值
docker inspect <blockscout-backend-container> \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep BLOCK_TRANSFORMER

# 2. 如果是 clique，改成 base：
#    在 blockscout 的 docker-compose override 文件（例如 geth-clique-consensus.yml）里：
#       BLOCK_TRANSFORMER: 'base'
#    然后重启 backend：
#       docker compose up -d --force-recreate backend

# 3. 验证生效（同上 grep）：
#   BLOCK_TRANSFORMER=base    → OK
#   (空输出)                  → OK（默认即 base；建议显式写 base 便于审计/值班交接）
#   BLOCK_TRANSFORMER=clique  → BLOCKER，必须先改 base 再 cutover
```

**如果错过了 pre-cutover，cutover 后才发现问题**（症状：dashboard 的 `total_addresses` 每秒涨，但链上 tx 极少）：

```bash
# 1. 改 BLOCK_TRANSFORMER=base 并重启 backend（如上）
#
# 2. 触发 Parlia 区块 refetch（让 base transformer 重写 miner）：
psql -U blockscout -c "
  INSERT INTO missing_block_ranges (from_number, to_number, priority)
  VALUES (<current_head>, <PGB>, 5);"
# (range 写法：from_number > to_number，indexer 从高到低拉)
#
# 3. 等 indexer 跑完（~1 分钟/几千块），然后清理孤儿地址：
psql -U blockscout -c "
  DELETE FROM addresses
  WHERE contract_code IS NULL
    AND (nonce IS NULL OR nonce = 0)
    AND (fetched_coin_balance IS NULL OR fetched_coin_balance = 0)
    AND hash NOT IN (SELECT DISTINCT miner_hash FROM blocks WHERE miner_hash IS NOT NULL)
    AND hash NOT IN (SELECT DISTINCT from_address_hash FROM transactions
                     UNION SELECT DISTINCT to_address_hash FROM transactions
                     WHERE to_address_hash IS NOT NULL);"
#
# 4. last_fetched_counters.addresses_count 是 cached 值，会在下一个
#    Blockscout 内部 recount 周期自动更新（≤ 1 小时）。不急可以等；
#    急了可 DELETE 那一行让下次请求即时 recount。
```

DevNet 2026-05-14 cutover 验证过这套补救流程，约 1 分钟完成 2400 块 refetch。

**params/config.go 修改：**
```go
// N = 2400（devnet 实测值，2026-05-28 reset re-run 后；与 05-26 那次相同）
// 选址要求：(a) head + ≥1h safety margin；(b) 200 grid 对齐属运维约定（非协议要求），
// 因为 PGB 通过 IsOnParliaGenesis 路径已被强制视为 epoch boundary。
// 实际值须在执行前根据当前链高度重新设定。
ABCoreDevnetChainConfig.ParliaGenesisBlock = big.NewInt(2400)
ABCoreMainChainConfig.ParliaGenesisBlock   = big.NewInt(N_mainnet)
ABCoreTestChainConfig.ParliaGenesisBlock   = big.NewInt(N_testnet)
```

**Parlia validator-set bootstrap（自动，无需预填充）：**
`prepareValidators` 在块 N 时从 Clique checkpoint extraData 自动读取当前 5 个 signer 地址，写入 Parlia snapshot。不需要提前在系统合约中填充 validator 地址，`INIT_VALIDATORSET_BYTES` 由 genesis 合约 bytecode 内嵌。

**块 N 自动发生（无需操作）：**
1. `TryUpdateBuildInSystemContract`（atBlockBegin=true）→ 部署 17 个系统合约
2. Parlia `Finalize` → `initContract` → 调用所有合约 `init()`，写入 `INIT_VALIDATORSET_BYTES`
3. `prepareValidators` → 从 Clique checkpoint 读取 5 个 validator 地址，写入 Parlia snapshot
4. Parlia 接管出块

**Parlia 切换完整验证清单：**
```bash
# 1. 日志无 errExtraSigners
grep "errExtraSigners" <logfile> | wc -l  # 期望 0

# 2. blockNumber 正常推进
eth.blockNumber

# 3. signer ordering 正确（Parlia 要求 validator 地址升序排列）
# 在 epoch block（N 本身若是 epoch block，或等待下一个 epoch block）的 extraData 中解析 validator 列表，验证地址升序
# 非 epoch block 的 extraData 不携带 validator 列表，不可在非 epoch block 验证此项

# 4. 系统合约已部署
eth.getCode("0x0000000000000000000000000000000000001000")  # 非 0x

# 5. validator set 从系统合约读取正确（5 个地址）
cast call 0x0000000000000000000000000000000000001000 \
  "getValidators()(address[])" --rpc-url http://rpc-0:8545

# 6. proposer rotation 正常（出块连续 10 个块内所有 5 个 validator 均有出块）

# 7. 等待第一个 Parlia epoch boundary（块高为 ceil(N/200)*200），验证 validator set 不变
```

**Foundation 多签 fee 验证（v0.2.0 后，本轮新增）：**

`deposit()` 是 Parlia 出块时每块由 coinbase 调用的 system tx，把 `FOUNDATION_RATIO`(15%) 的区块手续费通过 `call{value:,gas:30000}` 发给 `FOUNDATION_ADDR`（devnet = Safe multisig `0x0B53A578F024580563Ef1349b1F2c289115f6bE8`，owners=anvil[1,2,3]/2，由 init pipeline 在 PGB 前部署）。**只有 Parlia 接管出块后这条路径才跑**，所以 v0.2.0 是第一个能验证的档。

```bash
SAFE=0x0B53A578F024580563Ef1349b1F2c289115f6bE8
RPC=http://rpc-0:8545

# 1. deposit() system tx 每块不 revert（核心：验证 call{gas:30000} 对真实 Safe 不卡链）
#    若 deposit revert，链会卡在 finalize；上面"blockNumber 正常推进"已覆盖，
#    但额外确认日志无 "deposit" 相关 system tx 失败。

# 2. Safe 已部署且 owners/threshold 正确
cast call $SAFE "getOwners()(address[])"   --rpc-url $RPC   # = anvil[1,2,3]
cast call $SAFE "getThreshold()(uint256)"  --rpc-url $RPC   # = 2

# 3. 发非零 gasPrice 的 LEGACY 交易制造区块 fee → 观察 Safe 余额增长 ≈15%
#    v0.2.0 无 London/EIP-1559，必须 --legacy + 非零 --gas-price，否则 fee=0
#    foundation 收不到钱（非 bug）。
BEFORE=$(cast balance $SAFE --rpc-url $RPC)
cast send <recipient> --value 0 --legacy --gas-price 1gwei \
  --private-key <funder_key> --rpc-url $RPC
# 等几个块后
AFTER=$(cast balance $SAFE --rpc-url $RPC)
echo "Safe gained: $((AFTER - BEFORE)) wei (应 ≈ 该块总 fee 的 15%)"

# 4. owners 2/3 多签从 Safe execTransaction 转出，验证多签可用（资金能进能出）
#    用 anvil[1]+anvil[2] 两个 owner 签名（地址升序拼接），relayer 广播。
```

> **v0.3.0 复测**：London/EIP-1559 激活后 fee 模型从 legacy gasPrice 变为 baseFee+priority，`deposit()` 收到的 `msg.value` 构成变化。v0.3.0 后需复测 foundation 仍稳定收到 ≈15%。

**回滚预案：**
- 块 N 之前：全网换回 PGB=nil 配置，Clique 继续，无影响
- 块 N 之后或 cutover 失败（链卡住、报 `errInvalidSpanValidators`、节点之间 b N hash 不一致）：执行 [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md) 完整流程（停链 + maintenance 模式 setHead(N-1) + 移除 PGB 配置 + 全网 Clique 恢复）。**不要简单重启**——磁盘上的 Clique-form b N 仍在，重启会重新进入死锁。

**观察窗口：≥ 24h（≈ 28800 块 @ 3s）再推进 Upgrade 2。覆盖至少一个完整 Go 层 breathe block 周期，即使 v0.4.0 还没激活 Feynman 也确认调度路径不报错。**

**Upgrade 1 后执行 snapshot restore drill**（对象 val-4，单节点最安全）：停止 val-4 → `sha256sum -c manifest` 验证快照 → 恢复 pre-N datadir → **保持 v2 binary**（恢复后 v2 从 pre-N 旧块高重新同步追上 Parlia 链；用 v1 接入已切 Parlia 的网络不可行）→ 启动，观察从旧块高重新追链、链继续推进（4 validator 维持多数派）、无双签告警 → 追上 head 后再停止 → 恢复最新快照重新加入。目的：验证快照可恢复性 + manifest 准确性 + v2 追链/P2P 再加入流程。

**Release 配置完整性验证：**
每次 release binary 启动后，验证：
```bash
# 1. chain ID 正确
cast chain-id --rpc-url http://rpc-0:8545  # 期望 17140

# 2. genesis hash 正确（与 release notes 中一致）
eth.getBlock(0).hash

# 3. fork 配置正确（验证几个关键 fork 块高）
# 通过日志或 eth_getBlockByNumber 确认激活点与 release notes 一致
```

---

### Upgrade 2：v0.3.0 — London + 13 BSC block forks

**params/config.go 修改（**M 为示例值，须在执行前根据实际链高度重新设定**；建议 M 满足：(a) ≥ N + 28800 块（≥ 24h 观察窗口 @ 3s），(b) M mod 200 = 0（epoch boundary），这样 Luban extraData 变更在 M 自己生效）：**
```go
// M = 3600（devnet 实测值，2026-05-28 reset re-run；与 05-26 那次相同；= N(2400) + 1200 = reset + 3h，
// **故意短于 ≥24h 推荐窗口**，这是 devnet rehearsal pacing demo，testnet/mainnet
// 不要复制这个 gap。3600 mod 200 = 0 满足 epoch boundary 要求）
// 实际值须在执行前根据当前链高度重新设定
LondonBlock:     big.NewInt(3600),
RamanujanBlock:  big.NewInt(3600),
NielsBlock:      big.NewInt(3600),
MirrorSyncBlock: big.NewInt(3600),
BrunoBlock:      big.NewInt(3600),
EulerBlock:      big.NewInt(3600),
GibbsBlock:      big.NewInt(3600),
NanoBlock:       big.NewInt(3600),
MoranBlock:      big.NewInt(3600),
PlanckBlock:     big.NewInt(3600),
LubanBlock:      big.NewInt(3600),   // 非 no-op，需专项验证；必须落在 epoch boundary
PlatoBlock:      big.NewInt(3600),
HertzBlock:      big.NewInt(3600),
HertzfixBlock:   big.NewInt(3600),
```

> **M 与 epoch boundary**：Luban extraData 格式变更只在 Parlia epoch block（`Parlia.Epoch=200` 整数倍）生效。M 非 epoch block 时 M 自身 extraData 仍是 97B（正确行为非 bug），首个 Luban-form 438B 块为 `ceil(M/200)*200`。**推荐 M 选 epoch boundary（M mod 200 = 0）**，激活块即完成可观察性验证，也避免把"97B 不是 438B"误判为 bug。详见 §十 v0.3.0 retro 的 165400 复盘。

**激活效果：**
- EIP-1559 basefee 机制生效
- Luban：validator extraData 从 20B → 68B（零值 BLS key 自动回填）
- 解锁所有后续 timestamp forks 的前提条件

**验证清单：**
```bash
# 1. baseFeePerGas 非零
eth.getBlock(M).baseFeePerGas  # > 0

# 2. Luban extraData 格式（第一个 Luban epoch block：ceil(M/200)*200，M 为实际激活块高）
# 字节长度 = 32B vanity + 5×68B validators + 65B seal = 437B
# RPC 返回 hex 字符串已含 "0x" 前缀，jq .length = 2 + 437*2 = 876
EPOCH_BLOCK=$(( (60001 + 199) / 200 * 200 ))
cast rpc eth_getBlockByNumber $(cast to-hex $EPOCH_BLOCK) false --rpc-url http://rpc-0:8545 \
  | jq '.extraData | length'  # 期望 876

# 3. legacy type-0 交易仍可发送（向后兼容）

# 4. 链继续正常推进
```

**观察窗口：≥ 48h**

---

### Upgrade 3：v0.4.0 — Shanghai + Kepler + Feynman + FeynmanFix

**params/config.go 修改：**
```go
ShanghaiTime:   newUint64(T3),
KeplerTime:     newUint64(T3),
FeynmanTime:    newUint64(T3),
FeynmanFixTime: newUint64(T3),
```

> **T3 的设定**：T3 在发布 binary 时已硬编码，建议选择距发布时间 ≥ 48h 的 UTC 整点；Mainnet 建议 ≥ 1 周。所有节点须在 T3 到达前完成 binary 替换。
> **注意**：`BREATHE_BLOCK_INTERVAL = 10 分钟`，breathe block 的触发以 block.timestamp 对齐。若 T3 恰好落在 breathe 对齐点，第一个 breathe block 可能在激活后立即触发，注册窗口为零。**建议 T3 选在 breathe interval 边界后 3–5 分钟**（例如：breathe 在 HH:00/HH:10/...，则 T3 选 HH:03 或 HH:13），确保第一个 breathe block 距 T3 有足够缓冲完成注册。

**激活效果：**
- Shanghai/Kepler：EIP-3855（PUSH0）、EIP-3860（initcode size limit）、EIP-4895 对应的 BSC staking 相关逻辑（非 Ethereum beacon chain withdrawal 语义）
- Feynman：`updateValidatorSetV2` 在 breathe block 生效，StakeHub 开始参与 validator 选举

#### Validator 注册流程与活动窗口（Feynman 运维必读）

Feynman 后 validator 管理由 StakeHub (`0x...2002`) 接管，但"出块名册"仍由 BSCValidatorSet (`0x...1000`) 持有。理解三层 set + 两套时钟是避免 cutover 事故的前提。

**三层 validator 集合**：`StakeHub._validatorSet`（注册池，createValidator 写入）── breathe block (Go 层 24h，触发 `updateValidatorSetV2`，按 voting power 选 top-N) ──→ `BSCValidatorSet.currentValidatorSet`（top-N，含 jailed/maintaining，mainnet ~41）── epoch block (`% 200 == 0`，Parlia 调 `getMiningValidators` 过滤 jailed → cabinet + 候补洗牌，写 header.Extra) ──→ 实际出块名册。

**两套独立时钟**（都叫"breathe block"但作用/节奏不同，**不同步漂移**）：

| 时钟 | 来源 | devnet 值 | 作用 |
|---|---|---|---|
| **Epoch block** | Parlia `defaultEpochLength` | 200 块 ≈ 10 分钟 | 每 200 块把 mining set 写进 header.Extra |
| **Breathe block (Go 层)** | `params.BreatheBlockInterval` | 24h（UTC 天对齐）| 触发 `updateValidatorSetV2` 刷新 currentValidatorSet |
| **`BREATHE_BLOCK_INTERVAL` (合约)** | `StakeHub.sol` 常量（devnet 编译替换）| 10 分钟 | editXxx 冷却 + slash 桶 + 旧地址过期 |

**validator 操作对照**：

| 操作 | 冷却 | 谁可调 | 备注 |
|---|---|---|---|
| `createValidator` | 无 | 任何账户 | 任意时刻可注册；注册本身 set `updateTime`，10 分钟内不能 editXxx |
| `editConsensusAddress` / `editCommissionRate` / `editDescription` / `editVoteAddress` | **共享** 10 分钟 | 自己 operator key | 4 项共享同一个 `valInfo.updateTime` |
| `getValidatorBasicInfo` / `getValidatorElectionInfo` / `getMiningValidators` | — | 任何账户 | 三个查询角度，前两者读 StakeHub，最后一个读 BSCValidatorSet |

**Feynman 激活后的注册窗口（运维流程）**：窗口 = T3 激活那一刻 → 第一个 Go 层 breathe block（最坏接近 0 秒，取决于 T3 距 UTC 0 点多远）。**建议 T3 选在 UTC 边界 (HH:00:00) 之后 3-5 分钟**，能有近一天的注册时间。

**错过窗口的真实后果**（Parlia 轮值出块，1 个 validator 就能持续出块，无 N/2 阈值）：

| 情形 | 结果 | 链状态 |
|---|---|---|
| **0 个注册** | `updateValidatorSetV2(empty,...)` → `_forceMaintainingValidatorsExit` 访问空数组 `_validatorSet[0]` → 合约 revert → system tx 失败 → finalize 失败 | **链卡住**（[BSCValidatorSet.sol#L1011-L1019](https://github.com/ABFoundationGlobal/abcore-v2-genesis-contract/blob/master/contracts/BSCValidatorSet.sol#L1011-L1019)）|
| **1-4 个注册** | currentValidatorSet 被覆盖成残缺集，任一 validator 离线即出块停顿 | 高风险但能出块 |
| **5 个全注册** | 干净切换，新选举生效 | ✅ 正常 |

**推荐策略：必须在第一个 Go 层 breathe block 之前完成全部 5 个 `createValidator`**（与旧文档相反——空集**不**安全会直接卡链）。绝对避免"先注册 1-2 个测试"（收缩成残缺集，需等下一个 24h breathe block 恢复）和"一个都不注册"（空集 revert 卡链）。

> **协议级保护缺失**：BSC 假设 Feynman 激活时 StakeHub 已有 mainnet 那 41 个 validator，从未测过"空 StakeHub"路径；合约 line 229-233 的空集 short-circuit 看似防空集但到不了——line 211 `_forceMaintainingValidatorsExit` 先 revert。ABCore 的 Clique→Parlia migration 是 BSC 没设想的场景，**必须在 v0.4.0 激活前手动保证 StakeHub 非空**。

#### Feynman 操作命令（5 个 validator 注册）

`createValidator()` 作用：注册现有的 5 个 Parlia validator 到 StakeHub（consensus address 已在 `INIT_VALIDATORSET_BYTES` 中），active set 大小不变，不新增 validator。调用是幂等的：已存在时 revert，不 panic。

```bash
STAKE_HUB="0x0000000000000000000000000000000000002002"

# 动态查询 createValidator 所需的 msg.value（min_self_delegation + LOCK_AMOUNT）。
# 这两个值都来自部署时的 generate.py 默认值，不要硬编码——一旦未来通过
# governance 改了 minSelfDelegationBNB，硬编码值就过期。
MIN_SELF_WEI=$(cast call $STAKE_HUB "minSelfDelegationBNB()(uint256)" --rpc-url http://rpc-0:8545)
LOCK_WEI=$(cast call    $STAKE_HUB "LOCK_AMOUNT()(uint256)"          --rpc-url http://rpc-0:8545)
TX_VALUE_WEI=$(python3 -c "print(${MIN_SELF_WEI} + ${LOCK_WEI})")
# 健全性检查（避免合约未初始化导致发空 tx）
[ "${MIN_SELF_WEI}" -gt 0 ] || { echo "ERROR: minSelfDelegationBNB() == 0, StakeHub not initialized?"; exit 1; }

# coordinator 使用各 validator 的 operator key 依次代执行（需持有全部 operator key）
# gas 由 operator 账户支付（--private-key <operator_key>），确保 operator 地址有足够余额（详见下方预检）
cast send $STAKE_HUB \
  "createValidator(address,bytes,bytes,uint64,(string,string,string,string,string))" \
  <consensus_address> \
  <vote_address_bytes> \
  <bls_proof_bytes> \
  <commission_rate_bps> \
  "(<moniker>,<identity>,<website>,<security_contact>,<details>)" \
  --value "${TX_VALUE_WEI}" \
  --private-key <operator_key> \
  --rpc-url http://rpc-0:8545

# 验证注册状态
cast call $STAKE_HUB "getValidatorBasicInfo(address)" \
  <consensus_address> --rpc-url http://rpc-0:8545
```

**StakeHub 预检（T3 激活前）**：

- 验证 StakeHub 合约地址：`eth.getCode("0x...2002")` 非 0x
- 确认每个 operator 账户（签 createValidator、付 gas，非 consensus 地址）余额充足。余额要求（generate.py 统一注入，三网当前 staking 阈值一致）：`min_self_delegation = 20亿 ether` + `LOCK_AMOUNT = 1 ether`（StakeCredit 锁仓）+ `delegate` 的 `min_delegation_change = 1亿 ether` + gas ≈ 0.01 → 每个 operator 最低 > 21.0001亿 ether（质押均入池不销毁）。DevNet 实际起步：每 validator 100亿 ether、funder 1000亿 ether。`cast balance <operator>`
- 部署前比对 binary sha256 与 release checksum；提前在 DevNet 模拟 createValidator 确认 nonce/ABI/参数

**createValidator 提交策略**：串行提交（validator-0 → 等 receipt → 验证 → validator-1 …），不并行避免 nonce 竞争。幂等：已存在时 revert，可安全重试。

**StakeHub 注册补救策略**（"错过窗口后果"见上方注册流程章节）：

- 部分注册（1-4 个）：等下一个 Go 层 breathe block（24h）自动重选举；其间用残缺集出块，**禁止重启不在 active set 里的 validator 节点**
- **0 个注册（链将在第一个 breathe block 卡住）**：紧急动作——立即至少 1 个 validator `createValidator`，该 tx 必须在 breathe block 出块前被打包；若已卡住必须 rollback（[consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md)）
- DevNet 要求先串行跑完 5 个 createValidator 确认成功，才可在 Testnet/Mainnet 采用。**不允许"边激活边补注册"**。

**（可选）激活 govAB 治理投票权：**

`createValidator()` 通过 `GovToken.sync()` mint govAB 余额但不写 ERC20Votes checkpoint，故 `getVotes(operator) == 0`。要参与 `BSCGovernor` 治理提案，每个 validator 须额外调一次 `StakeHub.delegate(operator, true)`，`msg.value ≥ minDelegationBNBChange`（production 部署默认 `1亿 ether`），BNB 入池不销毁。

> **设计原因**：投票委托与质押故意解耦，允许 operator 把 govAB 投票权委托给独立治理代理地址。

> **环境差异**：`script/test/upgrade-drill/` 用 `abchain-local` 模式，`minDelegationBNBChange = 1 ether`；本节是 mainnet/testnet/devnet **production 部署**（`abchain-main/test/dev` 模式），默认 `1亿 ether`。两者是不同 generate.py 子命令注入的不同默认值，不冲突。下方 bash 用 `cast call` 动态查询而非硬编码。

```bash
GOV_TOKEN="0x0000000000000000000000000000000000002005"

# 动态查询当前 chain 的 minDelegationBNBChange，避免硬编码与实际部署值不一致
MIN_DELEG_WEI=$(cast call $STAKE_HUB "minDelegationBNBChange()(uint256)" --rpc-url http://rpc-0:8545)
[ "${MIN_DELEG_WEI}" -gt 0 ] || { echo "ERROR: minDelegationBNBChange() == 0, StakeHub not initialized?"; exit 1; }

# 每个 validator 执行一次（--private-key 使用对应 operator key）
cast send $STAKE_HUB \
  "delegate(address,bool)" \
  <operator_address> \
  true \
  --value "${MIN_DELEG_WEI}" \
  --private-key <operator_key> \
  --rpc-url http://rpc-0:8545

# 验证投票权已激活（应返回非零值）
cast call $GOV_TOKEN \
  "getVotes(address)(uint256)" \
  <operator_address> \
  --rpc-url http://rpc-0:8545
```

**DevNet funder 账户（2026-05-26 reset 后）**：genesis alloc 含一个 well-known funder = Foundry/Anvil 默认账户 #0（公开 mnemonic `"test test ... junk"` 派生）。

- 地址 `0xf39Fd6e51aad88F6F4ce6aB8827279cfFFb92266`，起步余额 10^11 ether（10^29 wei）；私钥业界公开（`cast wallet derive-private-key "test ... junk" 0`）
- 用途：governance 演练给 delegator transfer 提升 govAB 持仓测试 propose/quorum 边界（5 validator × 20亿 = 100亿 govAB，距 propose_start_threshold 300亿 差 200亿，由 funder transfer 后再 delegate）

> ⚠️ **严格仅限 DevNet**：私钥全球公开。绝不可在 Testnet/Mainnet 部署该地址、作为 production 合约 admin/owner/multisig signer、或把含该私钥的脚本复用到 Testnet/Mainnet（必须替换 funder）。对照：Testnet 有专用 funder（`0x009f1ddaf7f528e60a7c560c51ae997cd4709cc3`，私钥仅 ops 持有），Mainnet 走 Foundation 分发，无 well-known funder。

#### Fast finality 节点启动参数（`--vote`，T3 起生效）

Feynman 同时激活 BEP-126 fast finality（BLS 投票最终性）。注册 `vote_address`（上方 `createValidator` 的 `<vote_address_bytes>`）只是**链上**那一半；validator 进程还必须用 fast-finality 相关 flag **启动**才会真正产生并广播 BLS vote attestation。两半缺一不可：

| 半边 | 内容 | 缺失后果 |
|---|---|---|
| 链上 | `createValidator` 写入 `vote_address`（BLS pubkey）+ proof | 没注册 → 该 validator 的投票被其它节点拒收 |
| 链下 | 节点启动加 `--vote --blswallet <path> --blspassword <path>` | 没加 → 节点根本不投票，`eth_getFinalizedHeader` / `cast block finalized` 恒停在 genesis |

> **关键**：fast finality **没有"慢速降级"路径**。BEP-126 要求 ≥⌈2N/3⌉ 个 validator 对区块产生 BLS attestation，凑够 quorum 才能 justify（1 个）→ finalize（连续 2 个 justified）。投票不足时 `finalized` 恒为 0，**不是"变慢"而是完全不 finalize**。因此链上能观察到 finalized 高度持续推进，本身就证明 `--vote` 在所有 validator 上都已开启。

**devnet 部署落点**：`devnet-ops` 的 Jenkinsfile（`Jenkinsfile.newchain` / `Jenkinsfile.rolling`）在 `val-*` 节点的 `MINE_ARGS` 里固定带上这三个 flag：

```bash
MINE_ARGS="--mine --unlock <addr> --password /data/password.txt --miner.etherbase <addr> --allow-insecure-unlock \
    --vote \
    --blswallet /data/bls/wallet \
    --blspassword /data/bls-password.txt"
```

**引入 vs 生效（关键，勿混淆）**：这组 flag 在 devnet-ops commit `08ff96d`（**2026-05-20**）就加进 Jenkinsfile，**从 05-21 reset 起 validator 进程就一直带着 `--vote` 启动，但 T3 (Feynman) 激活前完全是 no-op**（vote manager 起来了，BEP-126 justify/finalize 未激活，`finalized` 恒为 0）。直到 **T3 (2026-05-28 fourth pass) 激活 Feynman + voteAddress 注册到位**才真正产生最终性。一句话：**flag 早带（05-21 起），T3 才生效**。v0.5.0 (T4) 及之后未改动。BLS wallet 由 `devnet-ops/scripts/register-validators.sh` 生成（`geth bls account generate-proof` 产出 pubkey+proof，pubkey 即上链 `vote_address`）。

**验证清单：**
```bash
# 1. PUSH0 opcode 可用（部署含 PUSH0 的合约）
# 2. 第一个 breathe block 后 validator set 正确（仍是 5 个）
cast call $STAKE_HUB "getValidators()(address[])" --rpc-url http://rpc-0:8545
# 3. 链继续正常推进
# 4. fast finality 工作：finalized 高度持续推进（证明 --vote + voteAddress 两半都到位）
cast block finalized --rpc-url http://rpc-0:8545 | grep -E "^number"
```

**观察窗口：≥ 48h（覆盖至少 2 个 breathe block 周期）**

---

### Upgrade 4：v0.5.0 — Cancun + Haber + HaberFix

**params/config.go 修改：**
```go
CancunTime:   newUint64(T4),
HaberTime:    newUint64(T4),
HaberFixTime: newUint64(T4),
```

**BlobScheduleConfig（必须，否则节点拒绝启动）：**
```go
BlobSchedule: &BlobScheduleConfig{
    Cancun: &BlobConfig{Target: 3, Max: 6},
},
```

**验证清单：**
```bash
# 1. 新 header 字段存在
eth.getBlock("latest").blobGasUsed  # 非 nil

# 2. 发送 blob 交易（type-3）
cast send --blob --rpc-url http://rpc-0:8545 ...

# 3. blob sidecar 可查询（eth_getBlobSidecars 或等效 RPC）

# 4. txpool 接受 blob 交易

# 5. 链继续正常推进
```

**Cancun 运营注意事项：**
- Blob sidecar 保留时间约 1.5 小时（BSC 标准），超时后 sidecar 不可查，但链数据仍完整
- 磁盘规划：每块最多 6 个 blob × 128KB ≈ 768KB 额外存储/块，规划磁盘时留 20% 余量
- Blob sidecar 不可用时节点仍可验证区块（区块头含 blob commitment hash）

**观察窗口：≥ 48h**

---

### Upgrade 5：v0.6.0 — Prague + Pascal + Lorentz + Maxwell + Bohr

**params/config.go 修改（模板，T5 为整点 UTC 时间戳）：**
```go
PascalTime:  newUint64(T5),
PragueTime:  newUint64(T5),
BohrTime:    newUint64(T5),
LorentzTime: newUint64(T5 + 86400),    // +1 天，epoch 200 → 500
MaxwellTime: newUint64(T5 + 86400*7),  // +7 天，epoch 500 → 1000
// 注：PragueTime 一旦设置，BlobScheduleConfig 必须新增 Prague 条目
// （BSC 用 DefaultPragueBlobConfigBSC == Cancun 的 Target3/Max6），否则
// CheckConfigForkOrder 启动即报 `missing entry for fork "prague" in blobSchedule`。
```

> **DevNet 实测采用值（2026-06-03，缩短窗口）**：`Pascal = Prague = Bohr = 1780473600`（**06-03 08:00 UTC = T5**）、`Lorentz = 1780488000`（**T5+4h**，epoch 200→500）、`Maxwell = 1780502400`（**T5+8h**，epoch 500→1000）。DevNet 把偏移从模板 +1天/+7天压缩到 +4h/+8h（4h≈4800 块 ≫ 500/1000，足够跨新 epoch 边界观察 promotion），当天跑完两次切换验证。Testnet/Mainnet 仍按模板保守偏移。

> **Lorentz/Maxwell epoch 切换行为**：时间戳激活与 epoch boundary 不对齐，激活后按新 epoch 长度（500/1000）重新计算 `blockNumber % epoch`，首个新 epoch block 位置不一定是直觉的整数倍块高。**验收标准**：激活后第一个 epoch block validator rotation 正常（无 missed slot 异常），后续 epoch boundary 间隔 500/1000 块。建议选整点 UTC 减少对齐偏差。

**激活效果：**
- Pascal：EIP-7623（calldata cost 调整）
- Prague：EIP-7702（EOA 账户委托合约实现，委托状态持久写入账户）、EIP-2537（BLS12-381 precompile）
- Lorentz：Parlia epoch 200 → 500 blocks（**不改变出块速度**，见 §1"代码现状"）
- Maxwell：Parlia epoch 500 → 1000 blocks（同上）
- **Bohr：在 ABCore 上 no-op**。bytecode 已在 PGB 部署含 Bohr 改动的最终版；`getTurnLength()` 在 `turnLength == 0` 时返回 1（与未激活时 `defaultTurnLength = 1` 一致）。唯一可见变化：epoch block header.extra 末尾追加 1 字节 turnLength（值 1）。并入主路径是为跟上 BSC 上游 fork 顺序；动态 TurnLength 是治理操作（`updateParam("turnLength", N)`），与 fork 激活解耦。

**验证清单：**
```bash
# Prague: EIP-7702 set-code 交易可发送，委托写入账户状态（extcodesize > 0）
# EIP-2537: BLS precompile 调用返回正确结果
# Lorentz: 激活后第一个 epoch block 正常产生，validator rotation 正确，后续 epoch 间隔为 500 块
# Maxwell: epoch 边界从 N*500 切换到 N*1000，validator rotation 正确
# Bohr: epoch block 的 extraData 包含 turnLength 字节（值=1），与 ValidatorContract.getTurnLength() 返回值一致
# 链继续正常推进（出块速度仍为 3s/block）
```

**观察窗口：≥ 9 天（T5 + 7 天等待 Maxwell 激活 + 48h 观察）**

---

### Upgrade 6：v0.7.0 — Fermi + Osaka + Mendel

**params/config.go 修改（模板，T6 为整点 UTC 时间戳）：**
```go
FermiTime:  newUint64(T6),
OsakaTime:  newUint64(T6),
MendelTime: newUint64(T6),

// BlobScheduleConfig 需要扩展：
BlobScheduleConfig: &BlobScheduleConfig{
    Cancun: DefaultCancunBlobConfig,
    Prague: DefaultPragueBlobConfigBSC,
    Osaka:  DefaultOsakaBlobConfigBSC,  // 新增；不加则 CheckConfigForkOrder 启动报 missing entry for fork "osaka"
},
```

> **DevNet 实测采用值**：`Fermi = Osaka = Mendel = 1780646400`（**2026-06-05 08:00 UTC = T6**）。T6 > Maxwell（1780502400），fork order 合法。三者合并因 BSC 主网 2026-04-28 同戳激活 Osaka+Mendel、Fermi 在 ABCore no-op，节省一次升级窗口。

**激活效果：**
- **Fermi：no-op**。上游把 `FermiBlockInterval` 750ms→450ms，但 ABCore 已 override 3000ms，出块速度不变；激活目的是跟上 BSC fork 顺序。
- Osaka：BPO (Blob Parameter Only) fork，引入新 blob schedule；chain config 须含 `blobSchedule.osaka`，否则 `CheckConfigForkOrder` 启动报错。
- Mendel：与 Osaka 同时激活；内容参考 BSC 上游 release notes。

**验证清单：**
```bash
# 1. CheckConfigForkOrder 通过（chain config 含 blobSchedule.osaka）
# 2. 出块速度仍为 3s/block（不变）
# 3. blob tx 仍可正常发送和打包（Osaka schedule 不影响功能性）
# 4. 链继续正常推进
```

**观察窗口：≥ 48h**

---

## 四、升级批次汇总

| # | 版本 | Fork 内容 | 激活方式 | 特殊操作 | 观察窗口 |
|---|------|-----------|----------|----------|---------|
| 1 | v0.2.0 | ParliaGenesisBlock = N（devnet 实测值 2400，2026-05-28 reset re-run）| 块高 | bootstrap 自动；snapshot restore drill；完整 Parlia 验证 | ≥ 24h（≈ 28800 块 @ 3s）|
| 2 | v0.3.0 | London + 13 BSC block forks = M（devnet 实测值 3600，2026-05-28 reset re-run）| 块高 | Luban extraData 验证（M 选在 200 倍数上时，M 自己就是首个 Luban-form epoch block）| ≥ 48h |
| 3 | v0.4.0 | Shanghai + Kepler + Feynman + FeynmanFix = T3（devnet 实测 T3=2026-05-28 08:00 UTC，由 #114 从 05-26 重设）| 时间戳（binary 中硬编码）| T3 后 5 个 validator 必须在**下一个 Go 层 breathe block 之前**完成 `createValidator` + `delegate govAB`（窗口 ≤ 24h，取决于 T3 落在 UTC-day 边界何处；详见 §3）| ≥ 48h |
| 4 | v0.5.0 | Cancun + Haber + HaberFix = T4 | 时间戳（binary 中硬编码）| BlobScheduleConfig 必设；blob tx + header 验证 | ≥ 48h |
| 5 | v0.6.0 | Prague + Pascal + Bohr = T5（devnet 实测 T5=2026-06-03 08:00 UTC=1780473600）；Lorentz = T5+4h（1780488000）；Maxwell = T5+8h（1780502400）。模板偏移为 +1d/+7d，devnet 缩短为 +4h/+8h | 时间戳（binary 中硬编码）| Prague 需 BlobScheduleConfig.Prague；epoch 200→500→1000；出块速度不变 | devnet ~1 天（模板 ≥9 天）|
| 6 | v0.7.0 | Fermi + Osaka + Mendel = T6（devnet 实测 T6=2026-06-05 08:00 UTC=1780646400）| 时间戳（binary 中硬编码）| blobSchedule.osaka 必设；出块速度不变 | ≥ 48h |

> 真正"可选"且暂未规划的 fork（BPO1 / BPO2 / Amsterdam / Pasteur）见文末附录。

---

## 五、DevNet 演练流程

### 整体时序

```
DevNet 搭建（abcore-v1，5 validator + 1 RPC 独立服务器）
  → Upgrade 1（Parlia 切换）+ snapshot restore drill
  → Upgrade 2（London + BSC forks）
  → Upgrade 3（Feynman，coordinator 执行 StakeHub 注册 + delegate govAB）
  → Upgrade 4（Cancun，BlobScheduleConfig 必设）
  → Upgrade 5（Prague + Pascal + Lorentz + Maxwell + Bohr，9 天观察窗口）
  → Upgrade 6（Fermi + Osaka + Mendel，blobSchedule.osaka 必设）
全部通过后
  → Testnet 执行相同 6 步（各步观察窗口相同）
  → Testnet 稳定 ≥ 2 周后执行 Mainnet
```

### 回滚预案（所有 Upgrade 适用）

硬分叉激活后，回滚必须结合 datadir 快照，不能只换 binary：

```
1. 停止所有节点（必须全部停止后再执行下一步）
2. 确认所有节点已停止（无进程，无 pending 的 P2P 连接）
3. 恢复 pre-fork datadir 快照（含 chaindata、keystore、nodekey、static-peers 等）
4. 换回旧 binary
5. 启动所有节点
6. 验证链从快照点继续推进
```

**⚠️ 双签保护**：回滚时必须先停止所有 validator 进程，确保旧状态已无任何节点在出块，再恢复快照。若旧 binary 在网络中恢复时，同 validator key 仍有新状态节点在运行，会触发双签。正确顺序：全部停止 → 全部恢复快照 → 全部启动。

`debug.setHead(N-1)` 仅在没有快照时作为 fallback 尝试，但可能导致 state/ancients/validator-set 视图不一致，不是可靠的回滚路径。

---

## 六、Testnet → Mainnet 推进

### Testnet

- DevNet 6 步全部通过后执行
- N、M、T3～T6 根据当前 Testnet 块高重新设定（dev team 定值）
- 时间戳 fork 的 T 值在发布 binary 时硬编码，选择距发布时间 ≥ 48h 的 UTC 整点
- 同样需要执行 snapshot restore drill（在 Testnet 的非关键节点上执行）
- **私钥归属与 DevNet 不同（关键差异）**：DevNet 的 validator / 桥私钥由 **dev team 自己生成、自己部署、完全控制**，所以 DevNet 上所有持私钥的链上操作（validator 注册/投票/委托等）都是 dev team 直接执行的（见 §十执行历史）。**Testnet（之后 Mainnet）的私钥在 devops 手里**——持私钥的链上操作改由 **devops 按 dev team 给定的命令执行，dev team 观测判定**。这正是为什么跨链桥能在 DevNet 由桥团队静态评估、却要到 Testnet 才首次实测（私钥与 setup 都在 devops/桥团队侧）。详细 RACI 见 [testnet-upgrade-plan.md §0/§1](testnet-upgrade-plan.md)。
- **跨链桥首次纳入（DevNet 未覆盖）**：DevNet 阶段没有桥 setup，桥连续性从未实测（见第七节缺口说明）。Testnet 须具备两条桥（AB Connect↔BSC、AB IOT↔AB Connect）的 setup——中继（relayer）+ 对端链连通——并把"桥在每步升级前后连续可用"纳入验收；每步操作编排见 [testnet-upgrade-plan.md §7.6 跨链桥连续性](testnet-upgrade-plan.md#76-跨链桥连续性贯穿全部升级步骤的-todo-devnet-未覆盖)。桥的端到端实测与判定由桥团队负责。

> **devops 操作编排**：Testnet（之后 Mainnet）的逐步操作流程、职责边界（dev team 定值/给步骤/验收 vs devops 操作并**持钥执行链上操作**——testnet 私钥在 devops 手里）、起点确认、滚动替换、监控接入、交接 checklist，见 [testnet-upgrade-plan.md](testnet-upgrade-plan.md)。本节及以下 Mainnet go/no-go 表是 dev team 拥有的参数与验收标准（SoT），testnet-upgrade-plan.md 引用本文而不复制。

### Mainnet go/no-go 标准（需满足所有指标）

| 指标 | 阈值 |
|------|------|
| Testnet 运行时长 | ≥ 2 周 |
| missed slot 率（滚动 24h；数据来源：节点 metrics / block explorer）| < 2% |
| reorg 次数（滚动 7 天）| 0 |
| proposer rotation（每 epoch 内各 validator 出块数偏差；数据来源：链上统计）| < 20% 偏差 |
| RPC 错误率（eth_call / eth_sendRawTransaction；数据来源：RPC 节点 metrics）| < 0.1% |
| 状态增长（与 Testnet 同期对比；数据来源：datadir 大小监控）| < 20% 偏差 |

### RPC 节点配置

DevNet 单 RPC 节点（rpc-0）可接受（演练环境）。**Testnet / Mainnet 要求**：≥ 2 个独立 RPC 节点（不同服务器），经 load balancer / DNS round-robin 服务；validator 不对外暴露 RPC；升级时 RPC 与 validator 同步替换 binary。

**RPC 健康检查探针**：liveness 用 `curl net_version`（进程存活 + HTTP 可响应）；readiness 比对 `cast block-number`（rpc-N 落后 rpc-0 > 10 块即摘除）。探针失败自动摘除，其余节点继续服务，无需人工介入。

---

### Mainnet 激活后前向修复 Runbook（当回滚不可行时）

若 Mainnet 激活后出现问题但已有外部交易上链，回滚代价极高，优先前向修复：① 隔离问题 validator（停出块、不停同步）；② 确认剩余 ≥ 3/5 多数派；③ RPC 流量切到健康节点；④ 通知外部消费者（问题性质 + 预计修复时间，建议暂停依赖新 fork 特性的操作）；⑤ 在问题 validator 调查根因；⑥ 修复后逐一重新引入验证同步后再出块；⑦ 恢复后更新状态页。

### Mainnet 推进注意

- 可跳过 v0.1.x，直接 abcore-v1 → v0.2.0
- Upgrade 1 的 N 建议留 3 天块高缓冲（约 86400 块 @ 3s）
- Upgrade 2 的 M 在 N + ≥ 28800 块之后（≥ 24h 观察窗口）；并对齐到 200 grid（M mod 200 = 0）以便 Luban-form extraData 在激活块即可验证
- **Mainnet 激活后无法依赖"回滚"作为保险**（见背景章节）

### 可选：Upgrade 1+2 合并（执行次数减少为 5 次）

> 注：主路径逻辑上仍是 6 步（Upgrade 1–6），合并 Upgrade 1+2 是指将两次 binary 替换操作合并为一次执行窗口，执行次数从 6 次减为 5 次，逻辑步骤数不变。

- 仅适用于 DevNet 演练，Testnet/Mainnet 不推荐
- 合并条件：ParliaGenesisBlock=N，LondonBlock=M，gap ≥ 28800 块（≥ 24h 观察窗口）
- gap 5000 块（约 4h）不够，因为 Upgrade 1 的观察窗口要求 ≥ 24h

---

## 七、DevNet 外部依赖测试清单

DevNet 演练期间，每次 Upgrade 后需验证以下外部集成（如有部署）：

| 组件 | 验证点 |
|------|--------|
| Block Explorer | 新 header 字段正确显示（baseFee、blobGasUsed 等） |
| Indexer | 能解析新交易类型（type-2 EIP-1559、type-3 blob） |
| Signing infra / wallet | Luban 后 extraData 格式变化不影响签名验证 |
| Alerting pipeline | missed block / consensus error alert 触发正常 |
| RPC proxy / load balancer | blob 相关 RPC 方法（eth_getBlobSidecars 等）转发正确 |
| 跨链桥（AB Connect↔BSC、AB IOT↔AB Connect）| **DevNet 阶段未覆盖** —— DevNet 无桥 setup，见下方说明 |

> ⚠️ **DevNet 未测试跨链桥（已知缺口）**：ABCore 在生产上有两条跨链桥——**AB Connect ↔ BSC** 与 **AB IOT ↔ AB Connect**（IoT 链即 AB IOT，部署见 `ab-deploy`）。**DevNet 环境没有部署任何桥实例，也没有对端链（BSC / AB IOT）的连通配置，因此 6 步升级的 DevNet 演练完全没有验证过桥在升级前后的连续性。** 桥相关系统合约（TokenHub `0x1004`、RelayerIncentivize `0x1005`、RelayerHub `0x1006`、CrossChain `0x2000`）虽随 Parlia genesis 一次性部署，但其链下中继（relayer）与对端链交互未在 DevNet 接入。
>
> **影响**：升级对桥的影响（见下方 Q2 §b/c 的 TODO）在 DevNet 阶段**无法实测，只能由桥团队按实现做静态评估**。**桥的首次实测必须在 Testnet 进行**——Testnet 需具备桥的 setup（中继 + 对端链连通），把"桥连续可用"纳入每步升级的验收（编排见 [testnet-upgrade-plan.md §7.6 跨链桥连续性](testnet-upgrade-plan.md#76-跨链桥连续性贯穿全部升级步骤的-todo-devnet-未覆盖)）。

---

## 八、Mainnet 升级 FAQ（外部集成方参考）

> 本节作用域：Mainnet 六次升级（主路径 Upgrade 1–6）对外部集成方的影响。DevNet/Testnet 升级仅用于内部演练。"链不中断"指持续出块、RPC 可用，不代表外部集成无需适配：RPC 方法名向后兼容，但各升级后区块 schema 会新增字段/新交易类型，严格 JSON schema 解析或 ORM 映射的集成方需关注。**ABCore 永久维持 3 秒出块间隔**（见 §一），所有升级不改变出块速度。

---

### Q1：Mainnet 六次升级总共需要多长时间？

#### 时间构成（每次升级）

| 阶段 | 说明 | 时长估算 |
|------|------|---------|
| 提前通知期 | 向外部集成方发布升级公告；交易所、跨链桥、托管、硬件钱包厂商通常需要更长准备周期 | 建议提前 ≥ 2 周；对有固件/App 发版、变更审批需求的对接方，建议 4 周 |
| 操作窗口 | 逐节点替换 binary（滚动，链不中断） | 2–4 小时 |
| 激活缓冲 | T 在发布 binary 时硬编码，与块高激活对称；Mainnet 建议 T 距发布时间 ≥ 1 周，DevNet/Testnet 建议 ≥ 48h | 无额外等待；替换窗口已包含在通知期内 |
| 观察窗口 | 激活后验证各项指标（见下表）；Upgrade 1–4 / 6 为运维/风控门槛，Upgrade 5 的 9 天含协议固定偏移（Maxwell = T5+7d） | 各升级不同 |
| 间隔缓冲 | 确认稳定后才排期下一次升级 | 稳妥模式：1–2 周 |

#### 各升级观察窗口

各升级最短观察窗口见 §四 汇总表。要点：Upgrade 1 ≥ 24h（覆盖一个 Go 层 breathe block 周期）、Upgrade 2/3/4/6 ≥ 48h、Upgrade 5 ≥ 9 天。Upgrade 3 激活后须在下一个 Go 层 breathe block 之前完成 5 个 validator StakeHub 注册 + delegate govAB（窗口 ≤ 24h，由 T3 落点决定，详见 §三）。

> **Upgrade 5 的 9 天含不可提前的协议配置**（Maxwell 时间点由链配置写死为 T5+7d），与间隔缓冲无关。

#### 总时长估算

| 模式 | 说明 | 估算总时长 |
|------|------|----------|
| 激进模式（不推荐用于 Mainnet）| 各升级观察窗口结束后立即排期下一次，无额外间隔缓冲 | 约 17 天（观察窗口合计约 15 天 + 操作/激活开销）|
| 稳妥模式（推荐）| 每次升级间隔 1–2 周（含观察窗口和缓冲），Upgrade 5 内部含固定 9 天 | 约 2–3 个月 |

> 实际排期还需叠加：外部集成方准备时间、公告发布周期、Testnet 稳定运行要求（≥ 2 周）。Mainnet 推进前须先在 Testnet 完成相同 6 步演练。

---

### Q2：每次升级对外部用户的影响和所需动作

> **总体前提**：所有升级均采用滚动替换，链持续出块，eth_* 方法名向后兼容。但各升级后区块/交易 schema 会新增字段或新增交易类型，严格 schema 解析的集成方须提前验证。下表中标注【强制】者为不执行会导致功能错误或资产风险。

#### a. AB Chain 普通用户（转账、DApp 交互）

| 升级 | 可见变化 | 所需动作 |
|------|---------|---------|
| Upgrade 1（Parlia）| 出块间隔不变（3s）；共识引擎对用户透明 | 无需操作 |
| Upgrade 2（London+BSC forks）| 手续费模型变化：钱包开始展示 base fee + priority fee；Gas 更可预测；旧式 gasPrice 交易仍可提交 | 确认所使用的钱包已适配 EIP-1559 fee 展示 |
| Upgrade 3（Shanghai/Feynman）| PUSH0 等新 opcode 对普通转账透明；StakeHub 注册在激活后下一个 Go 层 breathe block 之前完成（窗口最长 24h），链正常出块。极端情形（≥ 2 个 validator 漏注册）可能出现短时出块抖动（概率极低，有 DevNet/Testnet 演练保障） | 无需操作；可关注官方状态页 |
| Upgrade 4（Cancun）| 引入 blob 交易（type-3）；通常情况下普通用户不会直接发送 blob 交易；区块头新增 blob 相关字段 | 无需操作 |
| Upgrade 5（Prague + Pascal + Lorentz + Maxwell + Bohr）| EIP-7702：EOA 可通过 type-4 set-code 交易将其账户委托给合约实现；**委托状态写入账户，持续有效直到主动撤销**；普通 ETH 和 ERC-20 转账不受影响。Lorentz/Maxwell：Parlia epoch 长度变化（200→500→1000），对普通转账透明。Bohr 在 ABCore 上为 no-op | 无需操作；如有账户抽象需求可在此升级后评估 |
| Upgrade 6（Fermi + Osaka + Mendel）| 在 ABCore 上**出块速度仍为 3s**（不变）；Fermi 上游本应降至 450ms，已在 params override；Osaka 引入新 blob schedule，普通用户不感知 | 无需操作 |

#### b. AB Connect ↔ BSC 跨链桥 / c. AB IOT ↔ AB Connect 跨链桥

> ⚠️ **DevNet 未覆盖**：DevNet 环境未部署任何桥实例，也无对端链（BSC / AB IOT）连通配置，本项在 DevNet 阶段**完全没有实测**（详见第七节 DevNet 外部依赖测试清单下的缺口说明）。以下评估在 DevNet 只能由桥团队静态进行；**桥的首次端到端实测须在 Testnet 完成**，并在 Testnet/Mainnet 每步升级中持续验证桥不中断。

**TODO：分别由 AB Connect / AB IOT 桥团队评估**，每次升级后据桥实际实现评估影响：U1 共识引擎切换；U2 区块头格式 + EIP-1559 fee 模型；U3 激活前后监控跨链事件处理；U4 新区块头字段 + 新交易类型；U5 新交易类型 + EOA 委托机制对桥安全假设的影响（Bohr no-op）；U6 Fermi no-op、Osaka blob schedule 变化对跨链 blob tx 的影响（若有）。

#### d. 支持 $AB token 和 $USD1 充提的交易所

交易所主要关注：充值监听（eth_getLogs）、提现构造、确认数策略、热钱包 gas 管理。

| 升级 | 可见变化 | 所需动作 |
|------|---------|---------|
| Upgrade 1（Parlia）| 无 ERC-20 合约或事件变化；充提接口不变 | 【建议】升级操作窗口（2–4 小时）期间预防性暂停充提（非强制，链不中断） |
| Upgrade 2（London+BSC forks，含 Luban）| baseFeePerGas 引入，原 gasPrice 估算可能不足；归集、提现、nonce 管理、replace-by-fee 逻辑均受影响；须确保 gasPrice ≥ baseFee + 目标 tip | 【强制】更新热钱包/提现服务的 gas 估算：支持 EIP-1559 fee（maxFeePerGas / maxPriorityFeePerGas）；或验证 type-0 legacy tx（gasPrice ≥ baseFee + tip）可正常广播打包 |
| Upgrade 3（Feynman）| ERC-20 事件无变化；链正常运行 | 监控即可；参考下方 Feynman 注解 |
| Upgrade 4（Cancun）| 引入 type-3 blob 交易；区块头新增字段；ERC-20 充提逻辑不变 | 【强制】确认交易解析器对 type-3 tx 不会崩溃（可识别并跳过，不静默解码失败） |
| Upgrade 5（Prague + Pascal + Lorentz + Maxwell + Bohr）| ERC-20 Transfer 事件和充提流程无变化；type-4 为新交易类型；EIP-7702 授权账户的 code 为 `0xef0100 + target_address` 委托标记（不是普通合约 bytecode），extcodesize > 0；Lorentz/Maxwell 修改 Parlia epoch 长度（200→500→1000 blocks），与出块间隔无关，对充提业务透明；Bohr 在 ABCore 上为 no-op | 确认交易解析器对 type-4 tx 不会崩溃；若有"充币地址非合约（extcodesize == 0）"校验逻辑，需评估 EIP-7702 授权账户的影响（授权持续到主动撤销） |
| Upgrade 6（Fermi + Osaka + Mendel）| ERC-20 充提逻辑不变；出块速度仍为 3s（不变）；Osaka 引入新 blob schedule，对 ERC-20 充提无影响 | 无需操作；确认数策略沿用现有规则 |

> **Upgrade 3 Feynman StakeHub 注册失败的外部表现**：
> - 若在 T3 到达前发现准备不足，可发布新 binary（将 T3 设为 maxUint64）暂停激活并重新排期；一旦 T3 已到达，无法撤销激活，进入应急恢复流程
> - 1 个 validator 漏注册：该 validator 暂时退出 active set，链以 4/5 维持正常出块；约 10 分钟后（下一个 breathe block）可补注册恢复
> - ≥ 2 个 validator 同时漏注册：active set 可能不足多数派，出块不稳定，外部可见较长延迟；团队将启动应急恢复流程
> - DevNet + Testnet 均会演练串行注册流程，确认成功后才执行 Mainnet

#### e. Indexer / Block Explorer / RPC Provider（基础设施消费者）

参见第七节"DevNet 外部依赖测试清单"。核心验证点：

| 升级 | 关键验证点 |
|------|----------|
| Upgrade 1（Parlia）| 区块头 extraData 格式（Clique → Parlia）；共识字段解析；proposer 识别逻辑 |
| Upgrade 2（London+BSC forks，含 Luban）| baseFeePerGas 字段展示；epoch block 每条 validator 记录 68B 格式；type-2 tx 索引 |
| Upgrade 3（Shanghai/Feynman）| PUSH0 等新 opcode 的 tracer/反编译器支持；opcode 表更新 |
| Upgrade 4（Cancun）| 区块头新增 blob 相关字段（blobGasUsed、excessBlobGas 等）；type-3 blob tx 索引；blob sidecar 查询（需确认 AB Chain 是否实现对应 RPC 方法） |
| Upgrade 5（Prague + Pascal + Lorentz + Maxwell + Bohr）| type-4 EIP-7702 tx 索引；BLS precompile（EIP-2537）调用记录；7702 授权账户状态展示；epoch 长度变化（200→500→1000）对 validator rotation 监控和 epoch block 解析的影响；Bohr 后 epoch block extraData 末尾追加 1 字节 turnLength（值=1），解析器须容忍 |
| Upgrade 6（Fermi + Osaka + Mendel）| Osaka blob schedule 字段变化（若 indexer 解析 blob schedule 配置）；Fermi 在 ABCore 上为 no-op，无 indexer 影响 |

---

### Q3：钱包支持和集成在各个升级过程中需要做什么？

#### 各升级对钱包的要求

| 升级 | 变化 | 钱包要求 | 强制级别 |
|------|------|---------|---------|
| Upgrade 1（Parlia）| 共识引擎切换，对钱包透明 | 无需变化 | — |
| Upgrade 2（London+BSC forks）| baseFeePerGas 引入；fee market 模型变化 | ① 正确处理 baseFee（gas 估算须满足 gasPrice ≥ baseFee + 目标 tip，避免合法但长时间不打包）；② 支持展示 EIP-1559 fee 参数（建议）；③ 若继续支持 legacy type-0 tx，则追踪 baseFee 是【强制】（不是可选）——可选的是"是否继续支持 legacy 发送"，但支持后必须正确处理 baseFee | 【强制：①；继续支持 legacy 路径时③也为强制】【建议：②】|
| Upgrade 2（type-2 支持）| type-2 tx 为可选新能力 | 支持 type-2 签名和广播是**可选能力**；但不支持时遇到 type-2 须明确报错/提示，不可静默失败或返回错误 gas 估算 | 【可选支持；遇到 type-2 时明确拒绝为强制】|
| Upgrade 3–4 | EVM opcode / blob tx | Upgrade 3 对钱包透明；Upgrade 4 若展示 tx 列表须能渲染 type-3（blob）而不崩溃；通常情况下用户不会发送 blob tx | — / 建议 |
| Upgrade 5（Prague + Pascal + Lorentz + Maxwell + Bohr）| EIP-7702：EOA 可通过 type-4 set-code tx 委托合约实现，**委托写入账户状态，持续有效直到主动撤销**；Lorentz/Maxwell 修改 Parlia epoch 长度（200→500→1000 blocks），对钱包功能透明；Bohr 在 ABCore 上为 no-op | ① 对 7702 授权账户（账户代码为 EIP-7702 委托标记 `0xef0100 + target_address`，区别于普通合约字节码）须展示安全提示，告知用户该账户已委托合约实现；② 对未知 tx type（type-4）须明确拒绝或提示，不可静默失败；③ 支持发起 type-4 tx（可选，高级功能） | 【强制：①②】【可选：③】|
| Upgrade 6（Fermi + Osaka + Mendel）| 出块速度仍为 3s（不变）；Osaka 引入新 blob schedule，普通转账不感知 | 无需变化 | — |

#### 分阶段行动清单

**Upgrade 2 前（最高优先级）**：验证 EIP-1559 gas 估算（`eth_feeHistory` / `eth_maxPriorityFeePerGas`），确保 gasPrice ≥ baseFee + tip 避免"合法但不打包"；支持 type-2 签名/广播（若计划）或明确告知用户用 type-0；Testnet 集成测试。

**Upgrade 5 前（须就绪）**：实现 7702 授权账户检测（账户代码为 `0xef0100 + target_address` 委托标记）和安全提示（Prague 激活后立即生效）；对未知 tx type（type-4）明确拒绝或提示，不可静默失败。**Upgrade 5 后（可选）**：评估是否支持 type-4 tx 构造。

**Upgrade 6 前**：对未知 tx type 明确拒绝或提示（Osaka 后 blob schedule 字段会变化）。

#### 硬件钱包兼容性建议

| 升级 | 说明 |
|------|------|
| Upgrade 2（EIP-1559 / type-2）| 主流型号（Ledger、Trezor）在部分固件版本已支持 EIP-1559；**须确认具体型号 + 固件版本 + App 版本**，不可笼统依赖"已支持"；建议在 Upgrade 2 前通知用户检查并更新 |
| Upgrade 4（Cancun / type-3）| 通常情况下普通用户不发送 blob tx，无需特别更新；若展示 type-3 tx 历史，须确认 App 不会崩溃 |
| Upgrade 5（EIP-7702 / type-4）| type-4 为全新交易类型，硬件钱包固件和 App 支持通常会滞后；在固件/App 明确支持前，不要提示用户签名 type-4 tx；7702 授权账户的安全提示需 App 层实现 |

---

## 附录：可选升级

> 本附录列出代码已有 fork time 字段、但 BSC 上游尚未上线或定位未明、暂不规划进 ABCore 主路径升级的 fork。任何决定激活前需单独 review。
>
> **激活前提**：均需要 London（LondonBlock）已激活。
> **激活顺序**：各可选 fork 之间无强制顺序依赖，但配置时须满足 `params/config.go` 中 `CheckConfigForkOrder` 的时间戳升序要求。

### BPO1 / BPO2、Amsterdam / Pasteur（可选）

上游字段已定义（`BPO1Time`/`BPO2Time`/`AmsterdamTime`/`PasteurTime`，`params/config.go` 均为 `nil`），但 BSC 主网尚未激活。BPO = Blob Parameter Only fork（仅改 blob schedule 容量，不引入 EVM 功能）。跟随 BSC 上游激活节奏，具体内容/性能以 BSC 上线后实测为准。

### 关于 Bohr / Fermi / Osaka / Mendel 不在本附录

这四个 fork **已纳入主路径**（Bohr 进 v0.6.0，Fermi+Osaka+Mendel 进 v0.7.0），非可选。理由：BSC 主网均已激活（Bohr=2024-09-26、Fermi=2026-01-14、Osaka/Mendel=2026-04-28）；对 ABCore 都是 no-op 或仅小幅配置变化（Osaka 需 `blobSchedule.osaka`）；跟上 BSC fork 顺序避免未来 sync upstream patch 踩坑。代码层 `IsBohr`/`IsFermi`/`IsOsaka`/`IsMendel` 均只依赖 `IsLondon()`，技术上"永不激活"也可行，但运营决策是按主路径激活。

---

## 九、参考资料

| 资源 | 路径 |
|------|------|
| 共识切换 cutover Runbook | [docs/ops/fork-cutover-runbook.md](fork-cutover-runbook.md) |
| 共识切换回滚 Runbook | [docs/ops/consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md) |
| 节点部署与 v1→v2 升级手册 | [docs/ops/node-and-validator-deployment.md](node-and-validator-deployment.md) |
| Testnet 升级编排（devops 视角）| [docs/ops/testnet-upgrade-plan.md](testnet-upgrade-plan.md) |
| ops 文档索引 / 场景路由 | [docs/ops/README.md](README.md) |
| 链参数配置 | `params/config.go`（ABCoreMainChainConfig / ABCoreTestChainConfig / ABCoreDevnetChainConfig）|
| Block interval 常量（永久 3 秒）| `params/protocol_params.go:200-203` |
| System contract one-shot 部署 | `core/systemcontracts/upgrade.go:1453-1475` |
| 系统合约 bytecode | `core/systemcontracts/parliagenesis/{mainnet,testnet,default}/` |
| Genesis contract 源码 | `https://github.com/ABFoundationGlobal/abcore-v2-genesis-contract` |
| 演练脚本 README（工程视角）| [script/test/upgrade-drill/README.md](../../script/test/upgrade-drill/README.md) |
| 混版本兼容性测试脚本 | `script/test/compat/` |
| 过渡测试脚本 | `script/test/transition/` |
| 本地 Parlia devnet | `script/local/` |

---

## 十、Execution History

> 本节只跟踪**当前这次 reset（2026-06-15，预计为最后一次演练）**的执行情况。
> 此前 v0.2.0 → v0.7.0 全程演练（历经多次 reset）的逐次实测细节已归档，只保留
> ① 核心 **Lesson Learned**（踩坑根因，对 testnet/mainnet 仍有指导意义）
> ② **历史升级汇总表**（PR 锚点，供 commit 比对）。
> 每次升级"怎么测"的权威步骤在 §三 Upgrade 1~6，不在本节。

### Lesson Learned（历次 reset 提炼，testnet/mainnet 必读）

1. **下游 indexer 的 consensus-switch 适配必须在 cutover 之前确认。** 首轮 v0.2.0 cutover 后 Blockscout `BLOCK_TRANSFORMER=clique` 在 Parlia 阶段对 extraData 末 65 字节 ecrecover 出无意义伪 miner 地址，~3h 内 `total_addresses` 从 9 涨到 2388。根因 + 现场修复（改 `base` + Parlia 区间 refetch + DELETE 孤儿行）已固化进 §三 Upgrade 1 的 [Blockscout pre-cutover checklist](#blockscout-pre-cutover-checklist)。

2. **本地测试用 `abchain-local`（network=dev）会被 dev-only patch 掩盖生产 bug。** 第三次 reset（2026-05-26）卡死于首个 breathe block：`BSCValidatorSet.init()` 填了 `currentValidatorSet` 但没初始化平行数组 `validatorExtraSet`，`updateValidatorSetV2 → _forceMaintainingValidatorsExit` 越界 → `INVALID` → Finalize 失败 → 链停摆。本地测不出是因为 `abchain-local` 的 dev-only patch 在 `init()` 里补了 `validatorExtraSet.push(...)`，而生产模板 `abchain-dev`（network=testnet）不含。修复 [genesis-contract#12](https://github.com/ABFoundationGlobal/abcore-v2-genesis-contract/pull/12) 把初始化提进 `init()` 主体（所有环境一致）。**判据**：一个 dev-only patch 是不是"会卡链的坑"，取决于生产模板缺它时，是否有 Parlia 自动注入的系统 tx（`onlyCoinbase`）或必经路径会 revert——系统 tx 在 `Finalize()` revert = 块产不出 = 确定性重试永久卡死，无链上补救空间。**所有系统 tx 路径（breathe block / finality reward / slash）必须用生产模板 bytecode 实测**（breathe block 已在 [#113](https://github.com/ABFoundationGlobal/abcore-v2/pull/113) U-3 覆盖；slash 路径仍 defer 到 cloud testnet）。

3. **EpochLength 不要从 `Clique.Epoch` 继承。** PGB reseed 早期从 `Clique.Epoch`（30000）拷 snapshot EpochLength，导致 PGB 之后按固定块高激活的 fork（如 LubanBlock 165400）`% 30000 ≠ 0` → 非 epoch block → Luban 扩展信息延迟到下一个 epoch block 才出现在 extraData（链不 split，仅可观察性推迟）；二阶 bug：`snapshot.go` 的 Lorentz/Maxwell 自动 epoch 切换（200→500→1000）只在 `EpochLength == defaultEpochLength` 时触发，30000 永不满足。修复 [#103](https://github.com/ABFoundationGlobal/abcore-v2/pull/103)+[#104](https://github.com/ABFoundationGlobal/abcore-v2/pull/104)：`ParliaConfig` 加 `Epoch` 字段，reseed 读 `Parlia.Epoch`（fallback `defaultEpochLength=200`）。**运维建议**：PGB 可以是任何块号（`IsOnParliaGenesis` 接管）；但 PGB 之后计划在固定块高激活的 fork 应对齐 `% epochLength == 0`，否则扩展信息延迟一个 epoch 窗口。

4. **alloc 用 `10^Exp` 公式不用 hex 字面值。** devnet-ops validator alloc 曾用 hex 字面值 off-by-one（`0x33b2...`=10^9 ether < 20亿 self-delegation 阈值）导致 `SelfDelegationNotEnough` revert。[devnet-ops#12](https://github.com/ABFoundationGlobal/devnet-ops/pull/12) 改用 `new(big.Int).Exp(big.NewInt(10), big.NewInt(28), nil)` 算 10^28 wei = 100亿 ether。

5. **tag 重推后节点可能跑旧 image。** `Jenkinsfile.rolling` 的 `docker images | grep -q '^TAG$'` skip 在 tag 重打时仍命中 → 跳过 `docker pull` → 节点跑旧 binary。[devnet-ops#10](https://github.com/ABFoundationGlobal/devnet-ops/pull/10) 去掉 grep-skip，永远 `docker pull`。

### 历史升级汇总表（v0.2.0 → v0.7.0，commit 比对锚点）

> 全程在 chain 17140 演练，历经多次 reset（最终存活链为 2026-05-28 fourth-pass）。逐次实测细节已归档；下表 PR 链接为 commit 比对锚点。本次 2026-06-15 reset 后重新逐档推进，激活点见下方跟踪段。

| 升级 | 版本 | 激活内容 | 配置 PR | 历史结果 |
|---|---|---|---|---|
| 1 | v0.2.0 | Clique → Parlia 共识切换（PGB） | [#103](https://github.com/ABFoundationGlobal/abcore-v2/pull/103)/[#104](https://github.com/ABFoundationGlobal/abcore-v2/pull/104) | ✅ |
| 2 | v0.3.0 | London + 13 BSC block forks（EIP-1559） | [#105](https://github.com/ABFoundationGlobal/abcore-v2/pull/105) | ✅ |
| 3 | v0.4.0 | Shanghai + Kepler + Feynman + FeynmanFix | [#110](https://github.com/ABFoundationGlobal/abcore-v2/pull/110)/[#114](https://github.com/ABFoundationGlobal/abcore-v2/pull/114) | ✅ |
| 4 | v0.5.0 | Cancun + Haber + HaberFix（EIP-4844 blob） | [#118](https://github.com/ABFoundationGlobal/abcore-v2/pull/118) | ✅ |
| 5 | v0.6.0 | Pascal + Prague + Bohr + Lorentz + Maxwell | [#121](https://github.com/ABFoundationGlobal/abcore-v2/pull/121) | ✅ |
| 6 | v0.7.0 | Fermi + Osaka + Mendel | [#123](https://github.com/ABFoundationGlobal/abcore-v2/pull/123) | ✅ |

历史实测亮点（已验证，testnet/mainnet 可预期）：fast finality（BEP-126）自 Feynman 激活后 justified/finalized 持续推进；epoch promotion 在 block 184999（200→500）/189999（500→1000）精确切换；EVM fork（Pascal EIP-7623 floor gas、Prague EIP-7702 set-code + EIP-2537 BLS precompile）均链上验证；出块速度全程永久 3s（Lorentz/Maxwell/Fermi BlockInterval 均 override 3000ms）。

### Reset (2026-06-15) — 重走升级路径，单独验证 foundation 多签 fee（进行中）

本次 reset 目的：在 v1（Clique）阶段先部署 foundation Safe 多签 `0x0B53A578F024580563Ef1349b1F2c289115f6bE8`（owners=anvil[1,2,3]/2），再逐档走 v0.2.0 → v0.7.0，重点在 **Upgrade 1（v0.2.0）后单独验证 foundation 多签 fee 路径**（genesis-contract#16 `call{gas:30000}` 对真实 Safe 不卡链、Safe 收 15%、2/3 多签可转出）。这是此前几次 reset 未覆盖的新验证目标（foundation 地址此前是占位 `0x…f000`）。

#### Upgrade 1：v0.2.0 — Clique → Parlia cutover

- **配置 PR** [#126](https://github.com/ABFoundationGlobal/abcore-v2/pull/126)：`ABCoreDevnetChainConfig` 只调度 v0.2.0——`ParliaGenesisBlock = 4400`，v0.3.0+ 所有 block/timestamp fork 设 `nil`（PGB-only 合法，`IsOnParliaGenesis` 把 PGB 当 epoch boundary，不依赖 London）。Image `abfoundation/abcore-v2:v0.2.0`（foundation Safe addr 经 [#125](https://github.com/ABFoundationGlobal/abcore-v2/pull/125) 重嵌系统合约 bytecode）。
- **PGB basis**：head≈#2039 @ 06-15T13:08Z，period=3s，target ~15:00 UTC，aligned 4400（% 200 == 0）。
- **节点状态**（06-15T13:43Z 核实）：val-0/val-1 同步、Clique 相位、出块正常、5~6 peers、启动日志确认 PGB=4400 且 v0.3.0+ fork 全 nil。等块高到 4400 自动切 Parlia。

**Cutover 后待验证**（步骤见 §三 Upgrade 1）：
1. block 4400 extraData=197B（`IsOnParliaGenesis` 路径），Engine 从 clique 切 parlia，后续每 200 块为 epoch block。
2. Parlia round-robin + 节点同步健康。
3. **foundation 多签 fee**（本轮核心）：deposit() system tx 每块不 revert；发非零 gasPrice 的 legacy tx 制造 fee → Safe `0x0B53…6bE8` 余额增长 ≈15%；anvil[1,2,3] 的 2/3 多签 `execTransaction` 转出。注：v0.3.0（London/EIP-1559）后 fee 模型变化，需复测 15% 仍正确。
