#!/usr/bin/env bash
# Perform a rolling upgrade of the DevNet to a new Docker image.
#
# Usage:
#   ./02-upgrade.sh <step> <image>
#
# Steps:
#   1  v1 → v2 0.2.x  (Parlia consensus switch, block-height fork)
#   2  v2 0.2.x → 0.3.0  (London + 13 BSC block forks)
#   3  v2 0.3.0 → 0.4.0  (Shanghai + Feynman, timestamp fork)
#   4  v2 0.4.0 → 0.5.0  (Cancun, timestamp fork)
#   5  v2 0.5.0 → 0.6.0  (Prague + Lorentz + Maxwell, timestamp fork)
#
# Examples:
#   ./02-upgrade.sh 1 ghcr.io/abfoundationglobal/abcore-v2:v0.2.0
#   ./02-upgrade.sh 3 ghcr.io/abfoundationglobal/abcore-v2:v0.4.0
#
# The script replaces nodes one at a time in the rolling order:
#   val-4 → val-0 → val-1 → val-2 → val-3 → rpc-0
# At most 1 validator is offline at any point (4/5 always active).
#
# Environment overrides:
#   DATA_DIR        — node data root (default: ./data)
#   CHAIN_ID        — devnet chain ID (default: 17140)
#   LOG_LEVEL       — geth verbosity 1-5 (default: 3)
#   RESTART_WAIT    — seconds to wait after starting each node (default: 10)
#   BLOCK_WAIT      — extra blocks to wait before starting next node (default: 2)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

STEP="${1:-}"
NEW_IMAGE="${2:-}"

if [[ -z "$STEP" || -z "$NEW_IMAGE" ]]; then
    error "Usage: $0 <step 1-5> <docker_image>"
    echo ""
    echo "  Step 1: v1 → v2 0.2.x  (Parlia consensus switch)"
    echo "  Step 2: → v0.3.0        (London + 13 BSC block forks)"
    echo "  Step 3: → v0.4.0        (Shanghai + Feynman)"
    echo "  Step 4: → v0.5.0        (Cancun)"
    echo "  Step 5: → v0.6.0        (Prague + Lorentz + Maxwell)"
    exit 1
fi

if ! [[ "$STEP" =~ ^[1-5]$ ]]; then
    error "Step must be 1-5, got: $STEP"
    exit 1
fi

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

section "Upgrade $STEP: $STEP_DESC"
echo "  Image : $NEW_IMAGE"
echo ""

# ---------------------------------------------------------------------------
# Pre-upgrade checks
# ---------------------------------------------------------------------------
section "Pre-upgrade checks"

RPC_PORT="$(node_rpc_port rpc-0)"

# Verify at least rpc-0 is reachable
if ! wait_for_rpc "$RPC_PORT" 10; then
    error "rpc-0 RPC not reachable. Is the network running? (./03-status.sh)"
    exit 1
fi

CURRENT_BLOCK=$(block_number "$RPC_PORT")
info "Current block height: $CURRENT_BLOCK"

# For timestamp forks: the T is baked into the binary at build time.
# Warn the operator to verify the activation timestamp is in the future before proceeding.
if [[ "$FORK_TYPE" == "timestamp" ]]; then
    warn "This is a TIMESTAMP fork. The activation timestamp T is hardcoded in the binary."
    warn "Verify that T is at least 48 hours in the future before distributing the binary."
    warn "All nodes must be upgraded before T arrives."
    echo ""
fi

# Pull new image before starting the rolling upgrade
if docker image inspect "$NEW_IMAGE" &>/dev/null; then
    info "Image $NEW_IMAGE already present locally, skipping pull."
else
    info "Pulling $NEW_IMAGE ..."
    docker pull "$NEW_IMAGE"
fi

# ---------------------------------------------------------------------------
# Step 3 (Feynman) special pre-flight: remind about createValidator
# ---------------------------------------------------------------------------
if [[ "$STEP" == "3" ]]; then
    echo ""
    warn "STEP 3 — FEYNMAN SPECIAL ACTION REQUIRED:"
    warn "After activation, you have ~10 minutes before the first breathe block."
    warn "Each validator must call StakeHub.createValidator() within that window."
    warn "Failing to register ≥3 validators before the first breathe block"
    warn "will remove them from the active set and may halt the chain."
    echo ""
    warn "Use the following command for each validator:"
    echo "  cast send 0x0000000000000000000000000000000000002002 \\"
    echo "    'createValidator(address,bytes,bytes,uint64,(string,string,string,string,string))' \\"
    echo "    <consensus_addr> <vote_addr_bytes> <bls_proof_bytes> <commission_bps> \\"
    echo "    '(<moniker>,,,,' \\"
    echo "    --private-key <operator_key> --rpc-url http://127.0.0.1:8550"
    echo ""
fi

# ---------------------------------------------------------------------------
# Rolling upgrade: replace one node at a time
# ---------------------------------------------------------------------------
section "Rolling upgrade (order: ${UPGRADE_ORDER[*]})"

restart_node() {
    local node="$1"
    local image="$2"
    local local_dir
    local_dir="$(node_datadir "$node")"
    local rpc_port p2p_port name
    rpc_port="$(node_rpc_port "$node")"
    p2p_port="$(node_p2p_port "$node")"
    name="$(node_container_name "$node")"

    info "--- Upgrading $node ---"

    # Stop and remove old container
    if container_exists "$node"; then
        info "  Stopping old container $name ..."
        docker stop "$name"
        docker rm "$name"
    fi

    # Build extra flags for validators
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

    info "  Starting $name with new image ..."
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
        "${extra_flags[@]}" \
        > /dev/null

    # Wait for RPC to come back
    info "  Waiting for $node RPC to respond ..."
    if ! wait_for_rpc "$rpc_port" 30; then
        error "  $node RPC did not respond within 30s"
        echo "  Check: docker logs $name"
        exit 1
    fi

    # Wait a short block window so the node re-syncs with peers
    local before_block
    before_block=$(block_number "$rpc_port")
    local target=$(( before_block + BLOCK_WAIT ))
    info "  Waiting for $node to reach block $target ..."
    if ! wait_for_block "$rpc_port" "$target" 60; then
        warn "  $node did not reach block $target within 60s (may still be syncing)"
    fi

    local peers
    peers=$(peer_count "$rpc_port")
    local bn
    bn=$(block_number "$rpc_port")
    info "  $node ready: block=$bn peers=$peers"

    if [[ "$peers" -eq 0 ]]; then
        warn "  $node has 0 peers. Check static-nodes.json or P2P connectivity."
    fi

    echo ""
    sleep "$RESTART_WAIT"
}

for node in "${UPGRADE_ORDER[@]}"; do
    restart_node "$node" "$NEW_IMAGE"
done

# ---------------------------------------------------------------------------
# Re-wire P2P full mesh after rolling upgrade
# Each restarted node loses its in-memory peer list; re-run addPeer for all.
# ---------------------------------------------------------------------------
section "Re-wiring P2P full mesh"

declare -A ENODES
for node in "${ALL_NODES[@]}"; do
    port="$(node_rpc_port "$node")"
    p2p_port="$(node_p2p_port "$node")"
    raw=$(rpc_call "$port" admin_nodeInfo '[]' \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('enode',''))" 2>/dev/null || echo "")
    enode=$(echo "$raw" | sed -E "s|@[^:]+:[0-9]+(\?.*)?$|@${DOCKER_HOST_IP}:${p2p_port}|")
    if [[ -n "$enode" ]]; then
        ENODES["$node"]="$enode"
    fi
done

for src in "${ALL_NODES[@]}"; do
    src_port="$(node_rpc_port "$src")"
    for dst in "${ALL_NODES[@]}"; do
        [[ "$src" == "$dst" ]] && continue
        dst_enode="${ENODES[$dst]:-}"
        [[ -z "$dst_enode" ]] && continue
        rpc_call "$src_port" admin_addPeer "[\"$dst_enode\"]" > /dev/null
    done
done
info "addPeer sent to all nodes"

# ---------------------------------------------------------------------------
# Post-upgrade status
# ---------------------------------------------------------------------------
section "Post-upgrade status"

echo -e "${BLUE}Node status after upgrade $STEP:${NC}"
for node in "${ALL_NODES[@]}"; do
    port="$(node_rpc_port "$node")"
    if wait_for_rpc "$port" 5; then
        bn=$(block_number "$port")
        peers=$(peer_count "$port")
        img=$(docker inspect --format '{{.Config.Image}}' "$(node_container_name "$node")" 2>/dev/null || echo "unknown")
        printf "  %-8s block=%-6s peers=%-3s image=%s\n" "$node" "$bn" "$peers" "$img"
    else
        printf "  %-8s %s\n" "$node" "(RPC not ready)"
    fi
done

echo ""
info "Rolling upgrade $STEP complete. All nodes running $NEW_IMAGE."
echo ""

# Step-specific next-action hints
case "$STEP" in
    1)
        echo "Next steps for Upgrade 1 (Parlia):"
        echo "  1. Verify fork block activated: eth_getBlockByNumber shows Parlia header fields"
        echo "     cast rpc eth_getBlockByNumber <fork_block_hex> false --rpc-url http://127.0.0.1:8550"
        echo "  2. Check system contracts deployed at fork block:"
        echo "     cast code 0x0000000000000000000000000000000000001000 --rpc-url http://127.0.0.1:8550"
        echo "  3. Observe 2-3 Parlia epochs before proceeding to Upgrade 2."
        echo "  4. Run snapshot restore drill on val-4."
        ;;
    2)
        echo "Next steps for Upgrade 2 (London):"
        echo "  1. Verify baseFeePerGas > 0 after fork block:"
        echo "     cast rpc eth_getBlockByNumber <fork_block_hex> false --rpc-url http://127.0.0.1:8550 | jq .baseFeePerGas"
        echo "  2. Verify Luban extraData length = 876 on first epoch block after fork:"
        echo "     EPOCH=\$(( (M + 199) / 200 * 200 ))"
        echo "     cast rpc eth_getBlockByNumber \$(cast to-hex \$EPOCH) false ... | jq '.extraData | length'"
        echo "  3. Observe ≥48h before proceeding to Upgrade 3."
        ;;
    3)
        echo "Next steps for Upgrade 3 (Feynman):"
        echo "  1. After T3, immediately call createValidator for all 5 validators."
        echo "     You have ~10 minutes before the first breathe block."
        echo "  2. Verify after first breathe block: getValidators() returns 5 addresses."
        echo "  3. Observe ≥48h before proceeding to Upgrade 4."
        ;;
    4)
        echo "Next steps for Upgrade 4 (Cancun):"
        echo "  1. Verify blobGasUsed field present in blocks after T4."
        echo "  2. Send a test blob transaction (type-3)."
        echo "  3. Observe ≥48h before proceeding to Upgrade 5."
        ;;
    5)
        echo "Next steps for Upgrade 5 (Prague + Lorentz + Maxwell):"
        echo "  1. Verify EIP-7702 set-code transactions work after T5."
        echo "  2. After T5+1d (Lorentz): epoch boundary changes to 500. Monitor validator rotation."
        echo "  3. After T5+7d (Maxwell): epoch boundary changes to 1000. Monitor validator rotation."
        echo "  4. Full observation window: ≥9 days (T5 + 7d Maxwell + 2d observe)."
        echo ""
        echo "  DevNet upgrade sequence COMPLETE. Proceed to Testnet once all checks pass."
        ;;
esac
