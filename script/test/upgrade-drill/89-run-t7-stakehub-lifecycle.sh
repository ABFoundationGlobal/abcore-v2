#!/usr/bin/env bash
#
# 89-run-t7-stakehub-lifecycle.sh — T-7: StakeHub validator lifecycle
#
# T-7.a  editCommissionRate: real tx; by T-7 time the 5 s BREATHE_BLOCK_INTERVAL
#         cooldown from createValidator has long expired, so the tx succeeds.
# T-7.b  editDescription: real tx; sleep 7 s after T-7.a to clear its cooldown.
# T-7.c  editConsensusAddress: real tx; sleep 7 s after T-7.b then change to a test
#         address, verify, sleep 7 s, then restore the original address.
# T-7.d  validator info query suite: read-only queries for all 3 validators.
# T-7.e  Node ID management: addNodeIDs / removeNodeIDs / getNodeIDs round-trip.
# T-7.f  UpdateTooFrequently enforcement: immediately after T-7.b's real tx (which
#         sets updateTime = now), eth_call editCommissionRate — within the 5 s window
#         updateTime + 5 > block.timestamp → UpdateTooFrequently fires.
#
# Prerequisites:
#   - U-3 (82-run-u3-shanghai-feynman.sh) completed; all 3 nodes running.
#   - Validators registered via StakeHub.createValidator().
#
# Usage:
#   GETH=./build/bin/geth bash script/test/upgrade-drill/89-run-t7-stakehub-lifecycle.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

GETH=${GETH:-geth}

# ── Contract addresses ────────────────────────────────────────────────────────
STAKE_HUB="0x0000000000000000000000000000000000002002"

VAL1=$(val_addr 1 | tr '[:upper:]' '[:lower:]')
VAL2=$(val_addr 2 | tr '[:upper:]' '[:lower:]')
VAL3=$(val_addr 3 | tr '[:upper:]' '[:lower:]')

IPC1=$(val_ipc 1)
IPC2=$(val_ipc 2)
IPC3=$(val_ipc 3)
HTTP1="http://127.0.0.1:$(http_port 1)"

# A deterministic test node ID (32 bytes).
TEST_NODE_ID="0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

PASS=0; FAIL=0
ok()   { log "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { log "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

# ── Helpers ───────────────────────────────────────────────────────────────────

eth_call_raw() {
  local to="$1" data="$2"
  curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"${to}\",\"data\":\"${data}\"},\"latest\"],\"id\":1}" \
    2>/dev/null \
  | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if "error" in resp: print("0x"); sys.exit(0)
print(resp.get("result","0x"))' || echo "0x"
}

eth_call_with_state() {
  local to="$1" data="$2" from_addr="$3" state_json="$4"
  curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "$(python3 -c "
import json
print(json.dumps({
  'jsonrpc':'2.0','method':'eth_call','id':1,
  'params':[{'to':'${to}','from':'${from_addr}','data':'${data}'},'latest',${state_json}]
}))")" \
    2>/dev/null \
  | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if "error" in resp: print("error:" + str(resp["error"].get("message",""))); sys.exit(0)
print(resp.get("result","0x"))' || echo "error:curl"
}

eth_call_debug() {
  local to="$1" data="$2" from_addr="${3:-}"
  local body resp
  if [[ -n "$from_addr" ]]; then
    body="{\"to\":\"${to}\",\"from\":\"${from_addr}\",\"data\":\"${data}\"}"
  else
    body="{\"to\":\"${to}\",\"data\":\"${data}\"}"
  fi
  resp=$(curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[${body},\"latest\"],\"id\":1}" \
    2>/dev/null || echo '{}')
  echo "$resp" | python3 -c "
import json, sys
resp = json.load(sys.stdin)
if 'error' in resp:
    err = resp['error']
    msg = err.get('message','(no message)')
    data = err.get('data','') or ''
    if isinstance(data, str) and data.startswith('0x08c379a0'):
        raw = bytes.fromhex(data[10:])
        try:
            length = int.from_bytes(raw[32:64], 'big')
            reason = raw[64:64+length].decode('utf-8', 'replace')
        except Exception as e:
            reason = f'(decode error: {e})'
        print(f'  [dry-run] REVERT  Error({repr(reason)})  raw={data[:66]}...')
    elif isinstance(data, str) and len(data) >= 10:
        print(f'  [dry-run] REVERT  custom error selector=0x{data[2:10]}  raw={data[:66]}...')
    elif data:
        print(f'  [dry-run] REVERT  {msg}  data={data}')
    else:
        print(f'  [dry-run] REVERT  {msg}  (no revert data)')
elif 'result' in resp:
    r = resp['result']
    print(f'  [dry-run] SUCCESS  result={r[:66] if r else \"0x\"}')
else:
    print(f'  [dry-run] unexpected response: {json.dumps(resp)[:120]}')
"
}

eth_get_logs() {
  local address="$1" topic0="$2" from_block="${3:-0x1}" to_block="${4:-latest}"
  curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "$(python3 -c "
import json
print(json.dumps({
  'jsonrpc': '2.0', 'method': 'eth_getLogs', 'id': 1,
  'params': [{'address': '${address}', 'topics': ['${topic0}'],
              'fromBlock': '${from_block}', 'toBlock': '${to_block}'}]
}))")" \
    2>/dev/null \
  | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if "error" in resp:
    print("eth_getLogs error: " + str(resp["error"]), file=sys.stderr); sys.exit(1)
print(json.dumps(resp.get("result",[])))' || return 1
}

selector() { attach_exec "$GETH" "$IPC1" "web3.sha3('${1}').substring(2,10)" 2>/dev/null; }

send_tx_wait() {
  local ipc="$1" from_addr="$2" to_addr="$3" value_hex="$4" gas="$5" data="$6" label="$7"
  local tx
  tx=$(attach_exec "$GETH" "$ipc" \
    "eth.sendTransaction({from:'${from_addr}',to:'${to_addr}',value:'${value_hex}',gas:${gas},data:'${data}'})" \
    2>/dev/null || echo "")
  if [[ ! "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    log "  FAIL: ${label}: sendTransaction rejected (got: '${tx}')" >&2; return 1
  fi
  log "  ${label}: tx=${tx:0:20}…" >&2
  local i status
  for i in $(seq 1 60); do
    sleep 1
    status=$(attach_exec "$GETH" "$IPC1" \
      "(function(){var r=eth.getTransactionReceipt('${tx}');return r?r.status:'p';})()" \
      2>/dev/null || echo "p")
    if [[ "$status" == "0x1" || "$status" == "1" ]]; then echo "$tx"; return 0; fi
    if [[ "$status" == "0x0" || "$status" == "0" ]]; then
      log "  FAIL: ${label}: tx reverted (tx=${tx})" >&2
      eth_call_debug "$to_addr" "$data" "$from_addr" >&2 || true
      return 1
    fi
  done
  log "  FAIL: ${label}: tx not mined in 60 s (tx=${tx})" >&2; return 1
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
wait_for_ipc "$GETH" "$IPC1" 10
code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${STAKE_HUB}','latest')" 2>/dev/null || echo "0x")
[[ $(( (${#code} - 2) / 2 )) -gt 100 ]] || die "StakeHub not deployed at ${STAKE_HUB}. Run U-3 first."

log "T-7  StakeHub validator info queries and node ID management"
log "  StakeHub: ${STAKE_HUB}"
log "  VAL1: ${VAL1}  VAL2: ${VAL2}  VAL3: ${VAL3}"

# ── Compute selectors ─────────────────────────────────────────────────────────
log ""
log "Computing selectors..."
SEL_GET_COMMISSION=$(selector "getValidatorCommission(address)")
SEL_GET_DESC=$(selector "getValidatorDescription(address)")
SEL_GET_BASIC=$(selector "getValidatorBasicInfo(address)")
SEL_GET_VALIDATORS=$(selector "getValidators(uint256,uint256)")
SEL_GET_CREDIT=$(selector "getValidatorCreditContract(address)")
SEL_GET_CONSENSUS=$(selector "getValidatorConsensusAddress(address)")
SEL_GET_VOTE_ADDR=$(selector "getValidatorVoteAddress(address)")
SEL_ADD_NODE_IDS=$(selector "addNodeIDs(bytes32[])")
SEL_REMOVE_NODE_IDS=$(selector "removeNodeIDs(bytes32[])")
SEL_GET_NODE_IDS=$(selector "getNodeIDs(address[])")
SEL_EDIT_COMMISSION=$(selector "editCommissionRate(uint64)")
SEL_EDIT_DESC=$(selector "editDescription((string,string,string,string))")
SEL_EDIT_CONSENSUS=$(selector "editConsensusAddress(address)")
SEL_CONSENSUS_TO_OP=$(selector "consensusToOperator(address)")

TOPIC_NODE_ID_ADDED=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('NodeIDAdded(address,bytes32)')" 2>/dev/null)
TOPIC_NODE_ID_REMOVED=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('NodeIDRemoved(address,bytes32)')" 2>/dev/null)
TOPIC_COMMISSION_EDITED=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('CommissionRateEdited(address,uint64)')" 2>/dev/null)
TOPIC_DESC_EDITED=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('DescriptionEdited(address)')" 2>/dev/null)
# UpdateTooFrequently() custom error selector
ERR_UPDATE_TOO_FREQUENTLY=$(selector "UpdateTooFrequently()")

for _s in SEL_GET_COMMISSION SEL_GET_DESC SEL_GET_BASIC SEL_GET_VALIDATORS \
           SEL_GET_CREDIT SEL_GET_CONSENSUS SEL_GET_VOTE_ADDR \
           SEL_ADD_NODE_IDS SEL_REMOVE_NODE_IDS SEL_GET_NODE_IDS \
           SEL_EDIT_COMMISSION SEL_EDIT_DESC SEL_EDIT_CONSENSUS SEL_CONSENSUS_TO_OP \
           ERR_UPDATE_TOO_FREQUENTLY; do
  [[ "${!_s}" =~ ^[0-9a-fA-F]{8}$ ]] \
    || die "${_s}: bad selector '${!_s}' (geth attach failed?)"
done
log "  Selectors ready."

VAL1_PAD=$(printf '%064s' "${VAL1#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')

# ── Read commission info ──────────────────────────────────────────────────────
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_GET_COMMISSION}${VAL1_PAD}")
commission_info=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x' or len(raw) < 194:
    print('0 10000 1000'); exit()
data = bytes.fromhex(raw[2:])
rate       = int.from_bytes(data[0:32],  'big')
max_rate   = int.from_bytes(data[32:64], 'big')
max_change = int.from_bytes(data[64:96], 'big')
print(f'{rate} {max_rate} {max_change}')
" 2>/dev/null || echo "0 10000 1000")
current_rate="${commission_info%% *}"
_rest="${commission_info#* }"
max_rate="${_rest%% *}"
max_change="${_rest##* }"

new_commission_rate=$(python3 -c "
rate=int('${current_rate}'); mc=int('${max_change}'); mr=int('${max_rate}')
if mc==0: print(rate); exit()
step=min(mc,100)
print(rate+step if rate+step<=mr else max(0,rate-step))
" 2>/dev/null || echo "$current_rate")
edit_commission_data=$(python3 -c "
print('0x'+'${SEL_EDIT_COMMISSION}'+format(int('${new_commission_rate}'),'064x'))
")

# Read val1's current consensus address (needed to restore after T-7.c)
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_GET_CONSENSUS}${VAL1_PAD}")
VAL1_ORIGINAL_CONSENSUS="0x${raw: -40}"
log "  val1 current consensus: ${VAL1_ORIGINAL_CONSENSUS}"

# ─────────────────────────────────────────────────────────────────────────────
# T-7.a — editCommissionRate (real tx)
# The 5 s BREATHE_BLOCK_INTERVAL cooldown from createValidator has expired
# (createValidator ran minutes ago in U-3).
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-7.a: editCommissionRate (real tx) ──────────────────────────────────────"
log "  current commission: rate=${current_rate}  maxRate=${max_rate}  maxChangeRate=${max_change}"
log "  target rate: ${new_commission_rate}"

if [[ "$new_commission_rate" == "$current_rate" ]]; then
  log "  NOTE T-7.a: maxChangeRate=0 or no room to move — skipping"
  ok "T-7.a: editCommissionRate skipped (maxChangeRate constraint)"
else
  log "  Dry-run editCommissionRate(${new_commission_rate})..."
  eth_call_debug "$STAKE_HUB" "$edit_commission_data" "$VAL1"

  blk_before=$(attach_exec "$GETH" "$IPC1" "eth.blockNumber" 2>/dev/null || echo "0")
  t7a_tx=$(send_tx_wait "$IPC1" "$VAL1" "$STAKE_HUB" "0x0" 200000 \
    "$edit_commission_data" "T-7.a:editCommissionRate") || {
    fail "T-7.a: editCommissionRate tx failed"; t7a_tx=""; }

  if [[ "${t7a_tx:-}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    blk_after=$(attach_exec "$GETH" "$IPC1" \
      "(function(){var r=eth.getTransactionReceipt('${t7a_tx}');return r?r.blockNumber:0;})()" \
      2>/dev/null || echo "0")
    # Verify rate updated
    raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_GET_COMMISSION}${VAL1_PAD}")
    updated_rate=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x' or len(raw) < 194: print(-1); exit()
data = bytes.fromhex(raw[2:])
print(int.from_bytes(data[0:32], 'big'))
" 2>/dev/null || echo "-1")
    if [[ "$updated_rate" == "$new_commission_rate" ]]; then
      ok "T-7.a: getValidatorCommission(val1).rate == ${updated_rate} (updated)"
    else
      fail "T-7.a: commission rate expected ${new_commission_rate}, got ${updated_rate}"
    fi
    # Verify CommissionRateEdited event
    blk_before_hex=$(printf '0x%x' "$blk_before")
    blk_after_hex=$(printf '0x%x' "$blk_after")
    commission_logs=$(eth_get_logs "$STAKE_HUB" "$TOPIC_COMMISSION_EDITED" \
      "$blk_before_hex" "$blk_after_hex")
    _ev=0
    python3 - <<PYEOF 2>/dev/null || _ev=$?
import json, sys
logs = json.loads('''${commission_logs}''')
if not logs: print("no CommissionRateEdited event", file=sys.stderr); sys.exit(1)
PYEOF
    [[ "$_ev" -eq 0 ]] && ok "T-7.a: CommissionRateEdited event emitted" \
                        || fail "T-7.a: CommissionRateEdited event missing"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-7.b — editDescription (real tx)
# sleep 7 s to clear the 5 s BREATHE_BLOCK_INTERVAL cooldown set by T-7.a.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-7.b: editDescription (real tx) ────────────────────────────────────────"
log "  Sleeping 7 s to clear BREATHE_BLOCK_INTERVAL cooldown from T-7.a..."
sleep 7

EDIT_IDENTITY="abchain-val1"
EDIT_WEBSITE="https://abchain.local"
EDIT_DETAILS="test drill validator"

edit_desc_data=$(python3 -c "
sel = '${SEL_EDIT_DESC}'
def p32(n): return format(n, '064x')
def encode_str(s):
    b = s.encode('utf-8')
    if not b: return p32(0)
    return p32(len(b)) + b.hex().ljust(((len(b)+31)//32)*64,'0')
strs = ['', '${EDIT_IDENTITY}', '${EDIT_WEBSITE}', '${EDIT_DETAILS}']
off = 4*32; heads=''; bodies=[]
for s in strs:
    heads += p32(off); enc=encode_str(s); bodies.append(enc); off+=len(enc)//2
print('0x'+sel+p32(0x20)+heads+''.join(bodies))
")

blk_before=$(attach_exec "$GETH" "$IPC1" "eth.blockNumber" 2>/dev/null || echo "0")
t7b_tx=$(send_tx_wait "$IPC1" "$VAL1" "$STAKE_HUB" "0x0" 300000 \
  "$edit_desc_data" "T-7.b:editDescription") || {
  fail "T-7.b: editDescription tx failed"; t7b_tx=""; }

if [[ "${t7b_tx:-}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  blk_after=$(attach_exec "$GETH" "$IPC1" \
    "(function(){var r=eth.getTransactionReceipt('${t7b_tx}');return r?r.blockNumber:0;})()" \
    2>/dev/null || echo "0")
  # Verify DescriptionEdited event
  blk_before_hex=$(printf '0x%x' "$blk_before")
  blk_after_hex=$(printf '0x%x' "$blk_after")
  desc_logs=$(eth_get_logs "$STAKE_HUB" "$TOPIC_DESC_EDITED" "$blk_before_hex" "$blk_after_hex")
  _ev=0
  python3 - <<PYEOF 2>/dev/null || _ev=$?
import json, sys
logs = json.loads('''${desc_logs}''')
if not logs: print("no DescriptionEdited event", file=sys.stderr); sys.exit(1)
PYEOF
  [[ "$_ev" -eq 0 ]] && ok "T-7.b: DescriptionEdited event emitted" \
                      || fail "T-7.b: DescriptionEdited event missing"
  # Verify identity field updated
  raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_GET_DESC}${VAL1_PAD}")
  identity_got=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x' or len(raw) < 10: print(''); exit()
data = bytes.fromhex(raw[2:])
try:
    outer = int.from_bytes(data[0:32], 'big')
    base  = outer
    inner = [int.from_bytes(data[base+i*32:base+(i+1)*32], 'big') for i in range(4)]
    off   = base + inner[1]
    length = int.from_bytes(data[off:off+32], 'big')
    s = data[off+32:off+32+length].decode('utf-8', 'replace') if length > 0 else ''
    print(s)
except Exception:
    print('')
" 2>/dev/null || echo "")
  [[ "$identity_got" == "$EDIT_IDENTITY" ]] \
    && ok "T-7.b: getValidatorDescription(val1).identity == '${EDIT_IDENTITY}'" \
    || fail "T-7.b: identity expected '${EDIT_IDENTITY}', got '${identity_got}'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-7.f — UpdateTooFrequently enforcement
# T-7.b's real tx set updateTime = block.timestamp(N).  Immediately calling
# editCommissionRate (no real tx) triggers updateTime + 5 > block.timestamp(N+1).
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-7.f: UpdateTooFrequently enforcement ───────────────────────────────────"
log "  T-7.b just set updateTime = now; calling editCommissionRate immediately..."

_t7f_revert_data=$(curl -sS -X POST "$HTTP1" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"${STAKE_HUB}\",\"from\":\"${VAL1}\",\"data\":\"${edit_commission_data}\"},\"latest\"],\"id\":1}" \
  2>/dev/null \
  | python3 -c "
import json, sys
resp = json.load(sys.stdin)
if 'error' not in resp: print('no_revert'); sys.exit(0)
data = resp['error'].get('data','') or ''
if isinstance(data, str) and len(data) >= 10:
    print(data[2:10].lower())
else:
    print('no_data')
" 2>/dev/null || echo "exception")

if [[ "${_t7f_revert_data,,}" == "${ERR_UPDATE_TOO_FREQUENTLY,,}" ]]; then
  ok "T-7.f: editCommissionRate reverts UpdateTooFrequently within 5 s of T-7.b (selector=0x${ERR_UPDATE_TOO_FREQUENTLY})"
else
  fail "T-7.f: expected UpdateTooFrequently (0x${ERR_UPDATE_TOO_FREQUENTLY}), got '${_t7f_revert_data}'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-7.c — editConsensusAddress (real tx, no restore)
# sleep 7 s after T-7.b to clear cooldown.  Change to a test address and verify.
# Restore is intentionally NOT attempted: editConsensusAddress does not clear
# the old address from consensusToOperator, so trying to re-register the original
# address triggers DuplicateConsensusAddress.  This is by design — consensus
# addresses are permanently one-way deregistered.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-7.c: editConsensusAddress (real tx) ───────────────────────────────────"
log "  Sleeping 7 s to clear BREATHE_BLOCK_INTERVAL cooldown from T-7.b..."
sleep 7

TEST_NEW_CONSENSUS="0xdeadc0de00000000000000000000000000000001"
TEST_NEW_CONSENSUS_PAD=$(printf '%064s' "${TEST_NEW_CONSENSUS#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
edit_consensus_data="0x${SEL_EDIT_CONSENSUS}${TEST_NEW_CONSENSUS_PAD}"

log "  Dry-run editConsensusAddress(${TEST_NEW_CONSENSUS})..."
eth_call_debug "$STAKE_HUB" "$edit_consensus_data" "$VAL1"

t7c_tx=$(send_tx_wait "$IPC1" "$VAL1" "$STAKE_HUB" "0x0" 200000 \
  "$edit_consensus_data" "T-7.c:editConsensusAddress") || {
  fail "T-7.c: editConsensusAddress tx failed"; t7c_tx=""; }

if [[ "${t7c_tx:-}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  # Verify new consensus address in storage
  raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_GET_CONSENSUS}${VAL1_PAD}")
  new_cons="0x${raw: -40}"
  [[ "${new_cons,,}" == "${TEST_NEW_CONSENSUS,,}" ]] \
    && ok "T-7.c: getValidatorConsensusAddress(val1) == ${TEST_NEW_CONSENSUS} (updated)" \
    || fail "T-7.c: expected ${TEST_NEW_CONSENSUS}, got ${new_cons}"

  # Verify consensusToOperator mapping
  raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_CONSENSUS_TO_OP}${TEST_NEW_CONSENSUS_PAD}")
  mapped="0x${raw: -40}"
  [[ "${mapped,,}" == "${VAL1,,}" ]] \
    && ok "T-7.c: consensusToOperator(${TEST_NEW_CONSENSUS}) == val1 (routing updated)" \
    || fail "T-7.c: expected val1, got ${mapped}"

  ok "T-7.c: ConsensusAddressEdited — real tx confirmed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-7.d — validator info query suite
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-7.d: validator info query suite ───────────────────────────────────────"

for entry in "1:${VAL1}" "2:${VAL2}" "3:${VAL3}"; do
  n="${entry%%:*}"; addr="${entry#*:}"
  pad=$(printf '%064s' "${addr#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')

  # getValidatorBasicInfo
  raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_GET_BASIC}${pad}")
  if [[ "${#raw}" -gt 10 && "$raw" != "0x" ]]; then
    ok "T-7.d: getValidatorBasicInfo(val${n}) returned data (len=$(( (${#raw}-2)/2 )) bytes)"
  else
    fail "T-7.d: getValidatorBasicInfo(val${n}) returned empty"
  fi

  # getValidatorDescription
  raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_GET_DESC}${pad}")
  if [[ "${#raw}" -gt 10 && "$raw" != "0x" ]]; then
    ok "T-7.d: getValidatorDescription(val${n}) returned data"
  else
    fail "T-7.d: getValidatorDescription(val${n}) returned empty"
  fi

  # getValidatorCommission
  raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_GET_COMMISSION}${pad}")
  if [[ "${#raw}" -ge 194 && "$raw" != "0x" ]]; then
    ok "T-7.d: getValidatorCommission(val${n}) returned 3-field tuple"
  else
    fail "T-7.d: getValidatorCommission(val${n}) short or empty"
  fi

  # getValidatorCreditContract
  raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_GET_CREDIT}${pad}")
  credit="0x${raw: -40}"
  if [[ "$credit" != "0x0000000000000000000000000000000000000000" ]]; then
    ok "T-7.d: getValidatorCreditContract(val${n}) = ${credit}"
  else
    fail "T-7.d: getValidatorCreditContract(val${n}) returned zero address"
  fi

  # getValidatorConsensusAddress
  raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_GET_CONSENSUS}${pad}")
  cons="0x${raw: -40}"
  if [[ "$cons" != "0x0000000000000000000000000000000000000000" ]]; then
    ok "T-7.d: getValidatorConsensusAddress(val${n}) = ${cons}"
  else
    fail "T-7.d: getValidatorConsensusAddress(val${n}) returned zero"
  fi

  # getValidatorVoteAddress
  raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_GET_VOTE_ADDR}${pad}")
  if [[ "${#raw}" -gt 10 && "$raw" != "0x" ]]; then
    ok "T-7.d: getValidatorVoteAddress(val${n}) returned data"
  else
    fail "T-7.d: getValidatorVoteAddress(val${n}) returned empty"
  fi
done

# getValidators(0, 10) → should return 3 operators
get_vals_data="0x${SEL_GET_VALIDATORS}$(printf '%064x' 0)$(printf '%064x' 10)"
raw=$(eth_call_raw "$STAKE_HUB" "$get_vals_data")
val_count=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x' or len(raw) < 10: print(0); exit()
data = bytes.fromhex(raw[2:])
# Returns (address[] operators, bool[] jailed, uint256 totalLength)
# First word: offset to operators array
try:
    off = int.from_bytes(data[0:32], 'big')
    count = int.from_bytes(data[off:off+32], 'big')
    print(count)
except Exception:
    print(0)
" 2>/dev/null || echo "0")

if [[ "$val_count" -ge 3 ]]; then
  ok "T-7.d: getValidators(0,10) returned ${val_count} validators"
else
  fail "T-7.d: getValidators(0,10) returned ${val_count}, expected >= 3"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-7.b — Node ID management
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-7.e: Node ID management ────────────────────────────────────────────────"

# ABI-encode addNodeIDs(bytes32[]) — dynamic array with 1 element
# Selector + offset(32) + length(1) + element
add_node_data=$(python3 -c "
sel = '${SEL_ADD_NODE_IDS}'
node_id = '${TEST_NODE_ID}'.replace('0x','').lower().zfill(64)
def p32(n): return format(n,'064x')
# arg: bytes32[] at offset 32; array: length=1, one 32-byte element
data = sel + p32(32) + p32(1) + node_id
print('0x' + data)
")
log "  Dry-run addNodeIDs([${TEST_NODE_ID:0:20}...])..."
eth_call_debug "$STAKE_HUB" "$add_node_data" "$VAL1"

blk_before=$(attach_exec "$GETH" "$IPC1" "eth.blockNumber" 2>/dev/null || echo "0")
add_node_tx=$(send_tx_wait "$IPC1" "$VAL1" "$STAKE_HUB" "0x0" 200000 "$add_node_data" "T-7.e:addNodeIDs") || {
  fail "T-7.e: addNodeIDs tx failed"; }
blk_after=$(attach_exec "$GETH" "$IPC1" \
  "(function(){var r=eth.getTransactionReceipt('${add_node_tx}');return r?r.blockNumber:0;})()" \
  2>/dev/null || echo "0")

# Verify getNodeIDs contains the added node.
# getNodeIDs(address[]) takes an address array and returns (address[], bytes32[][]).
# Encode [val1] as address[]: offset(32) + length(1) + padded_addr.
get_node_data=$(python3 -c "
sel = '${SEL_GET_NODE_IDS}'
def p32(n): return format(n,'064x')
addr = '${VAL1}'.replace('0x','').lower().zfill(64)
print('0x' + sel + p32(32) + p32(1) + addr)
")
raw=$(eth_call_raw "$STAKE_HUB" "$get_node_data")
node_found=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x' or len(raw) < 10: print('false'); exit()
data = bytes.fromhex(raw[2:])
try:
    # Return layout: (address[], bytes32[][])
    # data[0:32]  = offset to consensusAddresses array
    # data[32:64] = offset to nodeIDsList (bytes32[][]) array
    nids_off = int.from_bytes(data[32:64], 'big')
    outer_len = int.from_bytes(data[nids_off:nids_off+32], 'big')
    if outer_len == 0: print('false'); exit()
    # Offset to inner array 0 (relative to start of outer array head, i.e. nids_off+32)
    inner0_rel = int.from_bytes(data[nids_off+32:nids_off+64], 'big')
    inner0_abs = nids_off + 32 + inner0_rel
    inner0_len = int.from_bytes(data[inner0_abs:inner0_abs+32], 'big')
    target = '${TEST_NODE_ID}'.replace('0x','').lower().zfill(64)
    for i in range(inner0_len):
        elem = data[inner0_abs+32+i*32:inner0_abs+64+i*32].hex().lower()
        if elem == target:
            print('true'); exit()
    print('false')
except Exception:
    print('false')
" 2>/dev/null || echo "false")

if [[ "$node_found" == "true" ]]; then
  ok "T-7.e: getNodeIDs(val1) contains test node ID after addNodeIDs"
else
  fail "T-7.e: getNodeIDs(val1) does not contain test node ID after addNodeIDs"
fi

blk_before_hex=$(printf '0x%x' "$blk_before")
blk_after_hex=$(printf '0x%x' "$blk_after")
add_node_logs=$(eth_get_logs "$STAKE_HUB" "$TOPIC_NODE_ID_ADDED" "$blk_before_hex" "$blk_after_hex")
_t7b_add_ev=0
python3 - <<PYEOF 2>/dev/null || _t7b_add_ev=$?
import json, sys
logs = json.loads('''${add_node_logs}''')
if not logs:
    print("no NodeIDAdded event found", file=sys.stderr); sys.exit(1)
PYEOF
if [[ "$_t7b_add_ev" -eq 0 ]]; then
  ok "T-7.e: NodeIDAdded event emitted"
else
  fail "T-7.e: NodeIDAdded event missing"
fi

# removeNodeIDs
remove_node_data=$(python3 -c "
sel = '${SEL_REMOVE_NODE_IDS}'
node_id = '${TEST_NODE_ID}'.replace('0x','').lower().zfill(64)
def p32(n): return format(n,'064x')
data = sel + p32(32) + p32(1) + node_id
print('0x' + data)
")

blk_before=$(attach_exec "$GETH" "$IPC1" "eth.blockNumber" 2>/dev/null || echo "0")
remove_node_tx=$(send_tx_wait "$IPC1" "$VAL1" "$STAKE_HUB" "0x0" 200000 "$remove_node_data" "T-7.e:removeNodeIDs") || {
  fail "T-7.e: removeNodeIDs tx failed"; }
blk_after=$(attach_exec "$GETH" "$IPC1" \
  "(function(){var r=eth.getTransactionReceipt('${remove_node_tx}');return r?r.blockNumber:0;})()" \
  2>/dev/null || echo "0")

# Verify getNodeIDs is now empty (no longer contains the node)
raw=$(eth_call_raw "$STAKE_HUB" "$get_node_data")
node_count_after=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x' or len(raw) < 10: print(0); exit()
data = bytes.fromhex(raw[2:])
try:
    nids_off = int.from_bytes(data[32:64], 'big')
    outer_len = int.from_bytes(data[nids_off:nids_off+32], 'big')
    if outer_len == 0: print(0); exit()
    inner0_rel = int.from_bytes(data[nids_off+32:nids_off+64], 'big')
    inner0_abs = nids_off + 32 + inner0_rel
    print(int.from_bytes(data[inner0_abs:inner0_abs+32], 'big'))
except Exception:
    print(0)
" 2>/dev/null || echo "0")

if [[ "$node_count_after" -eq 0 ]]; then
  ok "T-7.e: getNodeIDs(val1) is empty after removeNodeIDs"
else
  fail "T-7.e: getNodeIDs(val1) still has ${node_count_after} entries after removeNodeIDs"
fi

blk_before_hex=$(printf '0x%x' "$blk_before")
blk_after_hex=$(printf '0x%x' "$blk_after")
remove_node_logs=$(eth_get_logs "$STAKE_HUB" "$TOPIC_NODE_ID_REMOVED" "$blk_before_hex" "$blk_after_hex")
_t7b_rm_ev=0
python3 - <<PYEOF 2>/dev/null || _t7b_rm_ev=$?
import json, sys
logs = json.loads('''${remove_node_logs}''')
if not logs:
    print("no NodeIDRemoved event found", file=sys.stderr); sys.exit(1)
PYEOF
if [[ "$_t7b_rm_ev" -eq 0 ]]; then
  ok "T-7.e: NodeIDRemoved event emitted"
else
  fail "T-7.e: NodeIDRemoved event missing"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
if [[ "$FAIL" -eq 0 ]]; then
  log "[ PASS ]  T-7 stakehub-lifecycle: ${PASS} checks passed"
else
  log "[ FAIL ]  T-7 stakehub-lifecycle: ${PASS} passed, ${FAIL} failed"
  exit 1
fi
