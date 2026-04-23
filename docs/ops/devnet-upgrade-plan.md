# ABCore DevNet 建设 + 分阶段升级路径计划

> 本文档用于指导 DevNet 搭建、升级演练，以及后续 Testnet / Mainnet 的推进策略。
> **Last updated**: 2026-04-22

---

## 背景与目标

当前生产网络（Testnet 和 Mainnet）运行 abcore-v1（Clique PoA，geth v1.13.15）。目标是升级到 abcore-v2（BSC v1.7.x base，geth v1.16.x）并逐步激活最新 EVM 特性。

> **客户端说明**：升级目标不是 upstream geth，而是 abcore-v2（fork 自 bnb-chain/bsc，包含 Parlia 共识引擎、DualConsensus wrapper、ABCore 专属链配置）。upstream geth v1.14+ 已移除 Clique，无法执行 ABCore 链。

尽量减少 Testnet 上的升级次数，因此先建立 DevNet 完整演练整个升级路径，确认可行后再推 Testnet，最后推 Mainnet。

**升级总路径（6 次升级）：**

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
v0.6.0 — Bohr（出块间隔 3s → 450ms）
    ↓ Upgrade 6
v0.7.0 — Prague + Pascal + Lorentz + Maxwell（账户抽象 + epoch 变化）
```

> **为什么是 6 次而不是 5 次**：Feynman（validator 注册操作）和 Cancun（blob 交易）分开，出问题时更容易定位。若 DevNet 演练中 Feynman 注册已完全自动化，可合并 Upgrade 3+4 回到 5 次。

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

> **拓扑说明**：server-1 和 server-2 各有 2 个 validator，单机故障各失去 40% signer，但剩余 3 个仍构成多数派（3/5），链不中断。DevNet 拓扑与生产（每 validator 独立服务器）有差异，HA 测试结果不可直接推广到 Mainnet。

> **为什么 RPC 必须独立**：Bohr 激活后出块间隔 450ms，共享服务器的 IO/CPU 竞争会直接导致 val-4 missed block。server-4 是必须的，在 Upgrade 5（Bohr）之前完成迁移。

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

abcore-v1 和 abcore-v2 可以在同一网络中混合运行（切换前）。此兼容性已由 `script/compat-clique-v1-v2/` 验证（Phase 1 工作）：v2 节点可以 peer、同步、出块，v1 节点可以接受 v2 出的 Clique 块。DevNet 搭建时可逐节点替换 binary，不需要全网同步停机（仅切换 ParliaGenesisBlock 时才需要全网同步）。

### 数据库兼容性

abcore-v2 的 DB schema 是 additive：只新增 key prefix（Parlia snapshot、blob sidecar 等），不迁移现有 key，v1 datadir 直接复用。

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
ParliaGenesisBlock
    ↓（必须先于 LondonBlock）
LondonBlock
    ↓（IsShanghai/IsCancun/IsFeynman 全部依赖 IsLondon()，无 London 则全部无效）
13 个 BSC block forks（Ramanujan → Hertzfix，必须严格升序，可全设同一块高）
    ↓（CheckConfigForkOrder 要求 block forks 先于 timestamp forks）
KeplerTime + ShanghaiTime
    ↓
FeynmanTime + FeynmanFixTime  ⚠️ 需 validator 手动注册 StakeHub
    ↓
CancunTime + HaberTime + HaberFixTime
    ↓
BohrTime（高影响，3s → 450ms）
    ↓
PascalTime + PragueTime
    ↓
LorentzTime（epoch 200 → 500）→ MaxwellTime（epoch 500 → 1000）
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
| Upgrade 5（Bohr）单独一批 | 3s → 450ms 是高影响变更，需专项压测 |
| LorentzTime / MaxwellTime 各留缓冲 | epoch 长度变化影响 validator rotation，需逐步验证 |

---

## 三、6 次升级详细内容

### 每批次标准激活前 Checklist

```
□ 1. 确认当前块高/时间戳，计算激活点（至少留 30 分钟或 500 块缓冲）
□ 2. Observer 节点（非 validator）先运行新 binary，验证同步无崩溃（canary 检查）
□ 3. 验证所有节点 NTP 偏差（chronyc tracking）：
      - 所有 timestamp fork 前：< 1s
      - Bohr 前：< 50ms
□ 4. 验证节点间 peer count 稳定（每个节点至少 2 个已连接 peer）
□ 5. 发送测试交易，确认链正在出块
□ 6. 停机前做全量 datadir 快照（clean shutdown 后再复制，见快照规程）
□ 7. 按顺序替换 binary：
      server-3（val-4，单节点）→ server-1（val-0/1）→ server-2（val-2/3）→ server-4（rpc-0）
      每台替换后验证重连正常，peer count 恢复
□ 8. 所有节点启动正常后，再设定 T（timestamp fork）：
      T = 当前时间 + 30 分钟（不能提前硬编码）
      Mainnet 建议 T 至少比当前时间晚 1 小时
      T 设定后立即进入 config freeze：
        - 将当前 binary sha256、config 快照、fork 时间戳记录到操作日志
        - 不允许任何节点做额外的 binary 替换或 config 修改
        - 若必须修改（发现 critical bug），必须先中止本次升级（选择 T 尚未到来时修改
          fork timestamp 为 maxUint64 并重新发 release，或全网重启为上一版本），不允许
          在 T 已过或 T 临近时修改 config
□ 9. 等待激活点到达
□ 10. 执行对应 Upgrade 的验证清单
□ 11. 观察 2-3 个 epoch（确认 proposer rotation 正常、无 consensus 错误）再宣布成功
```

### 快照规程（一致性要求）

```
1. 停止节点（clean shutdown，等待日志输出"stopped"）
2. 记录当前块高（快照基准高度）
3. 复制 datadir 到备份目录：
   cp -a /data/validator-N /backup/validator-N-pre-upgradeX-blockH
4. 计算校验和：
   find /backup/validator-N-pre-upgradeX-blockH -type f | sort | xargs sha256sum > /backup/manifest-N.txt
5. 所有 6 个节点使用相同块高 H 作为基准（不能各自在不同块高做快照）
6. 快照前验证所有节点在块高 H 的 stateRoot 一致：
   cast call --rpc-url http://rpc-0:8545 eth_getBlockByNumber H | jq .stateRoot
   # 所有节点返回值必须相同，否则说明存在分叉，先解决分叉再快照
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
# 解析块 N 的 extraData，验证地址升序

# 4. 系统合约已部署
eth.getCode("0x0000000000000000000000000000000000001000")  # 非 0x

# 5. validator set 从系统合约读取正确（5 个地址）
cast call 0x0000000000000000000000000000000000001000 \
  "getValidators()(address[])" --rpc-url http://rpc-0:8545

# 6. proposer rotation 正常（10 个块内包含所有 5 个 validator 轮流出块）

# 7. 等待块 N+200（第一个 Parlia epoch boundary），validator set 不变
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
  4. 换回旧 binary（abcore-v1）
  5. 启动 val-4，观察：
     a. 节点从旧块高重新同步
     b. 链继续推进（其余 4 个 validator 维持多数派）
     c. 无双签告警
  6. 同步追上后，再次停止 val-4
  7. 恢复最新 datadir 快照 + 新 binary，重新加入网络
```

drill 目的：验证快照的可恢复性和 manifest 的准确性，以及回滚时 P2P 再加入流程正确。

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

**params/config.go 修改（M 选 epoch boundary，建议 M = 60001）：**
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

> **为什么 M 选 epoch boundary**：Luban extraData 格式变更在 epoch block 生效（epoch block = validator list 写入的块）。选 epoch boundary 确保第一个 Luban epoch block 格式正确。

**激活效果：**
- EIP-1559 basefee 机制生效
- Luban：validator extraData 从 20B → 68B（零值 BLS key 自动回填）
- 解锁所有后续 timestamp forks 的前提条件

**验证清单：**
```bash
# 1. baseFeePerGas 非零
eth.getBlock(M).baseFeePerGas  # > 0

# 2. Luban extraData 格式（epoch block M 的 extraData）
# 期望长度 = 32B vanity + 5×68B validators + 65B seal = 437B
eth.getBlock(M).extraData.length  # 期望 437

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

> **T3 的设定**：所有节点替换完成并验证启动正常后，T3 = 当前时间 + 30 分钟。不能提前硬编码时间。

**激活效果：**
- Shanghai/Kepler：EIP-3855（PUSH0）、EIP-3860（initcode size limit）、EIP-4895（staking withdrawals）
- Feynman：`updateValidatorSetV2` 在 breathe block 生效，StakeHub 开始参与 validator 选举

**⚠️ Feynman 特殊操作（T3 激活后、第一个 breathe block 之前完成）：**

`BREATHE_BLOCK_INTERVAL = 10 分钟`（合约内定义）。T3 后约 10 分钟触发第一个 `updateValidatorSetV2`。

`createValidator()` 作用：注册现有的 5 个 Parlia validator 到 StakeHub（consensus address 已在 `INIT_VALIDATORSET_BYTES` 中），active set 大小不变，不新增 validator。调用是幂等的：已存在时 revert，不 panic。

```bash
STAKE_HUB="0x0000000000000000000000000000000000002002"

# 每个 validator 各自执行（consensus address 就是当前出块地址）
# 资金：确保 consensus 账户有足够 gas 费
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

# 2. 确认每个 validator 的 operator 账户有足够余额支付 gas
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

### Upgrade 5：v0.6.0 — Bohr（3s → 450ms 出块）

**params/config.go 修改：**
```go
BohrTime: newUint64(T5),
```

**Bohr 激活前必须满足：**
- rpc-0 已迁移到 server-4（独立服务器）
- 所有 validator 节点间网络延迟 < 100ms（ping 互测验证）
- NTP 偏差 < 50ms（chronyc tracking）

**激活效果：**
- 出块间隔从 3s 降至约 450ms
- TurnLength 变为动态（写入 epoch block extraData）

**验证清单：**
```bash
# 出块间隔监控（连续 20 个块的 timestamp 差值，期望 ~0.45s）
# missed block 率（滚动 1 小时内 missed > 10% 即回滚）
# consensus 错误日志（任意 validator 出现即调查）
# 网络分叉检查（所有节点 eth.blockNumber 一致）
```

**回滚触发条件（任一满足即立即回滚）：**
- 滚动 1 小时内 missed block > 10%
- 任意两节点出现不同 head hash（分叉）
- 任意 validator state root 不匹配
- 任意 validator invalid block import 错误
- 不同节点 proposer set 不一致

**观察窗口：≥ 24h 压测（至少覆盖 2 个 Parlia epoch，即 400 块，约 3 分钟）**

---

### Upgrade 6：v0.7.0 — Prague + Pascal + Lorentz + Maxwell

**params/config.go 修改：**
```go
PascalTime:  newUint64(T6),
PragueTime:  newUint64(T6),
LorentzTime: newUint64(T6 + 86400),    // +1 天，epoch 200 → 500
MaxwellTime: newUint64(T6 + 86400*7),  // +7 天，epoch 500 → 1000
```

> **LorentzTime / MaxwellTime 的"epoch-aligned"说明**：timestamp fork 激活是按时间戳触发，实际激活块因出块速度变化而不确定。建议选整点 UTC 时间戳，并在激活后验证实际激活块与期望 epoch boundary 的偏差可接受。

**激活效果：**
- Pascal：EIP-7623（calldata cost 调整）
- Prague：EIP-7702（EOA 临时代理合约代码）、EIP-2537（BLS12-381 precompile）
- Lorentz：Parlia epoch 200 → 500 blocks
- Maxwell：Parlia epoch 500 → 1000 blocks

**验证清单：**
```bash
# Prague: EIP-7702 set-code 交易可发送
# EIP-2537: BLS precompile 调用返回正确结果
# Lorentz: epoch 边界从 N*200 切换到 N*500，validator rotation 正确
# Maxwell: epoch 边界从 N*500 切换到 N*1000，validator rotation 正确
# 链继续正常推进
```

**观察窗口：≥ 9 天（T6 + 7 天等待 Maxwell 激活 + 48h 观察）**

---

## 四、升级批次汇总

| # | 版本 | Fork 内容 | 激活方式 | 特殊操作 | 观察窗口 |
|---|------|-----------|----------|----------|---------|
| 1 | v0.2.0 | ParliaGenesisBlock = 30001 | 块高 | bootstrap 自动；snapshot restore drill；完整 Parlia 验证 | ≥ 30000 块（≈25h）|
| 2 | v0.3.0 | London + 13 BSC block forks = 60001 | 块高 | Luban extraData 验证 | ≥ 48h |
| 3 | v0.4.0 | Shanghai + Kepler + Feynman + FeynmanFix = T3 | 时间戳（升级后设定）| T3 后 10 分钟内 5 个 validator 注册 StakeHub | ≥ 48h |
| 4 | v0.5.0 | Cancun + Haber + HaberFix = T4 | 时间戳（升级后设定）| BlobScheduleConfig 必设；blob tx + header 验证 | ≥ 48h |
| 5 | v0.6.0 | Bohr = T5 | 时间戳（升级后设定）| rpc-0 独立服务器；NTP < 50ms；网络延迟预检；24h 压测 | ≥ 24h |
| 6 | v0.7.0 | Prague + Pascal = T6；Lorentz = T6+1d；Maxwell = T6+7d | 时间戳（升级后设定）| Maxwell 后 48h 才算完整观察 | ≥ 9 天 |

---

## 五、DevNet 演练流程

### 整体时序

```
DevNet 搭建（abcore-v1，5 validator + 1 RPC 独立服务器）
  → Upgrade 1（Parlia 切换）+ snapshot restore drill
  → Upgrade 2（London + BSC forks）
  → Upgrade 3（Feynman，coordinator 执行注册）
  → Upgrade 4（Cancun，BlobScheduleConfig 必设）
  → Upgrade 5（Bohr，24h 压测）
  → Upgrade 6（Prague + Lorentz + Maxwell，9 天观察窗口）
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
- 时间戳 fork 的 T 值在所有节点升级完成后才设定（不提前硬编码）
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

### 可选：Upgrade 1+2 合并（减少为 5 次）

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

## 八、参考资料

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
