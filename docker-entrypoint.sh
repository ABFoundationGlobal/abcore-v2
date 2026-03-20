#!/bin/bash
set -e

# Network selection via NETWORK env var (default: testnet).
# Supported values: testnet, mainnet
#
# Bootstrap nodes, genesis, and chain config are baked into the binary.
# No external config files are required for basic operation.
#
# Advanced config override:
#   Mount a custom config at /bsc/config/config.toml (or set BSC_CONFIG).
#   The mounted config acts as a baseline; the --abcore[.testnet] network flag
#   is always passed so genesis and bootstrap nodes are always correct.

NETWORK="${NETWORK:-testnet}"
case "$NETWORK" in
  testnet)  NETWORK_FLAG="--abcore.testnet" ;;
  mainnet)  NETWORK_FLAG="--abcore" ;;
  *) echo "ERROR: NETWORK must be testnet or mainnet, got: $NETWORK" >&2; exit 1 ;;
esac

# Config override: if a config file is provided, pass it via --config.
# Individual CLI flags below override any values in the config file.
CONFIG_ARGS=()
BSC_CONFIG="${BSC_CONFIG:-${BSC_HOME}/config/config.toml}"
if [ -f "$BSC_CONFIG" ]; then
  CONFIG_ARGS=(--config "$BSC_CONFIG")
fi

# Validator / mining support
# Set MINE=true and MINER_ADDR=0x... to enable block production.
# The keystore must be present in /data/keystore/
# and the password file at /data/password.txt (or PASSWORD_FILE).
MINE_ARGS=()
if [ "${MINE:-false}" = "true" ]; then
  if [ -z "${MINER_ADDR:-}" ]; then
    echo "ERROR: MINE=true but MINER_ADDR is not set" >&2
    exit 1
  fi
  PASSWORD_FILE="${PASSWORD_FILE:-/data/password.txt}"
  if [ ! -f "$PASSWORD_FILE" ]; then
    echo "ERROR: password file not found at $PASSWORD_FILE" >&2
    exit 1
  fi
  # --allow-insecure-unlock is required when HTTP-RPC is enabled.
  # Ensure port 8545 is NOT exposed publicly on validator nodes
  # (use -p 127.0.0.1:8545:8545 in docker run, not -p 0.0.0.0:8545:8545).
  MINE_ARGS=(
    --mine
    --unlock "${MINER_ADDR}"
    --miner.etherbase "${MINER_ADDR}"
    --allow-insecure-unlock
    --password "${PASSWORD_FILE}"
  )
fi

# NAT configuration
# NAT=auto  → advertise the container's own IP (for Docker devnet)
# NAT=<val> → pass the value verbatim (e.g. extip:1.2.3.4)
NAT_ARGS=()
if [ "${NAT:-}" = "auto" ]; then
  CONTAINER_IP=$(hostname -i | awk '{print $1}')
  NAT_ARGS=(--nat "extip:${CONTAINER_IP}")
elif [ -n "${NAT:-}" ]; then
  NAT_ARGS=(--nat "${NAT}")
fi

exec geth \
  "$NETWORK_FLAG" \
  --datadir /data \
  --port 33333 \
  --http --http.addr 0.0.0.0 --http.port 8545 --http.vhosts '*' \
  --http.api 'debug,txpool,net,web3,eth' \
  --ws --ws.addr 0.0.0.0 --ws.port 8546 \
  --ws.api 'debug,txpool,net,web3,eth' \
  --ipcpath /data/geth.ipc \
  --syncmode full \
  --gcmode archive \
  "${CONFIG_ARGS[@]}" \
  "${MINE_ARGS[@]}" \
  "${NAT_ARGS[@]}" \
  "$@"
