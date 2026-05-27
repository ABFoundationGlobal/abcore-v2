#!/usr/bin/env bash
#
# 92-run-t10-governor-extended.sh — T-10: BSCGovernor extended governance scenarios
#
# T-10.a  castVoteWithReason: submit a vote with an on-chain reason string.
# T-10.b  proposal cancel: proposer cancels before execution; castVote reverts.
# T-10.c  Defeated (majority Against): all 3 validators vote Against; queue reverts.
# T-10.d  Governor updateParam via governance: change votingPeriod through
#          GovHub.updateParam and confirm the new value on-chain.
#
# Prerequisites:
#   - U-3 completed; validators have govAB voting power.
#   - Timeouts: votingPeriod=10 blocks, minDelay=3 s (abchain-local genesis).
#
# Usage:
#   GETH=./build/bin/geth bash script/test/upgrade-drill/92-run-t10-governor-extended.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

GETH=${GETH:-geth}

# ── Contract addresses ────────────────────────────────────────────────────────
GOVERNOR="0x0000000000000000000000000000000000002004"
GOV_HUB="0x0000000000000000000000000000000000001007"
STAKE_HUB="0x0000000000000000000000000000000000002002"

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
  local id_hex="$1" sel raw
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

# Build propose() calldata; sets global PROPOSE_DATA.
# Args: govhub_calldata description
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

# Build queue/execute calldata given description hash.
# Args: govhub_calldata desc_hash selector
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

# Full governance round: propose → castVote×3 → Succeeded → queue → timelock → execute
# Globals set: PROPOSAL_ID_HEX, LAST_EXEC_TX, LAST_EXEC_BLK_HEX
run_governance_round() {
  local govhub_calldata="$1" description="$2" label="$3"

  build_propose_data "$govhub_calldata" "$description"

  log ""
  log "${label}: submitting governance proposal (val1 = proposer)"
  eth_call_debug "$GOVERNOR" "$PROPOSE_DATA" "$VAL1"

  local propose_tx
  propose_tx=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$PROPOSE_DATA" "${label}:propose()") || return 1

  PROPOSAL_ID_HEX=$(attach_exec "$GETH" "$IPC1" \
    "(function(){var r=eth.getTransactionReceipt('${propose_tx}');
      if(!r||!r.logs||!r.logs.length) return 'null';
      var topic=web3.sha3('ProposalCreated(uint256,address,address[],uint256[],string[],bytes[],uint256,uint256,string)');
      var log=r.logs.filter(function(l){return l.topics&&l.topics[0]===topic;})[0];
      var d=log?log.data:null;
      return d&&d.length>=66?d.slice(2,66):'null';})()" 2>/dev/null || echo "null")
  [[ "${#PROPOSAL_ID_HEX}" -eq 64 ]] \
    || { log "  FAIL: ${label}: could not parse proposalId (got: '${PROPOSAL_ID_HEX}')" >&2; return 1; }
  ok "${label}: propose() mined; proposalId=0x${PROPOSAL_ID_HEX:0:8}…"

  log ""
  log "${label}: casting votes (FOR=1) from all 3 validators"
  sleep 3
  local cast_data
  cast_data="0x${SEL_CAST_VOTE}${PROPOSAL_ID_HEX}$(printf '%064x' 1)"
  local entry n addr ipc
  for entry in "1:${VAL1}:${IPC1}" "2:${VAL2}:${IPC2}" "3:${VAL3}:${IPC3}"; do
    n="${entry%%:*}"; addr="${entry#*:}"; addr="${addr%%:*}"; ipc="${entry##*:}"
    send_tx_wait "$ipc" "$addr" "$GOVERNOR" "0x0" 200000 "$cast_data" "${label}:castVote(val${n})" || return 1
    ok "${label}: val${n} castVote(FOR) mined"
  done

  log ""
  log "${label}: waiting for Succeeded (10 blocks, timeout 90 s)"
  wait_for_governor_state "$PROPOSAL_ID_HEX" 4 90 "Succeeded" \
    || { fail "${label}: proposal did not reach Succeeded"; return 1; }
  ok "${label}: Proposal state == Succeeded"

  local desc_hash
  desc_hash=$(attach_exec "$GETH" "$IPC1" \
    "web3.sha3('${description}').slice(2)" 2>/dev/null)
  [[ "${#desc_hash}" -eq 64 ]] || { log "  FAIL: ${label}: bad descriptionHash" >&2; return 1; }

  local queue_data execute_data
  queue_data=$(build_qe_data "$govhub_calldata" "$desc_hash" "$SEL_QUEUE")
  execute_data=$(build_qe_data "$govhub_calldata" "$desc_hash" "$SEL_EXECUTE")

  local queue_tx
  queue_tx=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$queue_data" "${label}:queue()") || return 1
  ok "${label}: queue() mined"

  local cur
  cur=$(governor_state "$PROPOSAL_ID_HEX")
  [[ "$cur" -eq 5 ]] && ok "${label}: state == Queued" || fail "${label}: expected Queued(5), got ${cur}"

  log "${label}: waiting for BSCTimelock delay (3 s)..."
  sleep 10

  LAST_EXEC_TX=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 1000000 "$execute_data" "${label}:execute()") || return 1
  ok "${label}: execute() mined"

  cur=$(governor_state "$PROPOSAL_ID_HEX")
  [[ "$cur" -eq 7 ]] && ok "${label}: state == Executed" || fail "${label}: expected Executed(7), got ${cur}"

  LAST_EXEC_BLK_HEX=$(attach_exec "$GETH" "$IPC1" \
    "(function(){var r=eth.getTransactionReceipt('${LAST_EXEC_TX}');return r?web3.toHex(r.blockNumber):'0x0';})()" \
    2>/dev/null || echo "0x0")
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
wait_for_ipc "$GETH" "$IPC1" 10
code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${GOVERNOR}','latest')" 2>/dev/null || echo "0x")
[[ $(( (${#code} - 2) / 2 )) -gt 100 ]] || die "BSCGovernor not deployed at ${GOVERNOR}. Run U-3 first."

log "T-10  BSCGovernor extended governance scenarios"
log "  Governor: ${GOVERNOR}  GovHub: ${GOV_HUB}"
log "  VAL1: ${VAL1}  VAL2: ${VAL2}  VAL3: ${VAL3}"

# ── Compute selectors ─────────────────────────────────────────────────────────
log ""
log "Computing selectors..."
SEL_PROPOSE=$(selector "propose(address[],uint256[],bytes[],string)")
SEL_CAST_VOTE=$(selector "castVote(uint256,uint8)")
SEL_CAST_VOTE_REASON=$(selector "castVoteWithReason(uint256,uint8,string)")
SEL_CANCEL=$(selector "cancel(address[],uint256[],bytes[],bytes32)")
SEL_QUEUE=$(selector "queue(address[],uint256[],bytes[],bytes32)")
SEL_EXECUTE=$(selector "execute(address[],uint256[],bytes[],bytes32)")
SEL_STATE=$(selector "state(uint256)")
SEL_HAS_VOTED=$(selector "hasVoted(uint256,address)")
SEL_VOTING_PERIOD=$(selector "votingPeriod()")
SEL_GOV_UPDATE=$(selector "updateParam(string,bytes,address)")

TOPIC_VOTE_CAST=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('VoteCast(address,uint256,uint8,uint256,string)')" 2>/dev/null)
TOPIC_PROPOSAL_CANCELED=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('ProposalCanceled(uint256)')" 2>/dev/null)
TOPIC_PARAM_CHANGE=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('ParamChange(string,bytes)')" 2>/dev/null)

for _s in SEL_PROPOSE SEL_CAST_VOTE SEL_CAST_VOTE_REASON SEL_CANCEL \
           SEL_QUEUE SEL_EXECUTE SEL_STATE SEL_HAS_VOTED SEL_VOTING_PERIOD SEL_GOV_UPDATE; do
  [[ "${!_s}" =~ ^[0-9a-fA-F]{8}$ ]] \
    || die "${_s}: bad selector '${!_s}' (geth attach failed?)"
done
log "  Selectors ready."

PROPOSAL_ID_HEX=""
LAST_EXEC_TX=""
LAST_EXEC_BLK_HEX=""

# Dummy calldata for proposals that don't need a real effect (T-10.a/b/c use a
# no-op addToValidatorWhitelist for a throwaway address to form a valid proposal).
DUMMY_ADDR="0x000000000000000000000000000000000000d00d"
DUMMY_GOVHUB=$(python3 -c "
sel = '${SEL_GOV_UPDATE}'
key = b'addToValidatorWhitelist'
val = bytes.fromhex('${DUMMY_ADDR}'.replace('0x','').zfill(40))
target = '${STAKE_HUB}'.replace('0x','').lower().zfill(64)
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

VAL1_PAD=$(printf '%064s' "${VAL1#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')

# ─────────────────────────────────────────────────────────────────────────────
# T-10.a — castVoteWithReason
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-10.a: castVoteWithReason ───────────────────────────────────────────────"

build_propose_data "$DUMMY_GOVHUB" "T-10.a: castVoteWithReason test proposal"

log "  proposing..."
propose_tx=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$PROPOSE_DATA" "T-10.a:propose") || {
  fail "T-10.a: propose() failed"; }

PROPOSAL_ID_HEX=$(attach_exec "$GETH" "$IPC1" \
  "(function(){var r=eth.getTransactionReceipt('${propose_tx}');
    if(!r||!r.logs||!r.logs.length) return 'null';
    var topic=web3.sha3('ProposalCreated(uint256,address,address[],uint256[],string[],bytes[],uint256,uint256,string)');
    var log=r.logs.filter(function(l){return l.topics&&l.topics[0]===topic;})[0];
    var d=log?log.data:null;
    return d&&d.length>=66?d.slice(2,66):'null';})()" 2>/dev/null || echo "null")
[[ "${#PROPOSAL_ID_HEX}" -eq 64 ]] || die "T-10.a: could not parse proposalId"
ok "T-10.a: propose() mined; proposalId=0x${PROPOSAL_ID_HEX:0:8}…"

sleep 3  # wait for voting delay (0 blocks but ensure tx is settled)

# castVoteWithReason(proposalId, FOR=1, reason)
REASON="supporting whitelist update"
cast_reason_data=$(python3 -c "
sel = '${SEL_CAST_VOTE_REASON}'
proposal_id = '${PROPOSAL_ID_HEX}'
support = format(1, '064x')  # FOR
reason = '''${REASON}'''.encode()
def p32(n): return format(n, '064x')
def enc_dyn(b):
    pad = ((len(b)+31)//32)*32
    return p32(len(b)) + b.hex().ljust(pad*2,'0')
# castVoteWithReason(uint256 proposalId, uint8 support, string reason)
off_reason = 3 * 32
head = proposal_id + support + p32(off_reason)
body = enc_dyn(reason)
print('0x' + sel + head + body)
")

log "  Dry-run castVoteWithReason(FOR, '${REASON}')..."
eth_call_debug "$GOVERNOR" "$cast_reason_data" "$VAL1"

blk_before=$(attach_exec "$GETH" "$IPC1" "eth.blockNumber" 2>/dev/null || echo "0")
vote_reason_tx=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 300000 "$cast_reason_data" "T-10.a:castVoteWithReason") || {
  fail "T-10.a: castVoteWithReason tx failed"; }
blk_after=$(attach_exec "$GETH" "$IPC1" \
  "(function(){var r=eth.getTransactionReceipt('${vote_reason_tx}');return r?r.blockNumber:0;})()" \
  2>/dev/null || echo "0")

# Verify hasVoted(proposalId, val1) == true
has_voted_data="0x${SEL_HAS_VOTED}${PROPOSAL_ID_HEX}${VAL1_PAD}"
raw=$(eth_call_raw "$GOVERNOR" "$has_voted_data")
if [[ "${raw: -2}" == "01" ]]; then
  ok "T-10.a: hasVoted(proposalId, val1) == true after castVoteWithReason"
else
  fail "T-10.a: hasVoted(proposalId, val1) expected true, got ${raw}"
fi

# Verify VoteCast event includes reason
blk_before_hex=$(printf '0x%x' "$blk_before")
blk_after_hex=$(printf '0x%x' "$blk_after")
vote_logs=$(eth_get_logs "$GOVERNOR" "$TOPIC_VOTE_CAST" "$blk_before_hex" "$blk_after_hex")
_t10a_ev=0
python3 - <<PYEOF 2>/dev/null || _t10a_ev=$?
import json, sys
logs = json.loads('''${vote_logs}''')
if not logs:
    print("no VoteCast event found", file=sys.stderr); sys.exit(1)
log = logs[-1]
data = log.get('data','')
if len(data) < 10:
    print(f"VoteCast data too short: {data!r}", file=sys.stderr); sys.exit(1)
# VoteCast non-indexed data: (uint256 proposalId, uint8 support, uint256 weight, string reason)
# [0:32]=proposalId  [32:64]=support  [64:96]=weight  [96:128]=offset_to_reason
try:
    raw = bytes.fromhex(data[2:] if data.startswith('0x') else data)
    off = int.from_bytes(raw[96:128], 'big')
    slen = int.from_bytes(raw[off:off+32], 'big')
    reason = raw[off+32:off+32+slen].decode('utf-8', 'replace')
    expected = '${REASON}'
    if reason != expected:
        print(f"reason mismatch: expected {expected!r}, got {reason!r}", file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f"VoteCast reason parse error: {e}", file=sys.stderr); sys.exit(1)
PYEOF
if [[ "$_t10a_ev" -eq 0 ]]; then
  ok "T-10.a: VoteCast event emitted with reason field"
else
  fail "T-10.a: VoteCast event missing or reason mismatch"
fi

# BSC Governor restricts proposers to one active proposal at a time.
# Cast val2/val3 Against votes on T-10.a so the majority resolves quickly,
# then wait for the voting period to end (≤90 s) before T-10.b proposes.
log "  Resolving T-10.a: val2/val3 vote Against so voting period ends as Defeated..."
_cast_against="0x${SEL_CAST_VOTE}${PROPOSAL_ID_HEX}$(printf '%064x' 0)"
send_tx_wait "$IPC2" "$VAL2" "$GOVERNOR" "0x0" 200000 "$_cast_against" "T-10.a:val2-against" >/dev/null 2>&1 || true
send_tx_wait "$IPC3" "$VAL3" "$GOVERNOR" "0x0" 200000 "$_cast_against" "T-10.a:val3-against" >/dev/null 2>&1 || true
log "  Waiting for T-10.a proposal to leave Active state (voting period = 10 blocks)..."
_t10a_deadline=$(( $(date +%s) + 90 ))
while true; do
  _cur=$(governor_state "$PROPOSAL_ID_HEX")
  [[ "$_cur" != "1" ]] && { log "  T-10.a finished (state=${_cur} = Defeated)"; break; }
  [[ $(date +%s) -ge $_t10a_deadline ]] && { log "  WARNING: T-10.a still Active after 90s — proceeding anyway"; break; }
  sleep 2
done

# ─────────────────────────────────────────────────────────────────────────────
# T-10.b — proposal cancel
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-10.b: proposal cancel ──────────────────────────────────────────────────"

CANCEL_DESC="T-10.b: cancel test proposal"
build_propose_data "$DUMMY_GOVHUB" "$CANCEL_DESC"

log "  proposing (to be cancelled)..."
propose_tx=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$PROPOSE_DATA" "T-10.b:propose") || {
  fail "T-10.b: propose() failed"; }

PROPOSAL_ID_HEX=$(attach_exec "$GETH" "$IPC1" \
  "(function(){var r=eth.getTransactionReceipt('${propose_tx}');
    if(!r||!r.logs||!r.logs.length) return 'null';
    var topic=web3.sha3('ProposalCreated(uint256,address,address[],uint256[],string[],bytes[],uint256,uint256,string)');
    var log=r.logs.filter(function(l){return l.topics&&l.topics[0]===topic;})[0];
    var d=log?log.data:null;
    return d&&d.length>=66?d.slice(2,66):'null';})()" 2>/dev/null || echo "null")
[[ "${#PROPOSAL_ID_HEX}" -eq 64 ]] || die "T-10.b: could not parse proposalId"
ok "T-10.b: propose() mined"

# cancel(targets, values, calldatas, descHash)
desc_hash=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('${CANCEL_DESC}').slice(2)" 2>/dev/null)
[[ "${#desc_hash}" -eq 64 ]] || die "T-10.b: bad descriptionHash"

cancel_data=$(build_qe_data "$DUMMY_GOVHUB" "$desc_hash" "$SEL_CANCEL")
log "  cancelling proposal (from val1, the proposer)..."
blk_before=$(attach_exec "$GETH" "$IPC1" "eth.blockNumber" 2>/dev/null || echo "0")
cancel_tx=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 300000 "$cancel_data" "T-10.b:cancel") || {
  fail "T-10.b: cancel() tx failed"; }
blk_after=$(attach_exec "$GETH" "$IPC1" \
  "(function(){var r=eth.getTransactionReceipt('${cancel_tx}');return r?r.blockNumber:0;})()" \
  2>/dev/null || echo "0")

# Verify state == Canceled (2)
cur=$(governor_state "$PROPOSAL_ID_HEX")
if [[ "$cur" -eq 2 ]]; then
  ok "T-10.b: proposal state == Canceled (2)"
else
  fail "T-10.b: expected state Canceled(2), got ${cur}"
fi

# Verify ProposalCanceled event
blk_before_hex=$(printf '0x%x' "$blk_before")
blk_after_hex=$(printf '0x%x' "$blk_after")
cancel_logs=$(eth_get_logs "$GOVERNOR" "$TOPIC_PROPOSAL_CANCELED" "$blk_before_hex" "$blk_after_hex")
_t10b_ev=0
python3 - <<PYEOF 2>/dev/null || _t10b_ev=$?
import json, sys
logs = json.loads('''${cancel_logs}''')
if not logs: print("no ProposalCanceled event", file=sys.stderr); sys.exit(1)
PYEOF
if [[ "$_t10b_ev" -eq 0 ]]; then
  ok "T-10.b: ProposalCanceled event emitted"
else
  fail "T-10.b: ProposalCanceled event missing"
fi

# Verify castVote on a Canceled proposal reverts
cast_data="0x${SEL_CAST_VOTE}${PROPOSAL_ID_HEX}$(printf '%064x' 1)"
cast_resp=$(curl -sS -X POST "$HTTP1" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"${GOVERNOR}\",\"from\":\"${VAL2}\",\"data\":\"${cast_data}\"},\"latest\"],\"id\":1}" \
  2>/dev/null | python3 -c '
import json,sys
r=json.load(sys.stdin)
print("revert" if "error" in r else "ok")' 2>/dev/null || echo "revert")
if [[ "$cast_resp" == "revert" ]]; then
  ok "T-10.b: castVote on Canceled proposal reverts as expected"
else
  fail "T-10.b: castVote on Canceled proposal did not revert"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-10.c — Defeated (majority Against)
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-10.c: Defeated (majority Against) ─────────────────────────────────────"

DEFEATED_DESC="T-10.c: defeated test proposal (all vote against)"
build_propose_data "$DUMMY_GOVHUB" "$DEFEATED_DESC"

log "  proposing..."
propose_tx=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$PROPOSE_DATA" "T-10.c:propose") || {
  fail "T-10.c: propose() failed"; }

PROPOSAL_ID_HEX=$(attach_exec "$GETH" "$IPC1" \
  "(function(){var r=eth.getTransactionReceipt('${propose_tx}');
    if(!r||!r.logs||!r.logs.length) return 'null';
    var topic=web3.sha3('ProposalCreated(uint256,address,address[],uint256[],string[],bytes[],uint256,uint256,string)');
    var log=r.logs.filter(function(l){return l.topics&&l.topics[0]===topic;})[0];
    var d=log?log.data:null;
    return d&&d.length>=66?d.slice(2,66):'null';})()" 2>/dev/null || echo "null")
[[ "${#PROPOSAL_ID_HEX}" -eq 64 ]] || die "T-10.c: could not parse proposalId"
ok "T-10.c: propose() mined"

sleep 3
log "  casting AGAINST votes (support=0) from all 3 validators..."
against_data="0x${SEL_CAST_VOTE}${PROPOSAL_ID_HEX}$(printf '%064x' 0)"  # AGAINST = 0
for entry in "1:${VAL1}:${IPC1}" "2:${VAL2}:${IPC2}" "3:${VAL3}:${IPC3}"; do
  n="${entry%%:*}"; addr="${entry#*:}"; addr="${addr%%:*}"; ipc="${entry##*:}"
  send_tx_wait "$ipc" "$addr" "$GOVERNOR" "0x0" 200000 "$against_data" "T-10.c:castVote(AGAINST,val${n})" || \
    fail "T-10.c: castVote(AGAINST) from val${n} failed"
  ok "T-10.c: val${n} castVote(AGAINST) mined"
done

log "  waiting for voting period end (Defeated state=3, timeout 90 s)..."
wait_for_governor_state "$PROPOSAL_ID_HEX" 3 90 "Defeated" \
  || { fail "T-10.c: proposal did not reach Defeated"; }

cur=$(governor_state "$PROPOSAL_ID_HEX")
if [[ "$cur" -eq 3 ]]; then
  ok "T-10.c: proposal state == Defeated (3)"
else
  fail "T-10.c: expected state Defeated(3), got ${cur}"
fi

# Verify queue() on Defeated proposal reverts
desc_hash=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('${DEFEATED_DESC}').slice(2)" 2>/dev/null)
[[ "${#desc_hash}" -eq 64 ]] || die "T-10.c: bad descriptionHash"
queue_data=$(build_qe_data "$DUMMY_GOVHUB" "$desc_hash" "$SEL_QUEUE")
queue_resp=$(curl -sS -X POST "$HTTP1" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"${GOVERNOR}\",\"from\":\"${VAL1}\",\"data\":\"${queue_data}\"},\"latest\"],\"id\":1}" \
  2>/dev/null | python3 -c '
import json,sys
r=json.load(sys.stdin)
print("revert" if "error" in r else "ok")' 2>/dev/null || echo "revert")
if [[ "$queue_resp" == "revert" ]]; then
  ok "T-10.c: queue() on Defeated proposal reverts (ProposalNotSuccessful)"
else
  fail "T-10.c: queue() on Defeated proposal did not revert"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-10.d — Governor updateParam via governance (change votingPeriod)
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-10.d: Governor updateParam (change votingPeriod) ──────────────────────"

# Read current votingPeriod
raw=$(eth_call_raw "$GOVERNOR" "0x${SEL_VOTING_PERIOD}")
current_vp=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(0); exit()
print(int(raw, 16))
" 2>/dev/null || echo "0")
log "  current votingPeriod: ${current_vp} blocks"

# New value: current + 2 (to ensure it changes and stays reasonable)
NEW_VP=$(( current_vp + 2 ))
log "  target new votingPeriod: ${NEW_VP} blocks"

# Encode GovHub.updateParam("votingPeriod", newValue, GOVERNOR)
GOVHUB_CALLDATA_VP=$(python3 -c "
sel = '${SEL_GOV_UPDATE}'
key = b'votingPeriod'
val = int('${NEW_VP}').to_bytes(32, 'big')
target = '${GOVERNOR}'.replace('0x','').lower().zfill(64)
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
run_governance_round "$GOVHUB_CALLDATA_VP" "T-10.d: update votingPeriod to ${NEW_VP}" "T-10.d" \
  || { fail "T-10.d governance round failed"; exit 1; }

# Verify votingPeriod updated
raw=$(eth_call_raw "$GOVERNOR" "0x${SEL_VOTING_PERIOD}")
new_vp=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(-1); exit()
print(int(raw, 16))
" 2>/dev/null || echo "-1")
log "  BSCGovernor.votingPeriod() after governance: ${new_vp}"

if [[ "$new_vp" -eq "$NEW_VP" ]]; then
  ok "T-10.d: BSCGovernor.votingPeriod() == ${NEW_VP} (updated via governance)"
else
  fail "T-10.d: expected votingPeriod ${NEW_VP}, got ${new_vp}"
fi

# Verify ParamChange event in BSCGovernor (ParamChange is emitted by BSCGovernor, not GovHub)
param_logs=$(eth_get_logs "$GOVERNOR" "$TOPIC_PARAM_CHANGE" "$LAST_EXEC_BLK_HEX" "$LAST_EXEC_BLK_HEX")
_t10d_ev=0
python3 - <<PYEOF 2>/dev/null || _t10d_ev=$?
import json, sys
logs = json.loads('''${param_logs}''')
if not logs: print("no ParamChange event in BSCGovernor", file=sys.stderr); sys.exit(1)
PYEOF
if [[ "$_t10d_ev" -eq 0 ]]; then
  ok "T-10.d: ParamChange event emitted in BSCGovernor"
else
  fail "T-10.d: ParamChange event missing in BSCGovernor"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
if [[ "$FAIL" -eq 0 ]]; then
  log "[ PASS ]  T-10 governor-extended: ${PASS} checks passed"
else
  log "[ FAIL ]  T-10 governor-extended: ${PASS} passed, ${FAIL} failed"
  exit 1
fi
