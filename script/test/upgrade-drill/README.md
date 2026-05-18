# upgrade-drill — local 3-node phased upgrade drill (U-series)

Sequential drill of the 7-round abcore-v1 → abcore-v2 upgrade path, mirroring
`docs/ops/devnet-upgrade-plan.md` (branch `devnet-upgrade-plan`).

Uses a single abcore-v2 binary. Each round appends new fork activation block
heights or timestamps to the shared TOML config and does a rolling restart of
the 3-node network. Each round continues from the chain state left by the
previous round — chaindata is never reset between rounds.

For isolated edge-case tests of the Clique→Parlia transition itself, see
[`script/test/transition/README.md`](../transition/README.md).

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
| U-5 | `84-run-u5-bohr.sh` | v0.5→v0.6 | timestamp | Bohr: variable TurnLength (consecutive blocks per validator) | 🔲 |
| U-6 | `85-run-u6-prague-maxwell.sh` | v0.6→v0.7 | multi-phase timestamp | Prague + Pascal + Lorentz + Maxwell | ✅ |
| U-7 | `86-run-u7-fermi-osaka-mendel.sh` | v0.7→v0.8 | multi-phase timestamp | Fermi + Osaka + Mendel | ✅ |

### Helper scripts

| Script | Purpose |
|---|---|
| `00-init.sh` | Generate accounts + Clique genesis + init datadirs (3-node network) |
| `07-snapshot.sh` | Full backup of chaindata / keystore / nodekey / static-nodes.json |
| `08-restore.sh` | Restore a datadir from a snapshot archive (rollback after failed upgrade) |
| `lib.sh` | Shared functions: `launch_validator`, `stop_all`, `wire_mesh`, `wait_for_head_at_least`, `wait_for_timestamp` |

### Contract scenario tests

Beyond the U-series upgrade flow, a separate set of scripts (T-7 through T-13)
covers individual system-contract functions and cross-contract governance paths.
These scripts run against the 3-node network left up after U-3.

See **[CONTRACT-SCENARIOS.md](CONTRACT-SCENARIOS.md)** for the full scenario list,
implementation notes, and script index:

| ID | Script (planned) | Contracts | Description |
|---|---|---|---|
| T-7 | `89-run-t7-stakehub-lifecycle.sh` | `StakeHub` | Validator lifecycle edits: commission, description, consensus address, node IDs, info queries |
| T-8 | `90-run-t8-delegation-lifecycle.sh` | `StakeHub` + `StakeCredit` | Delegation lifecycle: additional delegate, undelegate, redelegate, claim (state-override), StakeCredit reads |
| T-9 | `91-run-t9-govtoken.sh` | `GovToken` | Voting-power history (`getPastVotes`, `getPastTotalSupply`), transfer/approve revert, `delegates` query |
| T-10 | `92-run-t10-governor-extended.sh` | `BSCGovernor` | `castVoteWithReason`, proposal cancel, Defeated state, Governor `updateParam` via governance |
| T-11 | `93-run-t11-validatorset-queries.sh` | `BSCValidatorSet` | `getLivingValidators`, `getMiningValidators`, `isWorkingValidator`, `getIncoming`, `updateParam` via governance |
| T-12 | `94-run-t12-slash-indicator.sh` | `SlashIndicator` | `getSlashThresholds`, `getSlashIndicator`, slash-counter state-override, `updateParam` via governance |
| T-13 | `95-run-t13-governance-param-matrix.sh` | `BSCGovernor` + `GovHub` + multi-target | Full governance pipeline for multiple system-contract parameter updates in sequence |

## Differences from devnet

| Parameter | devnet | local drill |
|---|---|---|
| Binary | Replace binary at each round | **Single abcore-v2 binary; only genesis.json / TOML fork fields change** |
| Node count | 5 validators + 1 RPC | 3 validators |
| U-1 / U-2 block heights | 30001 / 60001 | 30 / head+60 (≤90 block intervals) |
| Timestamp observation window | 24–168 hours | 2–10 minutes |
| StakeHub registration (U-3) | All validators must register before the first breathe block | Same requirement; script sends registration txs automatically via IPC |
| BlobScheduleConfig (U-4) | Production config file | Inline TOML minimal config |
| TurnLength init (U-5 Bohr) | Governance sets initial TurnLength via StakeHub before first epoch boundary | Script uses default TurnLength = 1; governance call not required for local drill |
| U-6 layered intervals | Prague→Lorentz +1 day, Lorentz→Maxwell +7 days | +3 minutes each |
| U-7 layered intervals | Fermi alone, Osaka+Mendel +1 day after Fermi | +3 minutes each |

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

**U-2 through U-7 — rolling genesis reinit:**
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
5. Script sends one `StakeHub.delegate(operator, delegateVotePower=true)` tx per validator
   (see **govAB voting-power note** below)
6. Observe for 3 minutes

**govAB voting-power note (two-step design):**

`createValidator()` stakes BNB into the validator's `StakeCredit` contract and calls
`GovToken.sync()` to mint the equivalent govAB tokens — but it does **not** activate
voting-power checkpoints.  `GovToken.delegateVote()` (the ERC20Votes checkpoint writer) is
`onlyStakeHub`-gated and is only reachable via `StakeHub.delegate(operatorAddress,
delegateVotePower=true)`.  Without this second call, `GovToken.getVotes(validator) == 0`
regardless of token balance, and any `BSCGovernor.propose()` call would revert with
`"Governor: proposer votes below proposal threshold"`.

The separation is intentional: it lets operators delegate their governance votes to a
separate address rather than to themselves.  The drill self-delegates by calling
`StakeHub.delegate(operator, true)` with `minDelegationBNBChange = 1 BNB`; the extra BNB
also enters the stake pool (nothing is burned).

Both steps are performed automatically by `82-run-u3-shanghai-feynman.sh`:
- Phase 5 (`createValidator`) — block-production registration
- Phase 5b (`StakeHub.delegate`) — govAB voting-power activation

**Verification:**
- Post-activation blocks include a `withdrawals` field (Shanghai EIP-4895)
- After the breathe block, `parlia_getValidators` still returns the correct 3 validators
- No `"no active validator"` errors in node logs

**Post-activation system contract verification:**

Run `script/test/transition/06-verify-contracts.sh` against the upgrade-drill nodes immediately after
U-3 completes (nodes remain running).  Both suites share the same `validator-N` datadir layout, so
pointing `DATADIR_ROOT` at the upgrade-drill data directory is sufficient:

```bash
DATADIR_ROOT=script/test/upgrade-drill/data \
  GETH=./build/bin/geth \
  bash script/test/transition/06-verify-contracts.sh
```

This covers the first focus area of the T-6 plan in
[`script/test/transition/README.md`](../transition/README.md):

- `FOUNDATION_RATIO == 1500` in `BSCValidatorSet` (15% fee share routed to `FOUNDATION_ADDR`)
- `GovToken` / `StakeHub` / `BSCGovernor` bytecode deployed at system addresses `0x2005` / `0x2002` / `0x2004`
- Submit a test transaction; confirm `FOUNDATION_ADDR` balance increases by the expected 15% fraction

**T-6.b — Whitelist election priority** (`87-run-u3-whitelist-test.sh`):

```bash
GETH=./build/bin/geth bash script/test/upgrade-drill/87-run-u3-whitelist-test.sh
```

Exercises the `StakeHub.validatorWhitelist` / `whitelistEnabled` mechanism using
`eth_call` state overrides (`stateDiff` in the third parameter), which simulate
modified storage without mutating the live chain:

- All 3 genesis validators start whitelisted; `getValidatorElectionInfo(0,10)` returns
  `WHITELIST_VOTING_POWER = uint256(type(uint64).max) × 1e10` for each
- Simulate removing a validator from the whitelist → `getValidatorElectionInfo` returns
  stake-based power for that slot
- Simulate `whitelistEnabled = false` → all validators fall back to stake-based power

Note: the full governance path (BSCGovernor → BSCTimelock → GovHub →
`StakeHub.updateParam("addToValidatorWhitelist", addr)`) requires a 7-day voting
period and 24-hour timelock; it is tested in cloud testnet scope (E-2/S-1).
The jailed-validator path (getValidatorElectionInfo returns 0 regardless of
whitelist status) requires a real slash event and is also in cloud testnet scope.

**T-6.c — `WHITELIST_VOTING_POWER` arithmetic correctness** (`87-run-u3-whitelist-test.sh`, Phase 0, runs automatically with T-6.b):

Verifies the `WHITELIST_VOTING_POWER` constant baked into the deployed StakeHub bytecode and
confirms the Parlia normalization path (`÷1e10` then cast to `uint64`) produces exactly
`type(uint64).max`:

- `WHITELIST_VP == 184467440737095516150000000000` (= `uint64_max × 1e10`, exact decimal)
- `WHITELIST_VP mod 1e10 == 0` — no truncation during Parlia normalization
- `WHITELIST_VP ÷ 1e10 == 18446744073709551615` (= `type(uint64).max`) — any stake-based
  voting power (real stake `÷ 1e10 ≤ ~10^16`) is guaranteed to fall below this value

**T-6.d — `initialize()` event-log audit** (`87-run-u3-whitelist-test.sh`, Phase 6):

Uses `eth_getLogs` against the live node to confirm that the assembly loop in
`StakeHub.initialize()` correctly decoded `INIT_WHITELIST_BYTES` and emitted one event per address:

- Exactly 3 `ValidatorWhitelistUpdated(addr, true)` events, addresses matching
  `VAL1_CONSENSUS`, `VAL2_CONSENSUS`, `VAL3_CONSENSUS` (the local drill genesis is generated
  with `abchain-local` mode, which packs all 3 validator consensus addresses into `INIT_WHITELIST_BYTES`)
- Exactly 0 `WhitelistEnabledUpdated` events — `initialize()` sets `whitelistEnabled = true`
  directly in storage without emitting the event; the event is only fired via `updateParam`
- Event count mismatch → assembly loop decoded wrong number of addresses;
  address mismatch → `INIT_WHITELIST_BYTES` encoding in the bytecode is wrong

**T-6.e — `updateParam` input validation (rejection tests)** (`87-run-u3-whitelist-test.sh`, Phase 7):

Uses `eth_call` with `from: GovHub (0x1007)` to simulate the governance call path (satisfies the
`onlyGov` modifier) without submitting a real transaction. Tests five sub-cases for the three new keys:

- `addToValidatorWhitelist` with 32-byte value (not 20 bytes) → `InvalidValue` revert
- `addToValidatorWhitelist` with zero address (20 zero bytes) → `InvalidValue` revert
- `removeFromValidatorWhitelist` with zero address → `InvalidValue` revert
- `whitelistEnabled` with flag `0x02` (exceeds 0/1 range) → `InvalidValue` revert
- `whitelistEnabled` with flag `0x01` from GovHub → success (`"result": "0x"`)

Note: the full on-chain governance path (BSCGovernor → BSCTimelock → GovHub → real `updateParam`
transaction, 7-day vote + 24-hour timelock) remains in cloud testnet scope (E-2/S-1).

**T-6.f — Whitelist vs. large-stake ordering invariant** (`87-run-u3-whitelist-test.sh`, Phase 3 extension):

Extends the existing Phase 3 `stateDiff` simulation: in addition to clearing val1's whitelist
storage slot, simultaneously overrides val1's staked-amount slot to `WHITELIST_VOTING_POWER × 2`.
Confirms that whitelisted validators always outrank non-whitelisted validators regardless of stake size:

- val2 and val3 (whitelisted) still return `WHITELIST_VOTING_POWER`
- val1 (non-whitelisted, with artificially inflated stake) returns a voting power below
  `WHITELIST_VOTING_POWER` — any real stake `÷ 1e10 ≤ ~10^16`, far below
  `type(uint64).max ≈ 1.8×10^19`

**T-6.g — `TokenRecoverPortal.SOURCE_CHAIN_ID` constant** (`87-run-u3-whitelist-test.sh`, Phase 8):

Calls `SOURCE_CHAIN_ID()` on `TokenRecoverPortal` (`0x0000000000000000000000000000000000003000`)
and ABI-decodes the returned `string`, confirming the bytecodes were produced by the
`abchain-local` command in `generate.py`:

- Expected: `"AB-Chain-Local"` (the local drill identifier injected by `generate.py abchain-local`)
- FAIL if result differs → bytecode was not generated by the `abchain-local` command

**T-6.h — Full governance path: whitelist update via BSCGovernor → BSCTimelock → GovHub** (`88-run-u3-governance-whitelist.sh`):

Exercises the complete on-chain governance path using the reduced timeouts baked into the
`abchain-local` genesis (10-block voting period × 3 s/block ≈ 30 s, 0 after-quorum extension,
3-second timelock delay = 1 block). A new address is added to the validator whitelist through a real governance
proposal that all 3 validators vote on:

1. `BSCGovernor.propose([GovHub], [0], [updateParam("addToValidatorWhitelist", newAddr, StakeHub)], description)`
2. Wait for voting period (10 blocks × 3 s ≈ 30 s)
3. `BSCGovernor.castVote(proposalId, 1)` from each of the 3 validators
4. Wait for voting period to end, confirm state == `Succeeded`
5. `BSCGovernor.queue(...)` — enqueue in BSCTimelock
6. Wait for timelock delay (3 s), confirm state == `Queued`
7. `BSCGovernor.execute(...)` — execute the queued transaction
8. `StakeHub.validatorWhitelist(newAddr) == true` — whitelist entry confirmed on-chain

Note: `propose_start_threshold = 0` and `init_voting_period = 10` are set only in the
`abchain-local` genesis configuration; production values are `10_000_000 govAB` supply
threshold and `28800 blocks` (7 days) respectively.

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

## U-5 — Bohr: variable TurnLength (timestamp activation)

Corresponds to devnet Upgrade 5 (v0.6.0). Introduces the `TurnLength` mechanism:
each validator may now produce multiple consecutive blocks per turn rather than
exactly one.  The current `TurnLength` is encoded as a single extra-data byte in
every epoch block and read by all nodes on each epoch boundary.

Key behavioural changes at Bohr:
- `TurnLength` is written into epoch-block `extra` and drives the
  `snap.TurnLength` field in Parlia snapshots.  The value is fetched from
  `ValidatorContract.getTurnLength()` each epoch (governance-controlled); before
  Bohr it falls back to `defaultTurnLength = 1`.
- `ParentBeaconRoot` changes from nil to the zero hash (`0x000…0`).
- Backoff random seed switches from `blockNumber` to `blockNumber / TurnLength`,
  keeping backoff distribution correct across longer turns.
- In-turn validator is excluded from the backoff candidate list.

**Local parameters:** `BohrTime = now + 120 s`

**Environment variables:**
- `FORK_TIME_OFFSET` — seconds from now to activation (default: 120)
- `FORK_TIME` — explicit activation timestamp (overrides `FORK_TIME_OFFSET`)
- `EPOCH_WAIT_TIMEOUT` — max seconds to wait for the first post-activation epoch block before skipping the TurnLength byte check (default: 60). Set to a higher value or use `CLIQUE_EPOCH=30` in `00-init.sh` to enable this check reliably.
- `KEEP_RUNNING=1` — leave nodes running after PASS

**Prerequisites:** none

**Steps:**
1. `07-snapshot.sh` — back up current chain state
2. Append `bohrTime` to genesis.json; rolling genesis reinit (stop → `geth init`
   → restart → sync, one node at a time); 2-of-3 quorum maintained throughout
3. Wait for activation; observe through the first epoch boundary (block % epochLength == 0)

**Verification:**
- Post-activation epoch block `extra` contains the `TurnLength` byte
- `ParentBeaconRoot` in post-activation block headers is `0x000…0` (not nil)
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
2. Append all 4 timestamps + `blobSchedule.prague` to genesis.json; rolling genesis reinit (stop →
   `geth init` → restart → sync, one node at a time); 2-of-3 quorum maintained throughout
3. Prague/Pascal activates → observe 2 minutes → Lorentz activates → observe
   2 minutes → Maxwell activates → observe 3 minutes

**Verification (per phase):**
- Prague: block headers include EIP-7685 requests field
- Lorentz: block interval remains stable with no visible jitter
- Maxwell: `parlia_getValidators` returns the correct validator set after activation

## U-7 — Fermi + Osaka + Mendel (multi-phase timestamp activation)

Corresponds to devnet Upgrade 7 (v0.8.0). Production uses layered activation:
Fermi alone at T7, Osaka+Mendel at T7 + 1 day. Local drill compresses each gap
to 3 minutes.

**Local parameters (relative to script start time):**
- `FermiTime = now + 60 s`
- `OsakaTime = MendelTime = now + 240 s` (Fermi + 3 min)

**Prerequisites:** none

**Steps:**
1. `07-snapshot.sh` — back up current chain state
2. Append all 3 timestamps to genesis.json; rolling genesis reinit (stop →
   `geth init` → restart → sync, one node at a time); 2-of-3 quorum maintained throughout
3. Fermi activates → observe 2 minutes → Osaka+Mendel activate → observe 3 minutes

**Verification (per phase):**
- Fermi: system contract upgrade fires at the activation block — confirm log line
  `Apply upgrade fermi at height <N>` appears on all 3 nodes
- Osaka: submit a `bigModExp` call with input length > 1024 bytes and confirm
  it reverts (EIP-7823); confirm `p256Verify` at `0x100` costs 6900 gas (EIP-7951)
- Mendel: submit a blob transaction and confirm it stays pending until a block
  where `blockNumber % 5 == 0`; non-eligible blocks do not include it
  (BEP-657 `BlobEligibleBlockInterval = 5`)

## Running

### One-shot (recommended)

```bash
# Runs init → U-1 → U-2 in sequence; auto-builds geth if GETH is unset.
bash script/test/upgrade-drill/99-run-all.sh

# With explicit binary and custom fork heights
GETH=./build/bin/geth PARLIA_GENESIS_BLOCK=50 bash script/test/upgrade-drill/99-run-all.sh

# Leave nodes running after PASS for manual inspection
GETH=./build/bin/geth KEEP_RUNNING=1 bash script/test/upgrade-drill/99-run-all.sh
```

### Round by round

Each U-N script leaves nodes running so the next script can pick up the live
chain head.  Use this path when adding snapshots between rounds or running
rounds in separate terminal sessions.

```bash
# Prerequisite: build the abcore-v2 binary
make geth

# Initialise 3-node network (one time)
GETH=./build/bin/geth bash script/test/upgrade-drill/00-init.sh

# Optional: snapshot before first round
bash script/test/upgrade-drill/07-snapshot.sh

# U-1: Clique→Parlia (starts the Clique network, then crosses the fork)
GETH=./build/bin/geth bash script/test/upgrade-drill/80-run-u1-parlia-switch.sh

# Optional: snapshot before U-2
bash script/test/upgrade-drill/07-snapshot.sh

# U-2: London + BSC forks (nodes still running from U-1)
GETH=./build/bin/geth bash script/test/upgrade-drill/81-run-u2-london-forks.sh

# Optional: snapshot before U-3
bash script/test/upgrade-drill/07-snapshot.sh

# U-3: Shanghai + Kepler + Feynman (nodes still running from U-2)
GETH=./build/bin/geth bash script/test/upgrade-drill/82-run-u3-shanghai-feynman.sh

# U-4: Cancun + Haber + HaberFix (nodes still running from U-3)
GETH=./build/bin/geth bash script/test/upgrade-drill/83-run-u4-cancun-haber.sh

# Optional: snapshot before U-5
bash script/test/upgrade-drill/07-snapshot.sh

# U-5: Bohr (nodes still running from U-4)
GETH=./build/bin/geth bash script/test/upgrade-drill/84-run-u5-bohr.sh

# U-6: Prague + Pascal + Lorentz + Maxwell (nodes still running from U-5)
GETH=./build/bin/geth bash script/test/upgrade-drill/85-run-u6-prague-maxwell.sh

# U-7: Fermi + Osaka + Mendel (nodes still running from U-6)
GETH=./build/bin/geth bash script/test/upgrade-drill/86-run-u7-fermi-osaka-mendel.sh
```

### Cleanup and rollback

```bash
# Wipe everything and start over
bash script/test/upgrade-drill/clean.sh

# Restore from a snapshot taken between rounds
SNAPSHOT=script/test/upgrade-drill/snapshots/snapshot-<timestamp>.tar.gz \
  bash script/test/upgrade-drill/08-restore.sh
# then re-run the round that follows the snapshot point
```
