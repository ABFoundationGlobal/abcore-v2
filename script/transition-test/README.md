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
| `93-run-clique-epoch-fork-test.sh` | Clique epoch boundary coincides with fork block (`CLIQUE_EPOCH == PARLIA_GENESIS_BLOCK`) |
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
| — | Fork block coincides with Clique epoch boundary | `93-run-clique-epoch-fork-test.sh` | ✅ |

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

### Clique epoch boundary coincides with fork block

- `CLIQUE_EPOCH == PARLIA_GENESIS_BLOCK == N`: fork fires exactly on a Clique epoch checkpoint
- The epoch block carries a full signer list in `extraData`; Parlia snapshot seeding must treat this block as both an epoch checkpoint and the fork origin
- Covers the code path excluded by T-2's `PARLIA_GENESIS_BLOCK >= EPOCH_LENGTH` guard
- 7 assertions: block existence, extraData length, non-zero miner, `parlia_getValidators` count, block `PGB+1` existence (chain did not stall at epoch/fork boundary), first Parlia epoch boundary, 3-node hash agreement

### Address consistency requirement (T-2)

At `ParliaGenesisBlock`, `initContract()` calls `BSCValidatorSet.init()` which reads
`INIT_VALIDATORSET_BYTES` from the compiled bytecode and writes those addresses into contract
storage. At each epoch boundary, `getValidators()` returns those addresses. If they differ from
the actual sealing node addresses, the chain halts at `epoch+1`.

T-2 uses fixed dev keystores from `core/systemcontracts/parliagenesis/default/keystores/`,
which match the addresses baked into `parliagenesis/default/ValidatorContract`. See
`core/systemcontracts/parliagenesis/default/README.md` for details.

## Remaining gaps

| Gap | Status |
|---|---|
| Parlia epoch boundary | Covered by T-2 (`95-run-epoch-test.sh`) |
| Fork block coincides with Clique epoch boundary | Covered by `93-run-clique-epoch-fork-test.sh` |
| Transaction submission across fork boundary | Planned (T-3, `94-run-tx-test.sh`) |
| Single-node rolling restart while chain is in Parlia | Planned |
| AB-chain system contract parameter verification after fork | Planned |
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

# Clique-epoch-fork: fork block == Clique epoch boundary (EPOCH_LENGTH=20, PGB=20)
GETH=./build/bin/geth bash script/transition-test/93-run-clique-epoch-fork-test.sh

# Clique-epoch-fork: custom epoch length
GETH=./build/bin/geth EPOCH_LENGTH=30 bash script/transition-test/93-run-clique-epoch-fork-test.sh

# T-1 + T-2 combined (adds ~3 minutes)
RUN_EPOCH_TEST=1 GETH=./build/bin/geth bash script/transition-test/99-run-all.sh

# T-1 + Clique-epoch-fork combined
RUN_CLIQUE_EPOCH_FORK_TEST=1 GETH=./build/bin/geth bash script/transition-test/99-run-all.sh

# Leave nodes running for manual inspection after PASS
KEEP_RUNNING=1 GETH=./build/bin/geth bash script/transition-test/95-run-epoch-test.sh
KEEP_RUNNING=1 GETH=./build/bin/geth bash script/transition-test/99-run-all.sh

# Leave the rolled-back Clique network running after the drill
KEEP_RUNNING=1 GETH=./build/bin/geth bash script/transition-test/96-run-rollback-drill.sh
```
