#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat <<EOF
Usage: $(basename "$0") -i IMAGE [OPTIONS]

Launch an abcore-v2 Docker node.

Required:
  -i, --image IMAGE       Docker image to run (e.g. ghcr.io/org/abcore-v2:v1.0.0)

Options:
  -n, --network NET       testnet|mainnet          (default: testnet)
  -m, --mode MODE         rpc|validator            (default: rpc)
  -d, --datadir PATH      Host data directory      (default: ./data)
  -a, --address ADDR      Validator address        (required for --mode validator)
  -p, --password FILE     Password file path       (required for --mode validator)
  -e, --external-ip IP    Advertise IP for P2P     (sets NAT=extip:IP)
      --public-rpc        Bind RPC/WS to 0.0.0.0  (default: 127.0.0.1 only)
  -h, --help              Show this help
EOF
}

# Defaults
NETWORK="testnet"
MODE="rpc"
DATADIR="$(pwd)/data"
IMAGE=""
MINER_ADDR=""
PASSWORD_FILE=""
EXTERNAL_IP=""
PUBLIC_RPC=false

# Parse long options manually (bash getopts doesn't support --)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      IMAGE="$2"; shift 2 ;;
    -n|--network)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      NETWORK="$2"; shift 2 ;;
    -m|--mode)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      MODE="$2"; shift 2 ;;
    -d|--datadir)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      DATADIR="$2"; shift 2 ;;
    -a|--address)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      MINER_ADDR="$2"; shift 2 ;;
    -p|--password)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      PASSWORD_FILE="$2"; shift 2 ;;
    -e|--external-ip)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      EXTERNAL_IP="$2"; shift 2 ;;
    --public-rpc)    PUBLIC_RPC=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# Validate required args
if [[ -z "$IMAGE" ]]; then
  echo "ERROR: --image is required" >&2
  usage
  exit 1
fi

if [[ "$NETWORK" != "testnet" && "$NETWORK" != "mainnet" ]]; then
  echo "ERROR: --network must be testnet or mainnet" >&2
  exit 1
fi

if [[ "$MODE" != "rpc" && "$MODE" != "validator" ]]; then
  echo "ERROR: --mode must be rpc or validator" >&2
  exit 1
fi

if [[ "$MODE" == "validator" ]]; then
  if [[ -z "$MINER_ADDR" ]]; then
    echo "ERROR: --address is required for validator mode" >&2
    exit 1
  fi
  if [[ -z "$PASSWORD_FILE" ]]; then
    echo "ERROR: --password is required for validator mode" >&2
    exit 1
  fi
  if [[ ! -f "$PASSWORD_FILE" ]]; then
    echo "ERROR: password file not found: $PASSWORD_FILE" >&2
    exit 1
  fi
fi

CONFIG_DIR="$SCRIPT_DIR/configs/$NETWORK"
if [[ ! -d "$CONFIG_DIR" ]]; then
  echo "ERROR: config directory not found: $CONFIG_DIR" >&2
  exit 1
fi

mkdir -p "$DATADIR"

CONTAINER_NAME="abcore-${NETWORK}-${MODE}"

# RPC/WS bind address: localhost by default, 0.0.0.0 only with --public-rpc
RPC_BIND="127.0.0.1"
if [[ "$PUBLIC_RPC" == "true" ]]; then
  RPC_BIND="0.0.0.0"
fi

# Build docker run args
DOCKER_ARGS=(
  run -d
  --name "$CONTAINER_NAME"
  -v "${DATADIR}:/data"
  -v "${CONFIG_DIR}/node.toml:/bsc/config/config.toml:ro"
  -v "${CONFIG_DIR}/genesis.json:/bsc/config/genesis.json:ro"
  -p "${RPC_BIND}:8545:8545"
  -p "${RPC_BIND}:8546:8546"
  -p "33333:33333/tcp"
  -p "33333:33333/udp"
)

if [[ "$MODE" == "validator" ]]; then
  DOCKER_ARGS+=(
    -v "$(realpath "$PASSWORD_FILE"):/bsc/config/password.txt:ro"
    -e "MINE=true"
    -e "MINER_ADDR=${MINER_ADDR}"
  )
fi

if [[ -n "$EXTERNAL_IP" ]]; then
  DOCKER_ARGS+=(-e "NAT=extip:${EXTERNAL_IP}")
fi

DOCKER_ARGS+=("$IMAGE")

echo "Running: docker ${DOCKER_ARGS[*]}"
exec docker "${DOCKER_ARGS[@]}"
