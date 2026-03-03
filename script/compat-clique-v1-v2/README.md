# Mixed-Version Clique Compatibility (v1.13.x ↔ v2)

This folder contains scripts to:
1) Start a local Clique PoA network with **3 v1.13.x validator binaries**.
2) Test compatibility scenarios for the **abcore-v2** binary.

## Prerequisites

- Build v2 binary from repo root: `make geth` (produces `./build/bin/geth`)
- v1 binary: downloaded automatically on first run via `00-get-v1-geth.sh` (requires `gh` CLI
  authenticated to GitHub). Saved to `script/compat-clique-v1-v2/bin/geth-v1` and reused on
  subsequent runs. Override with `ABCORE_V1_GETH=/path/to/geth` if you have it locally.
- `python3` in PATH (used by `01-setup.sh` to generate `genesis.json`)

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
- clean any prior state (`data/`, `genesis.json`)
- generate a fresh Clique `genesis.json` (chain ID 7141, 3-second blocks)
- start 3 v1 validators
- run the 3 scenarios in sequence, then stop all nodes

## Scenarios

**Scenario 1** (`10-scn1-upgrade-validator.sh`): Stop one v1 validator and restart it with the v2
binary using the same datadir. Verify it syncs to the canonical head and seals at least one block
alongside the remaining v1 validators. Tests in-place binary upgrade compatibility.

**Scenario 2** (`20-scn2-add-v2-rpc-node.sh`): Start a new v2 node without mining, peer it to
the v1 network, and verify it syncs to the current head with matching block hashes. Tests v2 as
an archive/RPC node in a predominantly v1 network.

**Scenario 3** (`30-scn3-add-v2-validator-vote.sh`): Create a new v2 validator account, vote it
into the Clique signer set via `clique.propose` from two existing validators, then restart it
with mining enabled. Verify it seals blocks and all nodes (v1 and v2) agree on the canonical
chain. Tests dynamic validator set changes across versions.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `ABCORE_V1_GETH` | `/data/kai/workspace/ab/abcore/build/bin/geth` | Path to v1.13.x binary |
| `ABCORE_V2_GETH` | `./build/bin/geth` | Path to v2 binary |
| `KEEP_RUNNING` | `0` | Set to `1` to leave nodes running after pass |
| `UPGRADE_VALIDATOR_N` | `2` | Which validator to upgrade in scenario 1 (1–3) |
| `CLIQUE_CHAIN_ID` | `7141` | Chain ID for the test network |
| `CLIQUE_PERIOD` | `3` | Block period in seconds |

## Notes

- Peering is forced deterministically via `admin.addPeer(...)` over IPC. No discovery needed.
- All control operations use IPC (no HTTP exposure required on validators).
- Scenarios are cumulative: each builds on the state left by the previous one. Do not run them
  out of order.
- On failure, logs are preserved under `data/` for debugging. Nodes are stopped automatically.

## Suggested future scenarios

These are not yet implemented but cover additional compatibility surface:

**Scenario 4 — Complete rolling upgrade**: Stop the remaining v1 validators and restart them with
the v2 binary, leaving a fully-v2 network. Verify all nodes converge on the same head and each
upgraded validator seals at least one block. Tests the end-state where no v1 nodes remain.

**Scenario 5 — v1/v2 re-org resilience**: Isolate a v1 and v2 node for 3 blocks (drop peers),
then reconnect and verify they converge on the same canonical chain via highest-difficulty fork
selection. Tests that fork choice is identical across versions.

**Scenario 6 — JSON-RPC response parity**: Query the v2 RPC node (from scenario 2) and a v1
validator with the same set of calls (`eth_getBlockByNumber`, `eth_getLogs`,
`clique_getSnapshot`) and assert the responses are byte-identical. Catches any JSON encoding or
field-ordering regressions.

**Scenario 7 — Clique propose/discard round-trip**: Vote a v2 validator in (as in scenario 3),
then vote it back out via `clique.discard` from a majority of signers, and confirm it stops
appearing in `clique.getSnapshot().signers`. Tests the full governance cycle across versions.
