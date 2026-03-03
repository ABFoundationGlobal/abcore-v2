#!/bin/bash
set -e

BSC_CONFIG=${BSC_HOME}/config/config.toml
BSC_GENESIS=${BSC_HOME}/config/genesis.json

# Init genesis state if geth not exist
DATA_DIR=$(cat ${BSC_CONFIG} | grep -A1 '\[Node\]' | grep -oP '\"\K.*?(?=\")')

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
    --allow-insecure-unlock
    --password /bsc/config/password.txt
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

exec "geth" "--config" ${BSC_CONFIG} "${MINE_ARGS[@]}" "${NAT_ARGS[@]}" "$@"
