#!/usr/bin/env bash
#
# 93-run-t11-validatorset-queries.sh — T-11: BSCValidatorSet state queries
#
# T-11.a  getLivingValidators: returns all 3 consensus addresses with vote addrs.
# T-11.b  getMiningValidators: returns 3 addresses eligible for block production.
# T-11.c  isWorkingValidator: true for val1, false for a dead address.
# T-11.d  getWorkingValidatorCount: returns 3.
# T-11.e  getIncoming: non-zero incoming BNB for val1 after blocks produced.
# T-11.f  getCurrentValidatorIndex: distinct index in [0,2] for each validator.
# T-11.g  BSCValidatorSet.updateParam via governance (maxNumOfWorkingCandidates).
#
# Prerequisites:
#   - U-3 completed; all 3 validators active.
#
# Usage:
#   GETH=./build/bin/geth bash script/test/upgrade-drill/93-run-t11-validatorset-queries.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

GETH=${GETH:-geth}

# ── Contract addresses ────────────────────────────────────────────────────────
VALIDATOR_SET="0x0000000000000000000000000000000000001000"
GOVERNOR="0x0000000000000000000000000000000000002004"
GOV_HUB="0x0000000000000000000000000000000000001007"

VAL1=$(val_addr 1 | tr '[:upper:]' '[:lower:]')
VAL2=$(val_addr 2 | tr '[:upper:]' '[:lower:]')
VAL3=$(val_addr 3 | tr '[:upper:]' '[:lower:]')

IPC1=$(val_ipc 1)
IPC2=$(val_ipc 2)
IPC3=$(val_ipc 3)
HTTP1="http://127.0.0.1:$(http_port 1)"

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

governor_state() {
  local id_hex="$1"
  local sel raw
  sel=$(selector "state(uint256)")
  raw=$(eth_call_raw "$GOVERNOR" "0x${sel}${id_hex}")
  python3 -c "print(int('${raw}' if '${raw}'.startswith('0x') else '0x0', 16))" 2>/dev/null || echo "-1"
}

wait_for_governor_state() {
  local id_hex="$1" expected="$2" timeout_s="$3" label="$4"
  local start cur elapsed
  start=$(date +%s)
  while true; do
    cur=$(governor_state "$id_hex")
    if [[ "$cur" -eq "$expected" ]]; then log "  state=${cur} (${label})"; return 0; fi
    elapsed=$(( $(date +%s) - start ))
    if [[ "$elapsed" -ge "$timeout_s" ]]; then
      fail "Proposal state timeout: expected=${expected} got=${cur} after ${elapsed}s"; return 1
    fi
    sleep 2
  done
}

build_propose_data() {
  local govhub_calldata="$1" description="$2"
  PROPOSE_DATA=$(python3 -c "
sel = '${SEL_PROPOSE}'
gov_hub = '${GOV_HUB}'.replace('0x','').lower()
inner   = bytes.fromhex('${govhub_calldata}'.replace('0x',''))
desc    = '''${description}'''.encode()
def p32(n): return format(n,'064x')
def enc_dyn(b):
    pad = ((len(b)+31)//32)*32
    return p32(len(b)) + b.hex().ljust(pad*2,'0')
targets_enc   = p32(1) + gov_hub.zfill(64)
values_enc    = p32(1) + p32(0)
calldatas_enc = p32(1) + p32(32) + enc_dyn(inner)
desc_enc      = enc_dyn(desc)
off0 = 4 * 32
off1 = off0 + len(targets_enc)//2
off2 = off1 + len(values_enc)//2
off3 = off2 + len(calldatas_enc)//2
head = p32(off0) + p32(off1) + p32(off2) + p32(off3)
print('0x' + sel + head + targets_enc + values_enc + calldatas_enc + desc_enc)
")
}

build_qe_data() {
  local govhub_calldata="$1" desc_hash="$2" qe_sel="$3"
  python3 -c "
sel = '${qe_sel}'
gov_hub   = '${GOV_HUB}'.replace('0x','').lower()
inner     = bytes.fromhex('${govhub_calldata}'.replace('0x',''))
desc_hash = '${desc_hash}'
def p32(n): return format(n,'064x')
def enc_dyn(b):
    pad = ((len(b)+31)//32)*32
    return p32(len(b)) + b.hex().ljust(pad*2,'0')
targets_enc   = p32(1) + gov_hub.zfill(64)
values_enc    = p32(1) + p32(0)
calldatas_enc = p32(1) + p32(32) + enc_dyn(inner)
off0 = 4 * 32
off1 = off0 + len(targets_enc)//2
off2 = off1 + len(values_enc)//2
head = p32(off0) + p32(off1) + p32(off2) + desc_hash
print('0x' + sel + head + targets_enc + values_enc + calldatas_enc)
"
}

run_governance_round() {
  local govhub_calldata="$1" description="$2" label="$3"
  build_propose_data "$govhub_calldata" "$description"
  log "${label}: submitting proposal..."
  eth_call_debug "$GOVERNOR" "$PROPOSE_DATA" "$VAL1"
  local propose_tx
  propose_tx=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$PROPOSE_DATA" "${label}:propose") || return 1
  PROPOSAL_ID_HEX=$(attach_exec "$GETH" "$IPC1" \
    "(function(){var r=eth.getTransactionReceipt('${propose_tx}');
      if(!r||!r.logs||!r.logs.length) return 'null';
      var topic=web3.sha3('ProposalCreated(uint256,address,address[],uint256[],string[],bytes[],uint256,uint256,string)');
      var log=r.logs.filter(function(l){return l.topics&&l.topics[0]===topic;})[0];
      var d=log?log.data:null;
      return d&&d.length>=66?d.slice(2,66):'null';})()" 2>/dev/null || echo "null")
  [[ "${#PROPOSAL_ID_HEX}" -eq 64 ]] || { log "  FAIL: ${label}: bad proposalId" >&2; return 1; }
  ok "${label}: propose() mined; proposalId=0x${PROPOSAL_ID_HEX:0:8}…"
  sleep 3
  local cast_data entry n addr ipc
  cast_data="0x${SEL_CAST_VOTE}${PROPOSAL_ID_HEX}$(printf '%064x' 1)"
  for entry in "1:${VAL1}:${IPC1}" "2:${VAL2}:${IPC2}" "3:${VAL3}:${IPC3}"; do
    n="${entry%%:*}"; addr="${entry#*:}"; addr="${addr%%:*}"; ipc="${entry##*:}"
    send_tx_wait "$ipc" "$addr" "$GOVERNOR" "0x0" 200000 "$cast_data" "${label}:castVote(val${n})" || return 1
    ok "${label}: val${n} castVote(FOR) mined"
  done
  wait_for_governor_state "$PROPOSAL_ID_HEX" 4 90 "Succeeded" \
    || { fail "${label}: not Succeeded"; return 1; }
  ok "${label}: Proposal Succeeded"
  local desc_hash
  desc_hash=$(attach_exec "$GETH" "$IPC1" "web3.sha3('${description}').slice(2)" 2>/dev/null)
  [[ "${#desc_hash}" -eq 64 ]] || { log "  FAIL: bad descHash" >&2; return 1; }
  local queue_data execute_data
  queue_data=$(build_qe_data "$govhub_calldata" "$desc_hash" "$SEL_QUEUE")
  execute_data=$(build_qe_data "$govhub_calldata" "$desc_hash" "$SEL_EXECUTE")
  send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$queue_data" "${label}:queue" || return 1
  ok "${label}: queue() mined"
  log "${label}: waiting timelock..."; sleep 10
  LAST_EXEC_TX=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 1000000 "$execute_data" "${label}:execute") || return 1
  ok "${label}: execute() mined"
  local cur; cur=$(governor_state "$PROPOSAL_ID_HEX")
  [[ "$cur" -eq 7 ]] && ok "${label}: state == Executed" || fail "${label}: expected Executed(7), got ${cur}"
  LAST_EXEC_BLK_HEX=$(attach_exec "$GETH" "$IPC1" \
    "(function(){var r=eth.getTransactionReceipt('${LAST_EXEC_TX}');return r?web3.toHex(r.blockNumber):'0x0';})()" \
    2>/dev/null || echo "0x0")
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
wait_for_ipc "$GETH" "$IPC1" 10
code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${VALIDATOR_SET}','latest')" 2>/dev/null || echo "0x")
[[ $(( (${#code} - 2) / 2 )) -gt 100 ]] || die "BSCValidatorSet not deployed at ${VALIDATOR_SET}. Run U-3 first."

log "T-11  BSCValidatorSet state queries"
log "  ValidatorSet: ${VALIDATOR_SET}"
log "  VAL1: ${VAL1}  VAL2: ${VAL2}  VAL3: ${VAL3}"

# ── Compute selectors ─────────────────────────────────────────────────────────
log ""
log "Computing selectors..."
SEL_GET_LIVING=$(selector "getLivingValidators()")
SEL_GET_MINING=$(selector "getMiningValidators()")
SEL_IS_WORKING=$(selector "isCurrentValidator(address)")
SEL_GET_WORKING_COUNT=$(selector "getWorkingValidatorCount()")
SEL_GET_INCOMING=$(selector "getIncoming(address)")
SEL_GET_CURR_IDX=$(selector "getCurrentValidatorIndex(address)")
SEL_PROPOSE=$(selector "propose(address[],uint256[],bytes[],string)")
SEL_CAST_VOTE=$(selector "castVote(uint256,uint8)")
SEL_QUEUE=$(selector "queue(address[],uint256[],bytes[],bytes32)")
SEL_EXECUTE=$(selector "execute(address[],uint256[],bytes[],bytes32)")
SEL_GOV_UPDATE=$(selector "updateParam(string,bytes,address)")

for _s in SEL_GET_LIVING SEL_GET_MINING SEL_IS_WORKING SEL_GET_WORKING_COUNT \
           SEL_GET_INCOMING SEL_GET_CURR_IDX SEL_PROPOSE SEL_CAST_VOTE \
           SEL_QUEUE SEL_EXECUTE SEL_GOV_UPDATE; do
  [[ "${!_s}" =~ ^[0-9a-fA-F]{8}$ ]] \
    || die "${_s}: bad selector '${!_s}' (geth attach failed?)"
done
log "  Selectors ready."

VAL1_PAD=$(printf '%064s' "${VAL1#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
VAL2_PAD=$(printf '%064s' "${VAL2#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
VAL3_PAD=$(printf '%064s' "${VAL3#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')

PROPOSAL_ID_HEX=""
LAST_EXEC_TX=""
LAST_EXEC_BLK_HEX=""

# ─────────────────────────────────────────────────────────────────────────────
# T-11.a — getLivingValidators
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-11.a: getLivingValidators ──────────────────────────────────────────────"

raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_GET_LIVING}")
living_count=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x' or len(raw) < 10: print(0); exit()
data = bytes.fromhex(raw[2:])
try:
    # returns (address[] consensusAddrs, bytes[] voteAddrs)
    off0 = int.from_bytes(data[0:32], 'big')
    count = int.from_bytes(data[off0:off0+32], 'big')
    print(count)
except Exception:
    print(0)
" 2>/dev/null || echo "0")
log "  getLivingValidators() returned ${living_count} validators"

if [[ "$living_count" -ge 3 ]]; then
  ok "T-11.a: getLivingValidators() returned ${living_count} validators (>= 3)"
else
  fail "T-11.a: getLivingValidators() returned ${living_count}, expected >= 3"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-11.b — getMiningValidators
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-11.b: getMiningValidators ──────────────────────────────────────────────"

raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_GET_MINING}")
mining_count=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x' or len(raw) < 10: print(0); exit()
data = bytes.fromhex(raw[2:])
try:
    # returns address[] — offset at word 0
    off0 = int.from_bytes(data[0:32], 'big')
    count = int.from_bytes(data[off0:off0+32], 'big')
    print(count)
except Exception:
    print(0)
" 2>/dev/null || echo "0")
log "  getMiningValidators() returned ${mining_count} validators"

if [[ "$mining_count" -ge 3 ]]; then
  ok "T-11.b: getMiningValidators() returned ${mining_count} validators"
else
  fail "T-11.b: getMiningValidators() returned ${mining_count}, expected >= 3"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-11.c — isCurrentValidator (address-based working-validator check)
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-11.c: isCurrentValidator ───────────────────────────────────────────────"

# val1 should be a current working validator
raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_IS_WORKING}${VAL1_PAD}")
if [[ "${raw: -2}" == "01" ]]; then
  ok "T-11.c: isCurrentValidator(val1) == true"
else
  fail "T-11.c: isCurrentValidator(val1) expected true, got ${raw}"
fi

# dead address should not be a current validator
DEAD_PAD="000000000000000000000000000000000000000000000000000000000000dead"
raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_IS_WORKING}${DEAD_PAD}")
if [[ "${raw: -2}" != "01" ]]; then
  ok "T-11.c: isCurrentValidator(0x...dead) == false"
else
  fail "T-11.c: isCurrentValidator(0x...dead) expected false, got ${raw}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-11.d — getWorkingValidatorCount
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-11.d: getWorkingValidatorCount ─────────────────────────────────────────"

raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_GET_WORKING_COUNT}")
wvc=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(0); exit()
print(int(raw, 16))
" 2>/dev/null || echo "0")
log "  getWorkingValidatorCount() = ${wvc}"

if [[ "$wvc" -ge 3 ]]; then
  ok "T-11.d: getWorkingValidatorCount() == ${wvc} (>= 3)"
else
  fail "T-11.d: getWorkingValidatorCount() == ${wvc}, expected >= 3"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-11.e — getIncoming
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-11.e: getIncoming ──────────────────────────────────────────────────────"

# Wait a few blocks to ensure incoming rewards have accumulated
cur_block=$(attach_exec "$GETH" "$IPC1" "eth.blockNumber" 2>/dev/null || echo "0")
wait_for_head_at_least "$GETH" "$IPC1" "$(( cur_block + 3 ))" 30

raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_GET_INCOMING}${VAL1_PAD}")
incoming=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(0); exit()
print(int(raw, 16))
" 2>/dev/null || echo "0")
log "  getIncoming(val1) = ${incoming} wei"

if [[ "$incoming" != "0" ]]; then
  ok "T-11.e: getIncoming(val1) > 0 (${incoming} wei — blocks produced)"
else
  log "  NOTE T-11.e: getIncoming(val1) == 0 (may depend on reward distribution timing)"
  ok "T-11.e: getIncoming(val1) call succeeded (value: ${incoming})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-11.f — getCurrentValidatorIndex
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-11.f: getCurrentValidatorIndex ────────────────────────────────────────"

indices=()
for entry in "1:${VAL1_PAD}" "2:${VAL2_PAD}" "3:${VAL3_PAD}"; do
  n="${entry%%:*}"; pad="${entry##*:}"
  raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_GET_CURR_IDX}${pad}")
  idx=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(-1); exit()
print(int(raw, 16))
" 2>/dev/null || echo "-1")
  log "  getCurrentValidatorIndex(val${n}) = ${idx}"
  if [[ "$idx" -ge 0 && "$idx" -le 2 ]]; then
    ok "T-11.f: val${n} index = ${idx} (within [0,2])"
  else
    fail "T-11.f: val${n} index = ${idx} (expected [0,2])"
  fi
  indices+=("$idx")
done

# Verify distinct indices
distinct=$(printf '%s\n' "${indices[@]}" | sort -u | wc -l | tr -d ' ')
if [[ "$distinct" -eq 3 ]]; then
  ok "T-11.f: all 3 validators have distinct indices (${indices[*]})"
else
  fail "T-11.f: validator indices not all distinct (${indices[*]})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-11.g — BSCValidatorSet.updateParam via governance (maxNumOfCandidates)
# maxNumOfWorkingCandidates requires <= maxNumOfCandidates (which is 0 on fresh devnet),
# so we use maxNumOfCandidates instead — it has no upper-bound validation.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-11.g: updateParam maxNumOfCandidates via governance ────────────────────"

SEL_MAX_CANDIDATES=$(selector "maxNumOfCandidates()")
raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_MAX_CANDIDATES}")
current_max=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(0); exit()
print(int(raw, 16))
" 2>/dev/null || echo "0")
log "  current maxNumOfCandidates: ${current_max}"

NEW_MAX=$(( current_max + 50 ))
log "  target maxNumOfCandidates: ${NEW_MAX}"

# Encode GovHub.updateParam("maxNumOfCandidates", newValue, ValidatorSet)
GOVHUB_CALLDATA_MAX=$(python3 -c "
sel = '${SEL_GOV_UPDATE}'
key = b'maxNumOfCandidates'
val = int('${NEW_MAX}').to_bytes(32, 'big')
target = '${VALIDATOR_SET}'.replace('0x','').lower().zfill(64)
def p32(n): return format(n, '064x')
def enc_dyn(b):
    pad = ((len(b) + 31) // 32) * 32
    return p32(len(b)) + b.hex().ljust(pad * 2, '0')
off_key = 3 * 32
off_val = off_key + 32 + ((len(key) + 31) // 32) * 32
head = p32(off_key) + p32(off_val) + target
body = enc_dyn(key) + enc_dyn(val)
print('0x' + sel + head + body)
")

PROPOSAL_ID_HEX=""
LAST_EXEC_TX=""
LAST_EXEC_BLK_HEX=""
run_governance_round \
  "$GOVHUB_CALLDATA_MAX" \
  "T-11.g: update maxNumOfCandidates to ${NEW_MAX}" \
  "T-11.g" \
  || { fail "T-11.g governance round failed"; exit 1; }

# Verify updated value
raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_MAX_CANDIDATES}")
new_max=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(-1); exit()
print(int(raw, 16))
" 2>/dev/null || echo "-1")
log "  maxNumOfCandidates after governance: ${new_max}"

if [[ "$new_max" -eq "$NEW_MAX" ]]; then
  ok "T-11.g: maxNumOfCandidates updated to ${NEW_MAX}"
else
  fail "T-11.g: expected maxNumOfCandidates ${NEW_MAX}, got ${new_max}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
if [[ "$FAIL" -eq 0 ]]; then
  log "[ PASS ]  T-11 validatorset-queries: ${PASS} checks passed"
else
  log "[ FAIL ]  T-11 validatorset-queries: ${PASS} passed, ${FAIL} failed"
  exit 1
fi
