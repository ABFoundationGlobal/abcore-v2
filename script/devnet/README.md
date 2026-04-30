# DevNet Scripts

Scripts to run and upgrade the ABCore DevNet (5 validators + 1 RPC node, Chain ID 17140).

Each script runs on a **single machine**. Multi-machine coordination (SSH, scp, rolling order, P2P wiring) is handled by the Jenkins Pipeline.

---

## Node Layout

| Server   | Nodes               | Role                       |
|----------|---------------------|----------------------------|
| server-1 | val-0, val-1        | Validator (Clique → Parlia) |
| server-2 | val-2, val-3        | Validator                  |
| server-3 | val-4               | Validator (canary)         |
| server-4 | rpc-0               | RPC node (non-mining)      |

RPC ports: val-0=19545 val-1=19546 val-2=19547 val-3=19548 val-4=19549 rpc-0=19550  
P2P ports: val-0=31300 val-1=31301 val-2=31302 val-3=31303 val-4=31304 rpc-0=31305

---

## Scripts

### What each script does

| Script | Runs on | What it does |
|--------|---------|--------------|
| `generate-genesis.sh` | Jenkins control machine | Reads validator addresses, generates `genesis.json`. No Docker required. |
| `start-single.sh <node...> <image>` | Each server | Resets specified nodes (wipes data), inits chaindata from genesis, starts containers. |
| `upgrade-single.sh <step> <node...> <image>` | Each server | Stops old containers, starts new image for specified nodes. |
| `status-single.sh [node...]` | Each server | Shows block height, peers, mining state for nodes on this machine. |

### What Jenkins Pipeline is responsible for

The scripts above are intentionally minimal — they only operate on the local machine. Jenkins handles everything that requires cross-machine coordination:

- SSH into each server and execute the scripts above
- `scp` the `genesis.json` and keystore files to each server before calling `start-single.sh`
- **Rolling upgrade order**: server-3 (val-4) → server-1 (val-0, val-1) → server-2 (val-2, val-3) → server-4 (rpc-0)
- **P2P mesh wiring**: after all nodes are started or upgraded, collect enodes from each server and call `admin_addPeer` on all nodes (or distribute a `static-nodes.json`)
- **Health check aggregation**: run `status-single.sh` on each server and collect output

---

## Upgrade Steps

| Step | From → To | Fork type | Key action |
|------|-----------|-----------|------------|
| 1 | v1 → v2 0.2.x | Block height (ParliaGenesisBlock) | Consensus switch to Parlia |
| 2 | v2 0.2.x → 0.3.0 | Block height (LondonBlock + 13 BSC forks) | EIP-1559 + Luban extraData |
| 3 | v2 0.3.0 → 0.4.0 | Timestamp (ShanghaiTime/FeynmanTime) | createValidator for all 5 validators within ~10 min after activation |
| 4 | v2 0.4.0 → 0.5.0 | Timestamp (CancunTime) | Blob transactions |
| 5 | v2 0.5.0 → 0.6.0 | Timestamp (PragueTime/LorentzTime/MaxwellTime) | Lorentz +1d, Maxwell +7d after Prague |

---

## Quick Start (manual / Jenkins reference)

```bash
# ── Jenkins control machine ─────────────────────────────────────────────────

# 1. Generate genesis (once)
./generate-genesis.sh
# Output: ./genesis.json

# 2. Distribute genesis and keystores to each server
scp genesis.json                         server-1:~/devnet/script/devnet/
scp keystores/val-0.json keystores/val-1.json  server-1:~/devnet/script/devnet/keystores/

scp genesis.json                         server-2:~/devnet/script/devnet/
scp keystores/val-2.json keystores/val-3.json  server-2:~/devnet/script/devnet/keystores/

scp genesis.json                         server-3:~/devnet/script/devnet/
scp keystores/val-4.json               server-3:~/devnet/script/devnet/keystores/

scp genesis.json                         server-4:~/devnet/script/devnet/

# ── Each server ─────────────────────────────────────────────────────────────

# server-1
GENESIS_FILE=~/devnet/script/devnet/genesis.json \
  ./start-single.sh val-0 val-1 ghcr.io/abfoundationglobal/abcore:v1.13.15

# server-2
GENESIS_FILE=~/devnet/script/devnet/genesis.json \
  ./start-single.sh val-2 val-3 ghcr.io/abfoundationglobal/abcore:v1.13.15

# server-3
GENESIS_FILE=~/devnet/script/devnet/genesis.json \
  ./start-single.sh val-4 ghcr.io/abfoundationglobal/abcore:v1.13.15

# server-4
GENESIS_FILE=~/devnet/script/devnet/genesis.json \
  ./start-single.sh rpc-0 ghcr.io/abfoundationglobal/abcore:v1.13.15

# ── Jenkins: wire P2P mesh (collect enodes from start-single.sh output, then addPeer) ──

# ── Status check (run on each server) ───────────────────────────────────────
./status-single.sh val-0 val-1   # server-1
./status-single.sh val-2 val-3   # server-2
./status-single.sh val-4          # server-3
./status-single.sh rpc-0          # server-4

# ── Rolling upgrade (run on each server in order) ───────────────────────────
# server-3 first (canary)
./upgrade-single.sh 1 val-4 ghcr.io/abfoundationglobal/abcore-v2:v0.2.0

# server-1
./upgrade-single.sh 1 val-0 val-1 ghcr.io/abfoundationglobal/abcore-v2:v0.2.0

# server-2
./upgrade-single.sh 1 val-2 val-3 ghcr.io/abfoundationglobal/abcore-v2:v0.2.0

# server-4
./upgrade-single.sh 1 rpc-0 ghcr.io/abfoundationglobal/abcore-v2:v0.2.0

# ── Jenkins: re-wire P2P mesh after upgrade ──────────────────────────────────
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GENESIS_FILE` | — | **Required for start-single.sh.** Path to genesis.json on this machine. |
| `DATA_DIR` | `./data` | Node data directory root |
| `CHAIN_ID` | `17140` | DevNet chain ID (must match genesis) |
| `LOG_LEVEL` | `3` | Geth verbosity (1–5) |
| `RESTART_WAIT` | `10` | Seconds between node restarts during upgrade |
| `BLOCK_WAIT` | `2` | Blocks to wait after restarting each node |
| `DOCKER_HOST_IP` | auto | IP containers use to reach host-bound ports |
| `VAL_ADDRESSES` | — | Comma-separated validator addresses for generate-genesis.sh (alternative to keystores/val-N.address) |

---

## Notes

- `start-single.sh` always **resets** the specified nodes. All existing data for those nodes is wiped.
- Block height forks (steps 1–2): the fork block N/M is hardcoded in `params/config.go` at build time. Ensure the fork block is above the current chain height before upgrading.
- Timestamp forks (steps 3–5): the activation timestamp T is hardcoded in the binary. All nodes across all servers must be upgraded before T arrives.
- Rolling upgrade order: val-4 → val-0 → val-1 → val-2 → val-3 → rpc-0. At most 1 validator offline at a time (4/5 majority maintained).
- For detailed upgrade procedures, observation windows, and rollback instructions, see the [devnet upgrade plan](https://github.com/ABFoundationGlobal/abcore-v2/blob/devnet-upgrade-plan/docs/ops/devnet-upgrade-plan.md).
