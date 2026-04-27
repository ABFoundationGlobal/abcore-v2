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
    rm -rf "$DATA_DIR"
fi

for node in "${ALL_NODES[@]}"; do
    mkdir -p "$(node_datadir "$node")/keystore"
done

# ---------------------------------------------------------------------------
# Step 1: copy pre-generated keystores into each validator's datadir
# ---------------------------------------------------------------------------
section "Installing validator keystores"

info "Pulling $V1_IMAGE ..."
docker pull "$V1_IMAGE"

VALIDATOR_ADDRESSES=()

for node in "${VALIDATOR_NODES[@]}"; do
    local_dir="$(node_datadir "$node")"
    addr=$(cat "$KEYSTORES_DIR/$node.address")

    # Copy keystore file into node's keystore directory
    cp "$KEYSTORES_DIR/$node.json" "$local_dir/keystore/$node.json"
    # Empty password (DevNet only)
    echo "" > "$local_dir/password.txt"
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
        2>&1 | grep -E "^(INFO|WARN|ERRO|err)" || true
done

# ---------------------------------------------------------------------------
# Step 4: write static-nodes.json
# We pre-generate deterministic node keys so enode IDs are stable across
# resets.  Each node gets a fixed nodekey file in its datadir/geth/ folder.
# ---------------------------------------------------------------------------
section "Generating node keys and building static-nodes.json"

# Generate a stable nodekey for each node using docker bootnode tool (if
# available in the image) or openssl fallback.  Store in datadir/geth/nodekey.
for node in "${ALL_NODES[@]}"; do
    local_dir="$(node_datadir "$node")"
    mkdir -p "$local_dir/geth"
    p2p_port="$(node_p2p_port "$node")"

    # Generate nodekey if not already present
    if [[ ! -f "$local_dir/geth/nodekey" ]]; then
        # 32-byte random hex private key
        openssl rand -hex 32 > "$local_dir/geth/nodekey"
    fi

    # Derive enode public key from nodekey using docker bootnode tool.
    # Write the result to a small file so the Python below (which runs in a
    # subshell via command substitution) can read it without needing to
    # inherit a bash associative array.
    enode_id=$(docker run --rm \
        -v "$local_dir/geth/nodekey:/nodekey:ro" \
        --entrypoint bootnode \
        "$V1_IMAGE" \
        -nodekey /nodekey -writeaddress 2>/dev/null || echo "")

    if [[ -z "$enode_id" ]]; then
        warn "  Could not derive enode for $node (bootnode not in image). Static-nodes will be incomplete."
        echo "" > "$local_dir/geth/enode.txt"
    else
        enode="enode://${enode_id}@127.0.0.1:${p2p_port}"
        echo "$enode" > "$local_dir/geth/enode.txt"
        info "  $node → $enode"
    fi
done

# Write static-nodes.json for every node.
# Reads enode.txt files written above — avoids bash associative array
# inheritance issues across the command-substitution subshell.
python3 - <<PYEOF
import json, os

nodes = "$( IFS=' '; echo "${ALL_NODES[*]}" )".split()
data_dir = "$DATA_DIR"

enodes = {}
for node in nodes:
    enode_file = os.path.join(data_dir, node, "geth", "enode.txt")
    if os.path.exists(enode_file):
        enodes[node] = open(enode_file).read().strip()
    else:
        enodes[node] = ""

valid = [e for e in enodes.values() if e]

for node in nodes:
    local_dir = os.path.join(data_dir, node, "geth")
    os.makedirs(local_dir, exist_ok=True)
    own = enodes.get(node, "")
    peers = [e for e in valid if e != own]
    with open(local_dir + "/static-nodes.json", "w") as f:
        json.dump(peers, f, indent=4)

print("  static-nodes.json written for %d nodes (%d valid enodes)" % (len(nodes), len(valid)))
PYEOF

# ---------------------------------------------------------------------------
# Step 5: start all nodes
# ---------------------------------------------------------------------------
section "Starting v1 Clique network"

start_node() {
    local node="$1"
    local image="$2"
    local local_dir
    local_dir="$(node_datadir "$node")"
    local rpc_port p2p_port name
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
        --nat "extip:127.0.0.1" \
        --nodiscover \
        "${extra_flags[@]}" \
        > /dev/null
}

# Start val-4 first (single-node server, acts as canary)
start_node val-4 "$V1_IMAGE"
sleep 3

# Start remaining validators
for node in val-0 val-1 val-2 val-3; do
    start_node "$node" "$V1_IMAGE"
    sleep 2
done

# Start RPC node last
start_node rpc-0 "$V1_IMAGE"

# ---------------------------------------------------------------------------
# Step 6: health check
# ---------------------------------------------------------------------------
section "Waiting for chain to produce blocks"

RPC_PORT="$(node_rpc_port rpc-0)"

info "Waiting for rpc-0 RPC to become available (:$RPC_PORT)..."
if ! wait_for_rpc "$RPC_PORT" 30; then
    error "rpc-0 RPC did not respond within 30s"
    echo "Check logs: docker logs devnet-rpc-0"
    exit 1
fi

info "Waiting for block > 0 ..."
if ! wait_for_block "$RPC_PORT" 1 120; then
    error "Chain did not produce a block within 120s"
    echo "Check logs: docker logs devnet-val-0"
    exit 1
fi

BLOCK=$(block_number "$RPC_PORT")
info "Chain is producing blocks. Current block: $BLOCK"

# Show peer counts
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
