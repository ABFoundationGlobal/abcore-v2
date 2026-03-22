# No-Genesis v2 Startup Tests

This suite validates two distinct properties introduced by the ABCore v2 chain config changes in commit `07548351f`:

1. **Binary-embedded genesis startup** — `--abcore.testnet` alone is sufficient to start a v2 node without `geth init`.
2. **`HasCliqueAndParlia()` Clique engine path** — when both `Clique` and `Parlia` are configured but `ParliaGenesisBlock` is nil, the node must route through the Clique branch of `CreateConsensusEngine()` and seal blocks normally, with no accidental Parlia activation.

These properties are **not covered** by the existing test suites:
- `compat-clique-v1-v2/` uses a custom genesis (chain ID 7141) and always runs `geth init`; it never exercises the binary-embedded genesis path or the `HasCliqueAndParlia()` code branch.
- `local-v2/` is a Parlia devnet (chain ID 7140) unrelated to either property.

## Prerequisites

- Build v2 binary: `make geth` (produces `./build/bin/geth`)
- v1 binary: downloaded automatically on first run. Override with `ABCORE_V1_GETH=/path/to/geth`.
- `python3` in PATH (used by `01-setup.sh` to generate the Scenario 2 genesis)

## Run

From repo root:

```bash
script/no-genesis-v2/99-run-all.sh
```

Or with an explicit v1 binary:

```bash
export ABCORE_V1_GETH=/path/to/abcore-v1-geth
script/no-genesis-v2/99-run-all.sh
```

## Scenarios

### Scenario 1 — Binary-embedded genesis startup (`10-scn1-v2-no-genesis-startup.sh`)

Validates the no-`geth init` startup path end-to-end.

**What it does**: A v1 node is initialized from the exact ABCore testnet genesis produced by `geth dumpgenesis --abcore.testnet` (chain ID 26888, genesis hash `0x739b6207...`). A v2 node is started with `--abcore.testnet` and a completely empty datadir — no `geth init`, no genesis file. After peering, both nodes must agree on the block 0 hash.

**What it proves**: The binary contains a valid embedded genesis that matches the production testnet chain. `GetBuiltInChainConfig()` correctly resolves `ABCoreTestChainConfig` from the hash, and `DefaultABCoreTestGenesisBlock()` writes a genesis block to the DB on first startup. A v2 node can handshake with a v1 peer on the real ABCore testnet chain without any manual initialization step.

**What it does not test**: Block sealing or `HasCliqueAndParlia()` — neither node mines in this scenario.

---

### Scenario 2 — `HasCliqueAndParlia()` Clique engine path (`20-scn2-v2-clique-sealing.sh`)

Validates that the ABCore dual-consensus engine branch correctly seals Clique blocks before the Parlia fork block is set.

**What it does**: A custom genesis is generated with:
- Chain ID 26888, Clique period 1
- A fresh validator account (so v2 can control the sole signer)
- `"parlia": {}` in the config — this is essential: it makes `HasCliqueAndParlia()` return true, routing `CreateConsensusEngine()` through the ABCore-specific branch rather than the plain Clique fallback

The custom genesis has a different hash from the production testnet, so v2 must be started with `--override.genesis` (not `--abcore.testnet`). This is intentional: the goal is to exercise the engine selection logic with a controllable validator, not to test the `--abcore.testnet` flag again.

v1 runs sync-only; v2 mines. After v2 seals 3+ blocks, v1 must sync to v2's head and agree on the block hash.

**What it proves**: With `Clique != nil`, `Parlia != nil`, and `ParliaGenesisBlock = nil`:
- `HasCliqueAndParlia()` returns true
- `IsParliaActive(num)` returns false at all heights
- `CreateConsensusEngine()` selects Clique (not Parlia, not an error)
- Blocks are sealed and propagated correctly
- No parlia-related errors appear in the v2 log

**Why `"parlia": {}` must be in the genesis**: without it, the genesis JSON produces a `ChainConfig` with `Parlia == nil`, `HasCliqueAndParlia()` returns false, and `CreateConsensusEngine()` falls through to the plain `c.Clique != nil` branch — the same code path as `compat-clique-v1-v2`. The test would be redundant. The `"parlia": {}` field is what makes this test meaningful.

---

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `ABCORE_V1_GETH` | `script/compat-clique-v1-v2/bin/geth-v1` (auto-downloaded) | Path to v1.13.x binary |
| `ABCORE_V2_GETH` | `./build/bin/geth` | Path to v2 binary |
| `KEEP_RUNNING` | `0` | Set to `1` to leave nodes running after pass |
| `PORT_BASE` | auto-selected | Offset added to all port numbers (auto-selected to avoid conflicts) |
| `DATADIR_ROOT` | `script/no-genesis-v2/data-<PORT_BASE>` | Root directory for all node data |

## Known constraints

**v1 binary does not support `--authrpc.port`** — v1 is started without it; all control goes through IPC.

**`--networkid 26888` on v2 triggers `DefaultABCoreTestGenesisBlock()`** — the guard `cfg.NetworkId == 26888` in `cmd/utils/flags.go` forces the built-in testnet genesis, which conflicts with a custom genesis already in the DB. Scenario 2 uses `--override.genesis` to bypass this.

**v2 requires `--miner.etherbase`** — unlike v1, the BSC-based v2 binary requires an explicit etherbase when `--mine` is set.

On failure, logs are preserved under `DATADIR_ROOT` for debugging. Nodes are stopped automatically.
