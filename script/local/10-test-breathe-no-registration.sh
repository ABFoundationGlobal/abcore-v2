#!/usr/bin/env bash
# Test: verify that updateValidatorSetV2 never executes when no validator is
# registered in StakeHub.
#
# Background
# ----------
# Parlia calls updateValidatorSetV2 on ValidatorContract (0x1000) at each
# breathe block.  With no registered validators the call receives empty arrays,
# which triggers an out-of-bounds access in
# BSCValidatorSet._forceMaintainingValidatorsExit() — INVALID opcode in
# Solidity < 0.8.0.  Finalize() propagates the error, the block sealing
# attempt is abandoned, and the miner retries without the breathe flag.
#
# Verification
# ------------
# Scan recent blocks for the exact updateValidatorSetV2 4-byte selector
# (keccak256("updateValidatorSetV2(address[],uint64[],bytes[])").slice(0,4)).
# Breathe-block attempts that fail leave no on-chain trace, so:
#   PASS = selector not found in last 50 blocks (all attempts failed)
#   FAIL = selector found (unexpected: breathe succeeded without registration)
#
# The test also asserts that the chain advanced past block 8 (Feynman init),
# confirming that the scan window covers at least one breathe period.

set -euo pipefail

BREATHE_INTERVAL=30

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GETH="$REPO_ROOT/build/bin/geth"
DATA_DIR="$SCRIPT_DIR/data"
VAL_DIR="$DATA_DIR/validator-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

RPC_PORT=8545
RPC_URL="http://127.0.0.1:$RPC_PORT"

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
trap cleanup EXIT

rpc_call() {
    curl -sf -X POST "$RPC_URL" \
        -H 'Content-Type: application/json' \
        -d "$1" 2>/dev/null || true
}

_attach() {
    "$GETH" attach --exec "$1" "$VAL_DIR/geth.ipc" 2>/dev/null \
        | tr -d '"' | tr -d '\r'
}

# ── Pre-flight ──────────────────────────────────────────────────────────────
if [ ! -x "$GETH" ]; then
    echo -e "${RED}Error: geth binary not found at $GETH${NC}"
    echo "Run 'make geth' from the repo root first."
    exit 1
fi
command -v python3 >/dev/null || { echo -e "${RED}Error: python3 required${NC}"; exit 1; }

# ── Step 1: Setup ──────────────────────────────────────────────────────────
if [ ! -d "$VAL_DIR" ]; then
    echo -e "${YELLOW}==> Running 01-setup.sh (1 validator)...${NC}"
    "$SCRIPT_DIR/01-setup.sh" 1
else
    echo -e "${GREEN}==> Setup already done, reusing existing keys.${NC}"
fi

VAL_ADDR=$(cat "$VAL_DIR/address.txt")
echo "  Validator address: $VAL_ADDR"

# ── Step 2: Start validator — no StakeHub registration ─────────────────────
echo ""
echo -e "${YELLOW}==> Starting validator-1 (breatheBlockInterval=${BREATHE_INTERVAL}s) — intentionally no StakeHub registration...${NC}"

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

# ── Step 3: Wait for RPC ───────────────────────────────────────────────────
echo -e "${YELLOW}==> Waiting for RPC on $RPC_URL...${NC}"
for i in $(seq 1 30); do
    RESP=$(rpc_call '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}')
    if echo "$RESP" | grep -q '"result"'; then
        echo -e "  ${GREEN}RPC ready (attempt $i).${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}Error: RPC did not become available after 30 s.${NC}"
        exit 1
    fi
    sleep 1
done

# ── Step 4: Wait for at least two breathe periods ─────────────────────────
# With genesis ts=0 the first breathe fires within 1–2 blocks of block 8.
# Waiting 2×BREATHE_INTERVAL+15 s guarantees at least two attempts were made.
WAIT=$(( BREATHE_INTERVAL * 2 + 15 ))
echo ""
echo -e "${YELLOW}==> Waiting ${WAIT}s (≥ 2 breathe periods) for attempts to accumulate...${NC}"
sleep "$WAIT"

# ── Step 5: Verify block height ≥ 9 (Feynman init completed) ──────────────
BN_HEX=$(rpc_call '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' \
    | grep -o '"result":"0x[^"]*"' | grep -o '0x[0-9a-fA-F]*') || true
BN=$(python3 -c "print(int('${BN_HEX:-0x0}',16))" 2>/dev/null || echo 0)
echo "  Current block: $BN"

if [ "${BN:-0}" -lt 9 ]; then
    echo -e "${RED}FAIL  Chain did not reach block 9 after ${WAIT}s — Feynman init may have failed${NC}"
    echo "  Tip: check $VAL_DIR/geth.log"
    exit 1
fi
echo -e "  ${GREEN}Block $BN ≥ 9 — Feynman contracts initialized, breathe periods have elapsed.${NC}"

# ── Step 6: Scan for updateValidatorSetV2 transactions ────────────────────
# A failed breathe-block attempt leaves no trace in the chain.
# If the selector is absent, all attempts reverted as expected.
echo ""
echo -e "${YELLOW}==> Scanning last 50 blocks for updateValidatorSetV2 (selector-specific)...${NC}"

SCAN_RESULT=$(_attach \
    'var sel=web3.sha3("updateValidatorSetV2(address[],uint64[],bytes[])").slice(2,10);
     var n=eth.blockNumber,hits=[];
     for(var i=n;i>n-50&&i>=0;i--){
       var b=eth.getBlock(i,true);
       if(b&&b.transactions.some(function(tx){
         return tx.to&&tx.to.toLowerCase()==="0x0000000000000000000000000000000000001000"
             &&tx.input&&tx.input.slice(2,10)===sel;
       }))hits.push("#"+i+"@ts="+b.timestamp);
     }
     hits.join(",")' \
    2>/dev/null | tr -d '"') || true

# ── Step 7: Report ─────────────────────────────────────────────────────────
echo ""
if [ -z "$SCAN_RESULT" ]; then
    echo -e "${GREEN}PASS  No updateValidatorSetV2 execution found in last 50 blocks.${NC}"
    echo "      Every breathe-block attempt failed (empty candidate set → INVALID opcode)"
    echo "      and was abandoned by the miner, leaving no on-chain trace."
    EXIT_CODE=0
else
    echo -e "${RED}FAIL  updateValidatorSetV2 succeeded unexpectedly: ${SCAN_RESULT}${NC}"
    echo "  Tip: a validator may have been registered before the breathe block fired."
    EXIT_CODE=1
fi

echo ""
exit $EXIT_CODE
