# Mixed-Version Clique Compatibility (v1.13.x ↔ v2)

This folder contains scripts to:
1) Start a local Clique PoA network with **3 v1.13.x validator binaries**.
2) Test compatibility scenarios for the **abcore-v2** binary.

## Prerequisites

- Build v2 binary:
  - From repo root: `make geth` (produces `./build/bin/geth`)
- Have an old v1.13.x geth binary available.

## Configure binaries

Scripts look for these env vars:

- `ABCORE_V1_GETH`: path to v1 binary (default: `/data/kai/workspace/ab/abcore/build/bin/geth` if present)
- `ABCORE_V2_GETH`: path to v2 binary (default: `./build/bin/geth` if present)

They will fail fast if the binaries don’t exist.

## Run

From repo root:

- `script/compat-clique-v1-v2/99-run-all.sh`

This will:
- create `script/compat-clique-v1-v2/data/`
- generate a Clique `genesis.json`
- start 3 v1 validators
- run the 3 scenarios:
  1. upgrade a v1 validator to v2 in-place
  2. add a v2 RPC node and sync
  3. add a v2 validator via Clique voting and verify it seals

## Notes

- Peering is forced deterministically via `admin.addPeer(...)` over IPC.
- All control operations use IPC (no need to expose HTTP on validators).
