#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

echo -e "${YELLOW}=== Stopping validators ===${NC}"

for i in 1 2 3; do
    VAL_DIR="$DATA_DIR/validator-$i"

    if [ ! -f "$VAL_DIR/geth.pid" ]; then
        echo -e "Validator $i: ${YELLOW}No PID file found${NC}"
        continue
    fi

    PID=$(cat "$VAL_DIR/geth.pid")

    if ! ps -p $PID > /dev/null 2>&1; then
        echo -e "Validator $i: ${YELLOW}Not running (PID $PID)${NC}"
        rm -f "$VAL_DIR/geth.pid"
        continue
    fi

    echo -e "Validator $i: Stopping PID $PID..."
    kill $PID 2>/dev/null || true

    # Wait for process to stop (max 10 seconds)
    for j in {1..10}; do
        if ! ps -p $PID > /dev/null 2>&1; then
            echo -e "Validator $i: ${GREEN}Stopped${NC}"
            rm -f "$VAL_DIR/geth.pid"
            break
        fi
        sleep 1
    done

    # Force kill if still running
    if ps -p $PID > /dev/null 2>&1; then
        echo -e "Validator $i: Force killing..."
        kill -9 $PID 2>/dev/null || true
        rm -f "$VAL_DIR/geth.pid"
        echo -e "Validator $i: ${GREEN}Force stopped${NC}"
    fi
done

echo ""
echo -e "${GREEN}=== All validators stopped ===${NC}"
