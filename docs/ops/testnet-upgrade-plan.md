# Testnet 升级操作计划（devops 视角）

**文档版本**: 1.0
**适用网络**: ABCore 测试网（Chain ID 26888）；之后同样流程用于主网（Chain ID 36888）
**受众**: devops / 运维同事
**前置**: DevNet 已完整跑通 6 步升级（路径与参数见 [devnet-upgrade-plan.md](devnet-upgrade-plan.md) §十 执行历史）

---

## §0 如何使用本文档

本文是 testnet（之后 mainnet）升级的**操作 runbook**。它只描述 **devops 要做哪些操作**，不解释代码内部为什么。明确分工：

- **devops（你）**：快照、拉取并校验镜像、按滚动顺序停起容器、等节点健康、把状态交回 dev team。
- **dev team**：决定所有参数值、改源码、构建并发布 binary、做所有持私钥的链上操作、判定每步升级是否验收通过。

你拿到的每个升级版本都是一个**黑盒交付物**：dev team 给你「镜像 tag + sha256 校验值 + 激活点（一个块高 N/M，或一个时间戳 T，已编进 binary）+ 预期观察窗口」。你**不需要**知道这些值怎么算出来、在源码哪里、为什么这么选。

> 🚦 **贯穿全文的红线**：本计划每一步、每一次 validator 重启都是 **rolling（逐个滚动）**，**绝不 stop-all（同时停起多台）**。同时重启过多 validator 会触发死锁，在共识切换那一步（§4 Upgrade 1）会导致**永久卡链**。机理见 [node-and-validator-deployment.md §5](node-and-validator-deployment.md#5-seal-race-死锁recents-机制所有路径通用) 与 [fork-cutover-runbook.md §2](fork-cutover-runbook.md#2-stop-window-race必须了解的故障模式)。

**配套文档**（什么场景用哪篇见 [README.md](README.md)）：

| 用途 | 文档 |
|---|---|
| 部署 / v1→v2 迁移 / 换 tag 的具体命令 | [node-and-validator-deployment.md](node-and-validator-deployment.md) |
| 共识切换（Upgrade 1）的完整 SOP | [fork-cutover-runbook.md](fork-cutover-runbook.md) |
| 共识切换失败回滚 | [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md) |
| fork 顺序 / 参数 / 验收标准（dev 拥有的 SoT） | [devnet-upgrade-plan.md](devnet-upgrade-plan.md) |

---

## §1 职责边界（RACI）

把这张表交给 dev team 对齐分工。R/A = 负责并拍板，C = 配合/提供输入，— = 不参与。

| 活动 | Dev team | Devops |
|---|---|---|
| 决定激活点（块高 N/M、时间戳 T）等所有参数值 | R/A | C（提供当前 head / 链上时间戳）|
| 改源码、构建 binary、发布镜像 + 公布 sha256 校验值 | R/A | C（消费镜像）|
| 每步升级前对所有节点做全量快照 | C | R/A |
| canary（先在 1 个非关键 RPC 节点验证新镜像）| C | R/A |
| validator 滚动替换、等健康、维持出块 | C（约定顺序与安全余量）| R/A |
| 任何持私钥的链上操作（注册、委托、投票等）| R/A | —（**devops 不持 validator 私钥**）|
| 每步升级后的观测与验收（missed slot / reorg / 出块轮换 / 最终性）| R/A | C（提供 metrics 访问与 dashboard）|
| 共识切换（Phase 2）go / abort 决策 | R/A | C/R（执行 abort 与回滚操作）|
| 协调式回滚的具体执行 | C | R/A |

> **一句话**：凡是"定值、改码、持私钥、判定通过"都归 dev team；devops 只做"快照、拉镜像、滚动停起、等健康、交回"。任何一步如果你发现需要私钥或需要改配置文件里的参数值，**停下来交给 dev team**。

---

## §2 第一步：确定 testnet 的起点

testnet 当前可能是 v1 裸机，也可能已经是某个 v2 Docker，但**一定还没做过 Parlia 共识切换**。进入 6 步升级前，必须先把全网拉到一个统一基线。

### §2.1 清点现状

对**每一个节点**（validator + RPC）记录下列信息（全部只读，不改任何东西）：

- host、角色（validator / RPC）、进程管理器（Supervisor 裸机 vs Docker）
- 当前 binary 版本：`geth version`（裸机）或 `docker exec <c> geth attach --exec 'admin.nodeInfo.name' /data/geth.ipc`
- datadir 路径、enode、当前 head（`eth.blockNumber`）、`clique.getSnapshot("latest").signers`

判定命令模板见 [node-and-validator-deployment.md §0](node-and-validator-deployment.md#0-你的起点是什么决策路由) 与 [§3.3](node-and-validator-deployment.md#33-升级前检查与备份)。

确认"还没切 Parlia"（每个节点都应返回 `null`）：

```bash
# 裸机：geth attach --exec '...' <ipc>；Docker：docker exec <c> geth attach --exec '...' /data/geth.ipc
admin.nodeInfo.protocols.eth.config.parliaGenesisBlock
# 期望全部 null。任一非 null 说明已配置 PGB，停下来找 dev team 确认现状再继续。
```

### §2.2 选择基线路径

| 现状 | 操作 |
|---|---|
| **Case A — v1.13.15 裸机 + Supervisor** | 按 [node-and-validator-deployment.md §3](node-and-validator-deployment.md#3-v11315-裸机--v2-docker-在线迁移phase-1仍-clique) 逐台迁移到 v2 Docker（仍纯 Clique）。 |
| **Case B — 已是 v2 Docker（PGB=nil）** | 确认当前 tag，按 [node-and-validator-deployment.md §4](node-and-validator-deployment.md#4-已是-v2-docker滚动换-tag) 滚动统一到 dev team 指定的"基线 tag"。 |

两种情况都遵守 [§3.2 Clique 滚动升级约束](node-and-validator-deployment.md#32-clique-滚动升级约束)。

### §2.3 基线 gate（不达标不进入 §4）

- [ ] 所有 validator + ≥2 个独立 RPC 节点都跑同一个 v2 基线 tag
- [ ] 每个节点 `parliaGenesisBlock == null`（纯 Clique）
- [ ] 全网 head 一致、链持续出块
- [ ] 最近 ≥3 小时无 reorg / 无告警
- [ ] 监控接好（见 [§7](#7-监控--metrics-接入)），dev team 能看到 metrics

### §2.4 RPC 拓扑要求

testnet / mainnet 要求 **≥2 个独立 RPC 节点**（不同服务器），经 load balancer / DNS round-robin 对外服务；validator **不对外暴露 RPC**；升级时 RPC 与 validator 一并替换 binary。RPC 健康探针见 [§7.4](#74-rpc-健康探针)，背景见 [devnet-upgrade-plan.md §六 RPC 节点配置](devnet-upgrade-plan.md)。

---

## §3 每步通用 pre-flight

下面三件事在 §4 的**每一步**升级前都要做一遍。

### §3.1 全量快照（一致性 + 双签安全）

每步升级前对所有节点做**全量 datadir 快照**（含链数据，用于硬分叉回滚——不是只备份 keystore）。规程与快照内容清单见 [devnet-upgrade-plan.md 快照规程](devnet-upgrade-plan.md)。两个必须遵守的安全顺序：

- **先停该节点，再快照该节点**（clean shutdown 后再复制，避免半写状态）。
- **回滚恢复快照时：先停全部 validator → 再全部恢复 → 再全部启动。** 绝不在另一台还用同一把 key 出块时恢复快照——会触发双签。

### §3.2 接收并校验镜像

dev team 交付 `tag + sha256 + 本次改了哪个激活点`。devops：

```bash
docker pull abfoundation/abcore-v2:$TAG          # 始终强制 pull
docker run --rm --entrypoint geth abfoundation/abcore-v2:$TAG version
# 比对 dev team 给的 sha256（docker inspect 的 image digest / 或对导出 tar 校验）
```

> ⚠️ **不要凭 `docker images | grep` 判断 tag 已存在就跳过 pull**。同名 tag 被重推后，本地缓存的旧镜像会让你跑到旧 binary——这是 devnet 真实踩过的坑。每次都强制 pull。

### §3.3 canary

新 tag 先上 **1 个非关键 RPC 节点**，确认它能正常同步、peer 正常、无崩溃，再去碰任何 validator。

---

## §4 6 步升级的 devops 操作流程

### 统一操作模板（每步都一样）

除 Upgrade 1（共识切换，特殊）外，每一步 devops 的操作完全相同：

1. **收 dev 交付**：镜像 tag + sha256 + 激活点（块高 N/M 或时间戳 T）+ 预期观察窗口。
2. **前置**：全量快照（[§3.1](#31-全量快照一致性--双签安全)）+ canary（[§3.3](#33-canary)）。
3. **滚动替换**（每台 validator 逐个做，遵守 [滚动约束](node-and-validator-deployment.md#32-clique-滚动升级约束)）：
   ```bash
   # 停一个 → 拉新镜像 → 强制重建 → 等健康 → 确认出块 → 下一个（以实际部署方式为准）
   docker stop abcore-validator
   docker compose pull                            # 显式拉取，同名 tag 重推时确保是最新 image
   docker compose up -d --force-recreate          # 必须 --force-recreate，否则仍跑旧 image
   # 等健康，最多 180s（90×2s）；超时仍不健康则停下排查，勿继续滚动下一个
   for i in $(seq 1 90); do
     docker exec abcore-validator geth attach \
       --exec 'eth.blockNumber + " peers=" + admin.peers.length' /data/geth.ipc \
       2>/dev/null | grep -qE '[0-9]+ peers=[1-9]' && break
     sleep 2
   done
   # 确认 head 追上其他节点（差 ≤5 块）、该节点重新出块后，再下一个
   ```
   RPC 节点最后替换（保持 ≥1 个对外）。
4. **激活方式二选一**：
   - **块高激活（Upgrade 1、2）**：确认全部节点都换好新 binary，且当前链尖仍**安全低于**激活块高，然后让链自然跑到激活点。
   - **时间戳激活（Upgrade 3–6）**：确认全部节点都在激活时间戳 T **到达之前**换好新 binary，链会自行跨过 T。
5. **交回 dev team 验收**（你不自行宣布成功）。

### 各步要点（只列 devops 需要知道的差异）

> 每步的 fork 内容、参数值、验收标准都在 [devnet-upgrade-plan.md §三 / §四](devnet-upgrade-plan.md) 由 dev team 拥有；本表只说 devops 的操作差异。

- **Upgrade 1 — Parlia 共识切换（特殊，不走上面的通用模板）**
  这一步是把链从 Clique 切到 Parlia，是整个升级里**唯一**真正"切共识"的步骤，风险最高。**整步严格按 [fork-cutover-runbook.md](fork-cutover-runbook.md) 执行**（rolling-only、安全余量计算、abort 标准都在那篇）。devops 红线：**绝不 stop-all**，否则永久卡链（机理见该 runbook §2，你不需要理解细节，只要照做 rolling）。
  - 若 testnet 部署了区块浏览器（Blockscout 之类），dev team 会要求你在切换**之前**把它的 `BLOCK_TRANSFORMER` 设为 `base`（这是 explorer 的配置项，devops 可执行）——检查命令见 [fork-cutover §3.3](fork-cutover-runbook.md)。
  - 在一个非关键节点上做一次 snapshot-restore 演练（练熟回滚），背景见 [devnet-upgrade-plan.md §六 Testnet](devnet-upgrade-plan.md)。

- **Upgrade 2 — London 等 block fork**：走通用模板，**块高激活**。激活块高由 dev team 给定，你只部署 dev 交付的 tag、按块高激活流程操作。验收由 dev team。

- **Upgrade 3 — Shanghai / Feynman（关键交接，时间窗紧迫）**：走通用模板，**时间戳激活**。
  这是唯一一个 dev team 侧有**严格时间窗**的步骤：激活后 dev team 需要在很短的时间窗内（约 24 小时）完成一组**持私钥的链上注册**，**漏做会卡链**。对 devops 的含义：
  - 你必须**远早于**激活时间戳 T 就完成全网滚动替换，给 dev team 留足注册窗口——不要拖到临近 T 才换完。
  - 确保每个 validator 用 dev team 给的**完整启动参数**启动（这一步会多带几个最终性相关 flag，按 dev team 提供的 compose/command 原样使用）。
  - 注册本身由 dev team 用私钥执行，**devops 不碰**。注册机制见 [devnet-upgrade-plan.md §三 Upgrade 3](devnet-upgrade-plan.md)，你不需要理解。

- **Upgrade 4 — Cancun**：走通用模板，**时间戳激活**。验收（blob 交易等）由 dev team。

- **Upgrade 5 — Prague / Lorentz / Maxwell**：走通用模板，**时间戳激活**。观察窗较长（dev team 给定，模板 ≥9 天）。验收由 dev team。

- **Upgrade 6 — Fermi / Osaka**：走通用模板，**时间戳激活**。验收由 dev team。

---

## §5 共识切换（Upgrade 1）的特殊滚动约束

Upgrade 1 整步按 [fork-cutover-runbook.md](fork-cutover-runbook.md) 做，这里只重申三条对 devops 最关键的：

1. **rolling-only**：逐个 validator 停→换→等健康→下一个；**绝不 stop-all**，否则在激活块高永久死锁。
2. **安全余量**：激活块高 N 必须远高于当前链尖，给全网滚动替换 + abort 留时间。dev team 会按公式给 N，devops 配合提供当前 head；切换过程中每替换完一个节点都要确认"链尖仍安全低于 N"（见 [fork-cutover §3.3 步骤 f](fork-cutover-runbook.md)）。
3. **abort 标准**：[fork-cutover §3.5](fork-cutover-runbook.md) 列了触发 abort 的所有情形（节点报错、链尖逼近 N 但还有节点没换完、切换后 head 卡住或各节点块 N hash 不一致等）。**任一触发即停**，转 [§6.2](#62-到达越过激活块高后的协调式回滚) 回滚。

---

## §6 回滚操作

按当前所处阶段选择回滚方式：

### §6.1 仍处于 Clique（基线阶段，或 Upgrade 1 激活块高之前）

单节点回退到 v1 / 上一个 tag：按 [node-and-validator-deployment.md §3.8](node-and-validator-deployment.md#38-回滚到-v1仅适用于仍处于-clique-阶段)。链不停，逐台进行。

### §6.2 到达 / 越过激活块高后的协调式回滚

Upgrade 1 已经到达或越过激活块高、链卡死或需要撤回：按 [consensus-switch-rollback-runbook.md](consensus-switch-rollback-runbook.md) 执行**全网协调回滚**（全网进维护窗口 → 统一回退到激活块高前一块 → 去掉 PGB 配置 → 以纯 Clique 重启）。devops 执行机制，go/abort 决策与验收由 dev team。

### §6.3 任意硬分叉步（Upgrade 2–6）的快照回滚

硬分叉激活后回滚必须**结合 datadir 快照**，不能只换 binary。流程见 [devnet-upgrade-plan.md §五 回滚预案](devnet-upgrade-plan.md)：全停 → 恢复 pre-fork 快照 → 换回旧 binary → 全部启动。务必遵守 [§3.1](#31-全量快照一致性--双签安全) 的双签安全顺序（全停→全恢复→全启动）。

### §6.4 Mainnet 注意

主网激活后一旦有外部交易上链，回滚代价极高甚至不可行，优先**前向修复**（隔离问题节点、保住多数派、RPC 流量切到健康节点、通知外部消费者）。详见 [devnet-upgrade-plan.md §六 Mainnet 激活后前向修复](devnet-upgrade-plan.md)。

---

## §7 监控 / metrics 接入

节点内置 Prometheus metrics，但**没有内置 Grafana 仪表盘或告警规则**——devops 需要自己接入抓取与告警。

### §7.1 启用 metrics

启动参数加：

```
--metrics --metrics.addr 0.0.0.0 --metrics.port 6060
```

（只有带 `--metrics` 时才会起 metrics server。）然后用你们的 Prometheus 抓 `<node>:6060/debug/metrics/prometheus`。

### §7.2 重点 series（自建告警）

| series | 类型 | 关注 |
|---|---|---|
| `parlia/doublesign` | counter | **必须恒 0**，>0 立即 page（双签） |
| `parlia/verifyVoteAttestation/error` | counter | 最终性投票校验错误 |
| `parlia/updateAttestation/error` | counter | 最终性投票更新错误 |
| `parlia/attestation/voteCount` | gauge | 每块投票数 |
| 标准 geth chain/head/peer series | gauge/counter | 派生 missed-slot、reorg、peer 数 |

### §7.3 验收指标（dev team 拥有的 gate，devops 提供 dashboard）

下列阈值是 dev team 判定升级是否通过、以及 testnet→mainnet 放行的 gate；devops 负责把数据做成 dashboard 供其判读。阈值原文见 [devnet-upgrade-plan.md §六 go/no-go 表](devnet-upgrade-plan.md)：missed slot 率 <2%、reorg=0、出块轮换偏差 <20%、RPC 错误率 <0.1%、状态增长偏差 <20%。

### §7.4 RPC 健康探针

- liveness：`curl` 一个 `net_version` 请求（进程存活 + HTTP 可响应）。
- readiness：`cast block-number` 与参考 RPC 比对，落后 >10 块即从 LB 摘除。

详见 [devnet-upgrade-plan.md §六 RPC 健康检查探针](devnet-upgrade-plan.md)。

### §7.5 每步外部依赖检查

每步升级后核对外部集成（区块浏览器 / indexer / 钱包 / 告警管道 / LB 转发新 RPC 方法）是否正常，清单见 [devnet-upgrade-plan.md §七 外部依赖测试清单](devnet-upgrade-plan.md)。

---

## §8 可选自动化：Jenkins 作为参考

**按 §4 手动滚动执行完全足够**；下面只是给有自动化需求的团队的参考，不是必需。

DevNet 的部署编排在一个独立的 `devnet-ops` 仓库用 Jenkins 完成，可作为模板按 testnet 环境改用：

- `jenkins/Jenkinsfile.newchain` — 全新链/节点 bootstrap
- `jenkins/Jenkinsfile.rolling` — 滚动升级，内置"升级后 fork 验证"和"安全余量 abort"两个 stage
- `scripts/register-validators.sh` — 生成密钥并做链上注册（**dev team / 持私钥，不是 devops 范围**）

无论手动还是 Jenkins，两个 devnet 实战教训务必照做：

1. **始终强制 `docker pull`，绝不凭 grep 跳过重推的 tag**（见 [§3.2](#32-接收并校验镜像)）。
2. 共识切换那一步的 **fork 验证检查**和**"链尖逼近 N 但仍有节点没换完就 abort"**检查（[fork-cutover §3.4 / §3.5](fork-cutover-runbook.md)）：Jenkins pipeline 会自动跑，**手动操作时必须自己逐条执行**。

> 镜像构建本身由 dev team 在代码仓库用 GitHub Actions 完成并推到 Docker Hub（`abfoundation/abcore-v2:<tag>`）。Jenkins（若采用）只负责**部署编排**，不负责构建——和 devnet 的"GH Actions 构建 + Jenkins 部署"分工一致。

---

## §9 交接 checklist（devops ⇄ dev team）

**每步进入（devops 动手前）**

- [ ] 已收到 dev team 的 tag + sha256，并校验通过
- [ ] 激活点（块高 N/M 或时间戳 T）+ 观察窗口已书面记录
- [ ] 全量快照已完成（[§3.1](#31-全量快照一致性--双签安全)）
- [ ] canary 节点 green（[§3.3](#33-canary)）
- [ ] 滚动顺序、安全余量与 abort 负责人已约定（尤其 Upgrade 1）

**每步退出（devops → dev team 验收）**

- [ ] 全部节点已换到新 tag
- [ ] 全网 head 一致，日志无 `BAD BLOCK`
- [ ] metrics 正常上报，dashboard 可见
- [ ] 交回 dev team 做观测与验收，由其签收观察窗

**testnet → mainnet 放行 gate**

- [ ] [devnet-upgrade-plan.md §六 go/no-go 表](devnet-upgrade-plan.md) 全部满足（testnet 稳定运行 ≥2 周、各项阈值达标），由 dev team 拍板。
