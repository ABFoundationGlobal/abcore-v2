# transition-test — Clique→Parlia transition and rollback drill suite

End-to-end scenarios for the ABCore Clique→Parlia migration, including the
baseline fork path, late restart handling, coordinated rollback drill, and
Parlia epoch boundary validator set transitions.

## Scenario coverage

| ID | Script                             | Description | Status |
|---|------------------------------------|---|---|
| T-1 | `99-run-all.sh`                    | All-stop-restart fork transition (3-validator network) | ✅ |
| T-1 variant | `98-run-vote-change.sh`            | Pre-fork `clique_propose` vote-in of a 4th validator | ✅ |
| T-1.5 | `97-run-late-restart.sh`           | Late-restart (chain already past fork block when node starts) | ✅ |
| T-1.6 | `96-run-rollback-drill.sh`         | Coordinated rollback (Parlia→Clique rewind via debug.setHead) | ✅ |
| T-2 | `95-run-epoch-test.sh`             | Parlia epoch boundary; validator set transition at first and second epoch | ✅ |
| T-3 | `94-run-tx-test.sh`                | User transaction submitted pre-fork, mined in first post-fork Parlia blocks | ✅ |
| T-4 | `93-run-clique-epoch-fork-test.sh` | Fork block coincides with Clique epoch boundary (`CLIQUE_EPOCH == PARLIA_GENESIS_BLOCK`) | ✅ |
| T-5 | planned                            | Single-node rolling restart while chain is in Parlia | 🔲 |
| T-6 | planned                            | Transaction-based logic verification of AB-chain system contract modifications: `FOUNDATION_ADDR` fee routing ratio, validator whitelist election priority (`StakeHub`), and governance `updateParam` boundary enforcement — requires sending transactions via the GovHub system-call path | 🔲 |

### Helper scripts

| Script | Purpose |
|---|---|
| `01-setup.sh` | Generate accounts + Clique genesis + init datadirs |
| `02-start.sh` | Start validators (Clique or DualConsensus via TOML config) |
| `03-stop.sh` | Gracefully stop all running validators |
| `04-clean.sh` | Stop + wipe datadirs |
| `05-verify.sh` | Post-fork verification checks (called by `99-run-all.sh` and `98-run-vote-change.sh`) |
| `06-verify-contracts.sh` | Static data validation for AB-chain system contract modifications: reads constants and storage values via `eth_call` (no transaction sent); called by `05-verify.sh`, can also run standalone on live nodes |

### T-1 — Baseline fork transition

- Parlia snapshot seeded from last Clique epoch checkpoint (not genesis)
- Pre-fork Clique-sealed headers skipped in Parlia's `snapshot.apply()`
- Fork block encodes validators even when not on a Parlia epoch boundary
- ValidatorSet system contract deployed at `ParliaGenesisBlock`, absent before
- `parlia_getValidators` returns the correct Clique signer set at the fork block
- All 3 nodes agree on the same chain hash after the fork
- Post-fork blocks have non-zero `miner` field (proves Parlia, not Clique, is sealing)
- Pre-fork `clique_propose` vote-in: 4th validator appears in post-fork Parlia set

### T-1.5 — Late restart after the fork

- One validator stops while the network is still in Clique mode
- The remaining validators cross `ParliaGenesisBlock` and continue in Parlia
- The stopped validator restarts with only pre-fork Clique history in its DB
- DualConsensus walks the missing Clique range, crosses the fork, reseeds from the checkpoint, and catches up

### T-1.6 — Coordinated rollback drill

- The network first follows the proven T-1 path and crosses into Parlia
- Operators stop all validators and restart them in maintenance mode with the same PGB config
- Each node performs `debug.setHead(N-1)` to rewind the local canonical head to the last Clique block
- Validators restart without the Parlia override and resume sealing pure Clique blocks from block `N`
- The rollback verifies that block `N-1` is preserved, block `N` is replaced, the Clique validator set is restored, and the `ValidatorSet` system contract is absent on the rolled-back chain

### T-2 — Parlia epoch boundary validator set transition

- Chain crosses first Parlia epoch boundary (`block % epochLength == 0`)
- `prepareValidators()` calls `BSCValidatorSet.getValidators()` at epoch boundary
- Validator set from contract storage encodes correctly into `header.Extra`
- Snapshot switches signer set at `epoch+1`; chain continues without `errUnauthorizedValidator`
- Chain crosses second epoch boundary; all 3 nodes remain in consensus
- `parlia_getValidators` at epoch boundary returns the correct 3 validators

### Address consistency requirement (T-2)

At `ParliaGenesisBlock`, `initContract()` calls `BSCValidatorSet.init()` which reads
`INIT_VALIDATORSET_BYTES` from the compiled bytecode and writes those addresses into contract
storage. At each epoch boundary, `getValidators()` returns those addresses. If they differ from
the actual sealing node addresses, the chain halts at `epoch+1`.

T-2 uses fixed dev keystores from `core/systemcontracts/parliagenesis/default/keystores/`,
which match the addresses baked into `parliagenesis/default/ValidatorContract`. See
`core/systemcontracts/parliagenesis/default/README.md` for details.

### T-3 — User transaction crossing the fork boundary

- All validators stop at `PRE_STOP` (`PARLIA_GENESIS_BLOCK − 5`); the effective fork
  block is set to `frozen_head + 1` at runtime, so the chain is stalled exactly one
  block before the fork regardless of the input `PARLIA_GENESIS_BLOCK`
- Val-1 restarts in sync-only mode (no `--mine`, no live peers) so no block can
  be produced
- A user transaction is submitted via val-1's IPC endpoint; it enters the txpool
  but cannot be mined while the chain is stalled
- Val-1 is stopped gracefully (SIGTERM); geth flushes the txpool journal to
  `<datadir>/geth/transactions.rlp`
- All 3 validators restart with `OverrideParliaGenesisBlock`; val-1 reloads the
  journal on startup and re-broadcasts the pending transaction to peers
- The chain crosses `ParliaGenesisBlock` and enters Parlia mode; the transaction
  is included in one of the first post-fork Parlia blocks
- Verifies: `receipt.blockNumber >= ParliaGenesisBlock`, `receipt.status == 0x1`,
  and the recipient balance increased by the transferred amount
- Confirms that `IsSystemTransaction()` does not incorrectly filter out a regular
  user transaction in `FinalizeAndAssemble`

### T-4 — Fork block coincides with Clique epoch boundary

- `CLIQUE_EPOCH` and `PARLIA_GENESIS_BLOCK` are set to the same value (e.g. 20)
  so the fork fires exactly on a Clique epoch block
- The epoch block carries a full Clique signer list in `extraData`; the Parlia
  snapshot seeding path must treat this block as both an epoch checkpoint and
  the fork origin
- Verifies: `parlia_getValidators` at the fork/epoch block returns the correct
  signer set, the chain continues without `errUnauthorizedValidator`, and the
  validator set encodes correctly into the first post-fork epoch block
- Covers the code path excluded by T-2's `die` guard
  (`PARLIA_GENESIS_BLOCK >= EPOCH_LENGTH`)

### T-5 — Single-node rolling restart while chain is in Parlia

- All 3 validators run normally in Parlia mode; chain advances well past the fork
- Val-2 is stopped while val-1 and val-3 continue sealing; the 2-of-3 quorum is
  maintained
- Val-1 and val-3 produce 10 or more Parlia blocks while val-2 is offline
- Val-2 restarts with the same TOML config; it syncs the missed Parlia blocks
  from peers and resumes participation
- Verifies: val-2 catches up to the canonical tip within the timeout, all 3
  nodes agree on the same hash, and val-2's miner address appears in the sealer
  rotation within a few blocks of the catch-up

### T-6 — AB-chain system contract on-chain behavior (planned)

Covers AB-chain-specific contract changes (introduced in `abcore-v2-genesis-contract`)
that can only be exercised via live transaction submission against running nodes. Three
focus areas, all requiring the GovHub system-call path (sender `SystemAddress` →
`GovHub` → target contract), which is not yet implemented in this suite.

**Fee routing to `FOUNDATION_ADDR`** (`BSCValidatorSet` / `System.sol`):
- `FOUNDATION_RATIO = 1500` (15 %) routes a fixed share of every block's fees to
  `FOUNDATION_ADDR`; `burnRatio` and `systemRewardBaseRatio` are both 0
- Submit user transactions and verify `FOUNDATION_ADDR` balance increases by the
  expected fraction; confirm no tokens reach the burn address or `SystemReward`

**Validator whitelist election priority** (`StakeHub`):
- `WHITELIST_VOTING_POWER = type(uint64).max × 1e10` guarantees whitelisted
  validators always outrank stake-based validators in Parlia election
- Call `addToValidatorWhitelist` / `removeFromValidatorWhitelist` via GovHub and
  verify `getValidatorElectionInfo()` returns `WHITELIST_VOTING_POWER` for listed
  validators; confirm jailed validators get 0 regardless of whitelist membership
- Toggle `whitelistEnabled` and confirm the election order changes accordingly

**Governance `updateParam` boundary enforcement** (`StakeHub`, `BSCGovernor`):
- AB-chain raises upper bounds for stake and governance thresholds (e.g.
  `minSelfDelegationBNB` max = `10_000_000_000 AB`,
  `proposalThreshold` max = `10_000_000_000 govAB`)
- Submit `updateParam` at the boundary value (expect accept) and one unit beyond
  (expect revert) for each tunable parameter

## Remaining gaps

| Gap | Status |
|---|---|
| Parlia epoch boundary | Covered by T-2 (`95-run-epoch-test.sh`) |
| Transaction submission across fork boundary | Covered by T-3 (`94-run-tx-test.sh`) |
| Fork block coincides with Clique epoch boundary | Covered by T-4 (`93-run-clique-epoch-fork-test.sh`) |
| Single-node rolling restart in Parlia mode | Planned as T-5 |
| AB-chain system contract on-chain behavior (T-6) | Planned — see T-6 section above |
| StakeHub validator registration (production mainnet, Luban+ path) | E-2/S-1 cloud testnet scope |

## Running

```bash
# T-1: default fork transition (PARLIA_GENESIS_BLOCK=20)
GETH=./build/bin/geth bash script/transition-test/99-run-all.sh

# T-1: non-genesis checkpoint (fork not on genesis epoch)
GETH=./build/bin/geth CLIQUE_EPOCH=10 PARLIA_GENESIS_BLOCK=25 \
  bash script/transition-test/99-run-all.sh

# T-1 vote-change variant
GETH=./build/bin/geth bash script/transition-test/98-run-vote-change.sh

# T-1.5: late restart
GETH=./build/bin/geth bash script/transition-test/97-run-late-restart.sh

# T-1.6: rollback drill
GETH=./build/bin/geth bash script/transition-test/96-run-rollback-drill.sh

# T-2: Parlia epoch boundary (~3 minutes)
GETH=./build/bin/geth bash script/transition-test/95-run-epoch-test.sh

# T-2: custom epoch length
GETH=./build/bin/geth EPOCH_LENGTH=100 bash script/transition-test/95-run-epoch-test.sh

# T-4 (Clique-epoch-fork): fork block == Clique epoch boundary (EPOCH_LENGTH=20, PGB=20)
GETH=./build/bin/geth bash script/transition-test/93-run-clique-epoch-fork-test.sh

# T-4: custom epoch length
GETH=./build/bin/geth EPOCH_LENGTH=30 bash script/transition-test/93-run-clique-epoch-fork-test.sh

# T-1 + T-3 (always included) + T-2 (opt-in, adds ~3 minutes)
RUN_EPOCH_TEST=1 GETH=./build/bin/geth bash script/transition-test/99-run-all.sh

# T-1 + Clique-epoch-fork combined
RUN_CLIQUE_EPOCH_FORK_TEST=1 GETH=./build/bin/geth bash script/transition-test/99-run-all.sh

# Leave nodes running for manual inspection after PASS
KEEP_RUNNING=1 GETH=./build/bin/geth bash script/transition-test/95-run-epoch-test.sh
KEEP_RUNNING=1 GETH=./build/bin/geth bash script/transition-test/99-run-all.sh

# Leave the rolled-back Clique network running after the drill
KEEP_RUNNING=1 GETH=./build/bin/geth bash script/transition-test/96-run-rollback-drill.sh

# T-3: user transaction crossing the fork boundary
GETH=./build/bin/geth bash script/transition-test/94-run-tx-test.sh

# T-3: run Clique chain to block ~25 before stopping (PRE_STOP = PARLIA_GENESIS_BLOCK − 5 = 25).
# The effective fork block is frozen_head+1 ≈ 26; PARLIA_GENESIS_BLOCK controls the
# pre-stop target, not the exact fork height.
GETH=./build/bin/geth PARLIA_GENESIS_BLOCK=30 bash script/transition-test/94-run-tx-test.sh

# T-6 assertions run automatically as part of T-1 and T-2; no extra flag needed.
# To run T-6 assertions standalone on already-live nodes:
GETH=./build/bin/geth bash script/transition-test/06-verify-contracts.sh
```
