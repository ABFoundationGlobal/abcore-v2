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

echo -e "${GREEN}=== Setting up 3-validator Parlia network ===${NC}"

# Check if geth binary exists
if [ ! -f "$GETH" ]; then
    echo -e "${RED}Error: geth binary not found at $GETH${NC}"
    echo "Please run 'make geth' first from $REPO_ROOT"
    exit 1
fi

# Clean up old data if exists
if [ -d "$DATA_DIR" ]; then
    echo -e "${YELLOW}Removing old data directory...${NC}"
    rm -rf "$DATA_DIR"
fi

mkdir -p "$DATA_DIR"

# Generate 3 validator accounts
echo -e "${GREEN}Generating validator accounts...${NC}"

for i in 1 2 3; do
    VAL_DIR="$DATA_DIR/validator-$i"
    mkdir -p "$VAL_DIR"

    echo -e "${YELLOW}Creating validator-$i account...${NC}"

    # Create empty password file
    touch "$VAL_DIR/password.txt"

    # Generate account
    ACCOUNT_OUTPUT=$($GETH account new --datadir "$VAL_DIR" --password "$VAL_DIR/password.txt" 2>&1)

    # Extract address from output
    ADDRESS=$(echo "$ACCOUNT_OUTPUT" | grep -oP 'Public address of the key:\s+\K0x[a-fA-F0-9]{40}' || echo "$ACCOUNT_OUTPUT" | grep -oP '0x[a-fA-F0-9]{40}' | head -1)

    if [ -z "$ADDRESS" ]; then
        echo -e "${RED}Failed to extract address for validator-$i${NC}"
        echo "Output: $ACCOUNT_OUTPUT"
        exit 1
    fi

    echo "$ADDRESS" > "$VAL_DIR/address.txt"
    echo -e "  Address: ${GREEN}$ADDRESS${NC}"
done

# Read validator addresses (remove 0x prefix properly)
VAL1_ADDR=$(cat "$DATA_DIR/validator-1/address.txt" | sed 's/^0x//')
VAL2_ADDR=$(cat "$DATA_DIR/validator-2/address.txt" | sed 's/^0x//')
VAL3_ADDR=$(cat "$DATA_DIR/validator-3/address.txt" | sed 's/^0x//')

# Validate addresses are 40 hex characters
for i in 1 2 3; do
    eval "ADDR=\$VAL${i}_ADDR"
    if [ ${#ADDR} -ne 40 ]; then
        echo -e "${RED}Error: Validator $i address is not 40 characters (got ${#ADDR}): $ADDR${NC}"
        exit 1
    fi
done

echo -e "${GREEN}Validator addresses:${NC}"
echo -e "  Validator 1: ${GREEN}0x$VAL1_ADDR${NC}"
echo -e "  Validator 2: ${GREEN}0x$VAL2_ADDR${NC}"
echo -e "  Validator 3: ${GREEN}0x$VAL3_ADDR${NC}"

# Generate genesis extraData
# Format: 32 bytes vanity + N * 20 bytes validators + 65 bytes seal
# For 3 validators: 32 + 60 + 65 = 157 bytes = 314 hex chars

VANITY="0000000000000000000000000000000000000000000000000000000000000000"
VALIDATORS="${VAL1_ADDR}${VAL2_ADDR}${VAL3_ADDR}"
SEAL="00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"

EXTRA_DATA="0x${VANITY}${VALIDATORS}${SEAL}"

echo -e "${GREEN}Genesis extraData:${NC}"
echo "  $EXTRA_DATA"

# Create genesis.json
echo -e "${GREEN}Creating genesis.json...${NC}"

cat > "$SCRIPT_DIR/genesis.json" <<EOF
{
    "config": {
        "chainId": 7140,
        "homesteadBlock": 0,
        "eip150Block": 0,
        "eip150Hash": "0x0000000000000000000000000000000000000000000000000000000000000000",
        "eip155Block": 0,
        "eip158Block": 0,
        "byzantiumBlock": 0,
        "constantinopleBlock": 0,
        "petersburgBlock": 0,
        "istanbulBlock": 0,
        "muirGlacierBlock": 0,
        "ramanujanBlock": 0,
        "nielsBlock": 0,
        "mirrorSyncBlock": 0,
        "brunoBlock": 0,
        "eulerBlock": 0,
        "gibbsBlock": 0,
        "nanoBlock": 0,
        "moranBlock": 0,
        "planckBlock": 0,
        "lubanBlock": 0,
        "platoBlock": 0,
        "berlinBlock": 0,
        "londonBlock": 0,
        "hertzBlock": 0,
        "hertzfixBlock": 0,
        "shanghaiTime": 0,
        "keplerTime": 0,
        "feynmanTime": 0,
        "feynmanFixTime": 0,
        "cancunTime": 0,
        "haberTime": 0,
        "haberFixTime": 0,
        "bohrTime": 0,
        "pascalTime": 0,
        "pragueTime": 0,
        "parlia": {
            "period": 3,
            "epoch": 200
        }
    },
    "nonce": "0x0",
    "timestamp": "0x0",
    "extraData": "$EXTRA_DATA",
    "gasLimit": "0x2625a00",
    "difficulty": "0x1",
    "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "coinbase": "0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE",
    "alloc": {
        "0x$VAL1_ADDR": {
            "balance": "0x200000000000000000000000000000000000000000000000000000000000000"
        },
        "0x$VAL2_ADDR": {
            "balance": "0x200000000000000000000000000000000000000000000000000000000000000"
        },
        "0x$VAL3_ADDR": {
            "balance": "0x200000000000000000000000000000000000000000000000000000000000000"
        }
    }
}
EOF

echo -e "${GREEN}Genesis file created at: $SCRIPT_DIR/genesis.json${NC}"

# Initialize each validator with genesis
echo -e "${GREEN}Initializing validators with genesis...${NC}"

for i in 1 2 3; do
    VAL_DIR="$DATA_DIR/validator-$i"
    echo -e "${YELLOW}Initializing validator-$i...${NC}"
    $GETH init --datadir "$VAL_DIR" "$SCRIPT_DIR/genesis.json"
done

echo -e "${GREEN}=== Setup complete! ===${NC}"
echo ""
echo "Next steps:"
echo "  1. Start validators: ./02-start-validators.sh"
echo "  2. Check status: ./03-check-status.sh"
echo "  3. Attach to validator: $GETH attach data/validator-1/geth.ipc"
