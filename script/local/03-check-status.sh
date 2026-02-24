#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GETH="$REPO_ROOT/build/bin/geth"
DATA_DIR="$SCRIPT_DIR/data"

# Count number of validators
NUM_VALIDATORS=$(ls -d "$DATA_DIR"/validator-* 2>/dev/null | wc -l)
if [ "$NUM_VALIDATORS" -eq 0 ]; then
    echo -e "${RED}Error: No validators found. Run ./01-setup.sh first${NC}"
    exit 1
fi

echo -e "${BLUE}=== Parlia Network Status ===${NC}"
echo ""

# Check each validator
for i in $(seq 1 $NUM_VALIDATORS); do
    VAL_DIR="$DATA_DIR/validator-$i"
    PORT=$((8544 + i))

    echo -e "${YELLOW}Validator $i:${NC}"

    # Check if PID file exists
    if [ ! -f "$VAL_DIR/geth.pid" ]; then
        echo -e "  Status: ${RED}NOT RUNNING (no PID file)${NC}"
        echo ""
        continue
    fi

    PID=$(cat "$VAL_DIR/geth.pid")

    # Check if process is running
    if ! ps -p $PID > /dev/null 2>&1; then
        echo -e "  Status: ${RED}NOT RUNNING (PID $PID not found)${NC}"
        echo ""
        continue
    fi

    echo -e "  Status: ${GREEN}RUNNING (PID: $PID)${NC}"
    echo "  RPC: http://127.0.0.1:$PORT"

    # Try to get block number via RPC
    if command -v curl > /dev/null 2>&1; then
        BLOCK=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://127.0.0.1:$PORT 2>/dev/null | grep -oP '"result":"\K0x[0-9a-fA-F]+' || echo "")

        if [ ! -z "$BLOCK" ]; then
            BLOCK_DEC=$((16#${BLOCK#0x}))
            echo "  Block: $BLOCK_DEC ($BLOCK)"
        else
            echo "  Block: Unable to query (RPC may not be ready yet)"
        fi

        # Get peer count
        PEERS=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
            http://127.0.0.1:$PORT 2>/dev/null | grep -oP '"result":"\K0x[0-9a-fA-F]+' || echo "")

        if [ ! -z "$PEERS" ]; then
            PEERS_DEC=$((16#${PEERS#0x}))
            echo "  Peers: $PEERS_DEC"
        fi
    fi

    # Check if IPC is available
    if [ -S "$VAL_DIR/geth.ipc" ]; then
        echo -e "  IPC: ${GREEN}Available${NC}"

        # Get additional info via IPC if available
        if [ -x "$GETH" ]; then
            MINING=$($GETH attach --exec "eth.mining" "$VAL_DIR/geth.ipc" 2>/dev/null || echo "")
            if [ "$MINING" = "true" ]; then
                echo -e "  Mining: ${GREEN}ACTIVE${NC}"
            elif [ "$MINING" = "false" ]; then
                echo -e "  Mining: ${YELLOW}INACTIVE${NC}"
            fi

            SYNCING=$($GETH attach --exec "eth.syncing" "$VAL_DIR/geth.ipc" 2>/dev/null || echo "")
            if [ "$SYNCING" = "false" ]; then
                echo -e "  Sync: ${GREEN}SYNCED${NC}"
            else
                echo -e "  Sync: ${YELLOW}SYNCING${NC}"
            fi
        fi
    else
        echo -e "  IPC: ${RED}Not available${NC}"
    fi

    echo ""
done

# Show recent logs
echo -e "${BLUE}=== Recent Logs (last 5 lines each) ===${NC}"
echo ""

for i in $(seq 1 $NUM_VALIDATORS); do
    VAL_DIR="$DATA_DIR/validator-$i"
    if [ -f "$VAL_DIR/geth.log" ]; then
        echo -e "${YELLOW}Validator $i:${NC}"
        tail -n 5 "$VAL_DIR/geth.log" | sed 's/^/  /'
        echo ""
    fi
done

echo -e "${BLUE}=== Commands ===${NC}"
echo "  View full logs: tail -f data/validator-1/geth.log"
echo "  Attach console: $GETH attach data/validator-1/geth.ipc"
echo "  Stop all: ./04-stop-validators.sh"
