#!/usr/bin/env bash
# Show status of all DevNet nodes.
#
# Usage:
#   ./03-status.sh
#
# Environment overrides:
#   DATA_DIR  — node data root (default: ./data)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

section "DevNet Node Status"

printf "%-10s %-12s %-8s %-8s %-8s %s\n" "NODE" "CONTAINER" "BLOCK" "PEERS" "MINING" "IMAGE"
printf "%-10s %-12s %-8s %-8s %-8s %s\n" "----" "---------" "-----" "-----" "------" "-----"

for node in "${ALL_NODES[@]}"; do
    name="$(node_container_name "$node")"
    port="$(node_rpc_port "$node")"

    if ! container_exists "$node"; then
        printf "%-10s %-12s %s\n" "$node" "$name" "(container does not exist)"
        continue
    fi

    running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)
    if [[ "$running" != "true" ]]; then
        status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
        printf "%-10s %-12s %s\n" "$node" "$name" "(container $status)"
        continue
    fi

    img=$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null | sed 's|.*/||')

    if wait_for_rpc "$port" 3; then
        bn=$(block_number "$port")
        peers=$(peer_count "$port")

        # Check mining status via eth_mining
        mining_raw=$(rpc_call "$port" eth_mining '[]' | python3 -c "import sys,json; print(json.load(sys.stdin).get('result','?'))" 2>/dev/null || echo "?")
        if [[ "$mining_raw" == "true" ]]; then mining="yes"; else mining="no"; fi

        printf "%-10s %-12s %-8s %-8s %-8s %s\n" "$node" "$name" "$bn" "$peers" "$mining" "$img"
    else
        printf "%-10s %-12s %-8s %-8s %-8s %s\n" "$node" "$name" "RPC?" "-" "-" "$img"
    fi
done

# ---------------------------------------------------------------------------
# Recent log snippets (errors/warnings only)
# ---------------------------------------------------------------------------
echo ""
echo -e "${BLUE}Recent errors/warnings (last 5 per node):${NC}"
for node in "${ALL_NODES[@]}"; do
    name="$(node_container_name "$node")"
    if container_running "$node"; then
        lines=$(docker logs --tail 50 "$name" 2>&1 | grep -iE "err|warn|crit|fatal" | tail -5 || true)
        if [[ -n "$lines" ]]; then
            echo -e "  ${YELLOW}$node:${NC}"
            echo "$lines" | sed 's/^/    /'
        fi
    fi
done

echo ""
echo -e "${BLUE}Useful commands:${NC}"
echo "  Logs (follow)  : docker logs -f devnet-<node>"
echo "  Attach console : docker exec -it devnet-<node> geth attach /data/geth.ipc"
echo "  Stop all       : docker stop \$(docker ps -q --filter name=devnet-)"
echo "  Upgrade        : ./02-upgrade.sh <step 1-5> <image>"
