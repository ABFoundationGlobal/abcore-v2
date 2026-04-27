# DevNet Scripts

Scripts to run and upgrade the ABCore DevNet (5 validators + 1 RPC node, Chain ID 17140).

## Node Layout

| Server   | Containers          | Role                        |
|----------|---------------------|-----------------------------|
| server-1 | devnet-val-0, val-1 | Validator (Clique → Parlia) |
| server-2 | devnet-val-2, val-3 | Validator                   |
| server-3 | devnet-val-4        | Validator (single, canary)  |
| server-4 | devnet-rpc-0        | RPC node (non-mining)       |

RPC ports: val-0=8545 val-1=8546 val-2=8547 val-3=8548 val-4=8549 rpc-0=8550  
P2P ports: val-0=30300 … val-4=30304 rpc-0=30305

## Scripts

| Script | Purpose |
|--------|---------|
| `01-start.sh <v1_image>` | **Reset chain to block 0** and start v1 Clique network |
| `02-upgrade.sh <step> <image>` | Rolling upgrade (step 1–5), one node at a time |
| `03-status.sh` | Show block height, peers, mining state for all nodes |

## Upgrade Steps

| Step | From → To | Fork type | Key action |
|------|-----------|-----------|------------|
| 1 | v1 → v2 0.2.x | Block height (ParliaGenesisBlock) | Consensus switch to Parlia |
| 2 | v2 0.2.x → 0.3.0 | Block height (LondonBlock + 13 BSC forks) | EIP-1559 + Luban extraData |
| 3 | v2 0.3.0 → 0.4.0 | Timestamp (ShanghaiTime/FeynmanTime) | createValidator for all 5 validators before first breathe block (~10 min window) |
| 4 | v2 0.4.0 → 0.5.0 | Timestamp (CancunTime) | Blob transactions |
| 5 | v2 0.5.0 → 0.6.0 | Timestamp (PragueTime/LorentzTime/MaxwellTime) | Lorentz +1d, Maxwell +7d after Prague |

## Quick Start

```bash
# 1. Start fresh v1 network
./01-start.sh ghcr.io/abfoundationglobal/abcore:v1.13.15

# 2. Check status
./03-status.sh

# 3. Upgrade to v2 (Parlia)
./02-upgrade.sh 1 ghcr.io/abfoundationglobal/abcore-v2:v0.2.0

# 4. Continue upgrades
./02-upgrade.sh 2 ghcr.io/abfoundationglobal/abcore-v2:v0.3.0
./02-upgrade.sh 3 ghcr.io/abfoundationglobal/abcore-v2:v0.4.0
./02-upgrade.sh 4 ghcr.io/abfoundationglobal/abcore-v2:v0.5.0
./02-upgrade.sh 5 ghcr.io/abfoundationglobal/abcore-v2:v0.6.0
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATA_DIR` | `./data` | Node data directory root |
| `CHAIN_ID` | `17140` | DevNet chain ID |
| `LOG_LEVEL` | `3` | Geth verbosity (1–5) |
| `RESTART_WAIT` | `10` | Seconds between node restarts during upgrade |
| `BLOCK_WAIT` | `2` | Blocks to wait after restarting each node |
| `V1_IMAGE` | — | Alternative to passing v1 image as argument |

## Notes

- `01-start.sh` always **resets** the chain. All existing data is wiped.
- Block height forks (steps 1–2): the fork block N/M is hardcoded in `params/config.go` at build time. Ensure the image's fork block is above the current chain height before upgrading.
- Timestamp forks (steps 3–5): the activation timestamp T is hardcoded in the binary. All nodes must be upgraded before T arrives.
- The rolling upgrade order is always: val-4 → val-0 → val-1 → val-2 → val-3 → rpc-0. At most 1 validator is offline at any time (4/5 majority maintained).
- For detailed upgrade procedures, observation windows, and rollback instructions, see `docs/ops/devnet-upgrade-plan.md`.
