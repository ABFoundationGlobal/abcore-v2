# transition-test — Clique→Parlia transition and rollback drill suite

End-to-end scenarios for the ABCore Clique→Parlia migration, including the
baseline fork path, late restart handling, coordinated rollback drill, and
Parlia epoch boundary validator set transitions.

## Scripts

| Script | Purpose |
|---|---|
| `99-run-all.sh` | T-1: 3-validator network, all-stop-restart fork transition |
| `98-run-vote-change.sh` | T-1 variant: pre-fork `clique_propose` vote-in of a 4th validator |
| `97-run-late-restart.sh` | T-1.5: late-restart (chain already past fork block when node starts) |
| `96-run-rollback-drill.sh` | T-1.6: coordinated rollback (Parlia→Clique rewind via debug.setHead) |
| `95-run-epoch-test.sh` | T-2: Parlia epoch boundary; validator set transition at first and second epoch |
| `94-run-tx-test.sh` | T-3: user transaction submitted pre-fork, mined in first post-fork Parlia blocks |
| `93-run-clique-epoch-fork-test.sh` | Clique epoch boundary coincides with fork block (`CLIQUE_EPOCH == PARLIA_GENESIS_BLOCK`) |
| `06-verify-contracts.sh` | T-6: AB-chain system contract parameter and fee-routing assertions (runs on live nodes; called by 05-verify.sh) |
| `01-setup.sh` | Generate accounts + Clique genesis + init datadirs |
| `02-start.sh` | Start validators (Clique or DualConsensus via TOML config) |
| `03-stop.sh` | Gracefully stop all running validators |
| `04-clean.sh` | Stop + wipe datadirs |
| `05-verify.sh` | Post-fork verification checks (called by 99/98) |

## Scenario coverage

| ID | Scenario | Script | Status |
|---|---|---|---|
| T-1 | All-stop-restart fork transition | `99-run-all.sh` | ✅ |
| T-1 variant | Pre-fork clique_propose vote-change | `98-run-vote-change.sh` | ✅ |
| T-1.5 | Late restart (chain already past fork) | `97-run-late-restart.sh` | ✅ |
| T-1.6 | Coordinated rollback drill (Parlia→Clique) | `96-run-rollback-drill.sh` | ✅ |
| T-2 | Parlia epoch boundary validator set transition | `95-run-epoch-test.sh` | ✅ |
| T-3 | User transaction crossing the fork boundary | `94-run-tx-test.sh` | ✅ |
| T-4 | Fork block coincides with Clique epoch boundary | `93-run-clique-epoch-fork-test.sh` | ✅ |
| T-5 | Single-node rolling restart while chain is in Parlia | planned | 🔲 |
| T-6 | AB-chain system contract parameter + fee routing | `06-verify-contracts.sh` | ✅ (T-6.a) |
| T-6.b | Feynman-initialized contract parameters | — | 📋 Planned |
| T-6.c | `updateParam` governance bounds testing | — | 📋 Planned |

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

### T-6 — AB-chain system contract parameter and logic verification after fork

`06-verify-contracts.sh` is the first implementation of T-6.
It verifies ABcore-specific values compiled into the `default/` bytecodes (built with
`abchain-local` via `make build`) and confirms that fee-routing logic routes 15 % of
transaction fees to `FOUNDATION_ADDR` with zero burn and zero system-reward distribution.

Expected values are loaded at runtime from `parliagenesis/default/params.env`, which is
generated by `make build` from `generate.py` `abchain_local` defaults and committed
alongside the bytecodes.

#### T-6.a — implemented (`06-verify-contracts.sh`)

Assertions via `eth_call` on `BSCValidatorSet` (0x1000), deployment checks, and post-tx balance verification:

| Contract | What is checked | Expected |
|---|---|---|
| BSCValidatorSet | `INIT_NUM_OF_CABINETS()` constant | `9` (`abchain_local` default; loaded from `params.env`) |
| BSCValidatorSet | `FOUNDATION_RATIO()` constant | `1500` (15 %; Solidity constant) |
| BSCValidatorSet | `burnRatio()` | `0` (loaded from `params.env`) |
| BSCValidatorSet | `systemRewardBaseRatio()` | `0` (loaded from `params.env`) |
| BSCValidatorSet | `systemRewardAntiMEVRatio()` | `0` (unset storage default) |
| GovToken (0x2005) | bytecode deployed | code length > 10 bytes |
| StakeHub (0x2002) | bytecode deployed | code length > 10 bytes |
| BSCGovernor (0x2004) | bytecode deployed | code length > 10 bytes |
| `FOUNDATION_ADDR` (from `params.env`) | balance after test tx | increases (15 % fee routed) |

Note: `FOUNDATION_ADDR` is `address public constant` in `System.sol` (inherited by BSCValidatorSet); the inherited getter is not reachable through BSCValidatorSet's ABI dispatch table in the compiled bytecode, so fee routing is verified via balance check. The address is `abchain_local`'s `foundation_addr` default (`0x…dEaD`), sourced from `params.env`.

#### T-6.b — planned: Feynman-initialized contract parameters

The following parameters are storage variables written by `initialize()` inside
`initializeFeynmanContract()`, which only fires when the Feynman fork is active.
The default transition-test genesis (`01-setup.sh`) does not set `feynmanTime` or
`londonBlock`, so `initializeFeynmanContract()` is never called and these values
remain zero.

**Implementation steps:**
1. Add `"londonBlock": 0` and `"feynmanTime": <N>` to the genesis config written
   by `01-setup.sh`, where N is a Unix timestamp guaranteed to be reached at or
   after `ParliaGenesisBlock` (e.g. `PARLIA_GENESIS_BLOCK` seconds after the
   genesis timestamp).
2. Verify that `TryUpdateBuildInSystemContract` does not overwrite the AB-chain
   bytecodes via `feynmanUpgrade[defaultNet]` (confirm that entry is nil or a
   no-op for the default network).
3. Add assertions in the script for:

| Contract | Method | Expected value |
|---|---|---|
| GovToken (0x2005) | `name()` | `"AB Governance Token"` |
| GovToken (0x2005) | `symbol()` | `"govAB"` |
| StakeHub (0x2002) | `minSelfDelegationBNB()` | `2_000_000_000 ether` |
| StakeHub (0x2002) | `minDelegationBNBChange()` | `100_000_000 ether` |
| BSCGovernor (0x2004) | `proposalThreshold()` | `2_000_000_000 ether` |
| BSCGovernor (0x2004) | `quorumNumerator()` | `50` |

#### T-6.c — planned: `updateParam` governance bounds testing

`updateParam` calls on StakeHub and BSCGovernor must be submitted through the
GovHub system-call path (caller must be `GovHub`), which requires a governance
test harness not yet available in this suite.

**Implementation steps:**
1. Build a helper that crafts and submits `updateParam` as a system transaction
   (from `SystemAddress` to `GovHub`, which forwards to the target contract).
2. For StakeHub: submit at `min_self_delegation_max = 10_000_000_000 ether`
   (accept) and at `10_000_000_000 ether + 1` (expect revert).
3. For BSCGovernor: submit at `proposal_threshold_max = 10_000_000_000 ether`
   (accept) and beyond (expect revert).

## Remaining gaps

| Gap | Status |
|---|---|
| Parlia epoch boundary | Covered by T-2 (`95-run-epoch-test.sh`) |
| Transaction submission across fork boundary | Covered by T-3 (`94-run-tx-test.sh`) |
| Fork block coincides with Clique epoch boundary | Covered by T-4 (`93-run-clique-epoch-fork-test.sh`) |
| Single-node rolling restart in Parlia mode | Planned as T-5 |
| AB-chain system contract constants + fee routing (T-6.a) | Covered by `06-verify-contracts.sh` |
| Feynman-initialized contract parameters (T-6.b) | Planned — see T-6.b section above |
| `updateParam` governance bounds testing (T-6.c) | Planned — see T-6.c section above |
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
