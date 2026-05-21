# ABCore DevNet 建设 + 分阶段升级路径计划

> 本文档用于指导 DevNet 搭建、升级演练，以及后续 Testnet / Mainnet 的推进策略。
> **本文档是升级计划的 single source of truth。** drill 脚本 README（`script/test/upgrade-drill/README.md`）是工程验证视角，不等于运营计划；以本文档为准。
> **Last updated**: 2026-05-19

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
> **关于 Bohr / Fermi / Osaka / Mendel**：BSC 上游里 Bohr 改变 TurnLength、Fermi 把出块间隔从 750ms 降到 450ms。**ABCore 永久维持 3 秒出块间隔**（已在 `params/protocol_params.go` 把 `LorentzBlockInterval` / `MaxwellBlockInterval` / `FermiBlockInterval` 全部 override 为 `3000ms`，与 `DefaultBlockInterval` 一致），所以这些 fork 在 ABCore 上对出块速度都没有影响。Bohr 并入 v0.6.0、Fermi+Osaka+Mendel 进入 v0.7.0 是为了跟上 BSC 上游 fork 顺序，免去未来 sync upstream patch 时踩坑。详见 §3 各升级段。

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

> 参考 BSC 官方 validator 节点推荐配置（8 核 / 16 GB / 500 GB SSD），并根据 DevNet 实际拓扑调整。DevNet 为演练环境，流量极低，但需覆盖完整 6 次升级周期。

| 服务器 | CPU | 内存 | 磁盘 | 备注 |
|--------|-----|------|------|------|
| server-1 | 16 核 | 32 GB | 500 GB NVMe SSD | 跑 2 个 validator 进程，资源需翻倍 |
| server-2 | 16 核 | 32 GB | 500 GB NVMe SSD | 同 server-1 |
| server-3 | 8 核 | 16 GB | 500 GB NVMe SSD | 单 validator |
| server-4 | 8 核 | 16 GB | 500 GB NVMe SSD | RPC 节点（独立服务器，与 validator 资源隔离）|

**磁盘说明**：NVMe SSD，要求顺序读写 ≥ 500 MB/s、随机 4K 读写 IOPS ≥ 8000、延迟 < 1ms。DevNet 链数据量远小于生产，500 GB 足以覆盖演练周期及多次快照备份。

**网络**：各节点间延迟 < 100ms。公网出口带宽 ≥ 10 Mbps 即可（DevNet 无外部流量压力）。

**云厂商参考规格**（仅供参考，按实际可用资源选择）：

| 角色 | AWS | GCP | 说明 |
|------|-----|-----|------|
| server-1 / server-2 | c5.4xlarge（16vCPU/32GB）| n2-standard-16 | 计算密集型，双 validator |
| server-3 / server-4 | c5.2xlarge（8vCPU/16GB）| n2-standard-8 | 单节点，规格可降 |
| 磁盘 | gp3，8000 IOPS，500 MB/s | pd-ssd | 避免 gp2（IOPS 受容量限制）|

> **拓扑说明**：server-1 和 server-2 各有 2 个 validator，单机故障各失去 40% signer，但剩余 3 个仍构成多数派（3/5），链不中断。DevNet 拓扑与生产（每 validator 独立服务器）有差异，HA 测试结果不可直接推广到 Mainnet。

> **为什么 RPC 必须独立**：尽管 ABCore 永久维持 3 秒出块（见 §0），RPC 服务的 IO/CPU 负载与 validator 出块共享时可能影响出块稳定性；server-4 在主路径中即应独立。

### 滚动升级原则

每次升级替换 binary 时，多 validator 服务器（server-1、server-2）不需要整台服务器下线，**逐个 validator 进程停止/替换/启动**：

```
server-1 升级示例：
  Step 1：停止 val-0 → 替换 binary → 启动 val-0 → 验证 val-0 重连并同步
  Step 2：停止 val-1 → 替换 binary → 启动 val-1 → 验证 val-1 重连并同步
```

任意时刻最多 1 个 validator 离线，始终保持 4/5 validator 在线（远超多数派 3/5 要求）。链不中断，slot 最多出现 1 个 missed block。

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
| ParliaGenesisBlock | 演练时设定；当前 devnet 实测值 1600（2026-05-21 reset 后）|

### 系统合约字节码路由

| 环境 | bytecode 目录 | 自动路由依据 |
|------|--------------|-------------|
| DevNet (chain 17140) | `parliagenesis/devnet/` | genesis hash = ABCoreDevnetGenesisHash（PR #90 起）|
| Testnet (chain 26888) | `parliagenesis/testnet/` | genesis hash = ABCoreTestGenesisHash |
| Mainnet (chain 36888) | `parliagenesis/mainnet/` | genesis hash = ABCoreMainGenesisHash |
| Local self-test | `parliagenesis/default/` | genesis hash 不匹配任何 ABCore 网络 → fallthrough |

路由由 `core/systemcontracts/upgrade.go` `applyParliaGenesisUpgrade` 在 PGB cutover 那一刻执行，不需要任何 flag。各网络 bytecode 不会跨链泄漏，链 ID / genesis hash 不同自动隔离。

<a id="one-shot-bytecode"></a>
### 一次性字节码部署（One-shot bytecode deployment）—— ABCore 关键设计

**与 BSC 上游不同**：BSC mainnet/chapelnet 在 ParliaGenesis 时部署的是**早期 Parlia 时代的合约 bytecode**，之后每个硬分叉（MirrorSync / Bruno / Euler / ... / **Luban** / Plato / ...）通过 `*Upgrade[network]` map 增量替换若干合约的 bytecode。这是 BSC 历史演进的产物：每次新增功能时升级对应合约。

**ABCore 的设计**：`parliagenesis/{mainnet,testnet,devnet}/` 里嵌入的是**最终版（含所有 post-Hertz 特性的）bytecode**。这意味着：

- ParliaGenesisBlock 那一刻 → 部署的合约**已经**支持 `getMiningValidators()` (Luban)、vote address 存储 (Luban+)、StakeHub 集成接口 (Feynman)、`updateValidatorSetV2` (Feynman) 等等
- 后续所有 BSC fork（Ramanujan ... Hertzfix、Feynman、Bohr、Lorentz、Maxwell、...）**对系统合约 bytecode 都是 no-op**
- `upgradeBuildInSystemContract` 在函数入口对 ABCore 网络 **early-return**（PR #99 起），完全跳过 14 个 `*Upgrade[network]` map lookup

**为什么这样设计**：
- ABCore 没有 BSC 那种"按时间线分批引入功能"的历史包袱，可以一次部署到位
- 减少出错面：BSC 上一个 fork 漏 bytecode 升级会让该 fork 引擎层失灵；ABCore 一次性部署后只要 PGB 跨过就所有功能都在
- bytecode 由 ABCore 自己的 `abcore-v2-genesis-contract` 仓库编译，5 个 validator 地址、chain ID、治理合约地址等已 baked-in；BSC mainnet/chapel bytecode 含 BSC-specific 常量，**不能**直接拿来增量升级 ABCore

**Chain config gate 仍然按 fork 顺序逐个激活**：`IsLuban(block) == true` 从 LubanBlock 起生效，引擎层（`Prepare`/`verifyValidators`/extraData layout/EIP-1559 schema/vote attestation）按 fork 边界切换。**合约 bytecode 不变 + chain config 按时激活** 是 ABCore 的标准工作模型。

**运维含义**：
- 每次升级（如 v0.3.0 London + 13 BSC forks）**只需要改 `params/config.go` 启用 fork**，不需要在 `upgrade.go` 注册 `*Upgrade[abcoreXxx]` 条目
- 任何往 `upgrade.go` 里加 `lubanUpgrade[abcoreDevNet]` 之类条目的 PR 都是**错的**（除非 PGB 时 bytecode 漏装了某功能 —— 那应当走 `abcore-v2-genesis-contract` 重新编译流程，而不是后置 hardfork upgrade）
- PR #99 之前节点日志会有 `Empty upgrade config network=Default height=N`（每个 fork 一行 INFO），那是 ABCore 网络落到 defaultNet 分支后调 `applySystemContractUpgrade(nil, ...)` 产生的噪音；PR #99 起 early-return 跳过这段，日志干净

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

Clique 的 `Clique.Epoch = 30000` 和 Parlia 的 `defaultEpochLength = 200` 是**两个独立、不同语义**的常量：

| 常量 | 文件 | 值 | 作用 |
|---|---|---|---|
| `Clique.Epoch` | `params/config.go` | 30000 | Clique snapshot 校验点间隔；v1 节点的 30000 块一次 signers 投票快照 |
| `defaultEpochLength` | `consensus/parlia/parlia.go:58` | 200 | Parlia 把当前 active mining set 写入 `header.Extra` 的节奏；validator set 的"链上检查点" |
| `lorentzEpochLength` | `consensus/parlia/parlia.go:59` | 500 | Lorentz fork 后 epoch 长度 |
| `maxwellEpochLength` | `consensus/parlia/parlia.go:60` | 1000 | Maxwell fork 后 epoch 长度 |

**PGB 时 `snap.EpochLength` 的来源**（v0.3.0 retro 修复后）：

```go
// consensus/parlia/parlia.go:956-967（修复后路径）
epochLen := defaultEpochLength
if p.chainConfig.Parlia != nil && p.chainConfig.Parlia.Epoch > 0 {
    epochLen = p.chainConfig.Parlia.Epoch
}
snap.EpochLength = epochLen
```

读取顺序：`ChainConfig.Parlia.Epoch`（显式覆盖）→ `defaultEpochLength = 200`（fallback）。**不再从 `Clique.Epoch` 拷贝**——v0.3.0 实测踩坑的根因：LubanBlock 选址用了 Parlia `defaultEpochLength=200` 假设（`165400 % 200 == 0`），但运行时 `snap.EpochLength=30000`（PGB 时从 Clique 拷贝），导致 `165400 % 30000 ≠ 0`，**165400 在运行时不是 epoch block**，Luban-form validator list 没写进 extraData。注意：PGB 本身不受这个影响，因为 PGB 通过 `IsOnParliaGenesis` 路径强制视为 epoch boundary；问题出在 PGB 之后的**普通** fork block（LubanBlock 等）依赖 `number % epochLength == 0` 走正常 epoch 路径。详见 §10 retro。

ABCore 三网 chain config 显式设 `Parlia: &ParliaConfig{Epoch: 200}`，与 BSC 上游对齐：BSC mainnet 起步 100 → 改 200 → Lorentz fork 200→500 → Maxwell fork 500→1000。`consensus/parlia/snapshot.go:362-372` 的自动 promotion 逻辑要求**起点必须是 `defaultEpochLength = 200`**，否则 Lorentz/Maxwell 激活时 epoch 切换永远不触发。

**fork × epoch 切换对照**：

| fork | 激活前 epoch | 激活后 epoch | 切换触发条件 |
|---|---|---|---|
| (起点) | — | 200 | PGB 时 reseed |
| Lorentz | 200 | 500 | 第一个 `block.Number % 500 == 0` 且 `IsLorentz(time)` |
| Maxwell | 500 | 1000 | 第一个 `block.Number % 1000 == 0` 且 `IsMaxwell(time)` |
| Fermi/Osaka/... | 1000 | 1000（不变） | — |

**测试时如何覆盖**：chain config 直接设 `Parlia: &ParliaConfig{Epoch: N}` 即可。`consensus/parlia/transition_snapshot_test.go` 中 `TestSnapshotGenesisPathRespectsParliaEpoch` 验证了 N=600 的覆盖路径。

### 代码现状：one-shot system contract bytecode

ABCore 网络（mainnet/testnet/devnet）的所有 system contract bytecode 在 `ParliaGenesisBlock` 时刻一次性部署最终版本，源自 `abcore-v2-genesis-contract` 仓库（init commit 来自 `bnb-chain/bsc-genesis-contract 34618f6`，已包含 Luban / Plato / Feynman / Bohr 等所有 fork 的合约改动）。

`core/systemcontracts/upgrade.go:1453-1475` 在 `upgradeBuildInSystemContract` 函数入口对 ABCore 网络做 early-return，**所有 fork 的 `*Upgrade[mainNet/chapelNet]` map（含 bohr / pascal / lorentz / maxwell / fermi）对 ABCore 永不触发**。

**运维含义**：
- 每次升级（如 v0.3.0 London + 13 BSC forks）**只需要改 `params/config.go` 启用 fork**，不需要在 `upgrade.go` 注册 `*Upgrade[abcoreXxx]` 条目
- 任何往 `upgrade.go` 加 `lubanUpgrade[abcoreDevNet]` 之类条目的 PR 都是错的（除非 PGB 时 bytecode 漏装了某功能 —— 那应当走 `abcore-v2-genesis-contract` 重新编译流程）

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

> **Bohr / Fermi 在 ABCore 上的行为**：因 `BlockInterval` 已在 params override 为 3000ms（见 §1"代码现状"），Fermi 不改变出块速度。Bohr 的 TurnLength 在 ABCore 上默认仍为 1（`BSCValidatorSet.getTurnLength()` 在 `turnLength == 0` 时返回 1），与未激活 Bohr 时一致；唯一可见变化是 header.extra 末尾追加 1 字节 turnLength（值为 1）。将来要打开"动态 TurnLength"完全是治理操作（`updateParam("turnLength", N)`），与 fork 激活解耦。

> **演练推荐顺序**（非代码依赖，基于风险隔离和观察窗口）：Shanghai/Feynman → Cancun → Prague+Lorentz+Maxwell+Bohr → Fermi+Osaka+Mendel，间隔排期以充分验证。

### 关于"13 个 BSC block forks 是 no-op"的说明

**重要校准（PR #99 加入）**：要区分**两层影响**：

**Layer 1 — 系统合约 bytecode 影响**：得益于 ABCore 的[一次性字节码部署](#one-shot-bytecode)设计，所有 13 个 BSC block fork 对 ABCore 系统合约 bytecode **都是 no-op**。PR #99 起 `upgradeBuildInSystemContract` 对 ABCore 网络 early-return，所以 fork block 上**不会有任何**与 bytecode upgrade 相关的日志。如果运行的是 PR #99 之前的 image，会看到 `"Empty upgrade config" network=Default height=N`（INFO，每个 fork 一行）—— 那是 ABCore 网络落到 defaultNet 分支后 `applySystemContractUpgrade(nil, ...)` 产生的，**是当时的预期行为，不是 bug**，但 PR #99 起被消除。

**Layer 2 — Parlia 引擎层 / chain-config gate 影响**：每个 fork 仍然按 chain config 顺序激活引擎层行为：

| Fork | 引擎层实际影响 | bytecode 升级（对 ABCore）|
|------|---------|---|
| Ramanujan, Niels | 出块 backoff 逻辑改进 | no-op |
| MirrorSync, Bruno, Euler, Gibbs, Nano, Moran, Planck | gas/内存调整、少量系统合约调用方式变化 | no-op |
| **Luban** | **非 no-op**：epoch block extraData 从 20B/validator → 68B/validator（20B 地址 + 48B 零值 BLS 公钥）；vote-attestation 字段引入；引擎调 `getMiningValidators()` 替代 `getValidators()` 读 validator set | no-op（合约 bytecode 从 PGB 起就支持 Luban 接口）|
| Plato | Parlia `IsOnPlato` 路径，fast-finality 投票 precompile 启用（无 vote address 时是 no-op）| no-op |
| Hertz, Hertzfix | EIP gas 调整 | no-op（无 upgrade map）|

**关于 Parlia epoch 长度**（PR #103 后已对齐 BSC 上游）：
ABCore Parlia `Parlia.Epoch = 200`（与 BSC mainnet `defaultEpochLength` 一致）。PGB reseed 时 `Parlia.snapshot()` 读 `chainConfig.Parlia.Epoch`，fallback 到 `defaultEpochLength=200`，**不再从 `Clique.Epoch=30000` 拷贝**。Lorentz/Maxwell 激活时 200→500→1000 的自动 promotion（`snapshot.go` 的 `apply()`）现在可以正确触发。

**实测验证**（devnet post-reset 2026-05-21）：PGB=1600 (197B, IsOnParliaGenesis 路径)、block 1800/2000/... 都是 197B Parlia epoch block (32 vanity + 5×20 validators + 65 seal)，epoch interval = 200 块。

**v0.3.0 升级真正验证什么**：
- ✓ EIP-1559 header schema（block M 起带 `baseFeePerGas` 字段，值=`0x0` 是 BSC Parlia 规范，`InitialBaseFeeForBSC = 0`）
- ✓ Luban chain-config gate 生效后，**第一个 Parlia epoch block** 写 Luban-form 438B extraData（若 M 选在 200 倍数上，则 M 本身就是；否则要等到 `ceil(M/200)*200`）
- ✓ 链推进无 errExtraSigners / errInvalidSpanValidators

**不要验证什么**：
- ✗ "fork block M 自身的 extraData 是 Luban-form" —— 仅在 `M % 200 == 0` 时成立。若 M off-grid，M 本身的 extraData 仍是 97B（这是正确行为，不是 bug），下一个 epoch block 才会变 438B
- ✗ "lubanUpgrade[abcoreDevNet] 被注册" —— 故意不注册，详见 [一次性字节码部署](#one-shot-bytecode)

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
      T 已在发布的 binary 中硬编码（params/config.go），与块高激活方式完全对称。
      发布时 T 应选择距发布时间至少 48 小时以上的 UTC 整点，留足替换窗口。
      Mainnet 建议 T 距发布时间 ≥ 1 周。
      binary 发布后立即进入 release freeze：
        - 将当前 binary sha256、fork 时间戳记录到操作日志
        - 冻结 release artifact / fork config / checksum，不允许修改；节点应持续部署该 release 直至全网完成替换
        - 若发现 critical bug 且 T 尚未到达：发布新 binary（将 T 推迟或设为 maxUint64），全网在 T 前完成替换后重新排期
        - 不允许在 T 临近（< 1 小时）或已过后修改 config
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

任何下游 indexer 都要在 cutover 之前就把共识切换适配做完。Blockscout 的具体动作是确认 `BLOCK_TRANSFORMER=base`（默认值）而**不是** `clique`。

**关键事实**：`eth_getBlockByNumber` 返回的 `miner` 字段直接来源于 `header.Coinbase`（见 [`internal/ethapi/api.go:1459`](../../internal/ethapi/api.go#L1459) 的 `"miner": head.Coinbase`），**不经过 `engine.Author()` 这个路径**。所以谁往 `header.Coinbase` 写什么，RPC 就返回什么。两个阶段下 Coinbase 的来源不同：

| 阶段 | `header.Coinbase` 来源 | RPC `miner`（= 直接 marshal 的 Coinbase） | `base` transformer 的行为 |
|---|---|---|---|
| Clique (Phase 1) | Clique 协议规定 sealer 通过 extraData 末尾 65 字节签名表达，**`header.Coinbase` 必须为 `0x0000…0000`**（`consensus/clique/clique.go` 的 verify 规则会拒绝非零 Coinbase 的非 epoch 块） | `0x0000…0000` | 拿到 `0x0` —— 准确反映 header 内容。若想看真实 signer，得另外调 `clique_getSigner(blockHash)`（Blockscout 在 `base` 模式下不会这么做）。 |
| Parlia (Phase 2+) | Parlia `Prepare()` 在 sealing 前把当前 validator 地址写进 `header.Coinbase`（见 [`consensus/parlia/parlia.go:1296`](../../consensus/parlia/parlia.go#L1296) 的 `header.Coinbase = p.val`） | 真实 validator 地址 | 拿到真实 validator 地址 —— 这就是 sealer 自己盖在 header 上的身份。 |

参考：`Clique.Author()` 是会做 ecrecover 的（[`clique.go:215-217`](../../consensus/clique/clique.go#L215-L217)），但 `eth_getBlockByNumber` 不调用它；`Parlia.Author()` 反而**不**做 recovery，直接返回 `header.Coinbase`（[`parlia.go:340-342`](../../consensus/parlia/parlia.go#L340-L342)）—— 因为 Parlia 在 Prepare 时已经把正确地址写进 Coinbase 了，不需要再 recover。Blockscout `clique` transformer 的逻辑是**忽略 RPC `miner`**，自己拿 header extraData 的末尾 65 字节当 Clique seal 去 ecrecover；这在 Parlia 阶段就坏掉了 —— Parlia extraData 的布局是 `vanity(32) + validators(N×20) + vote_attestation + seal(65)`，末尾 65 字节确实是 seal，但 ecrecover 的是 Parlia 域的签名（hash 域不同），结果是个**确定性但毫无意义**的伪地址，每块一个，污染 `addresses` 表。

Blockscout 在启动时一次性读取 `BLOCK_TRANSFORMER`，**不支持按块号切换**。所以唯一可行的策略是从一开始就用 `base`。`clique` 这个值是早期为兼容老旧不填 miner 字段的 RPC 节点留的兜底，现代 geth/abcore 的 RPC `miner` 在两个共识阶段都准确，`base` 在两个阶段都对。

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

# 3. 验证生效
docker inspect <blockscout-backend-container> \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep BLOCK_TRANSFORMER
# 三种可能输出，按下面这张表判断：
#   BLOCK_TRANSFORMER=base    → OK，显式安全配置
#   (空输出)                  → OK，未显式设置时 Blockscout 默认就是 base，安全。但建议
#                                显式写 BLOCK_TRANSFORMER=base 让本检查命令始终有可读
#                                输出，便于审计与值班交接。
#   BLOCK_TRANSFORMER=clique  → BLOCKER，必须先改成 base 再进入 cutover
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
// N = 1600（devnet 实测值，2026-05-21 reset 后）
// 选址要求：(a) head + ≥1h safety margin；(b) 200 grid 对齐属运维约定（非协议要求），
// 因为 PGB 通过 IsOnParliaGenesis 路径已被强制视为 epoch boundary。
// 实际值须在执行前根据当前链高度重新设定。
ABCoreDevnetChainConfig.ParliaGenesisBlock = big.NewInt(1600)
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

**回滚预案：**
- 块 N 之前：全网换回 PGB=nil 配置，Clique 继续，无影响
- 块 N 之后或 cutover 失败（链卡住、报 `errInvalidSpanValidators`、节点之间 b N hash 不一致）：执行 [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md) 完整流程（停链 + maintenance 模式 setHead(N-1) + 移除 PGB 配置 + 全网 Clique 恢复）。**不要简单重启**——磁盘上的 Clique-form b N 仍在，重启会重新进入死锁。

**观察窗口：≥ 24h（≈ 28800 块 @ 3s）再推进 Upgrade 2。覆盖至少一个完整 Go 层 breathe block 周期，即使 v0.4.0 还没激活 Feynman 也确认调度路径不报错。**

**Upgrade 1 后执行 snapshot restore drill：**
```
对象：val-4（单节点服务器，最安全的测试对象）
步骤：
  1. 停止 val-4
  2. 验证快照 manifest 校验和（sha256sum -c /backup/manifest-4.txt）
  3. 恢复 pre-N datadir（覆盖当前 datadir）
  4. 保持 v2 binary（abcore-v2，不换回 v1）
     注意：快照恢复后 v2 binary 会从 pre-N 旧块高重新同步，追赶已切换到 Parlia 的链；
     若用 v1 binary 接入已切到 Parlia 的网络，v1 无法处理 Parlia block，不可行。
  5. 启动 val-4，观察：
     a. 节点从旧块高重新追链（v2 binary 在 N 后自动切换到 Parlia 共识）
     b. 链继续推进（其余 4 个 validator 维持多数派）
     c. 无双签告警
  6. 同步追上 head 后，再次停止 val-4
  7. 恢复最新 datadir 快照，重新加入网络
```

drill 目的：验证快照的可恢复性和 manifest 的准确性，以及快照恢复后 v2 binary 追链和 P2P 再加入流程正确。

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
// M = 6000（devnet 实测值，2026-05-21 设定；= N(1600) + 4400 ≈ 3h40，
// **故意短于 ≥24h 推荐窗口**，这是 devnet rehearsal pacing demo，testnet/mainnet
// 不要复制这个 gap。6000 mod 200 = 0 满足 epoch boundary 要求）
// 实际值须在执行前根据当前链高度重新设定
LondonBlock:     big.NewInt(6000),
RamanujanBlock:  big.NewInt(6000),
NielsBlock:      big.NewInt(6000),
MirrorSyncBlock: big.NewInt(6000),
BrunoBlock:      big.NewInt(6000),
EulerBlock:      big.NewInt(6000),
GibbsBlock:      big.NewInt(6000),
NanoBlock:       big.NewInt(6000),
MoranBlock:      big.NewInt(6000),
PlanckBlock:     big.NewInt(6000),
LubanBlock:      big.NewInt(6000),   // 非 no-op，需专项验证；必须落在 epoch boundary
PlatoBlock:      big.NewInt(6000),
HertzBlock:      big.NewInt(6000),
HertzfixBlock:   big.NewInt(6000),
```

> **关于 M 与 epoch boundary 的关系**：Luban extraData 格式变更只在 Parlia epoch block 生效（epoch block 为 `Parlia.Epoch=200` 的整数倍块）。若 M 不是 epoch block，M 本身的 extraData 仍是 97B 是正确行为（不是 bug），第一个可验证 Luban-form 438B 的块为 `ceil(M/200)*200`。**推荐**将 M 直接选为 epoch boundary（M mod 200 = 0）以便在激活块即完成可观察性验证；运维上这也避免读者把 "97B 不是 438B" 误判为 bug。详见 §10 v0.3.0 retro addendum 中的 165400 复盘。

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

Feynman 后 validator 管理由 StakeHub (`0x...2002`) 接管，但实际"出块名册"仍由 BSCValidatorSet (`0x...1000`) 持有。理解三层 set + 两套时钟是避免 cutover 事故的前提。

**三层 validator 集合**：

```
StakeHub._validatorSet            (注册池，无上限 — createValidator 写入)
    │
    ▼  breathe block (Go 层 24h，触发 updateValidatorSetV2)
    │    StakeHub.getValidatorElectionInfo → top-N 按 voting power 选举
    │    BSCValidatorSet.updateValidatorSetV2(top-N) 覆盖 currentValidatorSet
    │
BSCValidatorSet.currentValidatorSet (top-N，含 jailed/maintaining；mainnet ~41)
    │
    ▼  epoch block (block.Number % 200 == 0，Parlia 调 getMiningValidators)
    │    过滤 jailed/maintaining → cabinet (numOfCabinets, mainnet 21) + 候补洗牌
    │    写入 header.Extra（链上检查点，供历史回放/同步验签）
    │
实际出块名册                       (cabinet_count 个，每 200 块洗一次候补)
```

**两套独立时钟**——名字都叫"breathe block"但**作用不同、节奏不同**：

| 时钟 | 来源 | devnet 实际值 | 作用 |
|---|---|---|---|
| **Epoch block** | Parlia `defaultEpochLength` | 200 块 ≈ 10 分钟 | 每 200 块把 mining set 写进 header.Extra |
| **Breathe block (Go 层)** | `params.BreatheBlockInterval` | 24 小时（UTC 天对齐） | 触发 `updateValidatorSetV2` 刷新 currentValidatorSet |
| **`BREATHE_BLOCK_INTERVAL` (合约)** | `StakeHub.sol` 常量（devnet 编译时替换） | 10 分钟 | editXxx 冷却 + slash 桶 + 旧地址过期 |

> ⚠️ 后两者**不会同步漂移**，是设计上独立的两套时钟。Go 层每 24h 才会刷新 active set；合约 10 分钟只控制 validator 自己改 commission/consensus address 的冷却。

**validator 操作对照**：

| 操作 | 冷却 | 谁可调 | 备注 |
|---|---|---|---|
| `createValidator` | 无 | 任何账户 | 任意时刻可注册；注册本身 set `updateTime`，10 分钟内不能 editXxx |
| `editConsensusAddress` / `editCommissionRate` / `editDescription` / `editVoteAddress` | **共享** 10 分钟 | 自己 operator key | 4 项共享同一个 `valInfo.updateTime` |
| `getValidatorBasicInfo` / `getValidatorElectionInfo` / `getMiningValidators` | — | 任何账户 | 三个查询角度，前两者读 StakeHub，最后一个读 BSCValidatorSet |

**Feynman 激活后的注册窗口（运维流程）：**

- **窗口起点**：T3 激活的那一刻
- **窗口终点**：第一个 Go 层 breathe block（最坏接近 0 秒，取决于 T3 落在 UTC 0 点前后多远）
- **建议**：T3 选在 UTC 边界 (HH:00:00) 之后 3-5 分钟，能有一天的注册时间

**错过窗口的真实后果**（Parlia 是轮值出块，1 个 validator 就能持续出块，无 N/2 阈值）：

| 情形 | currentValidatorSet 结果 | 链状态 |
|---|---|---|
| **0 个注册** | Go 层 `updateValidatorSetV2(empty, empty, empty)` 调到合约 → `_forceMaintainingValidatorsExit` 在 `numOfFelony (0) >= _validatorSet.length (0)` 分支访问空数组 `_validatorSet[0]` → **合约 revert** → system tx 失败 → block finalize 失败 | **链卡住**（参 [BSCValidatorSet.sol#L1011-L1019](https://github.com/ABFoundationGlobal/abcore-v2-genesis-contract/blob/master/contracts/BSCValidatorSet.sol#L1011-L1019)） |
| **1-4 个注册** | currentValidatorSet 被覆盖成残缺集（1-4 个），链继续但单点风险大 — 任一 validator 离线 → 出块停顿 | 高风险但能出块 |
| **5 个全注册** | 干净切换，新选举生效 | ✅ 正常 |

**推荐运维策略**：**必须**在第一个 Go 层 breathe block 之前完成全部 5 个 `createValidator`。这跟之前文档版本的建议相反——空集**不**安全，会直接卡链。
**绝对避免**"先注册 1-2 个测试一下"——会触发第一次 `updateValidatorSetV2` 把 active set 收缩成残缺集，恢复需要等下一个 24h breathe block。
**也绝对避免**"暂时一个都不注册等下次再统一做"——空集会让合约 revert 卡链。

> **协议级保护缺失**：上游 BSC 假设 Feynman 激活时 StakeHub 已经有 mainnet 那 41 个注册 validator，所以从未测试过"空 StakeHub" 路径，合约里 line 229-233 的空集 short-circuit (`if (validatorSetTemp.length != 0)`) 看似在防空集，但**到不了那里**——line 211 `_forceMaintainingValidatorsExit` 先 revert。ABCore 走 Clique→Parlia migration 路径是 BSC 没设想过的场景，必须在 v0.4.0 激活之前手动保证 StakeHub 非空。

#### Feynman 操作命令（5 个 validator 注册）

`createValidator()` 作用：注册现有的 5 个 Parlia validator 到 StakeHub（consensus address 已在 `INIT_VALIDATORSET_BYTES` 中），active set 大小不变，不新增 validator。调用是幂等的：已存在时 revert，不 panic。

```bash
STAKE_HUB="0x0000000000000000000000000000000000002002"

# coordinator 使用各 validator 的 operator key 依次代执行（需持有全部 operator key）
# gas 由 operator 账户支付（--private-key <operator_key>），确保 operator 地址有足够余额
cast send $STAKE_HUB \
  "createValidator(address,bytes,bytes,uint64,(string,string,string,string,string))" \
  <consensus_address> \
  <vote_address_bytes> \
  <bls_proof_bytes> \
  <commission_rate_bps> \
  "(<moniker>,<identity>,<website>,<security_contact>,<details>)" \
  --private-key <operator_key> \
  --rpc-url http://rpc-0:8545

# 验证注册状态
cast call $STAKE_HUB "getValidatorBasicInfo(address)" \
  <consensus_address> --rpc-url http://rpc-0:8545
```

**StakeHub 预检（T3 激活前）：**
```bash
# 1. 验证 StakeHub 合约地址（与 release notes 中一致）
eth.getCode("0x0000000000000000000000000000000000002002")  # 非 0x

# 2. 确认每个 validator 的 operator 账户（签名 createValidator 的账户）有足够余额支付 gas
# operator key 由 coordinator 持有，gas 从 operator 地址扣除（非 consensus 地址）
cast balance <operator_address> --rpc-url http://rpc-0:8545

# 3. 提前测试 createValidator 调用（在 DevNet 上模拟）
# 确认 nonce、ABI 编码、参数格式正确

# 4. 验证 binary sha256 与 release artifact 一致（部署前）
sha256sum /usr/local/bin/geth
# 对比 release page 上的 checksum
```

**createValidator 提交策略（串行，避免 nonce 竞争）：**
```
1. validator-0 提交 createValidator → 等待 tx 确认（eth_getTransactionReceipt）→ 验证事件
2. validator-1 提交 → 等确认 → 验证
...（依次串行，不并行提交）
createValidator 是幂等的：已存在时 revert，可以安全重试，不会造成状态损坏
```

**StakeHub 注册补救策略**（详细的"错过窗口后果"已在上方 Validator 注册流程章节给出）：

- 如果发现窗口已过且有部分注册（1-4 个）：等下一个 Go 层 breathe block（24h 后）自动重选举；中间这段时间用现有残缺集出块，单点风险高，**禁止重启不在 active set 里的 validator 节点**
- **如果发现窗口已过且 0 个注册：链将在第一个 breathe block 时卡住**（`updateValidatorSetV2` 空入参在合约 `_forceMaintainingValidatorsExit` 处 revert，block 无法 finalize）。紧急动作：
  1. 立即至少把 1 个 validator 调用 `createValidator` 到 StakeHub（任意节点的 RPC，只要它在 cutover 前能接受 tx 进 mempool）；该 tx 必须在 breathe block 出块前被打包进某个 block
  2. 如果已经卡住，必须 rollback：见 [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md)
- DevNet 演练要求：先在 DevNet 上串行执行所有 5 个 createValidator 并确认成功，才可以在 Testnet/Mainnet 采用同样流程。**不允许"边激活边补注册"**。

**（可选）激活 govAB 治理投票权：**

`createValidator()` 通过 `GovToken.sync()` 完成 govAB 余额 mint，但不写入 ERC20Votes checkpoint，因此 `getVotes(operator) == 0`。若后续需要参与 `BSCGovernor` 治理提案，还需每个 validator 额外调用一次 `StakeHub.delegate(operator, true)`。`msg.value` 须 ≥ `minDelegationBNBChange`（合约默认值 1 BNB），该 BNB 同样进入质押池，不被销毁。

> **设计原因**：投票委托与质押故意解耦，允许 operator 把 govAB 投票权委托给独立的治理代理地址（而非只能自委托）。

```bash
GOV_TOKEN="0x0000000000000000000000000000000000002005"

# 每个 validator 执行一次（--private-key 使用对应 operator key）
cast send $STAKE_HUB \
  "delegate(address,bool)" \
  <operator_address> \
  true \
  --value 1ether \
  --private-key <operator_key> \
  --rpc-url http://rpc-0:8545

# 验证投票权已激活（应返回非零值）
cast call $GOV_TOKEN \
  "getVotes(address)(uint256)" \
  <operator_address> \
  --rpc-url http://rpc-0:8545
```

**验证清单：**
```bash
# 1. PUSH0 opcode 可用（部署含 PUSH0 的合约）
# 2. 第一个 breathe block 后 validator set 正确（仍是 5 个）
cast call $STAKE_HUB "getValidators()(address[])" --rpc-url http://rpc-0:8545
# 3. 链继续正常推进
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

**params/config.go 修改：**
```go
PascalTime:  newUint64(T5),
PragueTime:  newUint64(T5),
BohrTime:    newUint64(T5),
LorentzTime: newUint64(T5 + 86400),    // +1 天，epoch 200 → 500
MaxwellTime: newUint64(T5 + 86400*7),  // +7 天，epoch 500 → 1000
```

> **LorentzTime / MaxwellTime 的 epoch 切换行为**：时间戳激活与 epoch boundary 不对齐。Lorentz/Maxwell 激活后，代码按新 epoch 长度（500/1000）重新计算 `blockNumber % epoch`。若在旧 epoch 中途激活，首个新 epoch block 的实际位置取决于实现（通常为激活后第一个满足新 epoch 条件的块），不一定是直觉上的整数倍块高。**验收标准**：激活后第一个 epoch block 的 validator set 轮换正常（无 missed slot 异常），且后续 epoch boundary 间隔为 500/1000 块。建议选整点 UTC 时间戳减少对齐偏差。

**激活效果：**
- Pascal：EIP-7623（calldata cost 调整）
- Prague：EIP-7702（EOA 账户委托合约实现，委托状态持久写入账户）、EIP-2537（BLS12-381 precompile）
- Lorentz：Parlia epoch 200 → 500 blocks（**不改变出块速度**，见 §1"代码现状"）
- Maxwell：Parlia epoch 500 → 1000 blocks（同上）
- **Bohr：在 ABCore 上行为为 no-op**。系统合约 bytecode 已在 PGB 一次性部署到含 Bohr 改动的最终版（见 §1"one-shot system contract bytecode"）；`getTurnLength()` 在 `turnLength == 0` 时返回 1，跟未激活 Bohr 时的 `defaultTurnLength = 1` 一致。激活的唯一可见变化：epoch block header.extra 末尾追加 1 字节 turnLength（值为 1）。

> **Bohr 为何并入主路径而非可选附录**：跟上 BSC 上游 fork 顺序，免去未来 sync upstream patch 时的踩坑风险。Bohr 在 ABCore 不引入实质功能变化，但保持代码层面"已激活 Bohr"的状态，能让将来的 BSC patch（依赖 Bohr 的功能）正常工作。将来要打开"动态 TurnLength"完全是治理操作（`updateParam("turnLength", N)`），与 fork 激活解耦。

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

**params/config.go 修改：**
```go
FermiTime:  newUint64(T6),
OsakaTime:  newUint64(T6),
MendelTime: newUint64(T6),

// BlobScheduleConfig 需要扩展：
BlobScheduleConfig: &BlobScheduleConfig{
    Cancun: DefaultCancunBlobConfig,
    Prague: DefaultPragueBlobConfigBSC,
    Osaka:  DefaultOsakaBlobConfigBSC,  // 新增
},
```

> **为什么把 Fermi / Osaka / Mendel 合并到一个升级**：BSC 主网 2026-04-28 同一时间戳激活 Osaka + Mendel；Fermi 在 ABCore 上为 no-op（不改变出块速度，见 §1"代码现状"）。三者合并节省一次升级窗口。

**激活效果：**
- **Fermi：在 ABCore 上行为为 no-op**。上游 BSC 把 `FermiBlockInterval` 从 750ms 改为 450ms，但 ABCore 在 `params/protocol_params.go` 已 override 为 3000ms（与 `DefaultBlockInterval` 一致），出块速度不变。激活 Fermi 的目的是跟上 BSC 上游 fork 顺序。
- Osaka：BPO (Blob Parameter Only) fork，引入新 blob schedule；要求 chain config 含 `blobSchedule.osaka` 字段，否则 `CheckConfigForkOrder` 在启动时报错。
- Mendel：与 Osaka 同时激活；具体内容参考 BSC 上游 release notes。

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
| 1 | v0.2.0 | ParliaGenesisBlock = N（devnet 实测值 1600，PR #103/#104）| 块高 | bootstrap 自动；snapshot restore drill；完整 Parlia 验证 | ≥ 24h（≈ 28800 块 @ 3s）|
| 2 | v0.3.0 | London + 13 BSC block forks = M（devnet 计划值 6000）| 块高 | Luban extraData 验证（M 选在 200 倍数上时，M 自己就是首个 Luban-form epoch block）| ≥ 48h |
| 3 | v0.4.0 | Shanghai + Kepler + Feynman + FeynmanFix = T3 | 时间戳（binary 中硬编码）| T3 后 ≤10 分钟内 5 个 validator 注册 StakeHub + delegate govAB | ≥ 48h |
| 4 | v0.5.0 | Cancun + Haber + HaberFix = T4 | 时间戳（binary 中硬编码）| BlobScheduleConfig 必设；blob tx + header 验证 | ≥ 48h |
| 5 | v0.6.0 | Prague + Pascal + Bohr = T5；Lorentz = T5+1d；Maxwell = T5+7d | 时间戳（binary 中硬编码）| Maxwell 后 48h 才算完整观察；出块速度不变 | ≥ 9 天 |
| 6 | v0.7.0 | Fermi + Osaka + Mendel = T6 | 时间戳（binary 中硬编码）| blobSchedule.osaka 必设；出块速度不变 | ≥ 48h |

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
- N、M、T3～T6 根据当前 Testnet 块高重新设定
- 时间戳 fork 的 T 值在发布 binary 时硬编码，选择距发布时间 ≥ 48h 的 UTC 整点
- 同样需要执行 snapshot restore drill（在 Testnet 的非关键节点上执行）

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

DevNet 中单 RPC 节点（rpc-0）是可接受的（演练环境）。

**Testnet / Mainnet 要求：**
- 至少 2 个独立 RPC 节点，位于不同服务器
- 通过 load balancer / DNS round-robin 提供服务
- validator 节点不对外暴露 RPC
- 每次升级时 RPC 节点与 validator 节点同步替换 binary

**RPC 健康检查（load balancer 需实现以下探针）：**
```bash
# 存活探针（liveness）：节点进程存活且 HTTP 可响应
curl -sf -X POST http://rpc-N:8545 \
  -d '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}'

# 就绪探针（readiness）：节点块高不落后超过 N 个块
LATEST=$(cast block-number --rpc-url http://rpc-0:8545)
LOCAL=$(cast block-number --rpc-url http://rpc-N:8545)
# 若 LATEST - LOCAL > 10，则标记为不健康，从 load balancer 摘除
```

load balancer 探针失败时自动摘除，其余健康节点继续服务，不需要人工介入。

---

### Mainnet 激活后前向修复 Runbook（当回滚不可行时）

若 Mainnet 激活后出现问题但已有外部交易上链，回滚代价极高，优先执行前向修复：

```
1. 隔离问题 validator（停止出块，但不停止同步）
2. 确认剩余 validator 仍构成多数派（≥ 3/5）
3. RPC 流量切换到健康节点（更新 load balancer / DNS）
4. 通知外部消费者（dApp、indexer、explorer）：
   - 告知问题性质和预计修复时间
   - 建议暂停依赖新 fork 特性的操作
5. 在问题 validator 上调查根因（日志、state、peers）
6. 修复后逐一重新引入隔离节点，验证同步正确后再出块
7. 全网恢复正常后更新状态页
```

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

---

## 八、Mainnet 升级 FAQ（外部集成方参考）

> 本节作用域：Mainnet 六次升级（主路径 Upgrade 1–6）对外部集成方的影响，用于协调外部对接团队的准备工作。
> DevNet / Testnet 升级仅用于内部演练，不作为对外服务承诺的参考。
> "链不中断"指链持续出块、RPC 持续可用；不代表所有外部集成无需任何适配。RPC 方法名向后兼容，但各升级后区块 schema 会新增字段、引入新交易类型，严格 JSON schema 解析或 ORM 映射的集成方需关注兼容性。
> **ABCore 永久维持 3 秒出块间隔**（见 §1"代码现状"），所有升级不改变出块速度；外部集成无需为出块加速做适配。

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

| # | 版本 | 激活方式 | 最短观察窗口 | 备注 |
|---|------|---------|------------|------|
| 1 | v0.2.0 Parlia | 块高（自动）| ≥ 24h（≈ 28800 块 @ 3s）| 覆盖至少一个完整 Go 层 breathe block 周期；Parlia epoch=200 块 (≈ 10 min) 已经在 PGB 自身 + 后续每 200 块验证过 |
| 2 | v0.3.0 London+BSC forks | 块高（自动）| ≥ 48h | London baseFee 和 Luban extraData 须专项验证 |
| 3 | v0.4.0 Shanghai/Feynman | 时间戳 | ≥ 48h | T3 硬编码在 binary 中；激活后约 10 分钟内须完成 5 个 validator StakeHub 注册 + delegate govAB |
| 4 | v0.5.0 Cancun | 时间戳 | ≥ 48h | — |
| 5 | v0.6.0 Prague + Pascal + Lorentz + Maxwell + Bohr | 时间戳 | ≥ 9 天 | Lorentz = T5+1d；Maxwell = T5+7d（协议配置固定）；Maxwell 激活后再观察 ≥ 48h；Bohr 在 ABCore 上为 no-op |
| 6 | v0.7.0 Fermi + Osaka + Mendel | 时间戳 | ≥ 48h | Fermi 在 ABCore 上为 no-op（出块速度不变）；Osaka 需要 blobSchedule.osaka 配置 |

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
| Upgrade 3（Shanghai/Feynman）| PUSH0 等新 opcode 对普通转账透明；StakeHub 注册在激活后约 10 分钟内完成，链正常出块。极端情形（≥ 2 个 validator 漏注册）可能出现短时出块抖动（概率极低，有 DevNet/Testnet 演练保障） | 无需操作；可关注官方状态页 |
| Upgrade 4（Cancun）| 引入 blob 交易（type-3）；通常情况下普通用户不会直接发送 blob 交易；区块头新增 blob 相关字段 | 无需操作 |
| Upgrade 5（Prague + Pascal + Lorentz + Maxwell + Bohr）| EIP-7702：EOA 可通过 type-4 set-code 交易将其账户委托给合约实现；**委托状态写入账户，持续有效直到主动撤销**；普通 ETH 和 ERC-20 转账不受影响。Lorentz/Maxwell：Parlia epoch 长度变化（200→500→1000），对普通转账透明。Bohr 在 ABCore 上为 no-op | 无需操作；如有账户抽象需求可在此升级后评估 |
| Upgrade 6（Fermi + Osaka + Mendel）| 在 ABCore 上**出块速度仍为 3s**（不变）；Fermi 上游本应降至 450ms，已在 params override；Osaka 引入新 blob schedule，普通用户不感知 | 无需操作 |

#### b. AB Connect ↔ BSC 跨链桥

**TODO：由 AB Connect 团队评估。** 每次升级后，团队需根据桥的实际技术实现，评估以下升级对桥的影响并确认所需动作：

| 升级 | 需评估 |
|------|--------|
| Upgrade 1（Parlia）| 共识引擎切换影响 |
| Upgrade 2（London+BSC forks）| 区块头格式变化、EIP-1559 fee 模型影响 |
| Upgrade 3（Feynman）| 激活前后监控跨链事件处理正常 |
| Upgrade 4（Cancun）| 新区块头字段、新交易类型影响 |
| Upgrade 5（Prague / EIP-7702 / Bohr）| 新交易类型、EOA 账户委托机制对桥安全假设的影响；Bohr 在 ABCore 上为 no-op |
| Upgrade 6（Fermi / Osaka / Mendel）| Fermi 在 ABCore 上为 no-op（出块速度不变）；Osaka blob schedule 变化对跨链 blob tx 的影响（若有） |

#### c. AB IOT ↔ AB Connect 跨链桥

**TODO：由 AB IOT 桥团队评估。** 同 b 项，团队需根据桥的实际技术实现自行评估各升级影响。

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

**Upgrade 2 前（最高优先级）**：
- 验证 EIP-1559 gas 估算（调用 `eth_feeHistory` 或 `eth_maxPriorityFeePerGas`）
- 确保 gasPrice ≥ baseFee + tip，避免"合法但不打包"
- 支持 type-2 交易签名和广播（若计划支持）；或明确告知用户使用 type-0 并说明限制
- Testnet 集成测试

**Upgrade 5 前**：
- 对未知 tx type（type-4）实现明确拒绝或提示，不可静默失败

**Upgrade 5 前（须就绪）**：
- 实现 7702 授权账户检测（账户代码为 `0xef0100 + target_address` 委托标记）和安全提示，Prague 激活后立即生效
- 对未知 tx type（type-4）确保明确拒绝或提示，不可静默失败

**Upgrade 5 后（可选后续）**：
- 评估是否支持 type-4 tx 构造（账户抽象高级功能）

**Upgrade 6 前**：
- 对未知 tx type 实现明确拒绝或提示（Osaka 后 blob schedule 字段会变化）

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

### BPO1 / BPO2（可选）

**状态**：BSC 上游已定义字段（`BPO1Time` / `BPO2Time`，`params/config.go` 中均为 `nil`），但 BSC 主网尚未激活。BPO = Blob Parameter Only fork（仅修改 blob schedule 容量参数，不引入 EVM 功能）。

**何时考虑激活**：跟随 BSC 上游激活节奏。具体内容、性能影响以 BSC 上线后的实测数据为准。

---

### Amsterdam / Pasteur（可选）

**状态**：上游字段已定义（`AmsterdamTime` / `PasteurTime`），但 BSC 主网尚未激活。具体内容需在 BSC 上线后 review。

---

### 关于 Bohr / Fermi / Osaka / Mendel 不在本附录的说明

这四个 fork **已纳入主路径**（Bohr 进 v0.6.0，Fermi+Osaka+Mendel 进 v0.7.0），不是"可选"。理由：

- BSC 主网均已激活（Bohr=2024-09-26、Fermi=2026-01-14、Osaka/Mendel=2026-04-28）
- 对 ABCore 上的运行行为都是 no-op 或仅小幅配置变化（Osaka 需要 `blobSchedule.osaka` 字段），无实质风险
- 跟上 BSC 上游 fork 顺序可避免未来 sync upstream patch 时的依赖踩坑

代码层面 `IsBohr` / `IsFermi` / `IsOsaka` / `IsMendel` 均只依赖 `IsLondon()`，与其它 fork 零关联，因此即便希望"永远不激活"也是技术上可行的；但 ABCore 当前的运营决策是按主路径激活。

---

## 九、参考资料

| 资源 | 路径 |
|------|------|
| 共识切换 cutover Runbook | [docs/ops/fork-cutover-runbook.md](fork-cutover-runbook.md) |
| 共识切换回滚 Runbook | [docs/ops/consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md) |
| Validator 升级 Runbook | [docs/ops/validator-upgrade-v1-to-v2.md](validator-upgrade-v1-to-v2.md) |
| 节点部署文档 | [docs/ops/node-deployment-v2.md](node-deployment-v2.md) |
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

## 十、Execution History（devnet 实际执行记录）

> 本节记录 devnet 每一次升级的实际执行情况，作为 testnet/mainnet 同阶段升级的参照模板。每行记录三件事：calculation basis 和 ETA 准确性、触达的代码改动 PR、跨越过程中踩到的坑及对应修复。

### v0.2.0 — Phase 2: Clique → Parlia cutover

| 项 | 值 |
|---|---|
| Target activation | 2026-05-14 ~08:00 UTC |
| Actual cutover ts | **2026-05-14T07:58:43Z**（比 target 早 77 s）|
| Cutover block | 50000 |
| Calculation basis | head=#36871 @ 2026-05-13T21:02Z, period=3.03 s/block, safety=13129 blocks ≈ 11h |
| Image tag | v0.2.0 |
| Activation PR | [#94](https://github.com/ABFoundationGlobal/abcore-v2/pull/94) — `params/config.go` `ParliaGenesisBlock: 50000` |
| 配套 PRs | [#82](https://github.com/ABFoundationGlobal/abcore-v2/pull/82) seal-race retry-loop tuning · [#84](https://github.com/ABFoundationGlobal/abcore-v2/pull/84) `stop_below_pgb_or_die` 三层防御 Layer A · [#85](https://github.com/ABFoundationGlobal/abcore-v2/pull/85) `docs/ops/fork-cutover-runbook.md` Layer B · [#86](https://github.com/ABFoundationGlobal/abcore-v2/pull/86) `VerifyForkBlockOnDisk` engine refuse-to-start Layer C · [#90](https://github.com/ABFoundationGlobal/abcore-v2/pull/90) `--abcore.devnet` flag + `MuirGlacierBlock` align · [#91](https://github.com/ABFoundationGlobal/abcore-v2/pull/91) remove `script/devnet/` (superseded by devnet-ops) · [#93](https://github.com/ABFoundationGlobal/abcore-v2/pull/93) runbook Jenkins automation notes · [#95](https://github.com/ABFoundationGlobal/abcore-v2/pull/95) T-1.7 partial-upgrade rollback drill · [#96](https://github.com/ABFoundationGlobal/abcore-v2/pull/96) Blockscout `BLOCK_TRANSFORMER=base` checklist |
| devnet-ops PRs | #3 §3.4 + §3.5 Jenkins automation · #4 `muirGlacierBlock: 0` in Jenkinsfile.init |

**踩到的问题 + 修复**：

1. **Fork-block seal-window race**（2026-05-07 incident，DevNet）—— "engine bug" 假象。
   - 现象：测试脚本 `wait_for_same_head` → `03-stop.sh` 之间 Clique 偶尔多 seal 一个块到 height==PGB，重启用新 chain config 时 Parlia 规则把这个 Clique-form 块判 `errInvalidSpanValidators`，链在 fork block 死锁。
   - 根因：测试脚本约束违反，但同时也是真实 production cutover 风险（stop-all-then-restart-all 模式）。
   - 三层防御：[#84](https://github.com/ABFoundationGlobal/abcore-v2/pull/84) (`stop_below_pgb_or_die` 在测试脚本 fail-fast) + [#85](https://github.com/ABFoundationGlobal/abcore-v2/pull/85) (cutover runbook 改为 rolling-only SOP) + [#86](https://github.com/ABFoundationGlobal/abcore-v2/pull/86) (engine 启动时检测 Clique-form 在 PGB 直接 refuse-to-start)。

2. **MuirGlacierBlock 不一致**（2026-05-11 发现）—— rolling upgrade compat 隐患。
   - 现象：V1→V2 CheckCompatible 测试发现 V1 inline genesis.json 不含 `muirGlacierBlock`，但 `ABCoreDevnetChainConfig` 设了 `MuirGlacierBlock=big.NewInt(0)`，rolling upgrade 时 `ConfigCompatError`。
   - 修复：devnet-ops #4 给 Jenkinsfile.init 加 `'muirGlacierBlock': 0`；[#90](https://github.com/ABFoundationGlobal/abcore-v2/pull/90) 同步 abcore-v2 + 加 `TestABCoreDevnetCompatWithLiveGenesis` 钉死契约。

3. **Blockscout `BLOCK_TRANSFORMER=clique` 在 Parlia 阶段产生伪 miner 地址**（2026-05-14 cutover 后发现）—— indexer 配置错误。
   - 现象：cutover 后 ~3h，Blockscout `total_addresses` 从 9 涨到 2388（每个 Parlia 块 +1 个伪地址）。
   - 根因：`BLOCK_TRANSFORMER=clique` 让 Blockscout 忽略 RPC `miner` 字段，自己拿 extraData 后 65 字节当 Clique seal ecrecover；Parlia extraData 布局不同，ecrecover 出确定性但毫无意义的伪地址。
   - 现场修复：`BLOCK_TRANSFORMER=base` + Parlia 区间 refetch + DELETE 孤儿 `addresses` 行（2388 → 23 行）。
   - 文档化：[#96](https://github.com/ABFoundationGlobal/abcore-v2/pull/96) cutover runbook 加 pre-cutover checklist。
   - **教训**：所有下游 indexer 的 consensus-switch 适配必须在 cutover **之前**确认。

### v0.3.0 — Phase 3: London + 13 BSC block forks

| 项 | 值 |
|---|---|
| Target activation | 2026-05-18 ~08:00 UTC |
| Actual cutover ts | **2026-05-18T08:08:43Z** (block 165400 sealed) |
| Cutover block | 165400 |
| Calculation basis | head=#152404 @ 2026-05-17T21:18Z, period=3.000 s/block (实测精确), safety=12996 blocks ≈ 10.83h |
| Image tag | v0.3.0 |
| Activation PR | [#98](https://github.com/ABFoundationGlobal/abcore-v2/pull/98) — `params/config.go` 14 个 fork field 同设 165400 |
| 配套 PRs | [#99](https://github.com/ABFoundationGlobal/abcore-v2/pull/99) — docs + abcoreDevNet 路由对称化（v0.3.0 retro 引发）|

**踩到的问题（升级 day 实测）**：

1. **错误地以为 fork block 165400 自身应该是 Luban-form 438B extraData** —— 实际链上是 97B，对吗？
   - 校准：M=165400 选址时计算用了 Parlia `defaultEpochLength=200` 假设（`165400 % 200 == 0`），但 ABCore devnet 实际 `snap.EpochLength=30000`（PGB 时从 Clique config 拷贝，PR #84 路径），`165400 % 30000 = 5400 ≠ 0`，**165400 不是 epoch block**。
   - 结果：`prepareValidators` 在非 epoch block 直接 return nil 不写 validator list，**97B 是正确行为**。
   - 真正的 Luban-form 验证块是下一个 epoch block 180000（实测 2026-05-18T20:18:43Z 出 438B extraData，6/6 节点 hash 一致 `0x449ecb..711ae6`）。

2. **错误地以为 `lubanUpgrade[abcoreDevNet]` 漏注册导致 bytecode 没升级**
   - 实际：ABCore 一次性字节码部署 → 后续 fork 都不需要 bytecode 升级 → `Empty upgrade config network=Default height=165400` log 是预期 INFO，不是 bug。PR #99 起 early-return 跳过这段，日志干净。
   - 调试用错 selector：从 BSC mainnet bytecode 反推用了 `0x96713da9`，但 ABCore 编译版 `getMiningValidators()` selector 是 `0x4df6e0c3`。用正确 selector 调用：返回 5 validators + 5 空 BLS pubkey，**完全正常**。
   - **教训**：调试 BSC 合约 ABI 时去 `consensus/parlia/abi.go` 查 ABCore 编译版 ABI，不要从 BSC mainnet deployed bytecode 反推。

**Verification 结果**：✓ chain config gates 全部生效 ✓ EIP-1559 header schema ✓ `getMiningValidators()` 返回 5 validators ✓ Parlia round-robin 健康 ✓ legacy type-0 tx 仍可发送 ✓ block 180000 Luban epoch block 438B extraData。**v0.3.0 升级完全成功**。

**Addendum (post-v0.3.0)：EpochLength misalignment 根因修复**

v0.3.0 retro 中 165400 = 97B（非 Luban-form 438B）的**实际**根因（精确版）：

- 165400 是 **LubanBlock**（与其他 13 个 BSC block fork 同块），**不是 PGB**（PGB 是 50000，已经过了）
- 选址时假设运行时 `snap.EpochLength=200`，所以 `165400 % 200 == 0` 是 epoch boundary
- 但运行时 `snap.EpochLength=30000`——`Parlia.snapshot()` 在 PGB reseed 时把 `snap.EpochLength` 从 `Clique.Epoch`（30000）拷贝过来
- `165400 % 30000 ≠ 0` → 165400 走非 epoch 路径 → `prepareValidators` 不写 validator list → extraData = 97B
- **链没有报错也没有 split**：`verifyHeader` 的 epoch 检查（见 `getValidatorBytesFromHeader` 和 `isEpoch` 判定）对非 epoch block 接受空 validator list 是正确行为。"缺失"的实际后果是 Luban 升级的扩展信息（BLS pubkey + 验证器格式变化）没在我们计划的激活块出现，要等到下一个真正的 epoch block (180000) 才补上
- 注意：**PGB 自身不受影响**——`getValidatorBytesFromHeader` 和 `verifyHeader` 的 `isEpoch` 判定都把 `IsOnParliaGenesis(PGB)` 强制视为 epoch boundary，PGB 那块的 validator list 总会写进 extraData。问题只发生在 PGB 之后依赖 `number % epochLength == 0` 的**普通** fork block 上

**修复方案**：本次 devnet reset 同步修：
1. `params.ParliaConfig` 加 `Epoch uint64` 字段
2. PGB reseed 路径（`Parlia.snapshot()` 中处理 `HasCliqueAndParlia()` migration 那段）改读 `chainConfig.Parlia.Epoch`，fallback 到 `defaultEpochLength = 200`，不再从 `Clique.Epoch` 拷贝
3. 三个 ABCore chain config 显式设 `Parlia: &ParliaConfig{Epoch: 200}`
4. ABCoreDevnetChainConfig 清空 PGB 之后所有 fork 字段（pre-PGB Clique-only 基线），ParliaGenesisBlock 重新选址（PR #103 + 后续 #104 把 PGB 设为 1600）

**二阶 bug 同步消除**：`consensus/parlia/snapshot.go` 中 `apply()` 的 Lorentz/Maxwell 自动 epoch 切换（200→500→1000）只在 `snap.EpochLength == defaultEpochLength` 时触发，30000 永远不满足。修复后 Lorentz/Maxwell 激活时 epoch 切换会正确发生。

**对未来 fork 调度的指导（运维建议，不是协议约束）**：PGB 可以是任何块号——`IsOnParliaGenesis` 已经把它当 epoch boundary。但 PGB 之后**计划在固定块高激活的 fork**（LubanBlock、HertzBlock 等）应当对齐 `% epochLength == 0`，否则该 fork 的扩展信息（如 Luban 的 BLS pubkey 列表）会延迟到下一个真正的 epoch block 才出现在 extraData 里。链不会 split——`verifyHeader` 的 isEpoch 检查接受非 epoch block 的空 validator list——但激活的"可观察性"被推迟一个 epoch 窗口。

修复 PR：本文档与代码改动在同一 PR 中；合并后 devnet 数据重置 → 重新部署 binary → 重打 v0.2.0 tag。

### v0.4.0+ — 后续 upgrades（待执行）

模板待 v0.4.0（Shanghai + Kepler + Feynman + FeynmanFix）实际执行时按 v0.2.0/v0.3.0 同样格式补全。
