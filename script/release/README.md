# ABCore v2 — Release Scripts

This folder contains configs and a launch script for running abcore-v2 Docker nodes.

## Folder structure

```
script/release/
  launch.sh               # Docker node launcher
  configs/
    testnet/
      node.toml           # Testnet node config (chain ID 26888, 1s block time)
      genesis.json        # Testnet genesis
    mainnet/
      node.toml           # Mainnet node config (chain ID 36888, 3s block time)
      genesis.json        # Mainnet genesis
```

`launch.sh` mounts the appropriate config files into the container automatically based on `--network`. On first boot the container initialises the chain from `genesis.json`; subsequent starts skip that step.

## Prerequisites

- Docker installed and running
- A released image, e.g. `ghcr.io/<org>/abcore-v2:v1.0.0`

## Typical usage

### Testnet RPC node

Syncs from the testnet bootstrap node automatically. Exposes RPC on port 8545 and WS on 8546.

```bash
./launch.sh \
  --image ghcr.io/<org>/abcore-v2:v1.0.0 \
  --network testnet \
  --datadir /data/abcore/testnet
```

### Mainnet RPC node

```bash
./launch.sh \
  --image ghcr.io/<org>/abcore-v2:v1.0.0 \
  --network mainnet \
  --datadir /data/abcore/mainnet
```

### Validator node

Requires a keystore and a plaintext password file on the host. The keystore file must be in `<datadir>/keystore/`.

```bash
./launch.sh \
  --image ghcr.io/<org>/abcore-v2:v1.0.0 \
  --network testnet \
  --mode validator \
  --datadir /data/abcore/testnet \
  --address 0xYourValidatorAddress \
  --password /path/to/password.txt
```

The password file is mounted read-only into the container. The keystore is picked up from `<datadir>/keystore/` which is already inside the mounted data volume.

> **Note:** Signing blocks requires your address to be in the Clique authorized signer set. Run as a syncing-only RPC node first, then have an existing validator call `clique_propose("0xYourAddress", true)` on their node. See the [becoming a validator](#becoming-a-validator) section below.

### Advertising a public IP for P2P

If the node runs behind NAT and you want other peers to reach it, pass `--external-ip`:

```bash
./launch.sh \
  --image ghcr.io/<org>/abcore-v2:v1.0.0 \
  --network mainnet \
  --datadir /data/abcore/mainnet \
  --external-ip 1.2.3.4
```

## All options

```
Usage: launch.sh -i IMAGE [OPTIONS]

Required:
  -i, --image IMAGE       Docker image to run

Options:
  -n, --network NET       testnet|mainnet          (default: testnet)
  -m, --mode MODE         rpc|validator            (default: rpc)
  -d, --datadir PATH      Host data directory      (default: ./data)
  -a, --address ADDR      Validator address        (required for --mode validator)
  -p, --password FILE     Password file path       (required for --mode validator)
  -e, --external-ip IP    Advertise IP for P2P     (sets NAT=extip:IP)
  -h, --help
```

## Managing the container

```bash
# View logs
docker logs -f abcore-testnet-rpc

# Stop
docker stop abcore-testnet-rpc

# Restart
docker start abcore-testnet-rpc

# Remove (data is preserved in --datadir)
docker rm abcore-testnet-rpc
```

Container names follow the pattern `abcore-<network>-<mode>`.

## Becoming a validator

1. Generate a new account (keystore stored under `<datadir>/keystore/`):
   ```bash
   docker run --rm -it \
     -v /data/abcore/testnet:/data \
     ghcr.io/<org>/abcore-v2:v1.0.0 \
     geth account new --datadir /data
   ```
   Note the printed address.

2. Start as an RPC node first (`--mode rpc`) and let it fully sync.

3. Ask an existing authorized validator to vote your address in via their node's console:
   ```js
   clique.propose("0xYourAddress", true)
   ```

4. Once the vote is included in an epoch checkpoint (every 30,000 blocks on testnet, same on mainnet), restart the node with `--mode validator`.
