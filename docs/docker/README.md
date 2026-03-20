# Docker

This document covers two usage scenarios:

- **Single validator node** — build the image and run one ABCore node (block-producing or sync-only).
- **Local Parlia devnet** — spin up a three-validator devnet in Docker Compose, mirroring the bare-metal workflow in `script/local/`.

> **Running a production node (testnet / mainnet)?**
> Use the operator release scripts in [`script/release/`](../../script/release/README.md).
> They provide pre-built configs and a `launch.sh` wrapper for connecting to the live networks without building from source.

---

## Prerequisites

- Docker 24+
- Docker Compose v2 (`docker compose`, not `docker-compose`)
- For the devnet: Python 3 (used by `script/local/01-setup.sh` to assemble `genesis.json`)

---

## Building the Image

Build from the repository root:

```bash
docker build -t abcore:local .
```

On Apple Silicon (M1/M2/M3), the image defaults to `linux/arm64`. To explicitly target `linux/amd64`:

```bash
docker build --platform linux/amd64 -t abcore:local .
```

`make docker` is also available as a shorthand (builds and tags as `abfoundationglobal/abcore-v2:latest`).

---

## Scenario 1 — Single Validator Node

> **For ABCore testnet / mainnet:** no config files are needed. Set `-e NETWORK=testnet` or `-e NETWORK=mainnet` and the binary uses the built-in genesis and bootstrap nodes automatically. The directory layout and `config.toml` below apply to **custom / private chains** only.

### Directory layout

Prepare a config directory on the host before starting the container:

```
my-node/
├── config/
│   ├── config.toml    ← node configuration (see template below)
│   ├── genesis.json   ← chain genesis
│   └── password.txt   ← keystore password (plain text)
└── data/
    └── keystore/
        └── UTC--...   ← validator keystore file
```

`config/` is mounted read-only at `/bsc/config` inside the container.
`data/` is mounted at `/data` (the value of `DataDir` in `config.toml`).

On first start the container initialises the chain state automatically (`geth init`). Subsequent starts skip this step.

### config.toml template

```toml
[Eth]
NetworkId = 7140          # replace with your chain ID
SyncMode = "full"
NoPruning = false
DatabaseCache = 512
TrieCleanCache = 256
TrieDirtyCache = 256
TrieTimeout = 360000000000
EnablePreimageRecording = false

[Eth.Miner]
GasCeil = 40000000
GasPrice = 1000000000
Recommit = 10000000000

[Eth.GPO]
Blocks = 20
Percentile = 60
OracleThreshold = 20

[Node]
DataDir = "/data"
InsecureUnlockAllowed = true
NoUSB = true
IPCPath = "geth.ipc"
HTTPHost = "0.0.0.0"
HTTPPort = 8545
HTTPVirtualHosts = ["*"]
HTTPModules = ["eth", "net", "web3", "debug", "parlia", "admin", "personal"]
WSHost = "0.0.0.0"
WSPort = 8546
WSModules = ["eth", "net", "web3", "debug", "parlia", "admin"]

[Node.P2P]
MaxPeers = 25
NoDiscovery = true        # set false if connecting to a live network
ListenAddr = ":30303"
EnableMsgEvents = false

[Node.HTTPTimeouts]
ReadTimeout = 30000000000
WriteTimeout = 30000000000
IdleTimeout = 120000000000
```

### Run (sync-only / RPC node)

```bash
docker run -d \
  --name abcore-node \
  -v $(pwd)/my-node/config:/bsc/config \
  -v $(pwd)/my-node/data:/data \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  -p 127.0.0.1:30303:30303 \
  abcore:local
```

> **Note:** Ports are bound to `127.0.0.1` by default. The config template above includes `admin` and `personal` in `HTTPModules` — these are convenient for local development but should be removed or restricted before exposing the node on a public network.

### Run (validator — block-producing)

Set `MINE=true` and `MINER_ADDR` to the keystore address. The keystore file must be present under `data/keystore/` and the password in `config/password.txt`.

```bash
docker run -d \
  --name abcore-validator \
  -e MINE=true \
  -e MINER_ADDR=0xYourValidatorAddress \
  -v $(pwd)/my-node/config:/bsc/config \
  -v $(pwd)/my-node/data:/data \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  -p 127.0.0.1:30303:30303 \
  abcore:local
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | `testnet` | `testnet` or `mainnet` — selects the built-in genesis and bootstrap nodes |
| `MINE` | `false` | Set `true` to enable block production |
| `MINER_ADDR` | — | Validator address to unlock (required when `MINE=true`) |
| `PASSWORD_FILE` | `/data/password.txt` | Path to keystore password file inside the container |
| `NAT` | — | NAT override. `auto` = use container IP (set automatically by the devnet compose). Accepts any value valid for geth `--nat` (e.g. `extip:1.2.3.4`) |

Additional geth flags can be appended after the image name and are passed through to `geth` verbatim:

```bash
docker run ... abcore:local --verbosity 4 --gcmode archive
```

---

## Scenario 2 — Local Parlia Devnet (Docker Compose)

Runs 1–5 validators on a private Docker network, equivalent to the bare-metal `script/local/` workflow.

### Quick start

```bash
cd script/local

# 1. Generate validator accounts and genesis.json
#    Supports 1–5 validators.
./01-setup.sh 3

# 2. Start the devnet
./07-docker-up.sh
```

`07-docker-up.sh` handles all preparation automatically:
- Copies `genesis.json` and `password.txt` into `config/`
- Writes a `.env` file with each validator's address
- Calls `docker compose` with the correct profile

### Endpoints after startup

| Node | HTTP RPC | WebSocket | P2P |
|------|----------|-----------|-----|
| validator-1 | `http://localhost:8545` | `ws://localhost:9545` | `30303` |
| validator-2 | `http://localhost:8546` | `ws://localhost:9546` | `30304` |
| validator-3 | `http://localhost:8547` | `ws://localhost:9547` | `30305` |
| validator-4 | `http://localhost:8548` | `ws://localhost:9548` | `30306` |
| validator-5 | `http://localhost:8549` | `ws://localhost:9549` | `30307` |

Only ports for the validators that were set up will be active.

### How peer connectivity works

Validators start with Kademlia discovery enabled (`NoDiscovery = false`). After all validators report healthy, the `mesh` sidecar container calls `admin_addPeer` on each validator pair to build a full peer mesh. The `mesh` container then exits; geth's built-in peer management maintains connectivity thereafter.

NAT is handled automatically: each container advertises its own Docker network IP via `--nat extip:<container-ip>`, so enodes are routable within the `devnet` bridge network.

### Common operations

```bash
# View logs for all containers
docker compose -f script/local/docker-compose.yml logs -f

# View logs for one validator
docker compose -f script/local/docker-compose.yml logs -f validator-1

# Attach a geth JavaScript console
docker exec -it abcore-v1 geth attach /data/geth.ipc

# Check block number
docker exec -it abcore-v1 geth attach --exec "eth.blockNumber" /data/geth.ipc

# Check peer count
docker exec -it abcore-v1 geth attach --exec "admin.peers.length" /data/geth.ipc

# Open a shell
docker exec -it abcore-v1 /bin/bash

# Stop and remove all devnet containers
docker compose -f script/local/docker-compose.yml down
```

### Reset and restart

```bash
# Stop containers
docker compose -f script/local/docker-compose.yml down

# Full reset (removes all chain data and generated keys)
./script/local/05-cleanup.sh

# Re-setup and restart
./script/local/01-setup.sh 3
./script/local/07-docker-up.sh
```

### File layout

```
script/local/
├── config/                    ← shared read-only config mount (generated by 07-docker-up.sh)
│   ├── config.toml            ← node config (committed, shared by all validators)
│   ├── genesis.json           ← copied from genesis.json at startup
│   └── password.txt           ← copied from data/validator-1/password.txt at startup
├── data/
│   ├── validator-1/
│   │   ├── keystore/          ← keystore file (generated by 01-setup.sh)
│   │   ├── geth/              ← chain state (initialised by 01-setup.sh)
│   │   └── address.txt
│   ├── validator-2/  ...
│   └── validator-3/  ...
├── docker-compose.yml
├── mesh.sh                    ← peer wiring script (runs inside alpine container)
└── 07-docker-up.sh            ← one-shot launcher
```

`data/` and `genesis.json` are git-ignored. `config/config.toml` is committed.

---

## Troubleshooting

**Container exits immediately**

Check the logs:
```bash
docker logs abcore-v1
```

Common causes:
- `MINE=true` but `MINER_ADDR` not set → entrypoint prints an explicit error and exits.
- Wrong keystore address or password → geth reports `could not unlock account`.
- `NETWORK` set to an unknown value → entrypoint prints an explicit error and exits.

**Validators not peering (multi-validator)**

Check the mesh container logs:
```bash
docker logs abcore-mesh
```

If the mesh container exited before all validators were healthy, restart it:
```bash
docker start abcore-mesh
```

**`geth init` runs every restart**

This happens when `/data/geth` does not exist, which means the data volume is not persisted across runs. Ensure `data/validator-N` is correctly mounted and not empty.

**Port conflicts on the host**

If ports 8545–8547 or 30303–30305 are already in use, edit the `ports:` section of `script/local/docker-compose.yml` to map to different host ports.
