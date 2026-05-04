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
GENESIS_CONTRACTS_JSON="$SCRIPT_DIR/genesis-contracts-dev.json"

# Parse number of validators (default: 1, max: 5)
NUM_VALIDATORS=${1:-1}
if ! [[ "$NUM_VALIDATORS" =~ ^[1-5]$ ]]; then
    echo -e "${RED}Error: Number of validators must be between 1 and 5${NC}"
    echo "Usage: $0 [num_validators]"
    echo "  num_validators: 1-5 (default: 1)"
    exit 1
fi

echo -e "${GREEN}=== Setting up ${NUM_VALIDATORS}-validator Parlia network ===${NC}"

# Check prerequisites
if [ ! -f "$GETH" ]; then
    echo -e "${RED}Error: geth binary not found at $GETH${NC}"
    echo "Please run 'make geth' first from $REPO_ROOT"
    exit 1
fi

if [ ! -f "$GENESIS_CONTRACTS_JSON" ]; then
    echo -e "${RED}Error: genesis-contracts-dev.json not found at $GENESIS_CONTRACTS_JSON${NC}"
    exit 1
fi

# Clean up old data if exists
if [ -d "$DATA_DIR" ]; then
    echo -e "${YELLOW}Removing old data directory...${NC}"
    rm -rf "$DATA_DIR"
fi

mkdir -p "$DATA_DIR"

# Generate validator accounts
echo -e "${GREEN}Generating validator accounts...${NC}"

for i in $(seq 1 $NUM_VALIDATORS); do
    VAL_DIR="$DATA_DIR/validator-$i"
    mkdir -p "$VAL_DIR"

    echo -e "${YELLOW}Creating validator-$i account...${NC}"

    # Create empty password file
    touch "$VAL_DIR/password.txt"

    # Generate account
    ACCOUNT_OUTPUT=$($GETH account new --datadir "$VAL_DIR" --password "$VAL_DIR/password.txt" 2>&1)

    # Extract address from output
    ADDRESS=$(echo "$ACCOUNT_OUTPUT" | grep -Eo '0x[0-9a-fA-F]{40}' | head -1)

    if [ -z "$ADDRESS" ]; then
        echo -e "${RED}Failed to extract address for validator-$i${NC}"
        echo "Output: $ACCOUNT_OUTPUT"
        exit 1
    fi

    echo "$ADDRESS" > "$VAL_DIR/address.txt"
    echo -e "  Address: ${GREEN}$ADDRESS${NC}"
done

# Validate and display addresses
echo -e "${GREEN}Validator addresses:${NC}"
for i in $(seq 1 $NUM_VALIDATORS); do
    ADDR=$(cat "$DATA_DIR/validator-$i/address.txt" | sed 's/^0x//')
    if [ ${#ADDR} -ne 40 ]; then
        echo -e "${RED}Error: Validator $i address is not 40 hex chars (got ${#ADDR}): $ADDR${NC}"
        exit 1
    fi
    echo -e "  Validator $i: ${GREEN}0x$ADDR${NC}"
done

# Build genesis.json using Python:
#   - Take system contract alloc from genesis-dev.json (all 0x1000-0x3000 contracts)
#   - Use pre-Luban extraData format (plain 20-byte addresses, no BLS keys)
#     because lubanBlock > 0, so block 0 is pre-Luban
#   - Inject our validator addresses and ABCore chain config
echo -e "${GREEN}Creating genesis.json...${NC}"

python3 - <<PYEOF
import json, sys

with open("$GENESIS_CONTRACTS_JSON") as f:
    dev = json.load(f)

# Collect our validator addresses
validator_addrs = []
for i in range(1, $NUM_VALIDATORS + 1):
    with open("$DATA_DIR/validator-{}/address.txt".format(i)) as f:
        addr = f.read().strip()
    validator_addrs.append(addr.lower().replace("0x", ""))

# Build pre-Luban extraData: 32B vanity + N*20B addresses + 65B seal
vanity = "00" * 32
seal   = "00" * 65
extra  = "0x" + vanity + "".join(validator_addrs) + seal

# System contract alloc from genesis-dev.json (all non-validator entries)
alloc = {k: v for k, v in dev["alloc"].items()
         if k.startswith("0x0000000000000000000000000000000000") or
            k == "0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE"}

# Add our validators with initial balance
for addr in validator_addrs:
    alloc["0x" + addr] = {"balance": "0x84595161401484a000000"}

genesis = {
    "config": {
        "chainId": 7140,
        "homesteadBlock": 0,
        "eip150Block": 0,
        "eip155Block": 0,
        "eip158Block": 0,
        "byzantiumBlock": 0,
        "constantinopleBlock": 0,
        "petersburgBlock": 0,
        "istanbulBlock": 0,
        "muirGlacierBlock": 0,
        "ramanujanBlock": 0,
        "nielsBlock": 0,
        "mirrorSyncBlock": 1,
        "brunoBlock": 1,
        "eulerBlock": 2,
        "nanoBlock": 3,
        "moranBlock": 3,
        "gibbsBlock": 4,
        "planckBlock": 5,
        "lubanBlock": 6,
        "platoBlock": 7,
        "berlinBlock": 8,
        "londonBlock": 8,
        "hertzBlock": 8,
        "hertzfixBlock": 8,
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
        "lorentzTime": 0,
        "parlia": {"period": 3, "epoch": 200},
        "blobSchedule": dev["config"]["blobSchedule"],
    },
    "nonce": "0x0",
    "timestamp": "0x0",
    "extraData": extra,
    "gasLimit": "0x2625a00",
    "difficulty": "0x1",
    "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "coinbase": "0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE",
    "alloc": alloc,
}

with open("$SCRIPT_DIR/genesis.json", "w") as f:
    json.dump(genesis, f, indent=4)

print("  extraData: " + extra[:80] + "...")
print("  alloc entries: {} ({} system contracts + {} validators)".format(
    len(alloc),
    len(alloc) - $NUM_VALIDATORS,
    $NUM_VALIDATORS,
))
PYEOF

echo -e "${GREEN}Genesis file created at: $SCRIPT_DIR/genesis.json${NC}"

# Initialize each validator with genesis
echo -e "${GREEN}Initializing validators with genesis...${NC}"

for i in $(seq 1 $NUM_VALIDATORS); do
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
