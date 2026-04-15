# transition-test — Clique→Parlia transition and rollback drill suite

End-to-end scenarios for the ABCore Clique→Parlia migration, including the
baseline fork path, late restart handling, and a coordinated rollback drill
back to pure Clique.

## Scripts

| Script | Purpose |
|---|---|
| `96-run-rollback-drill.sh` | T-1.6: cross the fork, rewind to `N-1`, restart in pure Clique |
| `97-run-late-restart.sh` | T-1.5: one validator restarts only after the chain is already past the fork |
| `99-run-all.sh` | Default scenario: 3-validator network, all-stop-restart |
| `98-run-vote-change.sh` | Pre-fork `clique_propose` vote-in of a 4th validator |
| `01-setup.sh` | Generate accounts + Clique genesis + init datadirs |
| `02-start.sh` | Start validators (Clique or DualConsensus via TOML config) |
| `03-stop.sh` | Gracefully stop all running validators |
| `04-clean.sh` | Stop + wipe datadirs |
| `05-verify.sh` | Post-fork verification checks (called by 99/98) |

## Scenario coverage

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

## Remaining gaps

| Gap | Why not in T-1 | Future test |
|---|---|---|
| **Rolling restart** (upgrade validators one-by-one) | T-1 all-stop-restart is sufficient to test snapshot logic; mixed-version handshake is covered by `compat-clique-v1-v2/` | T-2: mixed-version network crossing fork |
| **Parlia epoch boundary** (block 200) | Test ends at fork+5, well before `defaultEpochLength=200`; `getCurrentValidators()` system contract call never exercised | Long-running test or separate epoch boundary unit test |
| **StakeHub validator registration** | Validators must call `StakeHub.createValidator()` before the first Parlia epoch boundary or they lose block production rights at that epoch. T-1 ends at fork+5 and never reaches block 200. | T-2: run chain past block 200, verify epoch transition with registered vs unregistered validators |
| **Transaction submission** after fork | Slash/reward paths not exercised | Integration test with actual txs post-fork |

## Terminology

- T-1: baseline end-to-end Clique→Parlia fork correctness
- T-1.5: late-restart recovery after the network is already in Parlia
- T-1.6: coordinated rollback rehearsal from Parlia back to Clique
- T-2: mixed-version network crossing `ParliaGenesisBlock`

## Running

```bash
# Default (PARLIA_GENESIS_BLOCK=20, CLIQUE_EPOCH=30000)
GETH=./build/bin/geth bash script/transition-test/99-run-all.sh

# Late-restart scenario
GETH=./build/bin/geth bash script/transition-test/97-run-late-restart.sh

# Coordinated rollback drill
GETH=./build/bin/geth bash script/transition-test/96-run-rollback-drill.sh

# Non-genesis checkpoint (fork not on genesis epoch)
GETH=./build/bin/geth CLIQUE_EPOCH=10 PARLIA_GENESIS_BLOCK=25 \
  bash script/transition-test/99-run-all.sh

# Pre-fork vote-change scenario
GETH=./build/bin/geth bash script/transition-test/98-run-vote-change.sh

# Leave nodes running for manual inspection after PASS
KEEP_RUNNING=1 GETH=./build/bin/geth bash script/transition-test/99-run-all.sh

# Leave the rolled-back Clique network running after the drill
KEEP_RUNNING=1 GETH=./build/bin/geth bash script/transition-test/96-run-rollback-drill.sh
```
