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

# Parse long options manually (bash getopts doesn't support --)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)        IMAGE="$2";        shift 2 ;;
    -n|--network)      NETWORK="$2";      shift 2 ;;
    -m|--mode)         MODE="$2";         shift 2 ;;
    -d|--datadir)      DATADIR="$2";      shift 2 ;;
    -a|--address)      MINER_ADDR="$2";   shift 2 ;;
    -p|--password)     PASSWORD_FILE="$2"; shift 2 ;;
    -e|--external-ip)  EXTERNAL_IP="$2";  shift 2 ;;
    -h|--help)         usage; exit 0 ;;
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

# Build docker run args
DOCKER_ARGS=(
  run -d
  --name "$CONTAINER_NAME"
  -v "${DATADIR}:/data"
  -v "${CONFIG_DIR}/node.toml:/bsc/config/config.toml:ro"
  -v "${CONFIG_DIR}/genesis.json:/bsc/config/genesis.json:ro"
  -p "8545:8545"
  -p "8546:8546"
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
