#!/usr/bin/env bash
# Upgrade one or more DevNet nodes on the current machine to a new image.
# This is one step in the rolling upgrade sequence coordinated by Jenkins.
#
# Usage:
#   ./upgrade-single.sh <step> <node...> <image>
#
# Steps:
#   1  v1 → v2 0.2.x  (Parlia consensus switch, block-height fork)
#   2  v2 0.2.x → 0.3.0  (London + 13 BSC block forks)
#   3  v2 0.3.0 → 0.4.0  (Shanghai + Feynman, timestamp fork)
#   4  v2 0.4.0 → 0.5.0  (Cancun, timestamp fork)
#   5  v2 0.5.0 → 0.6.0  (Prague + Lorentz + Maxwell, timestamp fork)
#
# Examples:
#   ./upgrade-single.sh 1 val-4 ghcr.io/abfoundationglobal/abcore-v2:v0.2.0        # server-3
#   ./upgrade-single.sh 1 val-0 val-1 ghcr.io/abfoundationglobal/abcore-v2:v0.2.0  # server-1
#   ./upgrade-single.sh 3 rpc-0 ghcr.io/abfoundationglobal/abcore-v2:v0.4.0        # server-4
#
# Optional environment variables:
#   DATA_DIR        — node data root (default: ./data)
#   CHAIN_ID        — devnet chain ID (default: 17140)
#   LOG_LEVEL       — geth verbosity 1-5 (default: 3)
#   RESTART_WAIT    — seconds to wait after starting each node (default: 10)
#   BLOCK_WAIT      — extra blocks to wait after restart (default: 2)
#   DOCKER_HOST_IP  — IP containers use to reach host ports (default: auto-detected)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Parse arguments: <step> <node...> <image>
# ---------------------------------------------------------------------------
if [[ $# -lt 3 ]]; then
    error "Usage: $0 <step 1-5> <node...> <image>"
    echo ""
    echo "  Step 1: v1 → v2 0.2.x  (Parlia consensus switch)"
    echo "  Step 2: → v0.3.0        (London + 13 BSC block forks)"
    echo "  Step 3: → v0.4.0        (Shanghai + Feynman)"
    echo "  Step 4: → v0.5.0        (Cancun)"
    echo "  Step 5: → v0.6.0        (Prague + Lorentz + Maxwell)"
    exit 1
fi

STEP="$1"
shift
NEW_IMAGE="${@: -1}"
NODES=("${@:1:$(( $# - 1 ))}")

if ! [[ "$STEP" =~ ^[1-5]$ ]]; then
    error "Step must be 1-5, got: $STEP"
    exit 1
fi

for node in "${NODES[@]}"; do
    if ! node_is_valid_name "$node"; then
        error "Unknown node name: '$node'. Valid names: ${VALID_NODES[*]}"
        exit 1
    fi
done

CHAIN_ID="${CHAIN_ID:-17140}"
LOG_LEVEL="${LOG_LEVEL:-3}"
RESTART_WAIT="${RESTART_WAIT:-10}"
BLOCK_WAIT="${BLOCK_WAIT:-2}"

# ---------------------------------------------------------------------------
# Step-specific info
# ---------------------------------------------------------------------------
case "$STEP" in
    1) STEP_DESC="v1 → v2 0.2.x: Parlia consensus switch (block-height fork)"
       FORK_TYPE="block_height" ;;
    2) STEP_DESC="v2 0.2.x → v0.3.0: London + 13 BSC block forks"
       FORK_TYPE="block_height" ;;
    3) STEP_DESC="v2 0.3.0 → v0.4.0: Shanghai + Kepler + Feynman + FeynmanFix"
       FORK_TYPE="timestamp" ;;
    4) STEP_DESC="v2 0.4.0 → v0.5.0: Cancun + Haber + HaberFix"
       FORK_TYPE="timestamp" ;;
    5) STEP_DESC="v2 0.5.0 → v0.6.0: Prague + Pascal + Lorentz + Maxwell"
       FORK_TYPE="timestamp" ;;
esac

section "Upgrade step $STEP: $STEP_DESC"
echo "  Nodes : ${NODES[*]}"
echo "  Image : $NEW_IMAGE"
echo ""

# ---------------------------------------------------------------------------
# Timestamp fork warning
# ---------------------------------------------------------------------------
if [[ "$FORK_TYPE" == "timestamp" ]]; then
    warn "This is a TIMESTAMP fork. The activation timestamp T is hardcoded in the binary."
    warn "Verify that T is at least 48 hours in the future before distributing the binary."
    warn "All nodes across all servers must be upgraded before T arrives."
    echo ""
fi

# ---------------------------------------------------------------------------
# Step 3 (Feynman) special reminder
# ---------------------------------------------------------------------------
if [[ "$STEP" == "3" ]]; then
    warn "STEP 3 — FEYNMAN: after all nodes are upgraded and T3 activates,"
    warn "each validator must call StakeHub.createValidator() within ~10 minutes"
    warn "(before the first breathe block). Jenkins should handle this centrally."
    echo ""
fi

# ---------------------------------------------------------------------------
# Pull new image
# ---------------------------------------------------------------------------
if docker image inspect "$NEW_IMAGE" &>/dev/null; then
    info "Image $NEW_IMAGE already present locally, skipping pull."
else
    info "Pulling $NEW_IMAGE ..."
    docker pull "$NEW_IMAGE"
fi

# ---------------------------------------------------------------------------
# Restart each node with the new image
# ---------------------------------------------------------------------------
section "Restarting nodes"

for node in "${NODES[@]}"; do
    local_dir="$(node_datadir "$node")"
    rpc_port="$(node_rpc_port "$node")"
    p2p_port="$(node_p2p_port "$node")"
    name="$(node_container_name "$node")"

    info "--- Upgrading $node ---"

    if container_exists "$node"; then
        info "  Stopping $name ..."
        docker stop "$name"
        docker rm "$name"
    fi

    local_extra_flags=()
    if node_is_validator "$node"; then
        addr=$(cat "$local_dir/address.txt")
        local_extra_flags+=(
            "--mine"
            "--unlock" "$addr"
            "--password" "/data/password.txt"
            "--miner.etherbase" "$addr"
            "--allow-insecure-unlock"
        )
    fi

    info "  Starting $name with new image ..."
    docker run -d \
        --name "$name" \
        --restart unless-stopped \
        -v "$local_dir:/data" \
        -p "127.0.0.1:${rpc_port}:8545" \
        -p "${p2p_port}:${p2p_port}/tcp" \
        -p "${p2p_port}:${p2p_port}/udp" \
        --entrypoint geth \
        "$NEW_IMAGE" \
        --datadir /data \
        --networkid "$CHAIN_ID" \
        --port "$p2p_port" \
        --http \
        --http.addr "0.0.0.0" \
        --http.port 8545 \
        --http.api "eth,net,web3,parlia,clique,admin,personal,debug" \
        --http.corsdomain "*" \
        --ws \
        --ws.addr "0.0.0.0" \
        --ws.port 8546 \
        --ws.api "eth,net,web3,parlia,clique,admin,personal" \
        --syncmode full \
        --gcmode archive \
        --verbosity "$LOG_LEVEL" \
        --nat "extip:$DOCKER_HOST_IP" \
        "${local_extra_flags[@]}" \
        > /dev/null

    info "  Waiting for $node RPC ..."
    if ! wait_for_rpc "$rpc_port" 30; then
        error "  $node RPC did not respond within 30s"
        echo "  Check: docker logs $name"
        exit 1
    fi

    before_block=$(block_number "$rpc_port")
    target=$(( before_block + BLOCK_WAIT ))
    info "  Waiting for $node to reach block $target ..."
    if ! wait_for_block "$rpc_port" "$target" 60; then
        warn "  $node did not reach block $target within 60s (may still be syncing)"
    fi

    peers=$(peer_count "$rpc_port")
    bn=$(block_number "$rpc_port")
    info "  $node ready: block=$bn peers=$peers"

    if [[ "$peers" -eq 0 ]]; then
        warn "  $node has 0 peers. Jenkins should re-wire P2P mesh after all nodes are upgraded."
    fi

    echo ""
    sleep "$RESTART_WAIT"
done

# ---------------------------------------------------------------------------
# Post-upgrade status for nodes on this machine
# ---------------------------------------------------------------------------
section "Status after upgrade step $STEP"

printf "%-10s %-8s %-8s %s\n" "NODE" "BLOCK" "PEERS" "IMAGE"
printf "%-10s %-8s %-8s %s\n" "----" "-----" "-----" "-----"
for node in "${NODES[@]}"; do
    rpc_port="$(node_rpc_port "$node")"
    if wait_for_rpc "$rpc_port" 5; then
        bn=$(block_number "$rpc_port")
        peers=$(peer_count "$rpc_port")
        img=$(docker inspect --format '{{.Config.Image}}' "$(node_container_name "$node")" 2>/dev/null | sed 's|.*/||' || echo "unknown")
        printf "%-10s %-8s %-8s %s\n" "$node" "$bn" "$peers" "$img"
    else
        printf "%-10s %s\n" "$node" "(RPC not ready)"
    fi
done

echo ""
info "Upgrade step $STEP complete on this machine: ${NODES[*]}"
echo ""

# Step-specific next-action hints
case "$STEP" in
    1)
        echo "After ALL servers complete step 1:"
        echo "  1. Verify fork block activated: cast rpc eth_getBlockByNumber <fork_block_hex> false --rpc-url http://<rpc-server>:19550"
        echo "  2. Check system contracts: cast code 0x0000000000000000000000000000000000001000 --rpc-url ..."
        echo "  3. Observe 2-3 Parlia epochs before proceeding to step 2."
        echo "  4. Run snapshot restore drill on val-4."
        ;;
    2)
        echo "After ALL servers complete step 2:"
        echo "  1. Verify baseFeePerGas > 0 after fork block."
        echo "  2. Verify Luban extraData length = 876 on first epoch block after fork."
        echo "  3. Observe ≥48h before proceeding to step 3."
        ;;
    3)
        echo "After ALL servers complete step 3:"
        echo "  1. After T3 activates, immediately call createValidator for all 5 validators (~10 min window)."
        echo "  2. Verify after first breathe block: getValidators() returns 5 addresses."
        echo "  3. Observe ≥48h before proceeding to step 4."
        ;;
    4)
        echo "After ALL servers complete step 4:"
        echo "  1. Verify blobGasUsed field present in blocks after T4."
        echo "  2. Send a test blob transaction (type-3)."
        echo "  3. Observe ≥48h before proceeding to step 5."
        ;;
    5)
        echo "After ALL servers complete step 5:"
        echo "  1. Verify EIP-7702 set-code transactions work after T5."
        echo "  2. After T5+1d (Lorentz): epoch boundary changes to 500. Monitor validator rotation."
        echo "  3. After T5+7d (Maxwell): epoch boundary changes to 1000. Monitor validator rotation."
        echo "  4. Full observation window: ≥9 days."
        ;;
esac
