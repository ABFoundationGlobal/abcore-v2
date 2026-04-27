#!/usr/bin/env bash
# Shared helpers for devnet scripts.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/data}"

# ---------------------------------------------------------------------------
# Node layout
#   val-0  val-1  val-2  val-3  val-4  rpc-0
# RPC ports: val-N → 8545+N (0→8545 .. 4→8549), rpc-0 → 8550
# P2P ports: val-N → 30300+N,                     rpc-0 → 30305
# ---------------------------------------------------------------------------
ALL_NODES=(val-0 val-1 val-2 val-3 val-4 rpc-0)
VALIDATOR_NODES=(val-0 val-1 val-2 val-3 val-4)

# Rolling upgrade order: val-4 first (single server), then val-0..3, rpc-0 last
UPGRADE_ORDER=(val-4 val-0 val-1 val-2 val-3 rpc-0)

node_rpc_port() {
    case "$1" in
        val-0) echo 8545 ;;
        val-1) echo 8546 ;;
        val-2) echo 8547 ;;
        val-3) echo 8548 ;;
        val-4) echo 8549 ;;
        rpc-0) echo 8550 ;;
    esac
}

node_p2p_port() {
    case "$1" in
        val-0) echo 30300 ;;
        val-1) echo 30301 ;;
        val-2) echo 30302 ;;
        val-3) echo 30303 ;;
        val-4) echo 30304 ;;
        rpc-0) echo 30305 ;;
    esac
}

node_container_name() {
    echo "devnet-$1"
}

node_datadir() {
    echo "$DATA_DIR/$1"
}

node_is_validator() {
    [[ "$1" != "rpc-0" ]]
}

# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------

container_running() {
    docker inspect -f '{{.State.Running}}' "$(node_container_name "$1")" 2>/dev/null | grep -q true
}

container_exists() {
    docker inspect "$(node_container_name "$1")" &>/dev/null
}

stop_node() {
    local node="$1"
    local name
    name="$(node_container_name "$node")"
    if container_exists "$node"; then
        echo -e "  ${YELLOW}Stopping $node (container: $name)...${NC}"
        docker stop "$name" 2>/dev/null || true
        docker rm "$name" 2>/dev/null || true
        echo -e "  ${GREEN}$node stopped${NC}"
    else
        echo -e "  $node: no container found, skipping"
    fi
}

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------

rpc_call() {
    local port="$1"
    local method="$2"
    local params="${3:-[]}"
    curl -sf -X POST "http://127.0.0.1:$port" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" \
        2>/dev/null
}

block_number() {
    local port="$1"
    local hex
    hex=$(rpc_call "$port" eth_blockNumber '[]' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result','0x0'))" 2>/dev/null || echo "0x0")
    echo $(( 16#${hex#0x} ))
}

peer_count() {
    local port="$1"
    local hex
    hex=$(rpc_call "$port" net_peerCount '[]' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result','0x0'))" 2>/dev/null || echo "0x0")
    echo $(( 16#${hex#0x} ))
}

# Wait until block number > threshold, polling every 2s up to timeout_s
wait_for_block() {
    local port="$1"
    local min_block="${2:-1}"
    local timeout_s="${3:-60}"
    local elapsed=0
    while [[ $elapsed -lt $timeout_s ]]; do
        local bn
        bn=$(block_number "$port")
        if [[ $bn -ge $min_block ]]; then
            return 0
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    return 1
}

# Wait for RPC to respond at all
wait_for_rpc() {
    local port="$1"
    local timeout_s="${2:-30}"
    local elapsed=0
    while [[ $elapsed -lt $timeout_s ]]; do
        if rpc_call "$port" eth_blockNumber '[]' &>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done
    return 1
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BLUE}===${NC} $* ${BLUE}===${NC}"; }
