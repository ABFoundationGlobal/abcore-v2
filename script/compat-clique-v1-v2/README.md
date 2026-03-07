# Mixed-Version Clique Compatibility (v1.13.x ↔ v2)

This folder contains scripts to:
1) Start a local Clique PoA network with **3 v1.13.x validator binaries**.
2) Test compatibility scenarios for the **abcore-v2** binary.

## Prerequisites

- Build v2 binary from repo root: `make geth` (produces `./build/bin/geth`)
- v1 binary: downloaded automatically on first run via `00-get-v1-geth.sh` (requires `gh` CLI
  authenticated to GitHub). Saved to `script/compat-clique-v1-v2/bin/geth-v1` and reused on
  subsequent runs. Override with `ABCORE_V1_GETH=/path/to/geth` if you have it locally.
- `python3` in PATH (used by `01-setup.sh` to generate `genesis.json` and by `35-scn6-tx-propagation.sh` to parse HTTP responses)
- `curl` in PATH (used by `35-scn6-tx-propagation.sh` to submit transactions via the RPC HTTP endpoint)

## Configure binaries

By default no configuration is needed. Scripts resolve binaries in this order:

1. `ABCORE_V1_GETH` env var (if set)
2. `script/compat-clique-v1-v2/bin/geth-v1` (auto-downloaded from the GitHub release on first run)

For v2: `ABCORE_V2_GETH` env var, or `./build/bin/geth` (the result of `make geth`).

They will fail fast if the binaries cannot be resolved.

## Run

From repo root:

```bash
script/compat-clique-v1-v2/99-run-all.sh
```

This will:
- clean any prior state (`data-*/`, `genesis.json`)
- generate a fresh Clique `genesis.json` (chain ID 7141, 3-second blocks)
- start 3 v1 validators
- run the 7 scenarios in sequence, then stop all nodes

## Scenarios

**Scenario 1** (`10-scn1-upgrade-validator.sh`): Stop one v1 validator and restart it with the v2
binary using the same datadir. Verify it syncs to the canonical head and seals at least one block
alongside the remaining v1 validators. Tests in-place binary upgrade compatibility.

**Scenario 2** (`20-scn2-add-v2-rpc-node.sh`): Start a new v2 node without mining, peer it to
the v1 network, and verify it syncs to the current head with matching block hashes. Tests v2 as
an archive/RPC node in a predominantly v1 network.

**Scenario 3** (`30-scn3-add-v2-validator-vote.sh`): Full Clique governance round-trip across
versions. Phase 1: create a new v2 validator account, vote it into the signer set via
`clique.propose` from two existing validators, restart it with mining enabled, and verify it
seals blocks while all nodes agree on the canonical chain. Phase 2: vote it back out via
`clique.propose(addr, false)` from three of the four current signers (two v1, one v2 — the
exact mix depends on `UPGRADE_VALIDATOR_N`), confirm it disappears from `clique.getSigners()`
on both a v1 and a v2 node independently, then verify the three-signer network continues
producing blocks. Tests the full validator join/leave governance cycle across mixed v1/v2
networks.

**Scenario 4** (`40-scn4-all-validators-v2.sh`): Upgrade the remaining v1 validators (those not
upgraded in Scenario&nbsp;1, as determined by `UPGRADE_VALIDATOR_N`) to v2 in a coordinated step.
Verify the fully-v2 3-validator network continues producing blocks and all validators converge on
the same head. Tests the end-state of a complete rolling upgrade where no v1 nodes remain.
(validator-4 was voted out in Scenario 3 and is not part of this network.)

**Scenario 5** (`50-scn5-reorg-resilience.sh`): Isolate validator-1 from validators 2 and 3 via
`admin.removePeer`, let the majority fork (2-of-3 signers) advance 4 blocks, then reconnect and
verify validator-1 reorgs to the canonical chain by asserting matching block hashes at the
fork-point height. Confirms that Clique's highest-difficulty fork selection works identically on
v2 nodes — a critical property for safe rolling upgrades.

**Scenario 6** (`35-scn6-tx-propagation.sh`): Transaction propagation parity across the v1/v2
boundary. Runs after Scenario 3, while the network is still mixed (one v2 validator, two v1
validators, and the v2 RPC node from Scenario 2). Part 1: sign a transfer on the v2 validator's
IPC and submit the raw transaction via the v2 RPC node's HTTP endpoint (`eth_sendRawTransaction`);
wait for the receipt to appear on a v1 validator node (confirming the tx was gossiped across the
version boundary and accepted by v1 as part of the canonical chain — Clique is round-robin so
the assertion is receipt visibility on v1, not that v1 specifically sealed the block). Part 2:
submit a transfer directly from a v1 validator's IPC and wait for the receipt to appear on the
v2 validator's IPC. Exercises the full transaction-gossip path in both directions across the
version boundary — the most likely place for a silent incompatibility to manifest during a
partial rollout.

**Scenario 7** (`60-scn7-rollback-v1-sync.sh`): v1 syncing from a v2-majority network. Runs
after Scenario 5, when all three validators are v2 and the network is live. Stops the validator
that was first upgraded in Scenario 1 (controlled by `UPGRADE_VALIDATOR_N`), lets the remaining
two v2 validators advance 3 blocks, then restarts the stopped node using the v1 binary against
the same datadir. Re-peers it to the two v2 validators and asserts: (a) it syncs to the canonical
chain and agrees on the block hash at the pre-shutdown height, (b) all three validators converge
on the same head, and (c) the reverted v1 node resumes sealing blocks — confirming that Clique
governance continues across the version rollback and the v2-produced chain is accepted as
canonical by v1. Tests rollback capability: whether an operator can safely revert a single node
from v2 back to v1 if an issue is found post-upgrade.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `ABCORE_V1_GETH` | `script/compat-clique-v1-v2/bin/geth-v1` (auto-downloaded) | Path to v1.13.x binary |
| `ABCORE_V2_GETH` | `./build/bin/geth` | Path to v2 binary |
| `KEEP_RUNNING` | `0` | Set to `1` to leave nodes running after pass |
| `UPGRADE_VALIDATOR_N` | `2` | Which validator to upgrade in scenario 1 (1–3) |
| `CLIQUE_CHAIN_ID` | `7141` | Chain ID for the test network |
| `CLIQUE_PERIOD` | `3` | Block period in seconds |
| `PORT_BASE` | auto-selected | Offset added to all port numbers. Auto-selected by `99-run-all.sh` using the first free 100-unit slot, so multiple users can run the suite concurrently on the same host without port conflicts. Override with e.g. `PORT_BASE=200` to pin a specific offset. |
| `DATADIR_ROOT` | `script/compat-clique-v1-v2/data-<PORT_BASE>` | Root directory for all node data. Defaults to `data-<PORT_BASE>` relative to the script directory, isolating concurrent runs. Override to use a custom path. |

## Notes

- Peering is forced deterministically via `admin.addPeer(...)` over IPC. No discovery needed.
- All control operations use IPC (no HTTP exposure required on validators).
- Scenarios are cumulative: each builds on the state left by the previous one. Do not run them
  out of order.
- On failure, logs are preserved under `DATADIR_ROOT` (default `script/compat-clique-v1-v2/data-<PORT_BASE>/`) for debugging. Nodes are stopped automatically.

## Coverage and EVM parity

The suite tests **consensus-layer** compatibility: block sealing, Clique governance, reorg
selection, P2P sync, and transaction propagation across mixed v1/v2 networks. Scenario 6
submits simple ETH transfers (21 000 gas, no contract interaction), so the EVM execution
path is exercised only minimally — enough to confirm basic transaction acceptance, not
opcode-level parity.

**EVM execution tests are not required for this upgrade.** Here's why:

v2 is based on BSC v1.7.0-alpha (geth v1.16.7), which ships many new EIPs — Shanghai,
Cancun, Prague, Osaka — along with new precompiles (BLS12-381, KZG) and opcodes (CLZ,
EXTCALL). However, none of these activate on the test network because of a double gate in
`params/config.go`:

```
IsShanghai: (isMerge || c.IsInBSC()) && c.IsShanghai(num, timestamp)
```

`isMerge` is false (TerminalTotalDifficulty is set impossibly high) and `c.IsInBSC()`
is false (the test genesis has no `"parlia"` field — only `"clique"`). So, for this test
genesis, the Ethereum timestamp-gated forks that use this pattern (Shanghai, Cancun, Prague,
Osaka, etc.) all remain disabled regardless of the timestamps configured. The test network
therefore runs identical EVM rules to v1: Homestead through Petersburg (all activated at
block 0), with Istanbul and all later Ethereum forks left unset in the genesis.

Additionally, v2's own diff vs upstream touches zero files in `core/vm/`, `core/state/`,
or `core/txpool/`. The only code changes are Clique API restoration, P2P handshake
conditionals for BSC extensions, and miner timing (nil-delay handling).

Transaction **propagation** across the version boundary (not execution) is covered by
Scenario 6.

## Suggested future scenarios

These are not yet implemented but cover additional compatibility surface, ordered by priority
for the rolling v1→v2 upgrade:

**Scenario 8 — Epoch boundary with short epoch**: Run the full upgrade sequence (Scenarios
1–4) with `CLIQUE_EPOCH=10` so an epoch boundary is crossed during the mixed-version phase.
Verify all nodes agree on the signer set after the epoch transition. Catches divergence in how
v1 and v2 encode or decode the epoch checkpoint `extraData` field.

**Scenario 9 — JSON-RPC response parity** *(lower priority)*: Query the v2 RPC node (from
Scenario 2) and a v1 validator with the same set of calls (`eth_getBlockByNumber`,
`eth_getLogs`, `clique_getSnapshot`) and assert the responses are byte-identical. Catches any
JSON encoding or field-ordering regressions. Requires adding `--http` to a v1 validator at
startup (not currently done) or accepting IPC-only comparison.
