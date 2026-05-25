#!/usr/bin/env bash
# Test: StakeHub partial registration.
#
# Phase 1: Only validator-1 calls createValidator + delegate.
#          Waits for a breathe block and checks the network stays live,
#          and that StakeHub reports exactly 1 validator in the election set.
#
# Phase 2: Validators 2 and 3 also register.
#          Waits for the next breathe block and checks the network stays live,
#          and that StakeHub now reports 3 validators.
#
# Edit BREATHE_INTERVAL below to change the override (default: 30 s).
# All validators are started with --override.breatheblockinterval $BREATHE_INTERVAL.
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
BREATHE_INTERVAL=30

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GETH="$REPO_ROOT/build/bin/geth"
DATA_DIR="$SCRIPT_DIR/data"
BLS_PROOF_SRC="$REPO_ROOT/script/test/upgrade-drill/bls_proof/main.go"

STAKEHUB="0x0000000000000000000000000000000000002002"
VALCONTRACT="0x0000000000000000000000000000000000001000"

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# ── State ──────────────────────────────────────────────────────────────────────
GETH_PIDS=()
BLS_TMPDIR=""
FAILED=0

pass() { echo -e "${GREEN}  PASS  $*${NC}"; }
fail() { echo -e "${RED}  FAIL  $*${NC}"; FAILED=1; }
log()  { echo -e "${YELLOW}==> $*${NC}"; }

# ── Cleanup ────────────────────────────────────────────────────────────────────
cleanup() {
    if [ ${#GETH_PIDS[@]} -gt 0 ]; then
        log "Stopping validators..."
        for pid in "${GETH_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        for pid in "${GETH_PIDS[@]}"; do
            local i=0
            while kill -0 "$pid" 2>/dev/null && [ $i -lt 8 ]; do sleep 1; ((i++)); done
            kill -9 "$pid" 2>/dev/null || true
        done
    fi
    log "Removing generated data..."
    rm -rf "$DATA_DIR" "$SCRIPT_DIR/genesis.json" \
           "$SCRIPT_DIR/config/genesis.json" "$SCRIPT_DIR/config/password.txt"
    [ -n "$BLS_TMPDIR" ] && rm -rf "$BLS_TMPDIR"
}
trap cleanup EXIT

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

# ── Step 1: Setup 3 validators ─────────────────────────────────────────────────
log "Setting up 3-validator Parlia network..."
"$SCRIPT_DIR/01-setup.sh" 3

# ── Step 2: Build bls_proof binary and generate BLS keys ──────────────────────
log "Building bls_proof tool and generating BLS keys (chain-id=7140)..."
BLS_TMPDIR=$(mktemp -d)
BLS_PROOF_BIN="$BLS_TMPDIR/bls_proof"
BLS_PW="blspassword"

# Build once; reuse for all 3 validators.
(cd "$REPO_ROOT" && go build -o "$BLS_PROOF_BIN" "$BLS_PROOF_SRC")
log "  bls_proof compiled: $BLS_PROOF_BIN"

declare -a BLS_PUBKEY=()
declare -a BLS_PROOF=()

for n in 1 2 3; do
    addr=$(cat "$DATA_DIR/validator-$n/address.txt" | tr '[:upper:]' '[:lower:]')
    bls_dir="$BLS_TMPDIR/validator-$n"
    mkdir -p "$bls_dir"
    pwfile="$bls_dir/bls-pw.txt"
    printf '%s\n' "$BLS_PW" > "$pwfile"

    "$GETH" bls account new \
        --datadir "$bls_dir" \
        --blspassword "$pwfile" \
        2>/dev/null

    keystore=$(find "$bls_dir/bls/keystore" -name "keystore-*.json" 2>/dev/null | head -1)
    [ -n "$keystore" ] || { echo -e "${RED}No BLS keystore for validator-$n${NC}"; exit 1; }

    proof_out=$("$BLS_PROOF_BIN" \
        -keystore "$keystore" \
        -password "$BLS_PW" \
        -operator "$addr" \
        -chainid 7140)

    BLS_PUBKEY[$n]=$(echo "$proof_out" | grep '^PUBKEY=' | cut -d= -f2 | tr -d '[:space:]')
    BLS_PROOF[$n]=$(echo "$proof_out"  | grep '^PROOF='  | cut -d= -f2 | tr -d '[:space:]')

    [ ${#BLS_PUBKEY[$n]} -eq 96  ] || { echo -e "${RED}validator-$n: unexpected BLS pubkey length (${#BLS_PUBKEY[$n]})${NC}"; exit 1; }
    # Proof is 0x-prefixed 192-hex = 194 chars
    [ ${#BLS_PROOF[$n]} -eq 194 ] || { echo -e "${RED}validator-$n: unexpected BLS proof length (${#BLS_PROOF[$n]})${NC}"; exit 1; }

    log "  validator-$n ($addr): pubkey=${BLS_PUBKEY[$n]:0:12}..."
done

# ── Step 3: Start all 3 validators ────────────────────────────────────────────
log "Starting 3 validators (breatheBlockInterval=${BREATHE_INTERVAL}s)..."

_start_validator() {
    local n=$1
    local port=$((8544 + n))
    local p2p=$((30302 + n))
    local vdir="$DATA_DIR/validator-$n"
    local addr
    addr=$(cat "$vdir/address.txt")

    local extra_flags=()
    [ -n "${BOOTNODE:-}" ] && extra_flags+=(--bootnodes "$BOOTNODE")

    nohup "$GETH" \
        --datadir "$vdir" \
        --networkid 7140 \
        --port "$p2p" \
        --http --http.addr "127.0.0.1" --http.port "$port" \
        --http.api "eth,net,web3,debug,parlia,admin,personal" \
        --http.corsdomain "*" \
        --ws --ws.addr "127.0.0.1" --ws.port "$((port + 1000))" \
        --ws.api "eth,net,web3,debug,parlia,admin,personal" \
        --nat extip:127.0.0.1 \
        --maxpeers 10 \
        --mine \
        --unlock "$addr" \
        --password "$vdir/password.txt" \
        --miner.etherbase "$addr" \
        --allow-insecure-unlock \
        --syncmode "full" \
        --gcmode "archive" \
        --verbosity 3 \
        --override.breatheblockinterval "$BREATHE_INTERVAL" \
        ${extra_flags[@]+"${extra_flags[@]}"} \
        > "$vdir/geth.log" 2>&1 &

    local pid=$!
    GETH_PIDS+=("$pid")
    echo "$pid" > "$vdir/geth.pid"
    log "  validator-$n: PID=$pid  RPC=:$port"
}

_start_validator 1
sleep 5

# Extract enode for validators 2 and 3 to use as bootnode.
BOOTNODE=""
for i in $(seq 1 15); do
    if [ -S "$DATA_DIR/validator-1/geth.ipc" ]; then
        BOOTNODE=$("$GETH" attach --exec "admin.nodeInfo.enode" \
            "$DATA_DIR/validator-1/geth.ipc" 2>/dev/null \
            | tr -d '"' | sed 's/?.*$//') && [ -n "$BOOTNODE" ] && break
    fi
    sleep 2
done
[ -n "$BOOTNODE" ] && log "  validator-1 enode: ${BOOTNODE:0:40}..."

for n in 2 3; do
    _start_validator "$n"
    sleep 2
done

# Wire full mesh — retry until all IPC sockets are ready.
log "Wiring full peer mesh..."
ENODES=()
for n in 1 2 3; do
    e=""
    for attempt in $(seq 1 20); do
        e=$("$GETH" attach --exec "admin.nodeInfo.enode" \
            "$DATA_DIR/validator-$n/geth.ipc" 2>/dev/null \
            | tr -d '"' | sed 's/?.*$//') || true
        [ -n "$e" ] && break
        sleep 2
    done
    [ -n "$e" ] || { echo -e "${RED}validator-$n enode not available after 40 s${NC}"; exit 1; }
    ENODES+=("$e")
    log "  validator-$n enode: ${e:0:40}..."
done
for i in 1 2 3; do
    for j in 1 2 3; do
        [ $i -eq $j ] && continue
        "$GETH" attach --exec "admin.addPeer(\"${ENODES[$((j-1))]}\") + ''" \
            "$DATA_DIR/validator-$i/geth.ipc" 2>/dev/null >/dev/null || true
    done
    log "  validator-$i connected to 2 peers"
done

# Wait for all RPC endpoints to respond.
log "Waiting for all 3 RPC endpoints..."
for n in 1 2 3; do
    port=$((8544 + n))
    for i in $(seq 1 30); do
        resp=$(curl -sf -X POST "http://127.0.0.1:$port" \
            -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","method":"eth_blockNumber","id":1}' 2>/dev/null || true)
        echo "$resp" | grep -q '"result"' && break
        [ $i -eq 30 ] && { echo -e "${RED}validator-$n RPC never became ready${NC}"; exit 1; }
        sleep 1
    done
    log "  validator-$n RPC ready"
done

IPC1="$DATA_DIR/validator-1/geth.ipc"

# ── Helpers ────────────────────────────────────────────────────────────────────

# Run a JS snippet on validator-1 via IPC; strip surrounding quotes.
_attach() {
    "$GETH" attach --exec "$1" "$IPC1" 2>/dev/null \
        | tr -d '"' | tr -d '\r'
}

# Wait for a tx hash to be mined (up to 60s); set FAILED on error.
_wait_mined() {
    local tx="$1" label="$2"
    for i in $(seq 1 20); do
        sleep 3
        local st
        st=$(_attach "(function(){var r=eth.getTransactionReceipt('${tx}');return r?r.status:'pending';})()")
        case "$st" in
            0x1|1) pass "$label  (tx=${tx:0:14}…)"; return 0 ;;
            0x0|0) fail "$label reverted  (tx=${tx:0:14}…)"; return 1 ;;
        esac
    done
    fail "$label not mined after 60 s  (tx=${tx:0:14}…)"
    return 1
}

# Return current block number (decimal).
_tip() { _attach "eth.blockNumber" | grep -o '[0-9]*' | head -1; }

# Return 1 if ≥1 breathe block exists in the last $1 blocks (default 25).
_has_breathe() {
    local window="${1:-25}"
    local count
    count=$(_attach \
"(function(){var sel=web3.sha3('updateValidatorSetV2(address[],uint64[],bytes[])').slice(2,10);var n=eth.blockNumber,c=0;for(var i=n;i>n-${window}&&i>=0;i--){
var b=eth.getBlock(i,true);
if(b&&b.transactions.some(function(tx){return tx.to&&tx.to.toLowerCase()==='${VALCONTRACT}'&&tx.input&&tx.input.slice(2,10)===sel;}))c++;}
return c;})()")
    [ "${count:-0}" -gt 0 ]
}

# Count validators with voting power in StakeHub via getValidatorElectionInfo(0,0).
# Return type: (address[], uint256[], bytes[], uint256 totalLength)
# With ABI head = 4×32 bytes, totalLength is the 4th field (bytes 96-127 = hex chars 192-255).
_election_count() {
    local sel
    sel=$(_attach "web3.sha3('getValidatorElectionInfo(uint256,uint256)').slice(2,10)")
    # Build calldata: selector + offset(0) + limit(0)
    local zeros="0000000000000000000000000000000000000000000000000000000000000000"
    local raw
    raw=$(_attach "eth.call({to:'${STAKEHUB}',data:'0x${sel}${zeros}${zeros}'})")
    # Strip 0x prefix and parse totalLength at chars 192-255 (bytes 96-127).
    python3 -c "
d='${raw}'.replace('0x','').replace('\"','')
print(int(d[192:256],16) if len(d)>=256 else 0)
" 2>/dev/null || echo 0
}

# ── Query StakeHub constants (poll until StakeHub.initialize() completes) ─────
# LOCK_AMOUNT is a bytecode constant and is non-zero before initialize().
# minSelfDelegationBNB is a state variable set by initialize() at block 8;
# polling it until non-zero is the reliable signal that StakeHub is ready.
log "Precomputing function selectors..."
CREATE_SEL=$(_attach "web3.sha3('createValidator(address,bytes,bytes,(uint64,uint64,uint64),(string,string,string,string))').slice(2,10)") || true
DEL_SEL=$(_attach  "web3.sha3('delegate(address,bool)').slice(2,10)") || true
LOCK_SEL=$(_attach "web3.sha3('LOCK_AMOUNT()').slice(2,10)") || true
MIN_SEL=$(_attach  "web3.sha3('minSelfDelegationBNB()').slice(2,10)") || true

log "Waiting for StakeHub initialization (minSelfDelegationBNB > 0)..."
MIN_WEI=0
for i in $(seq 1 60); do
    MIN_RAW=$(_attach "eth.call({to:'${STAKEHUB}',data:'0x${MIN_SEL}'})") || true
    MIN_WEI=$(python3 -c "print(int('${MIN_RAW}'.replace('0x','') or '0',16))" 2>/dev/null || echo 0)
    [ "${MIN_WEI:-0}" != "0" ] && break
    [ $i -eq 60 ] && { echo -e "${RED}StakeHub not initialized after 60 s${NC}"; exit 1; }
    sleep 1
done
LOCK_RAW=$(_attach "eth.call({to:'${STAKEHUB}',data:'0x${LOCK_SEL}'})") || true
LOCK_WEI=$(python3 -c "print(int('${LOCK_RAW}'.replace('0x','') or '0',16))" 2>/dev/null || echo 0)
[ "${LOCK_WEI:-0}" != "0" ] || { echo -e "${RED}LOCK_AMOUNT query returned empty — StakeHub may not be deployed${NC}"; exit 1; }
TX_VALUE_HEX=$(python3 -c "print(hex(${MIN_WEI}+${LOCK_WEI}))")
log "  LOCK_AMOUNT:           ${LOCK_WEI} wei"
log "  minSelfDelegationBNB:  ${MIN_WEI} wei"
log "  createValidator value: ${TX_VALUE_HEX}"

# ── ABI-encode createValidator calldata for validator N ───────────────────────
_build_create_calldata() {
    local n=$1
    local addr
    addr=$(cat "$DATA_DIR/validator-$n/address.txt" | tr '[:upper:]' '[:lower:]')
    local addr_hex="${addr#0x}"
    local pubkey_hex="${BLS_PUBKEY[$n]}"
    local proof_hex="${BLS_PROOF[$n]#0x}"

    python3 - <<PY
def to32(n): return n.to_bytes(32,'big').hex()
def enc_bytes(h):
    d=bytes.fromhex(h); sz=len(d); pad=(32-sz%32)%32
    return to32(sz)+h+'00'*pad
def enc_str(s): return enc_bytes(s.encode().hex())

p_addr='00'*12+'${addr_hex}'
n=${n}
vote_enc=enc_bytes('${pubkey_hex}')
bls_enc=enc_bytes('${proof_hex}')
commission_enc=to32(10)+to32(100)+to32(5)
mon_enc=enc_str(f'Val{n}')
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
}

# ── Register validator N with StakeHub (createValidator + delegate) ────────────
_register() {
    local n=$1
    local ipc="$DATA_DIR/validator-$n/geth.ipc"
    local addr
    addr=$(cat "$DATA_DIR/validator-$n/address.txt" | tr '[:upper:]' '[:lower:]')

    log "  Sending createValidator for validator-$n ($addr)..."
    local body
    body=$(_build_create_calldata "$n")
    local calldata="0x${CREATE_SEL}${body}"
    local tx
    tx=$("$GETH" attach --exec \
        "eth.sendTransaction({from:'${addr}',to:'${STAKEHUB}',value:'${TX_VALUE_HEX}',gas:2000000,data:'${calldata}'})" \
        "$ipc" 2>/dev/null | tr -d '"')
    [[ "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]] \
        || { fail "validator-$n createValidator tx rejected (got: '${tx}')"; return 1; }
    _wait_mined "$tx" "validator-$n createValidator" || return 1

    log "  Sending delegate for validator-$n ($addr)..."
    local padded_addr
    padded_addr=$(printf '%064s' "${addr#0x}" | tr ' ' '0')
    local del_calldata="0x${DEL_SEL}${padded_addr}$(printf '%064x' 1)"
    tx=$("$GETH" attach --exec \
        "eth.sendTransaction({from:'${addr}',to:'${STAKEHUB}',value:'0xde0b6b3a7640000',gas:300000,data:'${del_calldata}'})" \
        "$ipc" 2>/dev/null | tr -d '"')
    [[ "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]] \
        || { fail "validator-$n delegate tx rejected (got: '${tx}')"; return 1; }
    _wait_mined "$tx" "validator-$n delegate"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Only validator-1 registers
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════"
echo "  PHASE 1 — validator-1 registers; 2 and 3 do not"
echo "══════════════════════════════════════════════════════"
echo ""

TIP_BEFORE=$(_tip)
log "Tip before phase 1: block #${TIP_BEFORE}"

_register 1

WAIT=$((BREATHE_INTERVAL + 10))
log "Waiting ${WAIT}s for breathe block (interval=${BREATHE_INTERVAL}s)..."
sleep "$WAIT"

TIP_AFTER=$(_tip)
log "Tip after wait: block #${TIP_AFTER}"

# 1a. Network liveness
if [ "${TIP_AFTER:-0}" -gt "${TIP_BEFORE:-0}" ]; then
    pass "Network live after partial registration: #${TIP_BEFORE} → #${TIP_AFTER}"
else
    fail "Network stalled after partial registration"
fi

# 1b. Breathe block fired
if _has_breathe 50; then
    pass "Breathe block fired (updateValidatorSetV2 called)"
else
    fail "No breathe block detected in last 25 blocks"
fi

# 1c. StakeHub election set = 1 validator
ELEC1=$(_election_count)
if [ "${ELEC1:-0}" -eq 1 ]; then
    pass "StakeHub election set = 1 validator (validator-1 only)"
elif [ "${ELEC1:-0}" -gt 1 ]; then
    fail "StakeHub election set = ${ELEC1} validators, expected 1"
else
    fail "StakeHub election set = 0 validators, expected 1 (registration/delegate may have failed)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2: Validators 2 and 3 register
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════"
echo "  PHASE 2 — validators 2 and 3 also register"
echo "══════════════════════════════════════════════════════"
echo ""

TIP_BEFORE=$(_tip)
log "Tip before phase 2: block #${TIP_BEFORE}"

_register 2
_register 3

log "Waiting ${WAIT}s for next breathe block..."
sleep "$WAIT"

TIP_AFTER=$(_tip)
log "Tip after wait: block #${TIP_AFTER}"

# 2a. Network liveness
if [ "${TIP_AFTER:-0}" -gt "${TIP_BEFORE:-0}" ]; then
    pass "Network live after full registration: #${TIP_BEFORE} → #${TIP_AFTER}"
else
    fail "Network stalled after full registration"
fi

# 2b. Breathe block fired
if _has_breathe 50; then
    pass "Breathe block fired (updateValidatorSetV2 called with all validators)"
else
    fail "No breathe block detected in last 25 blocks"
fi

# 2c. StakeHub election set = 3 validators
ELEC3=$(_election_count)
if [ "${ELEC3:-0}" -eq 3 ]; then
    pass "StakeHub election set = 3 validators"
elif [ "${ELEC3:-0}" -gt 0 ]; then
    fail "StakeHub election set = ${ELEC3} validators, expected 3"
else
    fail "StakeHub election set = 0 validators after phase 2"
fi

# ══════════════════════════════════════════════════════════════════════════════
# RESULT
# ══════════════════════════════════════════════════════════════════════════════
echo ""
if [ "${FAILED}" -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}SOME TESTS FAILED — check output above and data/validator-1/geth.log${NC}"
    exit 1
fi
