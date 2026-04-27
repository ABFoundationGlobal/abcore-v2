#!/usr/bin/env bash
# Start the DevNet from scratch (v1 Clique PoA, 5 validators + 1 RPC node).
# Running this script RESETS the chain to block 0.
#
# Usage:
#   ./01-start.sh <v1_image>
#
# Examples:
#   ./01-start.sh ghcr.io/abfoundationglobal/abcore:v1.13.15
#   V1_IMAGE=ghcr.io/abfoundationglobal/abcore:v1.13.15 ./01-start.sh
#
# Environment overrides:
#   DATA_DIR   — node data root (default: ./data)
#   CHAIN_ID   — devnet chain ID (default: 17140)
#   LOG_LEVEL  — geth verbosity 1-5 (default: 3)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

V1_IMAGE="${1:-${V1_IMAGE:-}}"
if [[ -z "$V1_IMAGE" ]]; then
    error "v1 Docker image required."
    echo "Usage: $0 <v1_image>"
    echo "  e.g. $0 ghcr.io/abfoundationglobal/abcore:v1.13.15"
    exit 1
fi

CHAIN_ID="${CHAIN_ID:-17140}"
LOG_LEVEL="${LOG_LEVEL:-3}"
KEYSTORES_DIR="$SCRIPT_DIR/keystores"

# ---------------------------------------------------------------------------
# Pre-flight: verify pre-generated keystores exist
# See keystores/README.md for how they were generated and how to restore.
# ---------------------------------------------------------------------------
section "Checking pre-generated keystores"

for node in "${VALIDATOR_NODES[@]}"; do
    ks="$KEYSTORES_DIR/$node.json"
    addr_file="$KEYSTORES_DIR/$node.address"
    if [[ ! -f "$ks" ]]; then
        error "Keystore not found: $ks"
        error "See keystores/README.md — copy the keystore files to this directory before running."
        exit 1
    fi
    if [[ ! -f "$addr_file" ]]; then
        error "Address file not found: $addr_file"
        exit 1
    fi
    info "  $node → $(cat "$addr_file")"
done

# ---------------------------------------------------------------------------
# Step 0: stop and remove any existing devnet containers + data
# ---------------------------------------------------------------------------
section "Reset: stopping existing containers and wiping data"

for node in "${ALL_NODES[@]}"; do
    stop_node "$node"
done

if [[ -d "$DATA_DIR" ]]; then
    warn "Removing existing data directory: $DATA_DIR"
    # geth init runs as root inside Docker, so chaindata is root-owned.
    # Use a throw-away container to delete it cleanly without requiring sudo.
    docker run --rm -v "$DATA_DIR:/target" --entrypoint sh \
        "$V1_IMAGE" -c "rm -rf /target/*" 2>/dev/null || sudo rm -rf "$DATA_DIR"
    rm -rf "$DATA_DIR"
fi

for node in "${ALL_NODES[@]}"; do
    mkdir -p "$(node_datadir "$node")/keystore"
done

# ---------------------------------------------------------------------------
# Step 1: copy pre-generated keystores into each validator's datadir
# ---------------------------------------------------------------------------
section "Installing validator keystores"

if docker image inspect "$V1_IMAGE" &>/dev/null; then
    info "Image $V1_IMAGE already present locally, skipping pull."
else
    info "Pulling $V1_IMAGE ..."
    docker pull "$V1_IMAGE"
fi

VALIDATOR_ADDRESSES=()

for node in "${VALIDATOR_NODES[@]}"; do
    local_dir="$(node_datadir "$node")"
    addr=$(cat "$KEYSTORES_DIR/$node.address")

    cp "$KEYSTORES_DIR/$node.json" "$local_dir/keystore/$node.json"
    echo "" > "$local_dir/password.txt"   # empty password for devnet
    echo "$addr" > "$local_dir/address.txt"

    VALIDATOR_ADDRESSES+=("$addr")
    info "  $node → $addr"
done

# ---------------------------------------------------------------------------
# Step 2: build genesis.json (Clique PoA)
# ---------------------------------------------------------------------------
section "Building genesis.json"

# Validator addresses must be sorted ascending for Clique extraData
SORTED_ADDRS=$(printf '%s\n' "${VALIDATOR_ADDRESSES[@]}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/^0x//' \
    | sort)

python3 - <<PYEOF
import json

sorted_addrs = """$SORTED_ADDRS""".strip().split()

vanity = "00" * 32
seal   = "00" * 65
extra  = "0x" + vanity + "".join(sorted_addrs) + seal

alloc = {}
for addr in sorted_addrs:
    alloc["0x" + addr] = {"balance": "0x84595161401484a000000"}  # 10000 ETH each

genesis = {
    "config": {
        "chainId": $CHAIN_ID,
        "homesteadBlock": 0,
        "eip150Block": 0,
        "eip155Block": 0,
        "eip158Block": 0,
        "byzantiumBlock": 0,
        "constantinopleBlock": 0,
        "petersburgBlock": 0,
        "istanbulBlock": 0,
        "berlinBlock": 0,
        "clique": {
            "period": 3,
            "epoch": 30000
        }
    },
    "nonce": "0x0",
    "timestamp": "0x0",
    "extraData": extra,
    "gasLimit": "0x1C9C380",
    "difficulty": "0x1",
    "mixHash": "0x" + "00" * 32,
    "coinbase": "0x0000000000000000000000000000000000000000",
    "alloc": alloc
}

with open("$SCRIPT_DIR/genesis.json", "w") as f:
    json.dump(genesis, f, indent=4)

print("  chainId:    $CHAIN_ID")
print("  validators: " + ", ".join("0x" + a for a in sorted_addrs))
print("  extraData:  " + extra[:72] + "...")
print("  genesis.json written")
PYEOF

# ---------------------------------------------------------------------------
# Step 3: initialise each node's chaindata with genesis
# ---------------------------------------------------------------------------
section "Initialising chaindata"

for node in "${ALL_NODES[@]}"; do
    local_dir="$(node_datadir "$node")"
    info "Initialising $node ..."
    docker run --rm \
        -v "$local_dir:/data" \
        -v "$SCRIPT_DIR/genesis.json:/genesis.json:ro" \
        --entrypoint geth \
        "$V1_IMAGE" \
        init --datadir /data /genesis.json \
        2>&1 | grep -E "(ERR|WARN|Fatal)" || true
done

# ---------------------------------------------------------------------------
# Step 4: start all nodes
# ---------------------------------------------------------------------------
section "Starting v1 Clique network"

start_node() {
    local node="$1"
    local image="$2"
    local local_dir rpc_port p2p_port name
    local_dir="$(node_datadir "$node")"
    rpc_port="$(node_rpc_port "$node")"
    p2p_port="$(node_p2p_port "$node")"
    name="$(node_container_name "$node")"

    local extra_flags=()
    if node_is_validator "$node"; then
        local addr
        addr=$(cat "$local_dir/address.txt")
        extra_flags+=(
            "--mine"
            "--unlock" "$addr"
            "--password" "/data/password.txt"
            "--miner.etherbase" "$addr"
            "--allow-insecure-unlock"
        )
    fi

    info "Starting $node (container: $name, RPC :$rpc_port, P2P :$p2p_port) ..."
    docker run -d \
        --name "$name" \
        --restart unless-stopped \
        -v "$local_dir:/data" \
        -p "127.0.0.1:${rpc_port}:8545" \
        -p "${p2p_port}:${p2p_port}/tcp" \
        -p "${p2p_port}:${p2p_port}/udp" \
        --entrypoint geth \
        "$image" \
        --datadir /data \
        --networkid "$CHAIN_ID" \
        --port "$p2p_port" \
        --http \
        --http.addr "0.0.0.0" \
        --http.port 8545 \
        --http.api "eth,net,web3,clique,admin,personal,debug" \
        --http.corsdomain "*" \
        --ws \
        --ws.addr "0.0.0.0" \
        --ws.port 8546 \
        --ws.api "eth,net,web3,clique,admin,personal" \
        --syncmode full \
        --gcmode archive \
        --verbosity "$LOG_LEVEL" \
        --nat "extip:$DOCKER_HOST_IP" \
        "${extra_flags[@]}" \
        > /dev/null
}

# Start val-4 first (single-node server, acts as canary)
start_node val-4 "$V1_IMAGE"
sleep 2

# Start remaining validators
for node in val-0 val-1 val-2 val-3; do
    start_node "$node" "$V1_IMAGE"
    sleep 1
done

# Start RPC node last
start_node rpc-0 "$V1_IMAGE"

# ---------------------------------------------------------------------------
# Step 5: wire full mesh via admin_addPeer
# Collect enode from each node's RPC and call admin_addPeer on all others.
# This is more reliable than static-nodes.json and works without bootnode.
# ---------------------------------------------------------------------------
section "Wiring P2P full mesh"

info "Waiting for all nodes to respond on RPC..."
for node in "${ALL_NODES[@]}"; do
    port="$(node_rpc_port "$node")"
    if ! wait_for_rpc "$port" 30; then
        error "$node RPC did not respond within 30s"
        echo "Check: docker logs $(node_container_name "$node")"
        exit 1
    fi
done

# Collect enodes via admin_nodeInfo.
# Replace the IP with DOCKER_HOST_IP so containers can reach each other via
# the host bridge (containers cannot use 127.0.0.1 to reach host-bound ports).
declare -A ENODES
for node in "${ALL_NODES[@]}"; do
    port="$(node_rpc_port "$node")"
    p2p_port="$(node_p2p_port "$node")"
    raw=$(rpc_call "$port" admin_nodeInfo '[]' \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('enode',''))" 2>/dev/null || echo "")
    # Rewrite IP and port to DOCKER_HOST_IP:p2p_port so containers can reach
    # each other via the host bridge. If the node already reported the correct
    # IP (because --nat extip was set), the sed is a no-op and that's fine.
    enode=$(echo "$raw" | sed -E "s|@[^:]+:[0-9]+(\?.*)?$|@${DOCKER_HOST_IP}:${p2p_port}|")
    if [[ -z "$enode" ]]; then
        warn "  Could not get enode for $node"
    else
        ENODES["$node"]="$enode"
        info "  $node → $enode"
    fi
done

# addPeer: each node connects to all others
for src in "${ALL_NODES[@]}"; do
    src_port="$(node_rpc_port "$src")"
    for dst in "${ALL_NODES[@]}"; do
        [[ "$src" == "$dst" ]] && continue
        dst_enode="${ENODES[$dst]:-}"
        [[ -z "$dst_enode" ]] && continue
        rpc_call "$src_port" admin_addPeer "[\"$dst_enode\"]" > /dev/null
    done
    info "  $src: addPeer sent to $(( ${#ALL_NODES[@]} - 1 )) peers"
done

# ---------------------------------------------------------------------------
# Step 6: health check
# ---------------------------------------------------------------------------
section "Waiting for chain to produce blocks"

RPC_PORT="$(node_rpc_port rpc-0)"

info "Waiting for block > 0 ..."
if ! wait_for_block "$RPC_PORT" 1 120; then
    error "Chain did not produce a block within 120s"
    echo "Check logs: docker logs devnet-val-0"
    exit 1
fi

BLOCK=$(block_number "$RPC_PORT")
info "Chain is producing blocks. Current block: $BLOCK"

echo ""
echo -e "${BLUE}Node status:${NC}"
for node in "${ALL_NODES[@]}"; do
    port="$(node_rpc_port "$node")"
    if wait_for_rpc "$port" 5; then
        bn=$(block_number "$port")
        peers=$(peer_count "$port")
        printf "  %-8s block=%-6s peers=%s\n" "$node" "$bn" "$peers"
    else
        printf "  %-8s %s\n" "$node" "(RPC not ready)"
    fi
done

echo ""
info "DevNet v1 Clique network is running."
echo ""
echo "  RPC endpoint : http://127.0.0.1:8550  (rpc-0)"
echo "  Chain ID     : $CHAIN_ID"
echo "  Genesis hash : $(rpc_call "$RPC_PORT" eth_getBlockByNumber '["0x0",false]' | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('hash','unknown'))" 2>/dev/null)"
echo ""
echo "  Logs         : docker logs devnet-<node>  (e.g. docker logs devnet-val-0)"
echo "  Status       : ./03-status.sh"
echo "  Next upgrade : ./02-upgrade.sh 1 <v2_image>   (Parlia consensus switch)"
