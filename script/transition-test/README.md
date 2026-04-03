# transition-test — Clique→Parlia fork transition test suite (T-1)

End-to-end tests proving the Clique→Parlia transition works correctly at a
configurable `ParliaGenesisBlock`.

## Scripts

| Script | Purpose |
|---|---|
| `99-run-all.sh` | Default scenario: 3-validator network, all-stop-restart |
| `98-run-vote-change.sh` | Pre-fork `clique_propose` vote-in of a 4th validator |
| `01-setup.sh` | Generate accounts + Clique genesis + init datadirs |
| `02-start.sh` | Start validators (Clique or DualConsensus via TOML config) |
| `03-stop.sh` | Gracefully stop all running validators |
| `04-clean.sh` | Stop + wipe datadirs |
| `05-verify.sh` | Post-fork verification checks (called by 99/98) |

## What T-1 covers

- Parlia snapshot seeded from last Clique epoch checkpoint (not genesis)
- Pre-fork Clique-sealed headers skipped in Parlia's `snapshot.apply()`
- Fork block encodes validators even when not on a Parlia epoch boundary
- ValidatorSet system contract deployed at `ParliaGenesisBlock`, absent before
- `parlia_getValidators` returns the correct Clique signer set at the fork block
- All 3 nodes agree on the same chain hash after the fork
- Post-fork blocks have non-zero `miner` field (proves Parlia, not Clique, is sealing)
- Pre-fork `clique_propose` vote-in: 4th validator appears in post-fork Parlia set

## Known gaps (T-2 scope)

| Gap | Why not in T-1 | Future test |
|---|---|---|
| **Rolling restart** (upgrade validators one-by-one) | T-1 all-stop-restart is sufficient to test snapshot logic; mixed-version handshake is covered by `compat-clique-v1-v2/` | T-2: mixed-version network crossing fork |
| **Parlia epoch boundary** (block 200) | Test ends at fork+5, well before `defaultEpochLength=200`; `getCurrentValidators()` system contract call never exercised | Long-running test or separate epoch boundary unit test |
| **StakeHub validator registration** | Validators must call `StakeHub.createValidator()` before the first Parlia epoch boundary or they lose block production rights at that epoch. T-1 ends at fork+5 and never reaches block 200. | T-2: run chain past block 200, verify epoch transition with registered vs unregistered validators |
| **Transaction submission** after fork | Slash/reward paths not exercised | Integration test with actual txs post-fork |

## T-1 / T-2 terminology

Defined in `.claude/task-plan.md` (local session context, git-ignored). T-1 = end-to-end
fork transition correctness. T-2 = mixed-version (v1 Clique + v2 DualConsensus) network
crossing `ParliaGenesisBlock`.

## Running

```bash
# Default (PARLIA_GENESIS_BLOCK=30, CLIQUE_EPOCH=30000)
GETH=./build/bin/geth bash script/transition-test/99-run-all.sh

# Non-genesis checkpoint (fork not on genesis epoch)
GETH=./build/bin/geth CLIQUE_EPOCH=10 PARLIA_GENESIS_BLOCK=25 \
  bash script/transition-test/99-run-all.sh

# Pre-fork vote-change scenario
GETH=./build/bin/geth bash script/transition-test/98-run-vote-change.sh

# Leave nodes running for manual inspection after PASS
KEEP_RUNNING=1 GETH=./build/bin/geth bash script/transition-test/99-run-all.sh
```
