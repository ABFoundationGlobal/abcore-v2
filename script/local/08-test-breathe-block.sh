#!/usr/bin/env bash
# Test: verify that updateValidatorSetV2 is called at breathe block intervals.
#
# Registers validator-1 with StakeHub before breathe blocks fire — required
# because ValidatorContract.updateValidatorSetV2 rejects an empty validator
# array.  BLS key generation uses the same bls_proof helper as test 09.
#
# --override.breatheblockinterval is a geth CLI flag (not TOML-configurable).
# Edit BREATHE_INTERVAL below to use a different test interval.
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
# Breathe block interval in seconds (override; default production value: 86400).
# With 3 s block time, 60 s → one breathe block every ~20 blocks.
BREATHE_INTERVAL=60

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GETH="$REPO_ROOT/build/bin/geth"
DATA_DIR="$SCRIPT_DIR/data"
VAL_DIR="$DATA_DIR/validator-1"
BLS_PROOF_SRC="$REPO_ROOT/script/test/upgrade-drill/bls_proof/main.go"

STAKEHUB="0x0000000000000000000000000000000000002002"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

RPC_PORT=8545
RPC_URL="http://127.0.0.1:$RPC_PORT"

# ── State ──────────────────────────────────────────────────────────────────────
BLS_TMPDIR=""

# ── Cleanup ────────────────────────────────────────────────────────────────────
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
    if [ "${KEEP_LOG:-0}" = "1" ] && [ -f "$VAL_DIR/geth.log" ]; then
        cp "$VAL_DIR/geth.log" /tmp/08-breathe-block-geth.log 2>/dev/null || true
        echo -e "${YELLOW}==> geth.log saved to /tmp/08-breathe-block-geth.log${NC}"
    fi
    echo -e "${YELLOW}==> Removing generated data...${NC}"
    rm -rf "$DATA_DIR" "$SCRIPT_DIR/genesis.json" \
           "$SCRIPT_DIR/config/genesis.json" "$SCRIPT_DIR/config/password.txt"
    [ -n "$BLS_TMPDIR" ] && rm -rf "$BLS_TMPDIR"
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

_wait_mined() {
    local tx="$1" label="$2"
    for i in $(seq 1 20); do
        sleep 3
        local st
        st=$(_attach "(function(){var r=eth.getTransactionReceipt('${tx}');return r?r.status:'pending';})()")
        case "$st" in
            0x1|1) echo -e "${GREEN}  PASS  $label  (tx=${tx:0:14}…)${NC}"; return 0 ;;
            0x0|0) echo -e "${RED}  FAIL  $label reverted  (tx=${tx:0:14}…)${NC}"; return 1 ;;
        esac
    done
    echo -e "${RED}  FAIL  $label not mined after 60 s  (tx=${tx:0:14}…)${NC}"
    return 1
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
if [ ! -x "$GETH" ]; then
    echo -e "${RED}Error: geth binary not found at $GETH${NC}"
    echo "Run 'make geth' from the repo root first."
    exit 1
fi
if [ ! -f "$BLS_PROOF_SRC" ]; then
    echo -e "${RED}Error: bls_proof tool not found at $BLS_PROOF_SRC${NC}"
    exit 1
fi
command -v python3 >/dev/null || { echo -e "${RED}Error: python3 required${NC}"; exit 1; }
command -v go     >/dev/null || { echo -e "${RED}Error: go toolchain required (for BLS key generation)${NC}"; exit 1; }

# ── Step 1: Setup ──────────────────────────────────────────────────────────────
if [ ! -d "$VAL_DIR" ]; then
    echo -e "${YELLOW}==> Running 01-setup.sh (1 validator)...${NC}"
    "$SCRIPT_DIR/01-setup.sh" 1
else
    echo -e "${GREEN}==> Setup already done, reusing existing keys.${NC}"
fi

VAL_ADDR=$(cat "$VAL_DIR/address.txt")
VAL_ADDR_LOWER=$(echo "$VAL_ADDR" | tr '[:upper:]' '[:lower:]')
echo "  Validator address: $VAL_ADDR"

# ── Step 2: Build bls_proof and generate BLS key ──────────────────────────────
echo ""
echo -e "${YELLOW}==> Building bls_proof and generating BLS key...${NC}"
BLS_TMPDIR=$(mktemp -d)
BLS_PROOF_BIN="$BLS_TMPDIR/bls_proof"
BLS_PW="blspassword"

(cd "$REPO_ROOT" && go build -o "$BLS_PROOF_BIN" "$BLS_PROOF_SRC")

bls_dir="$BLS_TMPDIR/validator-1"
mkdir -p "$bls_dir"
pwfile="$bls_dir/bls-pw.txt"
printf '%s\n' "$BLS_PW" > "$pwfile"

"$GETH" bls account new --datadir "$bls_dir" --blspassword "$pwfile" 2>/dev/null

keystore=$(find "$bls_dir/bls/keystore" -name "keystore-*.json" 2>/dev/null | head -1)
[ -n "$keystore" ] || { echo -e "${RED}No BLS keystore generated${NC}"; exit 1; }

proof_out=$("$BLS_PROOF_BIN" \
    -keystore "$keystore" \
    -password "$BLS_PW" \
    -operator "$VAL_ADDR_LOWER" \
    -chainid 7140)

BLS_PUBKEY=$(echo "$proof_out" | grep '^PUBKEY=' | cut -d= -f2 | tr -d '[:space:]')
BLS_PROOF_HEX=$(echo "$proof_out" | grep '^PROOF=' | cut -d= -f2 | tr -d '[:space:]')

[ ${#BLS_PUBKEY} -eq 96  ] || { echo -e "${RED}Unexpected BLS pubkey length (${#BLS_PUBKEY})${NC}"; exit 1; }
[ ${#BLS_PROOF_HEX} -eq 194 ] || { echo -e "${RED}Unexpected BLS proof length (${#BLS_PROOF_HEX})${NC}"; exit 1; }
echo "  BLS pubkey: ${BLS_PUBKEY:0:12}..."

# ── Step 3: Start validator-1 ─────────────────────────────────────────────────
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

# ── Step 4: Wait for RPC ──────────────────────────────────────────────────────
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
        exit 1
    fi
    sleep 1
done

# ── Step 5: Precompute selectors (IPC ready alongside RPC) ────────────────────
echo ""
echo -e "${YELLOW}==> Precomputing function selectors...${NC}"
CREATE_SEL=""
for i in $(seq 1 20); do
    CREATE_SEL=$(_attach "web3.sha3('createValidator(address,bytes,bytes,(uint64,uint64,uint64),(string,string,string,string))').slice(2,10)") || true
    [ ${#CREATE_SEL} -eq 8 ] && break
    sleep 1
done
[ ${#CREATE_SEL} -eq 8 ] || { echo -e "${RED}IPC not available after 20 s${NC}"; exit 1; }
DEL_SEL=$(_attach  "web3.sha3('delegate(address,bool)').slice(2,10)") || true
LOCK_SEL=$(_attach "web3.sha3('LOCK_AMOUNT()').slice(2,10)") || true
MIN_SEL=$(_attach  "web3.sha3('minSelfDelegationBNB()').slice(2,10)") || true
echo -e "  ${GREEN}Selectors ready.${NC}"

# ── Step 6: Wait for StakeHub to initialize (fires when block 8 is mined) ─────
# initializeFeynmanContract at block 8 calls StakeHub.initialize(), which sets
# minSelfDelegationBNB (a state variable).  LOCK_AMOUNT is a bytecode constant
# so it is always non-zero; polling minSelfDelegationBNB > 0 is the reliable
# signal that initialize() has been called.
echo ""
echo -e "${YELLOW}==> Waiting for StakeHub initialization (minSelfDelegationBNB > 0)...${NC}"
MIN_WEI=0
for i in $(seq 1 60); do
    MIN_RAW=$(_attach "eth.call({to:'${STAKEHUB}',data:'0x${MIN_SEL}'})") || true
    MIN_WEI=$(python3 -c "print(int('${MIN_RAW}'.replace('0x','') or '0',16))" 2>/dev/null || echo 0)
    [ "${MIN_WEI:-0}" != "0" ] && break
    [ $i -eq 60 ] && { echo -e "${RED}StakeHub not initialized after 60 s${NC}"; exit 1; }
    sleep 1
done
LOCK_RAW=$(_attach "eth.call({to:'${STAKEHUB}',data:'0x${LOCK_SEL}'})") || true
LOCK_WEI=$(python3 -c "print(int('${LOCK_RAW}'.replace('0x',''),16))")
TX_VALUE_HEX=$(python3 -c "print(hex(${MIN_WEI}+${LOCK_WEI}))")
echo -e "  ${GREEN}StakeHub ready — LOCK=${LOCK_WEI} wei  minSelfDel=${MIN_WEI} wei${NC}"

# ── Step 7: Register validator-1 — send both txs immediately, then wait ───────
# Build calldata before sending so that createValidator and delegate are both
# in the mempool for the same block.  Even if that block is a breathe block,
# user txs execute before Finalize(), so the validator is registered in time.
echo ""
echo -e "${YELLOW}==> Registering validator-1 in StakeHub (createValidator + delegate)...${NC}"

CALLBODY=$(python3 - <<PY
def to32(n): return n.to_bytes(32,'big').hex()
def enc_bytes(h):
    d=bytes.fromhex(h); sz=len(d); pad=(32-sz%32)%32
    return to32(sz)+h+'00'*pad
def enc_str(s): return enc_bytes(s.encode().hex())

addr_hex='${VAL_ADDR_LOWER#0x}'
pubkey_hex='${BLS_PUBKEY}'
proof_hex='${BLS_PROOF_HEX#0x}'

p_addr='00'*12+addr_hex
vote_enc=enc_bytes(pubkey_hex)
bls_enc=enc_bytes(proof_hex)
commission_enc=to32(10)+to32(100)+to32(5)
mon_enc=enc_str('Val1')
id_enc=enc_str(''); ws_enc=enc_str(''); det_enc=enc_str('')
inner_head=4*32
mon_off=inner_head
id_off=mon_off+len(mon_enc)//2
ws_off=id_off+len(id_enc)//2
det_off=ws_off+len(ws_enc)//2
desc_enc=(to32(mon_off)+to32(id_off)+to32(ws_off)+to32(det_off)
          +mon_enc+id_enc+ws_enc+det_enc)
HEAD=32+32+32+96+32
vote_off=HEAD
bls_off=vote_off+len(vote_enc)//2
desc_off=bls_off+len(bls_enc)//2
head=(p_addr+to32(vote_off)+to32(bls_off)+commission_enc+to32(desc_off))
print(head+vote_enc+bls_enc+desc_enc)
PY
)

PADDED_ADDR=$(printf '%064s' "${VAL_ADDR_LOWER#0x}" | tr ' ' '0')

CREATE_TX=$("$GETH" attach --exec \
    "eth.sendTransaction({from:'${VAL_ADDR_LOWER}',to:'${STAKEHUB}',value:'${TX_VALUE_HEX}',gas:2000000,data:'0x${CREATE_SEL}${CALLBODY}'})" \
    "$VAL_DIR/geth.ipc" 2>/dev/null | tr -d '"')
[[ "$CREATE_TX" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || { echo -e "${RED}createValidator tx rejected (got: '${CREATE_TX}')${NC}"; exit 1; }

DEL_TX=$("$GETH" attach --exec \
    "eth.sendTransaction({from:'${VAL_ADDR_LOWER}',to:'${STAKEHUB}',value:'0xde0b6b3a7640000',gas:300000,data:'0x${DEL_SEL}${PADDED_ADDR}$(printf '%064x' 1)'})" \
    "$VAL_DIR/geth.ipc" 2>/dev/null | tr -d '"')
[[ "$DEL_TX" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || { echo -e "${RED}delegate tx rejected (got: '${DEL_TX}')${NC}"; exit 1; }

_wait_mined "$CREATE_TX" "createValidator"
_wait_mined "$DEL_TX" "delegate"

# ── Step 8: Wait for breathe blocks ───────────────────────────────────────────
WAIT=$((BREATHE_INTERVAL + 10))
echo ""
echo -e "${YELLOW}==> Waiting ${WAIT}s for breathe block (interval=${BREATHE_INTERVAL}s, expect ~every 20 blocks)...${NC}"
sleep "$WAIT"

# ── Step 9: Scan recent blocks ────────────────────────────────────────────────
echo -e "${YELLOW}==> Scanning last 50 blocks for updateValidatorSetV2 system calls...${NC}"

SCAN_RESULT=$("$GETH" attach --exec \
    'var n=eth.blockNumber,hits=[];for(var i=n;i>n-50&&i>=0;i--){var b=eth.getBlock(i,true);if(b&&b.transactions.some(function(tx){return tx.to&&tx.to.toLowerCase()==="0x0000000000000000000000000000000000001000"&&tx.input&&tx.input.length>10;}))hits.push("#"+i+"@ts="+b.timestamp);}hits.join(",")' \
    "$VAL_DIR/geth.ipc" \
    2>/dev/null | tr -d '"') || true

# ── Step 10: Report ────────────────────────────────────────────────────────────
echo ""
if [ -n "$SCAN_RESULT" ]; then
    echo -e "${GREEN}PASS  updateValidatorSetV2 breathe blocks found: ${SCAN_RESULT}${NC}"
    EXIT_CODE=0
else
    TIP_BLOCK=$(rpc_call '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' \
        | grep -o '"result":"0x[^"]*"' | grep -o '0x[^"]*' || echo "?")
    echo -e "${RED}FAIL  no breathe block in last 50 blocks (tip ${TIP_BLOCK}).${NC}"
    echo "  Tip:  check $VAL_DIR/geth.log"
    EXIT_CODE=1
fi

echo ""
exit $EXIT_CODE
