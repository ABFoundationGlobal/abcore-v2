#!/bin/bash
set -e

# Network selection via NETWORK env var (default: testnet).
# Supported values: testnet, mainnet
#
# Bootstrap nodes, genesis, and chain config are baked into the binary.
# All other node parameters (RPC, sync mode, ports, etc.) are configured
# via node.toml. See script/release/configs/{testnet,mainnet}/node.toml.

NETWORK="${NETWORK:-testnet}"
case "$NETWORK" in
  testnet)  NETWORK_FLAG="--abcore.testnet" ;;
  mainnet)  NETWORK_FLAG="--abcore" ;;
  *) echo "ERROR: NETWORK must be testnet or mainnet, got: $NETWORK" >&2; exit 1 ;;
esac

# Config file: set BSC_CONFIG to the container path of node.toml.
# e.g. -e BSC_CONFIG=/data/node.toml (if node.toml is placed in $DATADIR)
CONFIG_ARGS=()
if [ -n "${BSC_CONFIG:-}" ] && [ -f "$BSC_CONFIG" ]; then
  CONFIG_ARGS=(--config "$BSC_CONFIG")
fi

# Validator / mining support.
# Set MINE=true and MINER_ADDR=0x... to enable block production.
# Keystore must be in /data/keystore/, password file at PASSWORD_FILE.
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
  # Never expose port 8545 publicly on validator nodes.
  MINE_ARGS=(
    --mine
    --unlock "${MINER_ADDR}"
    --miner.etherbase "${MINER_ADDR}"
    --allow-insecure-unlock
    --password "${PASSWORD_FILE}"
  )
fi

# NAT configuration.
# NAT=auto  → use the container's own IP (Docker devnet)
# NAT=<val> → pass verbatim, e.g. extip:1.2.3.4
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
  "${CONFIG_ARGS[@]}" \
  "${MINE_ARGS[@]}" \
  "${NAT_ARGS[@]}" \
  "$@"
