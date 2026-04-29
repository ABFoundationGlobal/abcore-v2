#!/usr/bin/env bash
# Generate genesis.json for the DevNet (Clique PoA, 5 validators).
# Run this once on the control machine; scp the output to each server.
#
# Usage:
#   ./generate-genesis.sh
#
# Reads validator addresses from keystores/val-{0..4}.address by default.
# Override with VAL_ADDRESSES (comma-separated):
#   VAL_ADDRESSES="0xAA...,0xBB...,0xCC...,0xDD...,0xEE..." ./generate-genesis.sh
#
# Environment overrides:
#   CHAIN_ID       — devnet chain ID (default: 17140)
#   GENESIS_OUT    — output path (default: ./genesis.json)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Inline only the logging helpers needed here — avoids sourcing lib.sh which
# unconditionally runs `docker network inspect` for DOCKER_HOST_IP detection.
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BLUE}===${NC} $* ${BLUE}===${NC}"; }

CHAIN_ID="${CHAIN_ID:-17140}"
GENESIS_OUT="${GENESIS_OUT:-$SCRIPT_DIR/genesis.json}"
KEYSTORES_DIR="$SCRIPT_DIR/keystores"

# ---------------------------------------------------------------------------
# Collect validator addresses
# ---------------------------------------------------------------------------
VALIDATOR_ADDRESSES=()

if [[ -n "${VAL_ADDRESSES:-}" ]]; then
    IFS=',' read -ra VALIDATOR_ADDRESSES <<< "$VAL_ADDRESSES"
    info "Using VAL_ADDRESSES from environment (${#VALIDATOR_ADDRESSES[@]} entries)"
else
    for node in val-0 val-1 val-2 val-3 val-4; do
        addr_file="$KEYSTORES_DIR/$node.address"
        if [[ ! -f "$addr_file" ]]; then
            error "Address file not found: $addr_file"
            error "Either provide VAL_ADDRESSES env var or ensure keystores/val-N.address files exist."
            exit 1
        fi
        addr=$(cat "$addr_file")
        VALIDATOR_ADDRESSES+=("$addr")
        info "  $node → $addr"
    done
fi

if [[ ${#VALIDATOR_ADDRESSES[@]} -eq 0 ]]; then
    error "No validator addresses found."
    exit 1
fi

# Validate: each address must be 0x + 40 hex chars
for addr in "${VALIDATOR_ADDRESSES[@]}"; do
    clean=$(echo "$addr" | tr -d '[:space:]')
    if ! echo "$clean" | grep -qiE '^0x[0-9a-f]{40}$'; then
        error "Invalid address: '$addr' (expected 0x + 40 hex chars)"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Generate genesis.json
# ---------------------------------------------------------------------------
section "Generating genesis.json"

SORTED_ADDRS=$(printf '%s\n' "${VALIDATOR_ADDRESSES[@]}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/^0x//' \
    | sort)

ADDR_COUNT=$(echo "$SORTED_ADDRS" | wc -l | tr -d ' ')

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

with open("$GENESIS_OUT", "w") as f:
    json.dump(genesis, f, indent=4)

print("  chainId:     $CHAIN_ID")
print("  validators:  " + str(len(sorted_addrs)))
for a in sorted_addrs:
    print("    0x" + a)
print("  extraData:   " + extra[:72] + "...")
print("  output:      $GENESIS_OUT")
PYEOF

info "genesis.json written to: $GENESIS_OUT"
echo ""
echo "Next: scp $GENESIS_OUT to each server, then run start-single.sh with GENESIS_FILE pointing to it."
