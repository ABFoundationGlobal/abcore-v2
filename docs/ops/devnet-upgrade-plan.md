# ABCore DevNet 建设 + 分阶段升级路径计划

> 本文档用于指导 DevNet 搭建、升级演练，以及后续 Testnet / Mainnet 的推进策略。
> **Last updated**: 2026-04-24

---

## 背景与目标

当前生产网络（Testnet 和 Mainnet）运行 abcore-v1（Clique PoA，geth v1.13.15）。目标是升级到 abcore-v2（BSC v1.7.x base，geth v1.16.x）并逐步激活最新 EVM 特性。

> **客户端说明**：升级目标不是 upstream geth，而是 abcore-v2（fork 自 bnb-chain/bsc，包含 Parlia 共识引擎、DualConsensus wrapper、ABCore 专属链配置）。upstream geth v1.14+ 已移除 Clique，无法执行 ABCore 链。

尽量减少 Testnet 上的升级次数，因此先建立 DevNet 完整演练整个升级路径，确认可行后再推 Testnet，最后推 Mainnet。

**升级总路径（5 次升级，另有可选升级见附录）：**

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
v0.6.0 — Prague + Pascal + Lorentz + Maxwell（账户抽象 + epoch 变化）
```

> **路径选择说明**：Feynman（validator 注册操作）和 Cancun（blob 交易）分开，出问题时更容易定位。若 DevNet 演练中 Feynman 注册已完全自动化，可合并 Upgrade 3+4 回到 4 次。Bohr 为可选升级（见文末附录），不在标准路径中；Bohr 实际效果为 TurnLength 动态化，不改变出块速度。

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

> 参考 BSC 官方 validator 节点推荐配置（8 核 / 16 GB / 500 GB SSD），并根据 DevNet 实际拓扑调整。DevNet 为演练环境，流量极低，但需覆盖完整 5 次升级周期（含可选 Bohr/Fermi 升级演练）。

| 服务器 | CPU | 内存 | 磁盘 | 备注 |
|--------|-----|------|------|------|
| server-1 | 16 核 | 32 GB | 500 GB NVMe SSD | 跑 2 个 validator 进程，资源需翻倍 |
| server-2 | 16 核 | 32 GB | 500 GB NVMe SSD | 同 server-1 |
| server-3 | 8 核 | 16 GB | 500 GB NVMe SSD | 单 validator；若激活 Bohr/Fermi（可选升级），IO 延迟敏感 |
| server-4 | 8 核 | 16 GB | 500 GB NVMe SSD | RPC 节点；若激活 Bohr/Fermi（可选升级），共机器会造成 missed block，必须独立 |

**磁盘说明**：NVMe SSD，要求顺序读写 ≥ 500 MB/s、随机 4K 读写 IOPS ≥ 8000、延迟 < 1ms。DevNet 链数据量远小于生产，500 GB 足以覆盖演练周期及多次快照备份。

**网络**：各节点间延迟 < 100ms；若计划激活 Bohr 或 Fermi（可选升级），激活前需 `ping` 互测验证延迟 < 100ms。公网出口带宽 ≥ 10 Mbps 即可（DevNet 无外部流量压力）。

**云厂商参考规格**（仅供参考，按实际可用资源选择）：

| 角色 | AWS | GCP | 说明 |
|------|-----|-----|------|
| server-1 / server-2 | c5.4xlarge（16vCPU/32GB）| n2-standard-16 | 计算密集型，双 validator |
| server-3 / server-4 | c5.2xlarge（8vCPU/16GB）| n2-standard-8 | 单节点，规格可降 |
| 磁盘 | gp3，8000 IOPS，500 MB/s | pd-ssd | 避免 gp2（IOPS 受容量限制）|

> **拓扑说明**：server-1 和 server-2 各有 2 个 validator，单机故障各失去 40% signer，但剩余 3 个仍构成多数派（3/5），链不中断。DevNet 拓扑与生产（每 validator 独立服务器）有差异，HA 测试结果不可直接推广到 Mainnet。

> **为什么 RPC 必须独立**：若激活 Bohr 或 Fermi（可选升级）后出块间隔缩短，共享服务器的 IO/CPU 竞争会直接导致 val-4 missed block。server-4 在主路径中即应独立，若计划激活 Bohr/Fermi，必须在激活前完成迁移。

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
| ParliaGenesisBlock | 演练时设定（建议 block 30001）|

### 系统合约字节码路由

| 环境 | bytecode 目录 | 自动路由依据 |
|------|--------------|-------------|
| DevNet | `parliagenesis/default/` | genesis hash 不匹配 mainnet/testnet，自动路由到 default |
| Testnet | `parliagenesis/testnet/` | genesis hash = ABCoreTestGenesisHash |
| Mainnet | `parliagenesis/mainnet/` | genesis hash = ABCoreMainGenesisHash |

路由由 `core/blockchain.go:471` 在节点启动时自动完成，不需要任何 flag。DevNet 的 dev bytecode 不会泄漏到 Testnet/Mainnet，链 ID 不同导致 genesis hash 不同，自动隔离。

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

---

## 二、Fork 依赖关系与合并策略

### 关键依赖链

```
【代码层真实依赖】
ParliaGenesisBlock
    ↓ 必须先于 LondonBlock（IsParlia 前置）
LondonBlock
    ↓ IsShanghai/IsCancun/IsFeynman/IsLorentz/IsMaxwell/IsPrague 全部依赖 IsLondon()
13 个 BSC block forks（Ramanujan → Hertzfix，须严格升序，可全设同一块高）
    ↓ CheckConfigForkOrder 要求 block forks 先于 timestamp forks
（以下 timestamp forks 代码层仅依赖 IsLondon()，彼此无强制顺序依赖）
KeplerTime + ShanghaiTime
FeynmanTime + FeynmanFixTime
CancunTime + HaberTime + HaberFixTime
PascalTime + PragueTime
LorentzTime（epoch 200 → 500）
MaxwellTime（epoch 500 → 1000）

【演练推荐顺序】（非代码依赖，基于风险隔离和观察窗口）
Shanghai/Feynman → Cancun → Prague+Lorentz+Maxwell（间隔排期以充分验证）

（可选，代码层仅依赖 IsLondon()，与主路径各 fork 无激活顺序依赖）
BohrTime — TurnLength 动态化（出块速度不变）
FermiTime — 出块间隔降至约 450ms（高影响，需专项压测）
```

### 关于"13 个 BSC block forks 是 no-op"的说明

不完全正确，Luban 是实质性变更：

| Fork | 实际影响 |
|------|---------|
| Ramanujan, Niels | 出块 backoff 逻辑改进，ABCore 轻微影响 |
| MirrorSync, Bruno, Euler, Gibbs, Nano, Moran, Planck | 系统合约逻辑/gas/内存调整，ABCore 上多为 no-op |
| **Luban** | **非 no-op**：validator extraData 格式从 20B → 68B（20B 地址 + 48B 零值 BLS 公钥），epoch block header 格式改变；必须显式验证 |
| Plato | Parlia `IsOnPlato` 路径，影响系统合约调用方式 |
| Hertz, Hertzfix | EIP gas 调整 |

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
| LorentzTime / MaxwellTime 各留缓冲 | epoch 长度变化影响 validator rotation，需逐步验证 |
| Bohr / Fermi 单独激活（若计划激活）| Fermi 的出块加速是高影响变更，需专项压测；Bohr 的 TurnLength 动态化影响较小但仍应独立验证 |

---

## 三、5 次升级详细内容

### 每批次标准激活前 Checklist

```
□ 1. 确认当前块高/时间戳，验证激活点仍有足够操作窗口（块高 fork：距 N 至少剩余 500 块；时间戳 fork：T 已硬编码于 binary，确认 T 距当前时间仍有足够替换窗口）
□ 2. Observer 节点（非 validator）先运行新 binary，验证同步无崩溃（canary 检查）
□ 3. 验证所有节点 NTP 偏差（chronyc tracking）：
      - 所有 timestamp fork 前：< 1s
      - 若计划激活 Bohr 或 Fermi（可选升级）：< 50ms
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

**params/config.go 修改：**
```go
// N = 30001（第一个 Clique epoch 结束后的首块，避免 epoch boundary 冲突）
ABCoreMainChainConfig.ParliaGenesisBlock = big.NewInt(30001)
ABCoreTestChainConfig.ParliaGenesisBlock = big.NewInt(N_testnet)
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
- 块 N 之前：全网换回 PGB=nil binary，Clique 继续，无影响
- 块 N 之后：
  1. 停止所有节点（P2P 隔离，避免老状态 + 相同 validator key 在网络中造成双签）
  2. 确认所有节点已停止
  3. 所有节点恢复 pre-N datadir 快照（同一基准块高）
  4. 换回旧 binary
  5. 启动节点
  （`debug.setHead(N-1)` 仅在无快照时作 fallback，但可能导致 state/ancients 不一致）

**观察窗口：≥ 30000 块（≈25h）再推进 Upgrade 2。**

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

**params/config.go 修改（建议 M = 60001；M 本身不是 epoch boundary，Luban extraData 变更在 M 之后的第一个 epoch block `ceil(M/200)*200 = 60200` 生效）：**
```go
LondonBlock:     big.NewInt(60001),
RamanujanBlock:  big.NewInt(60001),
NielsBlock:      big.NewInt(60001),
MirrorSyncBlock: big.NewInt(60001),
BrunoBlock:      big.NewInt(60001),
EulerBlock:      big.NewInt(60001),
GibbsBlock:      big.NewInt(60001),
NanoBlock:       big.NewInt(60001),
MoranBlock:      big.NewInt(60001),
PlanckBlock:     big.NewInt(60001),
LubanBlock:      big.NewInt(60001),   // 非 no-op，需专项验证
PlatoBlock:      big.NewInt(60001),
HertzBlock:      big.NewInt(60001),
HertzfixBlock:   big.NewInt(60001),
```

> **关于 M 与 epoch boundary 的关系**：Luban extraData 格式变更在 epoch block 生效（epoch block 为 200 的整数倍块）。M=60001 本身不是 epoch block（60001 mod 200 = 1），但 Luban 会在 M 之后第一个 epoch block（块 60200）生效。如需在激活块即完成 Luban extraData 验证，应将 M 选为真正的 epoch boundary（如 60000 或 60200）。若 M 不是 epoch block，第一个可验证 Luban extraData 的块为 `ceil(M/200)*200`。

**激活效果：**
- EIP-1559 basefee 机制生效
- Luban：validator extraData 从 20B → 68B（零值 BLS key 自动回填）
- 解锁所有后续 timestamp forks 的前提条件

**验证清单：**
```bash
# 1. baseFeePerGas 非零
eth.getBlock(M).baseFeePerGas  # > 0

# 2. Luban extraData 格式（第一个 Luban epoch block：ceil(M/200)*200 = 60200）
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

**⚠️ Feynman 特殊操作（T3 激活后、第一个 breathe block 之前完成）：**

`BREATHE_BLOCK_INTERVAL = 10 分钟`（合约内定义）。T3 后第一个 breathe block 触发 `updateValidatorSetV2`（窗口长度取决于 T3 与下一个 breathe 对齐点的距离，见上方 T3 设定建议）。

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

**StakeHub 注册部分完成的处理：**

| 情形 | 结果 | 处置 |
|------|------|------|
| 所有 5 个 validator 在第一个 breathe block 前注册完成 | active set 不变 | 继续观察 |
| 1 个 validator 错过第一个 breathe block | 该 validator 从 active set 移除（~10 分钟） | 补充调用 createValidator；等下一个 breathe block 重新加入；链继续（4/5 多数） |
| 2+ 个 validator 同时未注册 | active set 缩减为 ≤3；若 ≤2 则链无法正常出块 | 立即暂停 Feynman 激活计划；恢复快照回滚 |

DevNet 演练要求：先在 DevNet 上串行执行所有 5 个 createValidator 并确认成功，才可以在 Testnet/Mainnet 采用同样流程。不允许"边激活边补注册"。

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

### Upgrade 5：v0.6.0 — Prague + Pascal + Lorentz + Maxwell

**params/config.go 修改：**
```go
PascalTime:  newUint64(T5),
PragueTime:  newUint64(T5),
LorentzTime: newUint64(T5 + 86400),    // +1 天，epoch 200 → 500
MaxwellTime: newUint64(T5 + 86400*7),  // +7 天，epoch 500 → 1000
```

> **LorentzTime / MaxwellTime 的 epoch 切换行为**：时间戳激活与 epoch boundary 不对齐。Lorentz/Maxwell 激活后，代码按新 epoch 长度（500/1000）重新计算 `blockNumber % epoch`。若在旧 epoch 中途激活，首个新 epoch block 的实际位置取决于实现（通常为激活后第一个满足新 epoch 条件的块），不一定是直觉上的整数倍块高。**验收标准**：激活后第一个 epoch block 的 validator set 轮换正常（无 missed slot 异常），且后续 epoch boundary 间隔为 500/1000 块。建议选整点 UTC 时间戳减少对齐偏差。

**激活效果：**
- Pascal：EIP-7623（calldata cost 调整）
- Prague：EIP-7702（EOA 账户委托合约实现，委托状态持久写入账户）、EIP-2537（BLS12-381 precompile）
- Lorentz：Parlia epoch 200 → 500 blocks
- Maxwell：Parlia epoch 500 → 1000 blocks

**验证清单：**
```bash
# Prague: EIP-7702 set-code 交易可发送，委托写入账户状态（extcodesize > 0）
# EIP-2537: BLS precompile 调用返回正确结果
# Lorentz: 激活后第一个 epoch block 正常产生，validator rotation 正确，后续 epoch 间隔为 500 块
# Maxwell: epoch 边界从 N*500 切换到 N*1000，validator rotation 正确
# 链继续正常推进
```

**观察窗口：≥ 9 天（T5 + 7 天等待 Maxwell 激活 + 48h 观察）**

---

## 四、升级批次汇总

| # | 版本 | Fork 内容 | 激活方式 | 特殊操作 | 观察窗口 |
|---|------|-----------|----------|----------|---------|
| 1 | v0.2.0 | ParliaGenesisBlock = 30001 | 块高 | bootstrap 自动；snapshot restore drill；完整 Parlia 验证 | ≥ 30000 块（≈25h）|
| 2 | v0.3.0 | London + 13 BSC block forks = 60001 | 块高 | Luban extraData 验证 | ≥ 48h |
| 3 | v0.4.0 | Shanghai + Kepler + Feynman + FeynmanFix = T3 | 时间戳（binary 中硬编码）| T3 后 10 分钟内 5 个 validator 注册 StakeHub | ≥ 48h |
| 4 | v0.5.0 | Cancun + Haber + HaberFix = T4 | 时间戳（binary 中硬编码）| BlobScheduleConfig 必设；blob tx + header 验证 | ≥ 48h |
| 5 | v0.6.0 | Prague + Pascal = T5；Lorentz = T5+1d；Maxwell = T5+7d | 时间戳（binary 中硬编码）| Maxwell 后 48h 才算完整观察 | ≥ 9 天 |

> **可选升级（Bohr / Fermi）**：不在标准路径中，可在主路径完成后按需激活，见文末附录。

---

## 五、DevNet 演练流程

### 整体时序

```
DevNet 搭建（abcore-v1，5 validator + 1 RPC 独立服务器）
  → Upgrade 1（Parlia 切换）+ snapshot restore drill
  → Upgrade 2（London + BSC forks）
  → Upgrade 3（Feynman，coordinator 执行注册）
  → Upgrade 4（Cancun，BlobScheduleConfig 必设）
  → Upgrade 5（Prague + Lorentz + Maxwell，9 天观察窗口）
全部通过后
  → Testnet 执行相同 5 步（各步观察窗口相同）
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

- DevNet 5 步全部通过后执行
- N、M、T3～T5 根据当前 Testnet 块高重新设定
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
- Upgrade 1 的 N 建议留 3 天块高缓冲（约 86400 块）
- Upgrade 2 的 M 在 N+30000 之后（一个完整 Parlia epoch）
- **Mainnet 激活后无法依赖"回滚"作为保险**（见背景章节）

### 可选：Upgrade 1+2 合并（执行次数减少为 4 次）

> 注：主路径逻辑上仍是 5 步（Upgrade 1–5），合并 Upgrade 1+2 是指将两次 binary 替换操作合并为一次执行窗口，执行次数从 5 次减为 4 次，逻辑步骤数不变。

- 仅适用于 DevNet 演练，Testnet/Mainnet 不推荐
- 合并条件：ParliaGenesisBlock=N，LondonBlock=M，gap ≥ 30000 块（一个完整 Parlia epoch）
- gap 5000 块（约 4h）不够，因为 Upgrade 1 的观察窗口要求 ≥ 30000 块

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

> 本节作用域：Mainnet 五次升级（主路径 Upgrade 1–5，不含可选 Bohr/Fermi）对外部集成方的影响，用于协调外部对接团队的准备工作。
> DevNet / Testnet 升级仅用于内部演练，不作为对外服务承诺的参考。
> "链不中断"指链持续出块、RPC 持续可用；不代表所有外部集成无需任何适配。RPC 方法名向后兼容，但各升级后区块 schema 会新增字段、引入新交易类型，严格 JSON schema 解析或 ORM 映射的集成方需关注兼容性。

---

### Q1：Mainnet 五次升级总共需要多长时间？

#### 时间构成（每次升级）

| 阶段 | 说明 | 时长估算 |
|------|------|---------|
| 提前通知期 | 向外部集成方发布升级公告；交易所、跨链桥、托管、硬件钱包厂商通常需要更长准备周期 | 建议提前 ≥ 2 周；对有固件/App 发版、变更审批需求的对接方，建议 4 周 |
| 操作窗口 | 逐节点替换 binary（滚动，链不中断） | 2–4 小时 |
| 激活缓冲 | T 在发布 binary 时硬编码，与块高激活对称；Mainnet 建议 T 距发布时间 ≥ 1 周，DevNet/Testnet 建议 ≥ 48h | 无额外等待；替换窗口已包含在通知期内 |
| 观察窗口 | 激活后验证各项指标（见下表）；Upgrade 1–4 为运维/风控门槛，Upgrade 5 的 9 天含协议固定偏移（Maxwell = T5+7d） | 各升级不同 |
| 间隔缓冲 | 确认稳定后才排期下一次升级 | 稳妥模式：1–2 周 |

#### 各升级观察窗口

| # | 版本 | 激活方式 | 最短观察窗口 | 备注 |
|---|------|---------|------------|------|
| 1 | v0.2.0 Parlia | 块高（自动）| ≥ 25h（≥ 30000 块）| 需等待至少 1 个完整 Parlia epoch |
| 2 | v0.3.0 London+BSC forks | 块高（自动）| ≥ 48h | London baseFee 和 Luban extraData 须专项验证 |
| 3 | v0.4.0 Shanghai/Feynman | 时间戳 | ≥ 48h | T3 硬编码在 binary 中；激活后约 10 分钟内须完成 5 个 validator StakeHub 注册 |
| 4 | v0.5.0 Cancun | 时间戳 | ≥ 48h | — |
| 5 | v0.6.0 Prague/Maxwell | 时间戳 | ≥ 9 天 | Lorentz = T5+1d；Maxwell = T5+7d（协议配置固定）；Maxwell 激活后再观察 ≥ 48h |
| — | Bohr（可选）| 时间戳 | ≥ 24h | TurnLength 动态化，出块速度不变；可在主路径完成后按需激活 |
| — | Fermi（可选）| 时间戳 | ≥ 24h（压测）| 出块间隔降至约 450ms，高影响，需专项压测；见附录 |

> **Upgrade 5 的 9 天含不可提前的协议配置**（Maxwell 时间点由链配置写死为 T5+7d），与间隔缓冲无关。

#### 总时长估算

| 模式 | 说明 | 估算总时长 |
|------|------|----------|
| 激进模式（不推荐用于 Mainnet）| 各升级观察窗口结束后立即排期下一次，无额外间隔缓冲 | 约 16 天（观察窗口合计约 13 天 + 操作/激活开销）|
| 稳妥模式（推荐）| 每次升级间隔 1–2 周（含观察窗口和缓冲），Upgrade 5 内部含固定 9 天 | 约 2–3 个月 |

> 实际排期还需叠加：外部集成方准备时间、公告发布周期、Testnet 稳定运行要求（≥ 2 周）。Mainnet 推进前须先在 Testnet 完成相同 5 步演练。

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
| Upgrade 5（Prague + Lorentz + Maxwell）| EIP-7702：EOA 可通过 type-4 set-code 交易将其账户委托给合约实现；**委托状态写入账户，持续有效直到主动撤销**；普通 ETH 和 ERC-20 转账不受影响。Lorentz/Maxwell：Parlia epoch 长度变化（200→500→1000），对普通转账透明 | 无需操作；如有账户抽象需求可在此升级后评估 |

> **可选升级 Fermi（出块速度变化）**：若后续激活 Fermi，出块速度提升约 6.7 倍（从 3s 降至约 450ms）；依赖固定出块时间（如硬编码 3s 等待）的 DApp 行为会变化。激活 Fermi 前将单独发布升级通知，届时由 DApp 开发者评估适配（建议改为事件驱动）。

#### b. AB Connect ↔ BSC 跨链桥

**TODO：由 AB Connect 团队评估。** 每次升级后，团队需根据桥的实际技术实现，评估以下升级对桥的影响并确认所需动作：

| 升级 | 需评估 |
|------|--------|
| Upgrade 1（Parlia）| 共识引擎切换影响 |
| Upgrade 2（London+BSC forks）| 区块头格式变化、EIP-1559 fee 模型影响 |
| Upgrade 3（Feynman）| 激活前后监控跨链事件处理正常 |
| Upgrade 4（Cancun）| 新区块头字段、新交易类型影响 |
| Upgrade 5（Prague / EIP-7702）| 新交易类型、EOA 账户委托机制对桥安全假设的影响 |
| Fermi（可选升级）| 出块间隔变化对超时参数、轮询逻辑的影响；激活前单独通知 |

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
| Upgrade 5（Prague + Lorentz + Maxwell）| ERC-20 Transfer 事件和充提流程无变化；type-4 为新交易类型；EIP-7702 授权账户的 code 为 `0xef0100 + target_address` 委托标记（不是普通合约 bytecode），extcodesize > 0；Lorentz/Maxwell 修改 Parlia epoch 长度（200→500→1000 blocks），与出块间隔无关，对充提业务透明 | 确认交易解析器对 type-4 tx 不会崩溃；若有"充币地址非合约（extcodesize == 0）"校验逻辑，需评估 EIP-7702 授权账户的影响（授权持续到主动撤销） |

> **可选升级 Fermi（出块速度变化）**：若后续激活 Fermi，原"N 个确认"对应的时间大幅缩短（约 1/6.7）；入账速度加快，但原有安全性假设须重新核验。届时【强制】重新评估确认数策略，须结合 Fermi 后的重组特性和最终性模型与安全/风控团队共同制定；**不应机械地按 ×6.7 换算**（时间等价 ≠ 安全性等价）。激活 Fermi 前将单独发布升级通知。

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
| Upgrade 5（Prague+Lorentz+Maxwell）| type-4 EIP-7702 tx 索引；BLS precompile（EIP-2537）调用记录；7702 授权账户状态展示；epoch 长度变化（200→500→1000）对 validator rotation 监控和 epoch block 解析的影响 |
| Fermi（可选升级）| 出块速度提升后 indexer 摄入速率、存储 I/O、RPC QPS 压力评估；激活前单独通知 |

---

### Q3：钱包支持和集成在各个升级过程中需要做什么？

#### 各升级对钱包的要求

| 升级 | 变化 | 钱包要求 | 强制级别 |
|------|------|---------|---------|
| Upgrade 1（Parlia）| 共识引擎切换，对钱包透明 | 无需变化 | — |
| Upgrade 2（London+BSC forks）| baseFeePerGas 引入；fee market 模型变化 | ① 正确处理 baseFee（gas 估算须满足 gasPrice ≥ baseFee + 目标 tip，避免合法但长时间不打包）；② 支持展示 EIP-1559 fee 参数（建议）；③ 若继续支持 legacy type-0 tx，则追踪 baseFee 是【强制】（不是可选）——可选的是"是否继续支持 legacy 发送"，但支持后必须正确处理 baseFee | 【强制：①；继续支持 legacy 路径时③也为强制】【建议：②】|
| Upgrade 2（type-2 支持）| type-2 tx 为可选新能力 | 支持 type-2 签名和广播是**可选能力**；但不支持时遇到 type-2 须明确报错/提示，不可静默失败或返回错误 gas 估算 | 【可选支持；遇到 type-2 时明确拒绝为强制】|
| Upgrade 3–4 | EVM opcode / blob tx | Upgrade 3 对钱包透明；Upgrade 4 若展示 tx 列表须能渲染 type-3（blob）而不崩溃；通常情况下用户不会发送 blob tx | — / 建议 |
| Upgrade 5（Prague + Lorentz + Maxwell）| EIP-7702：EOA 可通过 type-4 set-code tx 委托合约实现，**委托写入账户状态，持续有效直到主动撤销**；Lorentz/Maxwell 修改 Parlia epoch 长度（200→500→1000 blocks），对钱包功能透明 | ① 对 7702 授权账户（账户代码为 EIP-7702 委托标记 `0xef0100 + target_address`，区别于普通合约字节码）须展示安全提示，告知用户该账户已委托合约实现；② 对未知 tx type（type-4）须明确拒绝或提示，不可静默失败；③ 支持发起 type-4 tx（可选，高级功能） | 【强制：①②】【可选：③】|
| Fermi（可选升级）| 出块速度降至约 450ms | Receipt 轮询间隔可缩短以改善确认速度体验；固定定时器可优化；无兼容性破坏 | 建议（UX 优化），激活前单独通知 |

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

**可选升级 Fermi 激活前（届时单独通知）**：
- 评估 receipt 轮询策略（可缩短间隔或改用订阅）
- 检查"待确认"tx 的 timeout 逻辑（若基于时间不需改动；若基于块数则受出块加速影响）

#### 硬件钱包兼容性建议

| 升级 | 说明 |
|------|------|
| Upgrade 2（EIP-1559 / type-2）| 主流型号（Ledger、Trezor）在部分固件版本已支持 EIP-1559；**须确认具体型号 + 固件版本 + App 版本**，不可笼统依赖"已支持"；建议在 Upgrade 2 前通知用户检查并更新 |
| Upgrade 4（Cancun / type-3）| 通常情况下普通用户不发送 blob tx，无需特别更新；若展示 type-3 tx 历史，须确认 App 不会崩溃 |
| Upgrade 5（EIP-7702 / type-4）| type-4 为全新交易类型，硬件钱包固件和 App 支持通常会滞后；在固件/App 明确支持前，不要提示用户签名 type-4 tx；7702 授权账户的安全提示需 App 层实现 |

---

## 附录：可选升级

> 本附录列出不在标准 5 步升级路径中、但可按需激活的 fork。与主路径的 fork 相比，这些升级没有强制依赖关系（仅需 London 已激活），可在主路径完成、网络稳定后根据运营需求决定是否激活及激活时机。
>
> **激活前提**：均需要 London（LondonBlock）已激活。
> **激活顺序**：各可选升级之间无强制顺序依赖，但配置时须满足 `params/config.go` 中 `CheckConfigForkOrder` 的时间戳升序要求。

### Bohr（可选）

**实际效果**：
- `TurnLength` 改为动态读取：每个 epoch block 从 ValidatorSet 系统合约读取 TurnLength 并写入 extraData
- 默认 `TurnLength = 1`（等同于未激活 Bohr 时的行为），激活后若合约未设置则仍保持 1
- **出块速度不变**：Bohr 本身不改变出块间隔；出块间隔由时间戳 fork 控制（Lorentz=1500ms，Maxwell=750ms，Fermi=450ms）

**代码依据**：`IsBohr()` 仅依赖 `IsLondon() && isTimestampForked(BohrTime)`，与 Lorentz/Maxwell/Prague 零依赖（`params/config.go` 确认）。

**何时考虑激活**：当需要动态调整 TurnLength（每个 validator 连续出块数）时。对于固定 TurnLength=1 的网络，Bohr 无实质收益，可跳过。

**激活前置条件**：
- rpc-0 已独立服务器（若 TurnLength 调大，出块密度上升）
- NTP 偏差 < 50ms
- 节点间延迟 < 100ms（ping 互测）

**params/config.go：**
```go
BohrTime: newUint64(T_bohr),  // T_bohr 在 binary 发布时硬编码，建议距发布 ≥ 48h
```

**验证清单：**
```bash
# 1. epoch block 的 extraData 中 TurnLength 字段存在（epoch block 为 epoch 长度整数倍）
# 2. TurnLength 与 ValidatorSet 合约返回值一致
# 3. 链继续正常推进，无 consensus 错误
```

**观察窗口：≥ 2 个完整 epoch（epoch 长度取决于当前激活的 fork：激活 Lorentz 前为 200 块≈10 分钟；激活 Maxwell 后为 1000 块≈50 分钟；选较长者确保充分验证）**

---

### Fermi（可选，出块间隔 → 450ms）

**实际效果**：
- 出块间隔从当前值（默认 3s；若已激活 Lorentz 则 1500ms；若已激活 Maxwell 则 750ms）降至约 450ms
- **这是真正改变出块速度的 fork**，而非 Bohr

**代码依据**：`IsFermi()` 仅依赖 `IsLondon() && isTimestampForked(FermiTime)`。

**⚠️ 高影响变更**，激活前须满足：
- rpc-0 已独立服务器（必须，避免 IO/CPU 竞争导致 missed block）
- 所有 validator 节点间网络延迟 < 100ms（ping 互测验证）
- NTP 偏差 < 50ms（chronyc tracking）

**params/config.go：**
```go
FermiTime: newUint64(T_fermi),  // T_fermi 在 binary 发布时硬编码，建议距发布 ≥ 48h
```

**验证清单：**
```bash
# 出块速率监控：统计 100 块窗口内的平均出块间隔
# (block_N.timestamp - block_{N-100}.timestamp) / 100，期望 ≈ 0.45s
# missed block 率（滚动 1 小时内 missed > 10% 即回滚）
# consensus 错误日志（任意 validator 出现即调查）
# 网络分叉检查（所有节点 eth.blockNumber 一致）
```

**回滚触发条件（任一满足即立即回滚）：**
- 滚动 1 小时内 missed block > 10%
- 任意两节点出现不同 head hash（分叉）
- 任意 validator state root 不匹配
- 任意 validator invalid block import 错误

**观察窗口：≥ 24h 专项压测**

---

### 说明：Bohr 与 Lorentz/Maxwell/Prague 的依赖关系

`IsLorentz()`、`IsMaxwell()`、`IsPrague()` 均只依赖 `IsLondon()`，与 `IsBohr()` 零关联。Bohr 的 TurnLength 动态读取功能在 Lorentz/Maxwell 的 epoch 计算逻辑中不参与，可完全独立于主路径激活，也可永久跳过。

---

## 九、参考资料

| 资源 | 路径 |
|------|------|
| Fork 激活路径完整文档 | `.claude/fork-activation-roadmap.md` |
| 共识切换回滚 Runbook | `docs/ops/consensus-switch-rollback-runbook.md` |
| Validator 升级 Runbook | `docs/ops/validator-upgrade-v1-to-v2.md` |
| 链参数配置 | `params/config.go`（ABCoreMainChainConfig / ABCoreTestChainConfig）|
| 系统合约 bytecode | `core/systemcontracts/parliagenesis/` |
| 混版本兼容性测试脚本 | `script/compat-clique-v1-v2/` |
| 过渡测试脚本 | `script/transition-test/` |
| 本地 Parlia devnet | `script/local-v2/` |
