# upgrade-drill — local 3-node phased upgrade drill (U-series)

Sequential drill of the 6-round abcore-v1 → abcore-v2 upgrade path, mirroring
`docs/ops/devnet-upgrade-plan.md` (branch `devnet-upgrade-plan`).

Uses a single abcore-v2 binary. Each round appends new fork activation block
heights or timestamps to the shared TOML config and does a rolling restart of
the 3-node network. Each round continues from the chain state left by the
previous round — chaindata is never reset between rounds.

For isolated edge-case tests of the Clique→Parlia transition itself, see
[`script/transition-test/README.md`](../transition-test/README.md).

## Scenario coverage

The local drill uses a **single abcore-v2 binary** throughout — no binary is replaced at
any round.  Each round is activated by adding new fork fields to `genesis.json` (or
`config.toml` for U-1 and U-4) and doing a rolling reinit/restart so that the updated
chainconfig takes effect on each node.  The upgrade-round labels (v0.x→v0.y) match the
rounds in `docs/ops/devnet-upgrade-plan.md` for cross-reference only; they do not imply
any code-version change in this local drill.

| ID | Script | Upgrade round | Activation | Description | Status |
|---|---|---|---|---|---|
| U-1 | `80-run-u1-parlia-switch.sh` | v0.1→v0.2 | block height | Clique→Parlia switch | 🔲 |
| U-2 | `81-run-u2-london-forks.sh` | v0.2→v0.3 | block height | London + 13 BSC block forks | 🔲 |
| U-3 | `82-run-u3-shanghai-feynman.sh` | v0.3→v0.4 | timestamp | Shanghai + Kepler + Feynman (includes StakeHub registration) | 🔲 |
| U-4 | `83-run-u4-cancun-haber.sh` | v0.4→v0.5 | timestamp | Cancun + Haber + HaberFix (includes BlobScheduleConfig) | 🔲 |
| U-5 | `84-run-u5-bohr.sh` | v0.5→v0.6 | timestamp | Bohr: block interval 3s→450ms | 🔲 |
| U-6 | `85-run-u6-prague-maxwell.sh` | v0.6→v0.7 | multi-phase timestamp | Prague + Pascal + Lorentz + Maxwell | 🔲 |

### Helper scripts

| Script | Purpose |
|---|---|
| `00-init.sh` | Generate accounts + Clique genesis + init datadirs (3-node network) |
| `07-snapshot.sh` | Full backup of chaindata / keystore / nodekey / static-nodes.json |
| `08-restore.sh` | Restore a datadir from a snapshot archive (rollback after failed upgrade) |
| `lib.sh` | Shared functions: `launch_validator`, `stop_all`, `wire_mesh`, `wait_for_head_at_least`, `wait_for_timestamp` |

## Differences from devnet

| Parameter | devnet | local drill |
|---|---|---|
| Binary | Replace binary at each round | **Single abcore-v2 binary; only genesis.json / TOML fork fields change** |
| Node count | 5 validators + 1 RPC | 3 validators |
| U-1 / U-2 block heights | 30001 / 60001 | 30 / head+60 (≤90 block intervals) |
| Timestamp observation window | 24–168 hours | 2–10 minutes |
| StakeHub registration (U-3) | All validators must register before the first breathe block | Same requirement; script sends registration txs automatically via IPC |
| BlobScheduleConfig (U-4) | Production config file | Inline TOML minimal config |
| NTP drift (U-5 Bohr) | Enforced < 50 ms | Local loopback — inherently satisfied |
| U-6 layered intervals | Prague→Lorentz +1 day, Lorentz→Maxwell +7 days | +3 minutes each |

## Config update mechanism per round

Two complementary mechanisms are used to activate forks:

**U-1 only — TOML `OverrideParliaGenesisBlock`:**
`config.toml` (created by `00-init.sh`) receives one appended line.  No genesis
reinit is needed because DualConsensus reads the override at runtime.

```toml
# config.toml after U-1
[Eth]
NetworkId = 99988
SyncMode = "full"
OverrideParliaGenesisBlock = 30    # ← appended by 80-run-u1-parlia-switch.sh

[Eth.Miner]
GasPrice = 1000000000

[Node]
InsecureUnlockAllowed = true
NoUSB = true
```

**U-2 through U-6 — rolling genesis reinit:**
`00-init.sh` writes `genesis.json` with only Berlin-and-below forks active; all
higher forks are **absent** (nil — never scheduled).  Before each round, the U-N
script adds the relevant fork fields to `genesis.json` and does a rolling genesis
reinit: each validator is stopped, `geth init` is run to update its stored
chainconfig, then it is restarted and synced before moving to the next node.
`geth init` stores the updated chainconfig in the database without wiping chain
data (the genesis block hash is unchanged; only the stored fork parameters differ).
2-of-3 quorum is maintained throughout — the chain keeps producing blocks.

```
genesis.json after 00-init.sh:
  berlinBlock = 0
  # higher forks absent (nil) — not scheduled

genesis.json after U-2 script adds them:
  berlinBlock = 0
  londonBlock = <head+60>, ramanujanBlock = <head+60>, ..., hertzfixBlock = <head+60>
  # shanghaiTime absent (nil) — still not scheduled until U-3

genesis.json after U-3 script adds them:
  londonBlock = <U-2 value>, ...
  shanghaiTime = <timestamp>, keplerTime = <timestamp>, feynmanTime = <timestamp>
  # cancunTime absent (nil) — still not scheduled until U-4
```

`config.toml` only needs additional entries for U-4 (`BlobScheduleConfig`) since
that setting has no genesis.json equivalent:

```toml
# config.toml after U-4 appends BlobScheduleConfig
[[Eth.BlobSchedule]]
Time   = 1745003600
Target = 3
Max    = 6
```

## Pre-upgrade checklist (run before every round)

```
□ 07-snapshot.sh  — full backup of current node data
□ Confirm new TOML fields are correct (block heights / timestamps leave ≥ 30 s buffer)
□ Verify all 3 nodes are in sync (eth.blockNumber matches, peers ≥ 2)
□ Complete this round's per-round prerequisite (see individual round sections)
```

## U-1 — Clique→Parlia switch (block height activation)

Corresponds to devnet Upgrade 1 (v0.2.0, `ParliaGenesisBlock = 30001`).

**Local parameters:** `PARLIA_GENESIS_BLOCK=30` (default)

**Prerequisites:** none

**Steps:**
1. `07-snapshot.sh` — back up Clique chain state
2. Set `OverrideParliaGenesisBlock = 30` in TOML; restart all validators with deadlock-recovery loop
3. Wait for block height to pass 30; observe for 2 minutes

**Verification:**
- `parlia_getValidators` returns the correct 3 validator addresses
- All 3 nodes agree on the same block hash
- Post-fork blocks have a non-zero `miner` field (proves Parlia, not Clique, is sealing)

## U-2 — London + 13 BSC block forks (block height activation)

Corresponds to devnet Upgrade 2 (v0.3.0, fork block = 60001).

**Local parameters:** `LONDON_BLOCK=<current head + 60>` (default); all 13 BSC historical block forks set to the same value

**Prerequisites:** none

**Steps:**
1. `07-snapshot.sh` — back up current chain state
2. Patch genesis.json with LONDON_BLOCK for all 14 fork fields; rolling genesis reinit (stop → `geth init` → restart → sync, one node at a time); 2-of-3 quorum maintained throughout
3. Wait for block height to pass LONDON_BLOCK; observe for 3 minutes

**Verification:**
- `eth_getBlockByNumber` returns a block with `baseFeePerGas` present (EIP-1559 active)
- No `errUnauthorizedValidator` or consensus errors in node logs

## U-3 — Shanghai + Kepler + Feynman (timestamp activation)

Corresponds to devnet Upgrade 3 (v0.4.0).

**Critical constraint:** The Go consensus engine fires `updateValidatorSetV2` at the
first breathe block after Feynman activation.  A breathe block occurs whenever two
consecutive block timestamps cross a UTC day boundary (`BreatheBlockInterval = 86400s`
in `params/protocol_params.go`).  With 1-second local blocks using wall-clock time, the
first breathe block falls at the next UTC midnight — anywhere from 0 to 24 hours after
activation.  All 3 validators must each call `StakeHub.createValidator()` **before** that
breathe block; if none are registered, `updateValidatorSetV2` produces an empty validator
set and the chain stops producing blocks.

The genesis pre-populates the validator whitelist (granting
`WHITELIST_VOTING_POWER` election priority), but whitelist membership is
independent of StakeHub registration — both steps are required.

The script sends registration transactions automatically via IPC immediately after
the activation block is confirmed.

**Local parameters:** `ShanghaiTime = KeplerTime = FeynmanTime = now + 120 s`

**Prerequisites:** Confirm that `INIT_VALIDATORSET_BYTES` in genesis encodes the
3 local validator addresses (required for `BSCValidatorSet.init()` at
`ParliaGenesisBlock`).

**Steps:**
1. `07-snapshot.sh` — back up current chain state
2. Patch genesis.json with 3 timestamps (now + 2 minutes); rolling genesis reinit (stop →
   `geth init` → restart → sync, one node at a time); 2-of-3 quorum maintained throughout
3. Wait for chain block timestamp to reach activation time
4. Script sends one `StakeHub.createValidator()` tx per validator over IPC
   (registration must complete before the next UTC midnight breathe block)
5. Observe for 3 minutes

**Verification:**
- Post-activation blocks include a `withdrawals` field (Shanghai EIP-4895)
- After the breathe block, `parlia_getValidators` still returns the correct 3 validators
- No `"no active validator"` errors in node logs

## U-4 — Cancun + Haber + HaberFix (timestamp activation)

Corresponds to devnet Upgrade 4 (v0.5.0). Requires `BlobScheduleConfig` in TOML.
(In production the RPC node must be migrated to a dedicated server first; not
applicable for local testing.)

**Local parameters:**
- `CancunTime = HaberTime = HaberFixTime = now + 120 s`
- `BlobScheduleConfig`: `[{ Time = <same timestamp>, Target = 3, Max = 6 }]`

**Prerequisites:** none

**Steps:**
1. `07-snapshot.sh` — back up current chain state
2. Append the 3 timestamps + `BlobScheduleConfig` section to TOML; rolling restart
3. Wait for activation; observe for 3 minutes

**Verification:**
- Block headers include `blobGasUsed` and `excessBlobGas` fields
- Submit one EIP-4844 blob transaction; `receipt.status == 0x1`

## U-5 — Bohr: block interval 3 s → 450 ms (timestamp activation)

Corresponds to devnet Upgrade 5 (v0.6.0). The most disruptive round in terms of
block cadence.

**Local parameters:** `BohrTime = now + 120 s`

**Prerequisites:** Local loopback clock drift is inherently < 50 ms; no NTP
configuration needed (production requires verified NTP drift < 50 ms before
this round).

**Steps:**
1. `07-snapshot.sh` — back up current chain state
2. Append `bohrTime` to TOML; rolling restart
3. Wait for activation; observe 50 consecutive blocks

**Verification:**
- Average block interval over 20 post-activation blocks < 1 s (local target;
  production target ≈ 450 ms)
- No missed slots; all 3 nodes agree on the same block hash

## U-6 — Prague + Pascal + Lorentz + Maxwell (multi-phase timestamp activation)

Corresponds to devnet Upgrade 6 (v0.7.0). Production uses layered activation:
Prague/Pascal at T6, Lorentz at T6 + 1 day, Maxwell at T6 + 7 days. Local drill
compresses each gap to 3 minutes.

**Local parameters (relative to script start time):**
- `PragueTime = PascalTime = now + 60 s`
- `LorentzTime = now + 240 s` (Prague + 3 min)
- `MaxwellTime = now + 420 s` (Lorentz + 3 min)

**Prerequisites:** none

**Steps:**
1. `07-snapshot.sh` — back up current chain state
2. Append all 4 timestamps to TOML; rolling restart
3. Prague/Pascal activates → observe 2 minutes → Lorentz activates → observe
   2 minutes → Maxwell activates → observe 3 minutes

**Verification (per phase):**
- Prague: block headers include EIP-7685 requests field
- Lorentz: block interval remains stable with no visible jitter
- Maxwell: `parlia_getValidators` returns the correct validator set after activation

## Running

### One-shot (recommended)

```bash
# Runs init → U-1 → U-2 in sequence; auto-builds geth if GETH is unset.
bash script/upgrade-drill/99-run-all.sh

# With explicit binary and custom fork heights
GETH=./build/bin/geth PARLIA_GENESIS_BLOCK=50 bash script/upgrade-drill/99-run-all.sh

# Leave nodes running after PASS for manual inspection
GETH=./build/bin/geth KEEP_RUNNING=1 bash script/upgrade-drill/99-run-all.sh
```

### Round by round

Each U-N script leaves nodes running so the next script can pick up the live
chain head.  Use this path when adding snapshots between rounds or running
rounds in separate terminal sessions.

```bash
# Prerequisite: build the abcore-v2 binary
make geth

# Initialise 3-node network (one time)
GETH=./build/bin/geth bash script/upgrade-drill/00-init.sh

# Optional: snapshot before first round
bash script/upgrade-drill/07-snapshot.sh

# U-1: Clique→Parlia (starts the Clique network, then crosses the fork)
GETH=./build/bin/geth bash script/upgrade-drill/80-run-u1-parlia-switch.sh

# Optional: snapshot before U-2
bash script/upgrade-drill/07-snapshot.sh

# U-2: London + BSC forks (nodes still running from U-1)
GETH=./build/bin/geth bash script/upgrade-drill/81-run-u2-london-forks.sh

# Optional: snapshot before U-3
bash script/upgrade-drill/07-snapshot.sh

# U-3: Shanghai + Kepler + Feynman (nodes still running from U-2)
GETH=./build/bin/geth bash script/upgrade-drill/82-run-u3-shanghai-feynman.sh

# U-4 through U-6: planned — see individual sections above
```

### Cleanup and rollback

```bash
# Wipe everything and start over
bash script/upgrade-drill/clean.sh

# Restore from a snapshot taken between rounds
SNAPSHOT=script/upgrade-drill/snapshots/snapshot-<timestamp>.tar.gz \
  bash script/upgrade-drill/08-restore.sh
# then re-run the round that follows the snapshot point
```
