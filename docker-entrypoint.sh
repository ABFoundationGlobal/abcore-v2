#!/bin/bash
set -e

# Network selection via NETWORK env var (default: testnet).
# Supported values: testnet, mainnet
#
# Bootstrap nodes, genesis, and chain config are baked into the binary.
# Additional node parameters (RPC, sync mode, ports, etc.) are passed as
# CLI arguments to this entrypoint via "$@". An optional node.toml is used
# only if BSC_CONFIG is set; see script/release/configs/{testnet,mainnet}/node.toml.

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
# Auto-detection: if MINE is not set, enable mining automatically when
# /data/keystore/ contains a keystore file and /data/password.txt exists.
# Override by setting MINE=true/false explicitly.
PASSWORD_FILE="${PASSWORD_FILE:-/data/password.txt}"

if [ -z "${MINE:-}" ]; then
  KEYSTORE_FILE=$(ls /data/keystore/ 2>/dev/null | head -1)
  if [ -n "$KEYSTORE_FILE" ] && [ -f "$PASSWORD_FILE" ]; then
    MINE=true
    echo "INFO: keystore and password found, enabling validator mode automatically"
  else
    MINE=false
  fi
fi

MINE_ARGS=()
if [ "${MINE}" = "true" ]; then
  # Auto-extract MINER_ADDR from keystore filename if not set.
  if [ -z "${MINER_ADDR:-}" ]; then
    KEYSTORE_FILE=$(ls /data/keystore/ 2>/dev/null | head -1)
    if [ -z "$KEYSTORE_FILE" ]; then
      echo "ERROR: MINE=true but no keystore file found in /data/keystore/" >&2
      exit 1
    fi
    ADDR_HEX=$(echo "$KEYSTORE_FILE" | sed 's/.*--//')
    if [ -z "$ADDR_HEX" ]; then
      echo "ERROR: failed to parse validator address from keystore filename: $KEYSTORE_FILE" >&2
      exit 1
    fi
    MINER_ADDR="0x${ADDR_HEX}"
    echo "INFO: using validator address ${MINER_ADDR}"
  fi
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
# Auto-detection: if NAT is not set, query the public IP automatically.
# NAT=auto → use the container's own IP (for Docker devnet / local testing)
# NAT=<val> → pass verbatim, e.g. extip:1.2.3.4
NAT_ARGS=()
if [ -z "${NAT:-}" ]; then
  PUBLIC_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
           || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || true)
  if [ -n "$PUBLIC_IP" ]; then
    NAT_ARGS=(--nat "extip:${PUBLIC_IP}")
    echo "INFO: detected public IP ${PUBLIC_IP}, setting NAT automatically"
  fi
elif [ "${NAT}" = "auto" ]; then
  CONTAINER_IP=$(hostname -i | awk '{print $1}')
  NAT_ARGS=(--nat "extip:${CONTAINER_IP}")
else
  NAT_ARGS=(--nat "${NAT}")
fi

exec geth \
  "$NETWORK_FLAG" \
  --datadir /data \
  "${CONFIG_ARGS[@]}" \
  "${MINE_ARGS[@]}" \
  "${NAT_ARGS[@]}" \
  "$@"
