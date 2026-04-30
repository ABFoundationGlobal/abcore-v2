# ABCore v2 — Release Scripts

This directory contains production configs and scripts for running abcore-v2 Docker nodes.

The Docker image bundles testnet and mainnet configs, so **no config files need to be prepared separately** — just pull the image and run.

## Quick start

### Testnet RPC node

```bash
docker run -d \
  --name abcore-testnet \
  --restart unless-stopped \
  -v /data/abcore/testnet:/data \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  -p 0.0.0.0:33333:33333 \
  -p 0.0.0.0:33333:33333/udp \
  -e NAT=extip:YOUR_PUBLIC_IP \
  abfoundation/abcore-v2:VERSION
```

`NETWORK` defaults to `testnet`. Set `-e NETWORK=mainnet` for mainnet.

### Mainnet RPC node

```bash
docker run -d \
  --name abcore-mainnet \
  --restart unless-stopped \
  -v /data/abcore/mainnet:/data \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  -p 0.0.0.0:33333:33333 \
  -p 0.0.0.0:33333:33333/udp \
  -e NETWORK=mainnet \
  -e NAT=extip:YOUR_PUBLIC_IP \
  abfoundation/abcore-v2:VERSION
```

### Validator node

Place the keystore under `<datadir>/keystore/` and the password at `<datadir>/password.txt`, then:

```bash
docker run -d \
  --name abcore-testnet-validator \
  --restart unless-stopped \
  -v /data/abcore/testnet:/data \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  -p 0.0.0.0:33333:33333 \
  -p 0.0.0.0:33333:33333/udp \
  -e NETWORK=testnet \
  -e NAT=extip:YOUR_PUBLIC_IP \
  -e MINE=true \
  -e MINER_ADDR=0xYourValidatorAddress \
  -e PASSWORD_FILE=/data/password.txt \
  abfoundation/abcore-v2:VERSION
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | `testnet` | `testnet` or `mainnet` — selects the built-in config |
| `NAT` | — | NAT override, e.g. `extip:1.2.3.4` |
| `MINE` | `false` | Set `true` to enable block production |
| `MINER_ADDR` | — | Validator address to unlock (required when `MINE=true`) |
| `PASSWORD_FILE` | `/data/password.txt` | Path to keystore password file inside the container |
| `BSC_CONFIG` | — | Path to a TOML config file inside the container (see below) |

## How it works

Bootstrap nodes, genesis block, and chain config are **baked into the binary** via
`--abcore` / `--abcore.testnet` flags.  No config files are needed for basic operation.

**Advanced config override**: to tune TxPool limits, gas settings, RPC timeouts, etc.,
mount a TOML file into the container and point `BSC_CONFIG` at it:

```bash
-v $(pwd)/configs/testnet/node.toml:/abcore-config/node.toml:ro \
-e BSC_CONFIG=/abcore-config/node.toml
```

`configs/testnet/node.toml` and `configs/mainnet/node.toml` are ready-made templates.
Individual CLI flags always take precedence over the config file, so the correct
network identity is preserved.

## Directory structure

```
script/release/
  launch.sh               # Alternative launcher using docker run
  configs/
    testnet/
      node.toml           # Optional advanced config override (chain ID 26888)
      genesis.json        # Genesis file (for reference / manual geth init)
      docker-compose.yml  # Docker Compose deployment
      .env.example        # Environment variable template
    mainnet/
      node.toml           # Optional advanced config override (chain ID 36888)
      genesis.json        # Genesis file (for reference / manual geth init)
      docker-compose.yml
      .env.example
```

## Alternative: Docker Compose

```bash
cd configs/testnet          # or configs/mainnet
cp .env.example .env        # edit TAG, DATADIR, NAT
docker compose up -d
```

## Alternative: launch.sh

```bash
./launch.sh \
  --image abfoundation/abcore-v2:VERSION \
  --network testnet \
  --datadir /data/abcore/testnet \
  --external-ip YOUR_PUBLIC_IP
```

For all `launch.sh` options run `./launch.sh --help`.

## Managing the container

```bash
docker logs -f abcore-testnet
docker stop abcore-testnet
docker restart abcore-testnet
docker exec -it abcore-testnet geth attach /data/geth.ipc
```

## Becoming a validator

1. Generate a new account:
   ```bash
   docker run --rm -it \
     -v /data/abcore/testnet:/data \
     abfoundation/abcore-v2:VERSION \
     geth account new --datadir /data
   ```
   Note the printed address.

2. Run as a syncing RPC node first and wait for full sync.

3. Ask an existing authorized validator to vote your address in:
   ```js
   clique.propose("0xYourAddress", true)
   ```

4. Once the vote is included in an epoch checkpoint (every 30,000 blocks), restart as a validator node.
