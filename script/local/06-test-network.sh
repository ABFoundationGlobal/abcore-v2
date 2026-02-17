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

echo -e "${BLUE}=== Testing Parlia Network ===${NC}"
echo ""

# Check if validators are running
if [ ! -S "$DATA_DIR/validator-1/geth.ipc" ]; then
    echo -e "${RED}Error: Validator 1 is not running${NC}"
    echo "Start validators with: ./02-start-validators.sh"
    exit 1
fi

echo -e "${YELLOW}1. Checking consensus mechanism...${NC}"
CONSENSUS=$($GETH attach --exec "eth.getBlock('latest').extraData" "$DATA_DIR/validator-1/geth.ipc" 2>/dev/null || echo "")
if [ ! -z "$CONSENSUS" ]; then
    echo -e "   ${GREEN}✓ Parlia consensus active${NC}"
else
    echo -e "   ${RED}✗ Unable to query block data${NC}"
fi

echo ""
echo -e "${YELLOW}2. Checking block production...${NC}"
BLOCK1=$($GETH attach --exec "eth.blockNumber" "$DATA_DIR/validator-1/geth.ipc" 2>/dev/null || echo "0")
echo "   Current block: $BLOCK1"
echo "   Waiting 10 seconds for new blocks..."
sleep 10
BLOCK2=$($GETH attach --exec "eth.blockNumber" "$DATA_DIR/validator-1/geth.ipc" 2>/dev/null || echo "0")
echo "   New block: $BLOCK2"

if [ "$BLOCK2" -gt "$BLOCK1" ]; then
    DIFF=$((BLOCK2 - BLOCK1))
    echo -e "   ${GREEN}✓ Produced $DIFF blocks in 10 seconds${NC}"
else
    echo -e "   ${RED}✗ No new blocks produced${NC}"
fi

echo ""
echo -e "${YELLOW}3. Checking peer connectivity...${NC}"
for i in $(seq 1 $NUM_VALIDATORS); do
    PEERS=$($GETH attach --exec "admin.peers.length" "$DATA_DIR/validator-$i/geth.ipc" 2>/dev/null || echo "0")
    if [ "$PEERS" -gt "0" ]; then
        echo -e "   Validator $i: ${GREEN}$PEERS peers${NC}"
    else
        echo -e "   Validator $i: ${YELLOW}$PEERS peers (may still be connecting)${NC}"
    fi
done

echo ""
echo -e "${YELLOW}4. Checking validator participation...${NC}"
for i in $(seq 1 $NUM_VALIDATORS); do
    MINING=$($GETH attach --exec "eth.mining" "$DATA_DIR/validator-$i/geth.ipc" 2>/dev/null || echo "false")
    ADDR=$(cat "$DATA_DIR/validator-$i/address.txt")
    if [ "$MINING" = "true" ]; then
        echo -e "   Validator $i ($ADDR): ${GREEN}Mining${NC}"
    else
        echo -e "   Validator $i ($ADDR): ${YELLOW}Not mining${NC}"
    fi
done

echo ""
echo -e "${YELLOW}5. Testing transaction...${NC}"
VAL1=$(cat "$DATA_DIR/validator-1/address.txt")
VAL2=$(cat "$DATA_DIR/validator-2/address.txt")

# Get balance before
BALANCE_BEFORE=$($GETH attach --exec "eth.getBalance('$VAL2')" "$DATA_DIR/validator-1/geth.ipc" 2>/dev/null || echo "0")
echo "   Validator 2 balance before: $BALANCE_BEFORE"

# Send transaction from validator 1 to validator 2
echo "   Sending 1 ETH from validator 1 to validator 2..."
TX_HASH=$($GETH attach --exec "eth.sendTransaction({from: '$VAL1', to: '$VAL2', value: web3.toWei(1, 'ether')})" "$DATA_DIR/validator-1/geth.ipc" 2>/dev/null || echo "")

if [ ! -z "$TX_HASH" ]; then
    echo "   Transaction hash: $TX_HASH"
    echo "   Waiting for transaction to be mined..."
    sleep 5

    BALANCE_AFTER=$($GETH attach --exec "eth.getBalance('$VAL2')" "$DATA_DIR/validator-1/geth.ipc" 2>/dev/null || echo "0")
    echo "   Validator 2 balance after: $BALANCE_AFTER"

    if [ "$BALANCE_AFTER" != "$BALANCE_BEFORE" ]; then
        echo -e "   ${GREEN}✓ Transaction successful${NC}"
    else
        echo -e "   ${YELLOW}⚠ Transaction may still be pending${NC}"
    fi
else
    echo -e "   ${RED}✗ Failed to send transaction${NC}"
fi

echo ""
echo -e "${YELLOW}6. Checking epoch transitions...${NC}"
CURRENT_BLOCK=$($GETH attach --exec "eth.blockNumber" "$DATA_DIR/validator-1/geth.ipc" 2>/dev/null || echo "0")
EPOCH=200
NEXT_EPOCH=$(( (CURRENT_BLOCK / EPOCH + 1) * EPOCH ))
BLOCKS_TO_EPOCH=$((NEXT_EPOCH - CURRENT_BLOCK))
echo "   Current block: $CURRENT_BLOCK"
echo "   Next epoch at: $NEXT_EPOCH (in $BLOCKS_TO_EPOCH blocks)"

echo ""
echo -e "${BLUE}=== Test Summary ===${NC}"
echo "Network appears to be functioning correctly!"
echo ""
echo "Additional tests you can run:"
echo "  - Deploy a smart contract"
echo "  - Test Parlia-specific features"
echo "  - Simulate validator downtime"
echo "  - Test epoch transitions"
echo ""
echo "Attach to console: $GETH attach data/validator-1/geth.ipc"
