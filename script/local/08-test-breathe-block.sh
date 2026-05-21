#!/usr/bin/env bash
# Test: verify that validators call updateValidatorSetV2 at the expected breathe block interval.
#
# --override.breatheblockinterval is a geth CLI flag that overrides the global
# params.BreatheBlockInterval (default 86400 s).  It cannot be set in config.toml
# because it maps to a package-level variable, not a config struct field.
# Edit BREATHE_INTERVAL below to use a different test interval.
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
# Breathe block interval in seconds (override; default production value: 86400).
# With 3 s block time, 30 s → one breathe block every ~10 blocks.
BREATHE_INTERVAL=30

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GETH="$REPO_ROOT/build/bin/geth"
DATA_DIR="$SCRIPT_DIR/data"
VAL_DIR="$DATA_DIR/validator-1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

RPC_PORT=8545
RPC_URL="http://127.0.0.1:$RPC_PORT"

# ── Helpers ────────────────────────────────────────────────────────────────────
cleanup() {
    local pid_file="$VAL_DIR/geth.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        echo -e "${YELLOW}==> Stopping validator (PID $pid)...${NC}"
        kill "$pid" 2>/dev/null || true
        local i=0
        while kill -0 "$pid" 2>/dev/null && [ $i -lt 10 ]; do
            sleep 1; ((i++))
        done
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$pid_file"
    fi
    echo -e "${YELLOW}==> Removing generated data...${NC}"
    rm -rf "$DATA_DIR" "$SCRIPT_DIR/genesis.json" \
           "$SCRIPT_DIR/config/genesis.json" "$SCRIPT_DIR/config/password.txt"
}

rpc_call() {
    # $1 = JSON body; returns response body or empty string on failure
    curl -sf -X POST "$RPC_URL" \
        -H 'Content-Type: application/json' \
        -d "$1" 2>/dev/null || true
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
if [ ! -x "$GETH" ]; then
    echo -e "${RED}Error: geth binary not found at $GETH${NC}"
    echo "Run 'make geth' from the repo root first."
    exit 1
fi

# ── Step 1: Setup ──────────────────────────────────────────────────────────────
if [ ! -d "$VAL_DIR" ]; then
    echo -e "${YELLOW}==> Running 01-setup.sh (1 validator)...${NC}"
    "$SCRIPT_DIR/01-setup.sh" 1
else
    echo -e "${GREEN}==> Setup already done, reusing existing keys.${NC}"
fi

VAL_ADDR=$(cat "$VAL_DIR/address.txt")
echo "  Validator address: $VAL_ADDR"

# ── Step 2: Start validator-1 with breathe block override ─────────────────────
echo ""
echo -e "${YELLOW}==> Starting validator-1 (breatheBlockInterval=${BREATHE_INTERVAL}s)...${NC}"

nohup "$GETH" \
    --datadir "$VAL_DIR" \
    --networkid 7140 \
    --port 30303 \
    --http \
    --http.addr "127.0.0.1" \
    --http.port $RPC_PORT \
    --http.api "eth,net,web3,debug,parlia,admin,personal" \
    --http.corsdomain "*" \
    --nat extip:127.0.0.1 \
    --maxpeers 0 \
    --mine \
    --unlock "$VAL_ADDR" \
    --password "$VAL_DIR/password.txt" \
    --miner.etherbase "$VAL_ADDR" \
    --allow-insecure-unlock \
    --syncmode "full" \
    --gcmode "archive" \
    --verbosity 3 \
    --override.breatheblockinterval "$BREATHE_INTERVAL" \
    > "$VAL_DIR/geth.log" 2>&1 &

GETH_PID=$!
echo "$GETH_PID" > "$VAL_DIR/geth.pid"
echo "  PID: $GETH_PID"

# ── Step 3: Wait for RPC to become available ──────────────────────────────────
echo -e "${YELLOW}==> Waiting for RPC on $RPC_URL...${NC}"
for i in $(seq 1 30); do
    RESP=$(rpc_call '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}')
    if echo "$RESP" | grep -q '"result"'; then
        echo -e "  ${GREEN}RPC ready (attempt $i).${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}Error: RPC did not become available after 30 s.${NC}"
        echo "Check $VAL_DIR/geth.log for details."
        cleanup
        exit 1
    fi
    sleep 1
done

# ── Step 4: Wait for breathe blocks ───────────────────────────────────────────
WAIT=$((BREATHE_INTERVAL * 2 + 10))
echo ""
echo -e "${YELLOW}==> Waiting ${WAIT}s for breathe blocks (interval=${BREATHE_INTERVAL}s, expect ~every 10 blocks)...${NC}"
sleep "$WAIT"

# ── Step 5: Scan recent blocks ────────────────────────────────────────────────
echo -e "${YELLOW}==> Scanning last 30 blocks for updateValidatorSetV2 system calls...${NC}"

# System tx fingerprint: to=ValidatorContract(0x1000), input has ≥4 bytes (ABI selector).
# Feynman-era blocks call updateValidatorSetV2 on the breathe block only.
SCAN_RESULT=$("$GETH" attach "$VAL_DIR/geth.ipc" --exec \
    'var n=eth.blockNumber,hits=[];for(var i=n;i>n-30&&i>=0;i--){var b=eth.getBlock(i,true);if(b&&b.transactions.some(function(tx){return tx.to&&tx.to.toLowerCase()==="0x0000000000000000000000000000000000001000"&&tx.input&&tx.input.length>10;}))hits.push("#"+i+"@ts="+b.timestamp);}hits.join(",")' \
    2>/dev/null | tr -d '"')

# ── Step 6: Report ─────────────────────────────────────────────────────────────
echo ""
if [ -n "$SCAN_RESULT" ]; then
    echo -e "${GREEN}PASS  updateValidatorSetV2 breathe blocks found: ${SCAN_RESULT}${NC}"
    EXIT_CODE=0
else
    TIP_BLOCK=$(rpc_call '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' \
        | grep -o '"result":"0x[^"]*"' | grep -o '0x[^"]*' || echo "?")
    echo -e "${RED}FAIL  no breathe block in last 30 blocks (tip ${TIP_BLOCK}).${NC}"
    echo "  Tip:  check $VAL_DIR/geth.log"
    echo "  Tip:  increase BREATHE_INTERVAL wait factor or check Feynman fork activation"
    EXIT_CODE=1
fi

# ── Step 7: Cleanup ───────────────────────────────────────────────────────────
echo ""
cleanup
echo ""
exit $EXIT_CODE
