#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GETH="$REPO_ROOT/build/bin/geth"
DATA_DIR="$SCRIPT_DIR/data"

# Check if setup was done
if [ ! -d "$DATA_DIR/validator-1" ]; then
    echo -e "${RED}Error: Setup not done. Run ./01-setup.sh first${NC}"
    exit 1
fi

# Count number of validators
NUM_VALIDATORS=$(ls -d "$DATA_DIR"/validator-* 2>/dev/null | wc -l)
if [ "$NUM_VALIDATORS" -eq 0 ]; then
    echo -e "${RED}Error: No validators found. Run ./01-setup.sh first${NC}"
    exit 1
fi

echo -e "${GREEN}=== Starting ${NUM_VALIDATORS}-validator Parlia network ===${NC}"

# Function to start a validator
start_validator() {
    local NUM=$1
    local PORT=$((8544 + NUM))
    local P2P_PORT=$((30302 + NUM))
    local VAL_DIR="$DATA_DIR/validator-$NUM"
    local VAL_ADDR=$(cat "$VAL_DIR/address.txt")

    echo -e "${YELLOW}Starting validator-$NUM...${NC}"
    echo "  Address: $VAL_ADDR"
    echo "  RPC Port: $PORT"
    echo "  P2P Port: $P2P_PORT"
    echo "  Data Dir: $VAL_DIR"

    # Start geth in background
    nohup $GETH \
        --datadir "$VAL_DIR" \
        --networkid 7140 \
        --port $P2P_PORT \
        --http \
        --http.addr "127.0.0.1" \
        --http.port $PORT \
        --http.api "eth,net,web3,debug,parlia,admin,personal" \
        --http.corsdomain "*" \
        --ws \
        --ws.addr "127.0.0.1" \
        --ws.port $((PORT + 1000)) \
        --ws.api "eth,net,web3,debug,parlia,admin,personal" \
        --nat extip:127.0.0.1 \
        --maxpeers 25 \
        --mine \
        --unlock "$VAL_ADDR" \
        --password "$VAL_DIR/password.txt" \
        --miner.etherbase "$VAL_ADDR" \
        --allow-insecure-unlock \
        --syncmode "full" \
        --gcmode "archive" \
        --verbosity 3 \
        > "$VAL_DIR/geth.log" 2>&1 &

    local PID=$!
    echo $PID > "$VAL_DIR/geth.pid"
    echo -e "  ${GREEN}Started with PID: $PID${NC}"

    # Wait a bit before starting next validator
    sleep 2
}

# Start validator 1 (bootnode)
start_validator 1

# Get enode of validator 1 to use as bootnode
echo -e "${YELLOW}Waiting for validator-1 to generate enode...${NC}"
sleep 3

# Extract enode from validator 1
ENODE=""
for i in {1..10}; do
    if [ -S "$DATA_DIR/validator-1/geth.ipc" ]; then
        ENODE=$($GETH attach --exec "admin.nodeInfo.enode" "$DATA_DIR/validator-1/geth.ipc" 2>/dev/null | tr -d '"' || echo "")
        if [ ! -z "$ENODE" ]; then
            break
        fi
    fi
    echo "  Attempt $i/10..."
    sleep 2
done

if [ -z "$ENODE" ]; then
    echo -e "${RED}Warning: Could not get enode from validator-1${NC}"
    echo "Validators will start but may not connect initially"
    BOOTNODE_FLAG=""
else
    # Remove query parameters from enode (e.g., ?discport=0)
    ENODE=$(echo "$ENODE" | sed 's/?.*$//')
    echo -e "${GREEN}Validator-1 enode: $ENODE${NC}"
    BOOTNODE_FLAG="--bootnodes $ENODE"
fi

# Start remaining validators with bootnode
for NUM in $(seq 2 $NUM_VALIDATORS); do
    PORT=$((8544 + NUM))
    P2P_PORT=$((30302 + NUM))
    VAL_DIR="$DATA_DIR/validator-$NUM"
    VAL_ADDR=$(cat "$VAL_DIR/address.txt")

    echo -e "${YELLOW}Starting validator-$NUM...${NC}"
    echo "  Address: $VAL_ADDR"
    echo "  RPC Port: $PORT"
    echo "  P2P Port: $P2P_PORT"

    nohup $GETH \
        --datadir "$VAL_DIR" \
        --networkid 7140 \
        --port $P2P_PORT \
        --http \
        --http.addr "127.0.0.1" \
        --http.port $PORT \
        --http.api "eth,net,web3,debug,parlia,admin,personal" \
        --http.corsdomain "*" \
        --ws \
        --ws.addr "127.0.0.1" \
        --ws.port $((PORT + 1000)) \
        --ws.api "eth,net,web3,debug,parlia,admin,personal" \
        --nat extip:127.0.0.1 \
        $BOOTNODE_FLAG \
        --maxpeers 25 \
        --mine \
        --unlock "$VAL_ADDR" \
        --password "$VAL_DIR/password.txt" \
        --miner.etherbase "$VAL_ADDR" \
        --allow-insecure-unlock \
        --syncmode "full" \
        --gcmode "archive" \
        --verbosity 3 \
        > "$VAL_DIR/geth.log" 2>&1 &

    PID=$!
    echo $PID > "$VAL_DIR/geth.pid"
    echo -e "  ${GREEN}Started with PID: $PID${NC}"

    sleep 2
done

# Wire all validators into a full mesh via admin.addPeer
echo -e "${YELLOW}Connecting validators (full mesh)...${NC}"
ENODES=()
for NUM in $(seq 1 $NUM_VALIDATORS); do
    IPC="$DATA_DIR/validator-$NUM/geth.ipc"
    ENODE=$($GETH attach --exec "admin.nodeInfo.enode" "$IPC" 2>/dev/null \
        | tr -d '"' | sed 's/?.*$//')
    ENODES+=("$ENODE")
done
for i in $(seq 1 $NUM_VALIDATORS); do
    for j in $(seq 1 $NUM_VALIDATORS); do
        [ $i -eq $j ] && continue
        $GETH attach --exec "admin.addPeer(\"${ENODES[$((j-1))]}\") + ''" \
            "$DATA_DIR/validator-$i/geth.ipc" 2>/dev/null >/dev/null
    done
    echo -e "  validator-$i: connected to $(($NUM_VALIDATORS - 1)) peers"
done

echo ""
echo -e "${GREEN}=== All validators started! ===${NC}"
echo ""
echo "Validator endpoints:"
for i in $(seq 1 $NUM_VALIDATORS); do
    PORT=$((8544 + i))
    WS_PORT=$((PORT + 1000))
    echo "  Validator $i: http://127.0.0.1:$PORT (WS: $WS_PORT)"
done
echo ""
echo "Check status with: ./03-check-status.sh"
echo "View logs: tail -f data/validator-1/geth.log"
echo "Attach console: $GETH attach data/validator-1/geth.ipc"
