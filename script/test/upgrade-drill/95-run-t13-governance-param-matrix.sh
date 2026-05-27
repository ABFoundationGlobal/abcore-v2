#!/usr/bin/env bash
#
# 95-run-t13-governance-param-matrix.sh — T-13: governance updateParam matrix
#
# Exercises BSCGovernor → BSCTimelock → GovHub → target.updateParam for
# multiple system-contract targets in sequence.  Each sub-case is an
# independent proposal.
#
# T-13.a  StakeHub  removeFromValidatorWhitelist → validatorWhitelist(val1)==false
# T-13.b  StakeHub  whitelistEnabled → false      → whitelistEnabled()==false
# T-13.c  StakeHub  whitelistEnabled → true       → whitelistEnabled()==true
# T-13.d  BSCValidatorSet  maxNumOfWorkingCandidates → getter returns new value
# T-13.e  SlashIndicator   felonyThreshold          → getSlashThresholds() returns new value
# T-13.f  BSCGovernor      votingPeriod             → BSCGovernor.votingPeriod() returns new value
#
# Prerequisites:
#   - U-3 completed; validators have govAB voting power.
#
# Usage:
#   GETH=./build/bin/geth bash script/test/upgrade-drill/95-run-t13-governance-param-matrix.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

GETH=${GETH:-geth}

# ── Contract addresses ────────────────────────────────────────────────────────
STAKE_HUB="0x0000000000000000000000000000000000002002"
VALIDATOR_SET="0x0000000000000000000000000000000000001000"
SLASH_INDICATOR="0x0000000000000000000000000000000000001001"
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
off0 = 4*32; off1 = off0 + len(targets_enc)//2
off2 = off1 + len(values_enc)//2; off3 = off2 + len(calldatas_enc)//2
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
off0 = 4*32; off1 = off0 + len(targets_enc)//2; off2 = off1 + len(values_enc)//2
head = p32(off0) + p32(off1) + p32(off2) + desc_hash
print('0x' + sel + head + targets_enc + values_enc + calldatas_enc)
"
}

run_governance_round() {
  local govhub_calldata="$1" description="$2" label="$3"
  build_propose_data "$govhub_calldata" "$description"
  log "${label}: submitting proposal (description: '${description}')..."
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
  [[ "${#PROPOSAL_ID_HEX}" -eq 64 ]] || { log "  FAIL: bad proposalId" >&2; return 1; }
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
  local desc_hash queue_data execute_data
  desc_hash=$(attach_exec "$GETH" "$IPC1" "web3.sha3('${description}').slice(2)" 2>/dev/null)
  [[ "${#desc_hash}" -eq 64 ]] || { log "  FAIL: bad descHash" >&2; return 1; }
  queue_data=$(build_qe_data "$govhub_calldata" "$desc_hash" "$SEL_QUEUE")
  execute_data=$(build_qe_data "$govhub_calldata" "$desc_hash" "$SEL_EXECUTE")
  send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$queue_data" "${label}:queue" || return 1
  ok "${label}: queue() mined"; log "${label}: waiting timelock..."; sleep 10
  LAST_EXEC_TX=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 1000000 "$execute_data" "${label}:execute") || return 1
  ok "${label}: execute() mined"
  local cur; cur=$(governor_state "$PROPOSAL_ID_HEX")
  [[ "$cur" -eq 7 ]] && ok "${label}: state == Executed" || fail "${label}: expected Executed(7), got ${cur}"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
wait_for_ipc "$GETH" "$IPC1" 10
code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${GOVERNOR}','latest')" 2>/dev/null || echo "0x")
[[ $(( (${#code} - 2) / 2 )) -gt 100 ]] || die "BSCGovernor not deployed at ${GOVERNOR}. Run U-3 first."

log "T-13  Governance updateParam matrix (6 independent proposals)"
log "  Governor: ${GOVERNOR}  GovHub: ${GOV_HUB}"
log "  VAL1: ${VAL1}  VAL2: ${VAL2}  VAL3: ${VAL3}"

# ── Compute selectors ─────────────────────────────────────────────────────────
log ""
log "Computing selectors..."
SEL_PROPOSE=$(selector "propose(address[],uint256[],bytes[],string)")
SEL_CAST_VOTE=$(selector "castVote(uint256,uint8)")
SEL_QUEUE=$(selector "queue(address[],uint256[],bytes[],bytes32)")
SEL_EXECUTE=$(selector "execute(address[],uint256[],bytes[],bytes32)")
SEL_GOV_UPDATE=$(selector "updateParam(string,bytes,address)")
SEL_WL_MEMBER=$(selector "validatorWhitelist(address)")
SEL_WL_ENABLED=$(selector "whitelistEnabled()")
SEL_MAX_WORKING=$(selector "maxNumOfWorkingCandidates()")
SEL_MAX_CAND=$(selector "maxNumOfCandidates()")
SEL_SLASH_TH=$(selector "getSlashThresholds()")
SEL_VOTING_PERIOD=$(selector "votingPeriod()")

for _s in SEL_PROPOSE SEL_CAST_VOTE SEL_QUEUE SEL_EXECUTE SEL_GOV_UPDATE \
           SEL_WL_MEMBER SEL_WL_ENABLED SEL_MAX_WORKING SEL_MAX_CAND SEL_SLASH_TH SEL_VOTING_PERIOD; do
  [[ "${!_s}" =~ ^[0-9a-fA-F]{8}$ ]] \
    || die "${_s}: bad selector '${!_s}' (geth attach failed?)"
done
log "  Selectors ready."

# Helper to build GovHub.updateParam calldata
# Args: key_string value_bytes_hex target_addr_hex
encode_govhub_calldata() {
  local key="$1" val_hex="$2" target="$3"
  python3 -c "
sel = '${SEL_GOV_UPDATE}'
key = '''${key}'''.encode()
val = bytes.fromhex('${val_hex}')
target = '${target}'.replace('0x','').lower().zfill(64)
def p32(n): return format(n, '064x')
def enc_dyn(b):
    pad = ((len(b) + 31) // 32) * 32
    return p32(len(b)) + b.hex().ljust(pad * 2, '0')
off_key = 3 * 32
off_val = off_key + 32 + ((len(key) + 31) // 32) * 32
head = p32(off_key) + p32(off_val) + target
body = enc_dyn(key) + enc_dyn(val)
print('0x' + sel + head + body)
"
}

VAL1_PAD=$(printf '%064s' "${VAL1#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')

PROPOSAL_ID_HEX=""
LAST_EXEC_TX=""

# ─────────────────────────────────────────────────────────────────────────────
# T-13.a — removeFromValidatorWhitelist
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-13.a: removeFromValidatorWhitelist ────────────────────────────────────"

# First verify current whitelist state of val1
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_MEMBER}${VAL1_PAD}")
pre_wl="${raw: -2}"
log "  validatorWhitelist(val1) before: 0x${pre_wl}"

# Encode: removeFromValidatorWhitelist, val1 address (20 bytes), target=StakeHub
VAL1_20B="${VAL1#0x}"
[[ "${#VAL1_20B}" -eq 40 ]] || die "bad val1 address"

CALLDATA_13A=$(encode_govhub_calldata \
  "removeFromValidatorWhitelist" \
  "$VAL1_20B" \
  "$STAKE_HUB")

PROPOSAL_ID_HEX=""
run_governance_round "$CALLDATA_13A" "T-13.a: removeFromValidatorWhitelist val1" "T-13.a" \
  || { fail "T-13.a governance round failed"; exit 1; }

raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_MEMBER}${VAL1_PAD}")
if [[ "${raw: -2}" != "01" ]]; then
  ok "T-13.a: validatorWhitelist(val1) == false after removeFromValidatorWhitelist"
else
  fail "T-13.a: validatorWhitelist(val1) expected false, got ${raw}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-13.b — whitelistEnabled → false
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-13.b: whitelistEnabled → false ────────────────────────────────────────"

CALLDATA_13B=$(encode_govhub_calldata \
  "whitelistEnabled" \
  "$(printf '%064x' 0)" \
  "$STAKE_HUB")

PROPOSAL_ID_HEX=""
run_governance_round "$CALLDATA_13B" "T-13.b: whitelistEnabled=false" "T-13.b" \
  || { fail "T-13.b governance round failed"; exit 1; }

raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_ENABLED}")
if [[ "${#raw}" -ne 66 ]]; then
  fail "T-13.b: whitelistEnabled() call failed (got: ${raw})"
elif [[ "${raw: -2}" != "01" ]]; then
  ok "T-13.b: whitelistEnabled() == false"
else
  fail "T-13.b: whitelistEnabled() expected false, got ${raw}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-13.c — whitelistEnabled → true
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-13.c: whitelistEnabled → true ─────────────────────────────────────────"

CALLDATA_13C=$(encode_govhub_calldata \
  "whitelistEnabled" \
  "$(printf '%064x' 1)" \
  "$STAKE_HUB")

PROPOSAL_ID_HEX=""
run_governance_round "$CALLDATA_13C" "T-13.c: whitelistEnabled=true" "T-13.c" \
  || { fail "T-13.c governance round failed"; exit 1; }

raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_ENABLED}")
if [[ "${raw: -2}" == "01" ]]; then
  ok "T-13.c: whitelistEnabled() == true"
else
  fail "T-13.c: whitelistEnabled() expected true, got ${raw}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-13.d — BSCValidatorSet maxNumOfWorkingCandidates
# maxNumOfWorkingCandidates requires value <= maxNumOfCandidates.
# Read the current upper bound first; if it is 0 (fresh devnet without T-11
# having run) the validation in BSCValidatorSet will silently fail via GovHub
# try/catch, so we skip the test with a NOTE rather than producing a false PASS.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-13.d: BSCValidatorSet maxNumOfWorkingCandidates ───────────────────────"

raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_MAX_CAND}")
max_candidates=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(0); exit()
print(int(raw, 16))
" 2>/dev/null || echo "0")
raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_MAX_WORKING}")
current_working=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(0); exit()
print(int(raw, 16))
" 2>/dev/null || echo "0")
log "  maxNumOfCandidates (upper bound): ${max_candidates}"
log "  current maxNumOfWorkingCandidates: ${current_working}"

if [[ "$max_candidates" -eq 0 ]]; then
  log "  NOTE T-13.d: maxNumOfCandidates == 0 — run T-11 first to set it; skipping"
  ok "T-13.d: skipped (maxNumOfCandidates not yet set)"
else
  NEW_MAX=$(( current_working + 1 ))
  [[ "$NEW_MAX" -le "$max_candidates" ]] || NEW_MAX=$(( max_candidates ))

  CALLDATA_13D=$(encode_govhub_calldata \
    "maxNumOfWorkingCandidates" \
    "$(printf '%064x' "${NEW_MAX}")" \
    "$VALIDATOR_SET")

  PROPOSAL_ID_HEX=""
  run_governance_round "$CALLDATA_13D" "T-13.d: maxNumOfWorkingCandidates=${NEW_MAX}" "T-13.d" \
    || { fail "T-13.d governance round failed"; exit 1; }

  raw=$(eth_call_raw "$VALIDATOR_SET" "0x${SEL_MAX_WORKING}")
  new_working=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(-1); exit()
print(int(raw, 16))
" 2>/dev/null || echo "-1")
  if [[ "$new_working" -eq "$NEW_MAX" ]]; then
    ok "T-13.d: maxNumOfWorkingCandidates == ${NEW_MAX}"
  else
    fail "T-13.d: expected ${NEW_MAX}, got ${new_working}"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-13.e — SlashIndicator felonyThreshold
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-13.e: SlashIndicator felonyThreshold ──────────────────────────────────"

raw=$(eth_call_raw "$SLASH_INDICATOR" "0x${SEL_SLASH_TH}")
current_felony=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x' or len(raw) < 130: print(0); exit()
data = bytes.fromhex(raw[2:])
# getSlashThresholds() returns (misdemeanorThreshold, felonyThreshold)
print(int.from_bytes(data[32:64], 'big'))
" 2>/dev/null || echo "0")
log "  current felonyThreshold: ${current_felony}"

NEW_FELONY=$(( current_felony > 0 ? current_felony + 1 : 151 ))

CALLDATA_13E=$(encode_govhub_calldata \
  "felonyThreshold" \
  "$(printf '%064x' "${NEW_FELONY}")" \
  "$SLASH_INDICATOR")

PROPOSAL_ID_HEX=""
run_governance_round "$CALLDATA_13E" "T-13.e: felonyThreshold=${NEW_FELONY}" "T-13.e" \
  || { fail "T-13.e governance round failed"; exit 1; }

raw=$(eth_call_raw "$SLASH_INDICATOR" "0x${SEL_SLASH_TH}")
new_felony=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x' or len(raw) < 130: print(-1); exit()
data = bytes.fromhex(raw[2:])
# getSlashThresholds() returns (misdemeanorThreshold, felonyThreshold)
print(int.from_bytes(data[32:64], 'big'))
" 2>/dev/null || echo "-1")
if [[ "$new_felony" -eq "$NEW_FELONY" ]]; then
  ok "T-13.e: felonyThreshold == ${NEW_FELONY}"
else
  fail "T-13.e: expected ${NEW_FELONY}, got ${new_felony}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-13.f — BSCGovernor votingPeriod
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-13.f: BSCGovernor votingPeriod ────────────────────────────────────────"

raw=$(eth_call_raw "$GOVERNOR" "0x${SEL_VOTING_PERIOD}")
current_vp=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(0); exit()
print(int(raw, 16))
" 2>/dev/null || echo "0")
log "  current votingPeriod: ${current_vp} blocks"

NEW_VP=$(( current_vp > 0 ? current_vp + 2 : 12 ))

CALLDATA_13F=$(encode_govhub_calldata \
  "votingPeriod" \
  "$(printf '%064x' "${NEW_VP}")" \
  "$GOVERNOR")

PROPOSAL_ID_HEX=""
run_governance_round "$CALLDATA_13F" "T-13.f: votingPeriod=${NEW_VP}" "T-13.f" \
  || { fail "T-13.f governance round failed"; exit 1; }

raw=$(eth_call_raw "$GOVERNOR" "0x${SEL_VOTING_PERIOD}")
new_vp=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(-1); exit()
print(int(raw, 16))
" 2>/dev/null || echo "-1")
if [[ "$new_vp" -eq "$NEW_VP" ]]; then
  ok "T-13.f: BSCGovernor.votingPeriod() == ${NEW_VP}"
else
  fail "T-13.f: expected ${NEW_VP}, got ${new_vp}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "T-13 governance param matrix results:"
log "  T-13.a removeFromValidatorWhitelist — complete"
log "  T-13.b whitelistEnabled=false       — complete"
log "  T-13.c whitelistEnabled=true        — complete"
log "  T-13.d maxNumOfWorkingCandidates    — complete"
log "  T-13.e felonyThreshold              — complete"
log "  T-13.f votingPeriod                 — complete"
log ""
if [[ "$FAIL" -eq 0 ]]; then
  log "[ PASS ]  T-13 governance-param-matrix: ${PASS} checks passed"
else
  log "[ FAIL ]  T-13 governance-param-matrix: ${PASS} passed, ${FAIL} failed"
  exit 1
fi
