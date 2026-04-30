#!/usr/bin/env bash
# Shared helpers for devnet scripts.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/data}"

# IP that Docker containers use to reach ports bound on the host.
# On Linux with the default bridge network this is the docker0 gateway (172.17.0.1).
# This is used for --nat extip so containers on THIS machine can reach each other
# via host-bound ports. It is NOT the externally advertised IP for cross-server P2P;
# Jenkins should override DOCKER_HOST_IP with the server's LAN/public IP when wiring
# the multi-machine mesh (e.g. DOCKER_HOST_IP=192.168.1.10 ./start-single.sh ...).
DOCKER_HOST_IP="${DOCKER_HOST_IP:-$(docker network inspect bridge \
    --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo 127.0.0.1)}"

# ---------------------------------------------------------------------------
# Node layout
#   val-0  val-1  val-2  val-3  val-4  rpc-0
# RPC ports: 19545–19550  (chosen to avoid collisions with testnet on 8545/18545/28545)
# P2P ports: 31300–31305
# ---------------------------------------------------------------------------
VALID_NODES=(val-0 val-1 val-2 val-3 val-4 rpc-0)

node_rpc_port() {
    case "$1" in
        val-0) echo 19545 ;;
        val-1) echo 19546 ;;
        val-2) echo 19547 ;;
        val-3) echo 19548 ;;
        val-4) echo 19549 ;;
        rpc-0) echo 19550 ;;
        *) error "unknown node: $1"; return 1 ;;
    esac
}

node_p2p_port() {
    case "$1" in
        val-0) echo 31300 ;;
        val-1) echo 31301 ;;
        val-2) echo 31302 ;;
        val-3) echo 31303 ;;
        val-4) echo 31304 ;;
        rpc-0) echo 31305 ;;
        *) error "unknown node: $1"; return 1 ;;
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

node_is_valid_name() {
    local node="$1" n
    for n in "${VALID_NODES[@]}"; do
        [[ "$n" == "$node" ]] && return 0
    done
    return 1
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
    curl -sf -X POST "http://${DOCKER_HOST_IP}:$port" \
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

# Wait until block number >= min_block, polling every 2s up to timeout_s
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
