#!/bin/bash
set -e

DEFAULT_BSC_CONFIG=${BSC_HOME}/config/config.toml
DEFAULT_BSC_GENESIS=${BSC_HOME}/config/genesis.json
FALLBACK_CONFIG=${DATA_DIR}/.docker-config/config.toml
FALLBACK_GENESIS=${DATA_DIR}/.docker-config/genesis.json
FALLBACK_PASSWORD=${DATA_DIR}/.docker-config/password.txt

BSC_CONFIG=${BSC_CONFIG:-$DEFAULT_BSC_CONFIG}
BSC_GENESIS=${BSC_GENESIS:-$DEFAULT_BSC_GENESIS}
PASSWORD_FILE=${PASSWORD_FILE:-${BSC_HOME}/config/password.txt}

if [ ! -f "$BSC_CONFIG" ] && [ -f "$FALLBACK_CONFIG" ]; then
  BSC_CONFIG="$FALLBACK_CONFIG"
fi
if [ ! -f "$BSC_GENESIS" ] && [ -f "$FALLBACK_GENESIS" ]; then
  BSC_GENESIS="$FALLBACK_GENESIS"
fi
if [ ! -f "$PASSWORD_FILE" ] && [ -f "$FALLBACK_PASSWORD" ]; then
  PASSWORD_FILE="$FALLBACK_PASSWORD"
fi

[ -f "$BSC_CONFIG" ] || { echo "ERROR: config.toml not found (looked for $DEFAULT_BSC_CONFIG and $FALLBACK_CONFIG)" >&2; exit 1; }
[ -f "$BSC_GENESIS" ] || { echo "ERROR: genesis.json not found (looked for $DEFAULT_BSC_GENESIS and $FALLBACK_GENESIS)" >&2; exit 1; }

# Init genesis state if geth not exist
DATA_DIR=$(grep -E '^\s*DataDir\s*=' "${BSC_CONFIG}" | head -1 | grep -oP '"\K[^"]+')

GETH_DIR=${DATA_DIR}/geth
if [ ! -d "$GETH_DIR" ]; then
  geth --datadir ${DATA_DIR} init ${BSC_GENESIS}
fi

# Validator / mining support
# Set MINE=true and MINER_ADDR=0x... to enable block production.
# The keystore must be present in ${DATA_DIR}/keystore/
# and the password file at /bsc/config/password.txt
MINE_ARGS=()
if [ "${MINE:-false}" = "true" ]; then
  if [ -z "${MINER_ADDR:-}" ]; then
    echo "ERROR: MINE=true but MINER_ADDR is not set" >&2
    exit 1
  fi
  MINE_ARGS=(
    --mine
    --unlock "${MINER_ADDR}"
    --miner.etherbase "${MINER_ADDR}"
    # --allow-insecure-unlock is required to unlock accounts over the HTTP-RPC
    # interface. Only enabled when MINE=true (i.e. this is a signing validator).
    # Do NOT set MINE=true on internet-facing or production nodes.
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

exec "geth" "--config" "${BSC_CONFIG}" "${MINE_ARGS[@]}" "${NAT_ARGS[@]}" "$@"
