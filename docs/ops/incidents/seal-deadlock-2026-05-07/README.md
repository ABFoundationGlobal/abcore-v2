# Incident: Phase 2 cutover seal-window deadlock (2026-05-07)

> **TL;DR**: During a T-3 transition test (`script/test/transition/94-run-tx-test.sh`), a stop-all-then-restart-all cutover from pure Clique to `ParliaGenesisBlock=N` produced a permanent chain split at `height = N`. Three validators ended up with two different `block N` values that no fork-choice rule can reconcile. Eight consecutive retry restarts all stalled identically. Root cause: a sub-second race between `wait_for_same_head` observing `head = N-1` and `03-stop.sh` actually killing every validator process. This document is the source-of-truth evidence record for [`docs/ops/fork-cutover-runbook.md`](../../fork-cutover-runbook.md), which codifies the operational rules that prevent this in production.

---

## 1. Context

- **Date**: 2026-05-07
- **Where**: DevNet (3 validators, Clique period = 1 s)
- **What was being exercised**: T-3 = "user transaction crossing the fork", part of compat CI gate
- **Symptom that first surfaced**: PR #82 had widened the retry loop (PGB+5 / 120 s / 8 attempts) to absorb seal races during restart. CI started reporting `WARNING: chain stalled (seal-race deadlock)` and the 5-run gate occasionally failed. Eight retries in a row all hit the same wall.
- **Outcome**: not an engine bug. The retry loop was papering over a deadlock the engine cannot recover from on its own, because the on-disk state of different validators was permanently divergent.

## 2. Timeline (real timestamps, validator-2 geth.log + test script log)

```
13:26:54.000  validator-1 imported b15 (head=15)
13:26:54.001  validator-2 imported b15 (head=15)
13:26:54.985  validator-2 commit new sealing work for b16 (Clique mode, PGB=nil)
13:26:55.000  validator-2 successfully seal and write b16 hash=b75d54..d906a4 (Clique-form, miner=0x000)
13:26:54        ── test script observes head=15, starts 03-stop.sh ──
13:26:54        Stopping validator-1
13:26:55        Stopping validator-2   ← v2 had already persisted b16
13:26:55        Stopping validator-3   ← v3 had imported b16 from v2
13:26:55        All validators stopped.
                ── write OverrideParliaGenesisBlock=16 into config, restart all ──
13:27:00        v1 restarts, head=15 (v1 was not in-turn at b16, never sealed it)
13:27:01.228    v1 commit b16 sealing work (Parlia mode)
13:27:01.483    v1 successfully seal b16 hash=262f29..6a3c7f (Parlia-form, miner=0xC3edefb...)
                ── on disk: v1 b16 = Parlia-form, v2/v3 b16 = Clique-form ──
13:27:12.681    v1: "BAD BLOCK 16 (0xb75d54..d906a4) Miner: 0x0000... Error: invalid validator list on sprint end block"
                ── v1 receives Clique-form b16 from v2/v3 → Parlia engine rejects, no reorg path ──
13:27:01.483    v2: "Syncing, discarded propagated block number=16 hash=262f29..6a3c7f"
                ── v2 already has b16 locally, drops Parlia-form b16 from v1 ──
```

## 3. Post-deadlock disk state

| Node | disk `b16` hash | `b16` miner | `b16` extraData length | shape |
|------|------------------|-------------|------------------------|-------|
| validator-1 | `0x262f29b5...` | `0xC3edefb989...` | 316 hex chars | Parlia-form |
| validator-2 | `0xb75d543b...` | `0x00000000...` | 196 hex chars | Clique-form |
| validator-3 | `0xb75d543b...` | `0x00000000...` | 196 hex chars | Clique-form |

The chain is frozen at `height = 16`. b17 is never produced anywhere because every node's b17 seal attempt requires a `b16` snapshot that disagrees with the peer majority.

## 4. Why standard fork-choice does not recover

- **v1** (PGB=16, head=16=Parlia) receives v2/v3's Clique-form b16 → block validation in the Parlia engine fails with `errInvalidSpanValidators` before fork-choice ever sees the block.
- **v2/v3** (PGB=16, head=16=Clique) receive v1's Parlia-form b16 → during the restart they are still in `Syncing` state, propagated blocks are discarded; even after syncing, the local head already covers b16 and standard fork-choice never reorgs to replace a block already at the head.
- All validators trying to mine b17 cannot agree on a `b16` snapshot → permanent stall.

Recovery is only possible via the manual [consensus-switch-rollback-runbook.md](../../consensus-switch-rollback-runbook.md) procedure (`debug.setHead(N-1)` coordinated across all validators, then re-attempt cutover with rolling upgrade).

## 5. Why the retry loop cannot recover this case

Each retry iteration reloads the same on-disk b16. The Parlia engine fails verification on the same block on every attempt. PRs #79 / #82 widened the retry window to handle *recoverable* seal races during restart (where head can still rewind to before the racing block); they cannot help once the racing block is `b N` itself, because the offending block is now the very fork point.

## 6. Root cause

The millisecond window between `wait_for_same_head` returning (`head = N-1` observed) and `03-stop.sh` actually killing every node was wide enough for one validator (the in-turn signer for `b N` at Clique period = 1 s) to seal one more block. That block was a perfectly legal Clique-form `b N` at the time of writing. After restart with `ParliaGenesisBlock = N`, the same block on disk is now interpreted under Parlia rules and is invalid. The chain has no fork-choice path back.

## 7. Mitigations

| Layer | Mitigation | Status |
|-------|------------|--------|
| Test scripts | `stop_below_pgb_or_die` helper in [`script/test/transition/lib.sh`](../../../../script/test/transition/lib.sh) — fail-fast if any node persisted `b ≥ N` before stop completes | landed in PR #84 |
| Test scripts | T-3 added to compat CI 5-run gate | landed in PR #84 |
| Production operations | [`fork-cutover-runbook.md`](../../fork-cutover-runbook.md) — mandates rolling cutover, bans stop-all, defines safety-margin formula and verification checklist | landed in PR #85 (this) |
| Engine | Refuse to start when `head ≥ PGB` and on-disk head is Clique-form (defense-in-depth) | deferred follow-up, tracked in `.claude/progress.md` |

## 8. Related PRs

- **#79** / **#82** — retry-loop deadline tuning (PGB+5 / 120 s / 8 attempts). Helps recoverable seal races, cannot help this case.
- **#83** — superseded by #84.
- **#84** — test-script-level fail-fast via `stop_below_pgb_or_die`; adds T-3 to CI.
- **#85** — Phase 2 fork-cutover runbook (this incident is its primary motivation).
