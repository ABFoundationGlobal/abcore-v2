# Phase 2 共识激活操作手册（fork cutover）

> **适用范围**：所有 validator 已经完成 v1 → v2 binary 升级（Phase 1，参考 [validator-upgrade-v1-to-v2.md](validator-upgrade-v1-to-v2.md)），全网仍以 pure Clique 跑链（`ParliaGenesisBlock = nil`），现在准备激活 Parlia 共识，把 chain 切到 dual-consensus 模式。
>
> **文档版本**: 1.0
> **适用版本**: abcore-v2
> **最后更新**: 2026-05-07

---

## 0. TL;DR

激活 Parlia（在 chain config 里写入 `ParliaGenesisBlock = N` 并重启所有 validator）必须 **rolling upgrade**，**不能** stop-all-then-restart-all。Rolling 升级需要在 chain 跑到 N 之前完成所有节点升级，给足安全余量。**如果违反**，会出现 "stop-window race"：某 validator 在被 SIGTERM 之前的最后几百毫秒抢 seal 了一个 height = N 的 Clique-form 块，写到 disk；重启带 PGB=N 后这个块在 Parlia 引擎下校验失败 → **chain 永久死锁在 height N**。本手册解释为什么、怎么预防、怎么验证、什么时候必须 abort 进入 [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md)。

---

## 1. 什么是 Phase 2 共识激活

### 1.1 Phase 1 vs Phase 2

Phase 1 升级（v1.13.15 → abcore-v2 binary，`ParliaGenesisBlock = nil`）是 **binary swap**，consensus 引擎不变（仍是 Clique），同 Clique 滚动升级一致 —— 详见 [validator-upgrade-v1-to-v2.md](validator-upgrade-v1-to-v2.md)。

Phase 2 升级（`ParliaGenesisBlock = nil` → `ParliaGenesisBlock = N`）是 **consensus engine 切换的激活**：v2 binary 不变，但 chain config 里多了一行 `ParliaGenesisBlock`，DualConsensus 引擎从 block N 开始用 Parlia 替代 Clique。这才是真正"切共识"的那一步。

### 1.2 共识引擎在 fork 块的行为

- block `< N` —— DualConsensus 路由到 Clique 引擎，按 Clique 规则 seal 和 verify
- block `= N`（fork 块）—— DualConsensus 路由到 Parlia 引擎；该块 extraData 必须包含完整 validator 列表（Parlia epoch checkpoint 形式），miner 字段必须是 Parlia signer 地址（非零）
- block `> N` —— Parlia 引擎，正常出块

对 chain config 的影响：**任何 validator 在 head ≥ N 时，磁盘上的 block N 必须是 Parlia-form**。如果磁盘上的 block N 是 Clique-form（miner = `0x000000…`，extraData 长度 = 196 hex chars），节点重启时 Parlia 引擎会拒绝它（`errInvalidSpanValidators` "invalid validator list on sprint end block"），chain 卡死。

---

## 2. Stop-window race（必须了解的故障模式）

### 2.1 故障场景

如果按下面这种 stop-all-then-restart-all 的方式做 Phase 2 升级：

```
T+0      给所有 validator 发 SIGTERM 进程
T+t1     v1 进程退出
T+t2     v2 进程退出
T+t3     v3 进程退出
T+t4     更新所有节点的 chain config，加 ParliaGenesisBlock=N
T+t5     重启所有节点
```

那么从 T+0 到 T+t3 这段时间（实测 100ms ~ 几秒之间），**chain 仍然在用旧 config 跑（PGB=nil，pure Clique）**。Clique period=1s 时，window 内可能完成一次 seal —— 如果该 seal 的高度刚好是 N，就成了致命的 Clique-form block N。

### 2.2 真实事件（DevNet 测试中复现）

时间线（来自 [`script/test/transition/94-run-tx-test.sh`](../../script/test/transition/94-run-tx-test.sh) 复现日志；完整 evidence 与三节点 disk 状态对照见 [`incidents/seal-deadlock-2026-05-07/`](incidents/seal-deadlock-2026-05-07/)）：

```
13:26:54.000  validator-1 imported b15 (head=15)
13:26:54.001  validator-2 imported b15 (head=15)
13:26:54.985  validator-2 commit new sealing work for b16 (Clique mode)
13:26:55.000  validator-2 successfully seal and write b16 hash=b75d54..d906a4 (Clique-form, miner=0x000)
13:26:54        ── 测试脚本同步层观测到 head=15，开始调 03-stop.sh ──
13:26:54        Stopping validator-1
13:26:55        Stopping validator-2  ← 此时 v2 已经把 b16 持久化
13:26:55        Stopping validator-3  ← 此时 v3 已从 v2 同步到 b16
13:26:55        All validators stopped.
                ── 写 OverrideParliaGenesisBlock=16 的配置，重启 ──
13:27:00        v1 重启，head=15（v1 在 b16 不是 in-turn，没 seal）
13:27:01.228    v1 用 Parlia 模式 commit b16 sealing work
13:27:01.483    v1 successfully seal b16 hash=262f29..6a3c7f (Parlia-form, miner=0xC3edefb...)
                ── v1 disk 上的 b16 是 Parlia-form，v2/v3 disk 上的 b16 是 Clique-form ──
13:27:12.681    v1: "BAD BLOCK 16 (0xb75d54..d906a4) Miner: 0x0000... Error: invalid validator list on sprint end block"
                ── v1 收到 v2/v3 推过来的 Clique-form b16，按 Parlia 引擎校验失败，永久拒绝 ──
13:27:01.483    v2: "Syncing, discarded propagated block number=16 hash=262f29..6a3c7f"
                ── v2 disk 已有 b16，丢弃 v1 推过来的 Parlia-form b16，不做 reorg ──
```

最终状态：

| Node | disk b16 hash | b16 miner | b16 extraData 长度 | 含义 |
|------|---------------|-----------|-------------------|------|
| validator-1 | `0x262f29b5...` | `0xC3edefb989...` | 316 hex | Parlia-form |
| validator-2 | `0xb75d543b...` | `0x00000000...` | 196 hex | Clique-form |
| validator-3 | `0xb75d543b...` | `0x00000000...` | 196 hex | Clique-form |

链卡死在 height 16，永远无法推进。8 次 retry 重启全部 stall。

### 2.3 为什么不能自动 reorg 修复

- **v1**（PGB=16, head=16=Parlia）收到 v2/v3 的 Clique-form b16 → block validation 阶段就被 Parlia 引擎拒绝（`errInvalidSpanValidators`），根本进不到 fork-choice 决策
- **v2/v3**（PGB=16, head=16=Clique）收到 v1 的 Parlia-form b16 → 启动期处于 syncing 状态，propagated block 被 discard；即使过了 syncing，本地 head 已经覆盖 b16，标准 fork-choice 不会自动 reorg 替换
- 所有 validator 在 b17 都尝试 mine 但拿不到合法的 b16 snapshot → 全部死锁

唯一恢复路径是 [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md)（手动 `debug.setHead(N-1)`）。

---

## 3. 预防：rolling cutover SOP

### 3.1 核心原则

**不要 stop-all。** 让 chain 持续在 Clique 模式跑，逐个 validator stop → 升级 chain config → restart → wait healthy，下一个。所有 validator 必须在 chain 跑到 N 之前完成升级。

这跟 Phase 1 的 binary 升级是同样的滚动节奏（[validator-upgrade-v1-to-v2.md §5](validator-upgrade-v1-to-v2.md)），但有一个新约束：**chain 必须没有跑到 N**。

### 3.2 安全余量计算

`PARLIA_GENESIS_BLOCK = N` 必须满足：

```
N ≥ current_head + safety_margin

safety_margin ≥ (per_node_restart_time × num_validators × overhead_factor) / clique_period
```

参数推荐值：

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| `per_node_restart_time` | 60 秒 | 单节点 stop → 启动新 config → wait healthy + RPC 响应 |
| `num_validators` | 实际数量 | DevNet=3, Testnet=5, Mainnet=具体 |
| `overhead_factor` | 3x | 应对单节点重启失败需要 SRE 介入的极端情况 |
| `clique_period` | 1s（DevNet）/ 3s（Mainnet） | 来自 genesis.json `clique.period` |

**示例（5 个 Mainnet validator，period=3s）**：

```
safety_margin ≥ (60s × 5 × 3x) / 3s = 300 块（约 15 分钟链上时间）
```

**实务建议**：用 1 小时缓冲（Mainnet ≈ 1200 块，DevNet ≈ 3600 块）。1 小时给操作员充足的 abort 时间，且不会因为某节点重启卡 5 分钟就触线。

### 3.3 操作步骤

**前置条件检查**：

```bash
# 1. 所有 validator 都已经在跑 v2 binary（Phase 1 已完成）
for host in val-1 val-2 val-3 val-4 val-5; do
  ssh "$host" 'docker exec abcore geth attach --exec "admin.nodeInfo.name"' \
    | grep -q 'v1.7' || echo "$host still on old binary"
done

# 2. 当前 chain config 里 ParliaGenesisBlock 是 nil（仍是 pure Clique）
geth attach --exec 'admin.nodeInfo.protocols.eth.config.parliaGenesisBlock' \
  ipc:/var/lib/abcore/geth.ipc
# 期望输出：null

# 3. 当前 head
HEAD=$(geth attach --exec 'eth.blockNumber' ipc:/var/lib/abcore/geth.ipc)
echo "current head: $HEAD"
```

**挑选 N**：

```bash
# 例如 5 validator + Mainnet period=3s + 1 小时缓冲
SAFETY_MARGIN=$(( 3600 / 3 ))  # 1200 blocks
N=$(( HEAD + SAFETY_MARGIN ))
echo "ParliaGenesisBlock = $N (head + ${SAFETY_MARGIN} blocks ≈ 1 hour from now)"
```

**滚动升级流程**（per validator，从 val-N 开始降序，跟 Phase 1 顺序一致）：

```bash
# 在每台 validator 上：
# 步骤 a: 提前在 config（params/config.go 或 chain config override）里写入 ParliaGenesisBlock=N
#         然后重新构建 binary 或更新启动 flag。
# 步骤 b: 停止当前 validator
docker stop abcore-validator
# 步骤 c: 启动带新 config 的进程
docker start abcore-validator
# 步骤 d: 等节点健康
until docker exec abcore-validator geth attach \
        --exec 'eth.blockNumber + " peers=" + admin.peers.length' \
        2>/dev/null | grep -E '[0-9]+ peers=[1-9]'; do
  sleep 2
done
# 步骤 e: 验证 head 已经追上其他节点（差 ≤ 5 块）
# 步骤 f: 验证当前 chain tip 仍 < N - 60（继续下一个节点的安全 buffer）
TIP=$(docker exec abcore-validator geth attach --exec 'eth.blockNumber' 2>/dev/null)
if [[ $TIP -ge $(( N - 60 )) ]]; then
  echo "ABORT: tip=$TIP too close to N=$N, run rollback procedure"
  exit 1
fi
```

每个节点完成后，进入下一个。所有节点完成后，等待 chain 自然跑到 N。

### 3.4 验证 fork crossover

链跑到 N 时（每个节点都已升级、配置一致、head < N 等到自然推进过去），按以下步骤验证：

```bash
# 1. 所有节点都跨过 N 且同意同一个 b N hash
for host in val-1 val-2 val-3 val-4 val-5; do
  ssh "$host" "docker exec abcore geth attach --exec 'eth.getBlock($N).hash'"
done | sort -u | wc -l
# 期望输出：1（所有节点 b N 一致）

# 2. b N 是 Parlia-form：miner 非零
ssh val-1 "docker exec abcore geth attach --exec 'eth.getBlock($N).miner'"
# 期望非 0x000000000000000000000000000000000000000000

# 3. b N extraData 含 validator 列表（长度 > 196 hex）
ssh val-1 "docker exec abcore geth attach --exec 'eth.getBlock($N).extraData.length'"
# 期望 ≥ 314 hex chars (vanity 64 + N×40 validator addresses + seal 130 + 余项)

# 4. ValidatorSet 系统合约已部署
ssh val-1 "docker exec abcore geth attach --exec '\
  eth.getCode(\"0x0000000000000000000000000000000000001000\", $N).length'"
# 期望 > 2（"0x" 之外有真实 bytecode）

# 5. b N-1（pre-fork 最后一块）仍是 Clique-form
ssh val-1 "docker exec abcore geth attach --exec 'eth.getBlock($((N-1))).extraData.length'"
# 期望 196 hex chars
```

参考 [devnet-upgrade-plan.md "Parlia 切换完整验证清单"](devnet-upgrade-plan.md) 的完整后置检查项。

**Devnet 自动化**：上述 5 项检查 + §3.5 post 的 BAD BLOCK 扫描已在 [devnet-ops/jenkins/Jenkinsfile.rolling](https://github.com/ABFoundationGlobal/devnet-ops/blob/master/jenkins/Jenkinsfile.rolling) 的 "升级后 - Fork 验证 (§3.4)" stage 自动执行（仅在 `pgb != nil && pgb <= head <= pgb + 1000` 窗口内跑一次；其他情况 SKIP）。Mainnet/testnet 的 Phase 2 cutover 仍是手工执行本节命令。

### 3.5 Abort 标准

任意一项触发即 abort，进入 [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md)：

- **Pre-cutover**（链还没跑到 N 时）：
  - 任何已升级 validator 重启后报 `Failed to prepare header for sealing` 或 `unauthorized validator: 0x...`（地址不在 keystore 里）
  - 任何已升级 validator 报 `BAD BLOCK <N>` 或 `invalid validator list on sprint end block`
  - 链 tip 已经 ≥ N - 60 但仍有 validator 没升级完
- **Post-cutover**（链已跑过 N 时）：
  - 任何节点 head 卡住 ≥ 2 分钟不推进
  - 任何节点反复报 BAD BLOCK
  - 节点之间 b N hash 不一致

**Devnet 自动化**："tip ≥ N - 60 且仍有节点未升级" 在 [Jenkinsfile.rolling](https://github.com/ABFoundationGlobal/devnet-ops/blob/master/jenkins/Jenkinsfile.rolling) 的 "升级前 - Phase 2 安全余量检查 (§3.5 pre)" stage 自动 abort；"head 卡住" 由前后两个 "跨节点一致性检查" stage 间接检测（如果 head 不动，commonHeight 不变，PR #2 的 hash 校验仍跑但不会进 Phase 2 验证窗口）；"反复 BAD BLOCK" 和 "b N hash 不一致" 在 "升级后 - Fork 验证 (§3.4)" stage 自动 abort。

---

## 4. 为什么 stop-all 不行

为对照清楚记录：以下做法**不安全**，严禁：

```
❌ 同时给所有 validator SIGTERM
❌ 等所有进程退出
❌ 修改所有节点 config 加 PGB=N
❌ 同时 restart 所有 validator
```

理由：在 SIGTERM 串行投递的窗口内（实测可达 1-2 秒），剩余在跑的 validator 仍是旧 config（PGB=nil，pure Clique），如果当前 chain head + 1 = 选中的 N，那个 validator 完全合法地 seal 了一个 Clique-form block N 写到 disk。重启带 PGB=N 后这个块在 Parlia 引擎下非法 → 永久死锁。

即使把 N 选到很远（head + 1000），stop-all 模式仍有以下问题：

- **多次 round 的累积风险**：每次 stop-all 的 race window 即使概率低，跨多次升级累计；rolling 模式从架构上消除了这个 race
- **没有 abort 路径**：stop-all 模式下如果某节点重启失败，整个网络已经进入新 config 的不一致状态，回滚成本高（必须全网 setHead）；rolling 模式可以单点回退，链不停

DevNet 测试套件历史上用 stop-all 是因为 testing 简化（让所有节点磁盘 head 同时 frozen，便于 wait_for_same_head 断言）。**生产环境不能照搬这个模式**。已通过 [`script/test/transition/lib.sh`](../../script/test/transition/lib.sh) 的 `stop_below_pgb_or_die` helper（2026-05-07 加入）在测试层面把这个 race 转成显式 fail-fast，但根本上测试模式跟生产模式应当不同。

---

## 5. 与其他 ops doc 的关系

| 阶段 | Doc |
|------|-----|
| 节点首次部署 | [node-deployment-v2.md](node-deployment-v2.md) |
| Phase 1 binary 升级（v1 → v2，仍 Clique） | [validator-upgrade-v1-to-v2.md](validator-upgrade-v1-to-v2.md) |
| **Phase 2 共识激活（PGB=nil → PGB=N）** | **本文** |
| Phase 2 失败后回滚到 Clique | [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md) |
| 完整 5-phase 升级路径规划 | [devnet-upgrade-plan.md](devnet-upgrade-plan.md) |

---

## 6. Changelog

- **1.0 (2026-05-07)** — 初版。基于 DevNet 测试中发现的 stop-window race（详见 [`incidents/seal-deadlock-2026-05-07/`](incidents/seal-deadlock-2026-05-07/)），系统化记录 Phase 2 cutover 的 race 模式和 rolling 升级 SOP。
