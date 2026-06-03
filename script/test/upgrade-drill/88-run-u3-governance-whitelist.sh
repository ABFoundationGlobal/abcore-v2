#!/usr/bin/env bash
#
# 88-run-u3-governance-whitelist.sh — T-6.h/i/j: full governance whitelist tests
#
# T-6.h  addToValidatorWhitelist via governance (original test):
#   BSCGovernor.propose → castVote × 3 → queue → (timelock) → execute
#   → StakeHub.validatorWhitelist(newAddr) == true
#
# T-6.i  removeFromValidatorWhitelist via governance:
#   Full governance round to remove val1_consensus from the whitelist.
#   Verifies whitelist storage, election power reverts to stake-based,
#   and ValidatorWhitelistUpdated(val1, false) event emitted.
#
# T-6.j  whitelistEnabled toggle via governance (Part A off, Part B on):
#   Part A: disable whitelist → all validators revert to stake-based power,
#           WhitelistEnabledUpdated(false) event emitted.
#   Part B: re-enable whitelist → val2/val3 (still whitelisted) back to
#           WHITELIST_VOTING_POWER; val1 (removed in T-6.i) stays stake-based.
#
# T-6.n (false path): ValidatorWhitelistUpdated data field after T-6.i:
#   data == 0x...0000 (whitelisted=false); complements T-6.n true-path in 87.
#
# Uses the reduced timeouts baked into the abchain-local genesis by generate.py:
#   init_voting_period          = 10 blocks  (≈ 30 s at 3 s/block)
#   init_voting_delay           = 0 blocks   (Active immediately)
#   init_min_period_after_quorum = 0 blocks
#   init_minimal_delay          = 3 seconds  (BSCTimelock; 1 block at 3 s/block)
#   propose_start_threshold     = 0 ether    (no total-supply gate)
#
# Prerequisites:
#   - U-3 (82-run-u3-shanghai-feynman.sh) completed; all 3 nodes running
#   - Validators registered via StakeHub.createValidator() (done by U-3 script)
#
# Usage:
#   GETH=./build/bin/geth bash script/test/upgrade-drill/88-run-u3-governance-whitelist.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

GETH=${GETH:-geth}

# ── Contract addresses ────────────────────────────────────────────────────────
GOVERNOR="0x0000000000000000000000000000000000002004"
GOV_HUB="0x0000000000000000000000000000000000001007"
STAKE_HUB="0x0000000000000000000000000000000000002002"
NEW_WL_ADDR="0x000000000000000000000000000000000000beef"

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

# Simulate a call and print the revert reason (Error(string) or custom error selector).
# Usage: eth_call_debug <to> <data> [from_addr]
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

# Query eth_getLogs for a single topic from a contract address.
# Arguments: address topic0_hex fromBlock(hex) toBlock
# Prints JSON array of log objects.
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

# Send tx via ipc; wait up to 60 s for receipt; echo tx hash to stdout or print
# error to stderr and return 1.  Stderr is used so callers like TX=$(send_tx_wait ...)
# still see the error message even though stdout is captured.
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
      log "  [post-revert] eth_call dry-run to get revert reason..." >&2
      eth_call_debug "$to_addr" "$data" "$from_addr" >&2 || true
      return 1
    fi
  done
  # tx not mined — check if it was evicted from pool and retry once
  local _tx_in_pool
  _tx_in_pool=$(attach_exec "$GETH" "$IPC1" \
    "(function(){var t=eth.getTransactionByHash('${tx}');return t?'found':'null';})()" \
    2>/dev/null || echo "null")
  if [[ "$_tx_in_pool" == "null" ]]; then
    log "  ${label}: tx dropped from pool (nonce evicted by system tx) — re-submitting..." >&2
    tx=$(attach_exec "$GETH" "$ipc" \
      "eth.sendTransaction({from:'${from_addr}',to:'${to_addr}',value:'${value_hex}',gas:${gas},data:'${data}'})" \
      2>/dev/null || echo "")
    if [[ "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
      log "  ${label}: re-submitted tx=${tx:0:20}…" >&2
      for i in $(seq 1 60); do
        sleep 1
        status=$(attach_exec "$GETH" "$IPC1" \
          "(function(){var r=eth.getTransactionReceipt('${tx}');return r?r.status:'p';})()" \
          2>/dev/null || echo "p")
        if [[ "$status" == "0x1" || "$status" == "1" ]]; then echo "$tx"; return 0; fi
        if [[ "$status" == "0x0" || "$status" == "0" ]]; then
          log "  FAIL: ${label}: re-submitted tx reverted (tx=${tx})" >&2
          return 1
        fi
      done
    fi
  fi
  log "  FAIL: ${label}: tx not mined in 60 s (tx=${tx})" >&2
  # Dump txpool diagnostics
  local nonce_l nonce_p pool_s pool_c tx_info
  nonce_l=$(attach_exec "$GETH" "$IPC1" "eth.getTransactionCount('${from_addr}','latest')"  2>/dev/null | tr -d '"' || echo "err")
  nonce_p=$(attach_exec "$GETH" "$IPC1" "eth.getTransactionCount('${from_addr}','pending')" 2>/dev/null | tr -d '"' || echo "err")
  pool_s=$(attach_exec "$GETH" "$IPC1" \
    "(function(){var s=txpool.status();return JSON.stringify({pending:s.pending,queued:s.queued});})()" \
    2>/dev/null | tr -d '"' || echo "err")
  pool_c=$(attach_exec "$GETH" "$IPC1" \
    "(function(){var c=txpool.content();var a='${from_addr}'.toLowerCase();var p=c.pending&&c.pending[a]?Object.keys(c.pending[a]):'[]';var q=c.queued&&c.queued[a]?Object.keys(c.queued[a]):'[]';return JSON.stringify({pending_nonces:p,queued_nonces:q});})()" \
    2>/dev/null | tr -d '"' || echo "err")
  tx_info=$(attach_exec "$GETH" "$IPC1" \
    "(function(){var t=eth.getTransactionByHash('${tx}');return t?JSON.stringify({nonce:t.nonce,blockNumber:t.blockNumber}):'null';})()" \
    2>/dev/null | tr -d '"' || echo "err")
  log "  [DEBUG] nonce_latest=${nonce_l}  nonce_pending=${nonce_p}" >&2
  log "  [DEBUG] txByHash=${tx_info}  pool_in=${_tx_in_pool}" >&2
  log "  [DEBUG] txpool.status=${pool_s}" >&2
  log "  [DEBUG] txpool.content[${from_addr:0:10}...]=${pool_c}" >&2
  return 1
}

# Query BSCGovernor.state(proposalId); returns decimal integer
governor_state() {
  local id_hex="$1" sel raw
  sel=$(selector "state(uint256)")
  raw=$(eth_call_raw "$GOVERNOR" "0x${sel}${id_hex}")
  python3 -c "print(int('${raw}' if '${raw}'.startswith('0x') else '0x0', 16))" 2>/dev/null || echo "-1"
}

# Poll until state == expected or timeout
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

# Extract votingPowers[] from the ABI-encoded return of getValidatorElectionInfo.
# Prints one decimal integer per line.
parse_voting_powers() {
  python3 -c "
import sys
raw = '''${1}'''.strip()
if not raw or raw == '0x': sys.exit(1)
if raw.startswith('0x'): raw = raw[2:]
if len(raw) < 128: sys.exit(1)
data = bytes.fromhex(raw)
vp_off = int.from_bytes(data[32:64], 'big')
vp_len = int.from_bytes(data[vp_off:vp_off+32], 'big')
for i in range(vp_len):
    start = vp_off + 32 + i * 32
    print(int.from_bytes(data[start:start+32], 'big'))
"
}

count_wl_validators() {
  local raw="$1" wl_count=0 vp
  while IFS= read -r vp; do
    [[ -z "$vp" ]] && continue
    [[ "$vp" == "$WHITELIST_VP" ]] && wl_count=$(( wl_count + 1 ))
  done < <(parse_voting_powers "$raw")
  echo "$wl_count"
}

# ── run_governance_round ──────────────────────────────────────────────────────
# Execute a full governance proposal cycle:
#   propose → castVote(FOR)×3 → wait Succeeded → queue → wait timelock → execute
#
# Globals set on return:
#   PROPOSAL_ID_HEX   — 64 hex chars (no 0x) of the proposal ID
#   LAST_EXEC_TX      — 0x-prefixed execute() tx hash
#   LAST_EXEC_BLK_HEX — 0x-prefixed block number where execute() was mined
#
# Arguments:
#   $1  govhub_calldata  — full 0x-prefixed hex calldata for GovHub.updateParam(...)
#   $2  description      — human-readable proposal description (must be unique)
#   $3  label            — short label for log output (e.g. "T-6.h")
run_governance_round() {
  local govhub_calldata="$1" description="$2" label="$3"

  # ── propose ──
  log ""
  log "${label}: submitting governance proposal (val1 = proposer)"
  log "  description: ${description}"

  local propose_data
  propose_data=$(python3 -c "
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

  log "  PROPOSE_DATA size: $((( ${#propose_data} - 2 ) / 2)) bytes"
  log "  Dry-run eth_call propose() from val1 (${VAL1})..."
  eth_call_debug "$GOVERNOR" "$propose_data" "$VAL1"

  local propose_tx
  propose_tx=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$propose_data" "${label}:propose()") || return 1

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

  # ── cast votes ──
  log ""
  log "${label}: casting votes (FOR) from all 3 validators"
  sleep 3
  local cast_data
  cast_data="0x${SEL_CAST_VOTE}${PROPOSAL_ID_HEX}$(printf '%064x' 1)"
  local entry n addr ipc vtx
  for entry in "1:${VAL1}:${IPC1}" "2:${VAL2}:${IPC2}" "3:${VAL3}:${IPC3}"; do
    n="${entry%%:*}"; addr="${entry#*:}"; addr="${addr%%:*}"; ipc="${entry##*:}"
    vtx=$(send_tx_wait "$ipc" "$addr" "$GOVERNOR" "0x0" 200000 "$cast_data" "${label}:castVote(val${n})") || return 1
    ok "${label}: val${n} castVote(FOR) mined"
  done

  # ── wait Succeeded (state=4) ──
  log ""
  log "${label}: waiting for voting period (10 blocks × 3 s, timeout 90 s)"
  wait_for_governor_state "$PROPOSAL_ID_HEX" 4 90 "Succeeded" \
    || { fail "${label}: proposal did not reach Succeeded"; return 1; }
  ok "${label}: Proposal state == Succeeded"

  # ── queue ──
  log ""
  log "${label}: queuing proposal"
  local desc_hash
  desc_hash=$(attach_exec "$GETH" "$IPC1" \
    "web3.sha3('${description}').slice(2)" 2>/dev/null)
  [[ "${#desc_hash}" -eq 64 ]] || { log "  FAIL: ${label}: bad descriptionHash '${desc_hash}'" >&2; return 1; }

  local qe_data queue_data execute_data
  qe_data=$(python3 -c "
def build(sel):
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
    return '0x' + sel + head + targets_enc + values_enc + calldatas_enc
print(build('${SEL_QUEUE}'))
print(build('${SEL_EXECUTE}'))
")
  queue_data=$(echo "$qe_data" | head -1)
  execute_data=$(echo "$qe_data" | tail -1)

  local queue_tx
  queue_tx=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$queue_data" "${label}:queue()") || return 1
  ok "${label}: queue() mined"

  local cur
  cur=$(governor_state "$PROPOSAL_ID_HEX")
  if [[ "$cur" -eq 5 ]]; then
    ok "${label}: Proposal state == Queued"
  else
    fail "${label}: expected state 5 (Queued), got ${cur}"
  fi

  # ── timelock delay ──
  log ""
  log "${label}: waiting for BSCTimelock delay (3 s)..."
  sleep 10

  # ── execute (with one retry in case the tx is transiently dropped) ──
  # In P2P test networks a tx can occasionally fail to propagate to the block
  # producers' mempools and time out without being mined.  Re-submitting once
  # (with the same data) is sufficient to recover.
  log ""
  log "${label}: executing proposal"
  _exec_attempts=0
  while true; do
    _exec_attempts=$(( _exec_attempts + 1 ))
    LAST_EXEC_TX=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 1000000 "$execute_data" "${label}:execute()") && break
    if [[ "$_exec_attempts" -ge 2 ]]; then
      log "  FAIL: ${label}: execute() failed after ${_exec_attempts} attempts" >&2
      return 1
    fi
    log "  ${label}: execute() not mined, retrying (attempt ${_exec_attempts})..."
    sleep 3
  done
  ok "${label}: execute() mined"

  cur=$(governor_state "$PROPOSAL_ID_HEX")
  if [[ "$cur" -eq 7 ]]; then
    ok "${label}: Proposal state == Executed"
  else
    fail "${label}: expected state 7 (Executed), got ${cur}"
  fi

  # Record execute block number for event log queries
  LAST_EXEC_BLK_HEX=$(attach_exec "$GETH" "$IPC1" \
    "(function(){var r=eth.getTransactionReceipt('${LAST_EXEC_TX}');return r?web3.toHex(r.blockNumber):'0x0';})()" \
    2>/dev/null || echo "0x0")
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
wait_for_ipc "$GETH" "$IPC1" 10
code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${GOVERNOR}','latest')" 2>/dev/null || echo "0x")
[[ $(( (${#code} - 2) / 2 )) -gt 100 ]] || die "BSCGovernor not deployed at ${GOVERNOR}. Run U-3 first."

log "T-6.h/i/j  Full governance whitelist tests"
log "  Governor : ${GOVERNOR}  GovHub: ${GOV_HUB}"
log "  StakeHub : ${STAKE_HUB}  NewAddr: ${NEW_WL_ADDR}"
log "  VAL1     : ${VAL1}"
log "  VAL2     : ${VAL2}"
log "  VAL3     : ${VAL3}"

# ── Compute selectors ─────────────────────────────────────────────────────────
log ""
log "Computing selectors..."
SEL_PROPOSE=$(selector "propose(address[],uint256[],bytes[],string)")
SEL_CAST_VOTE=$(selector "castVote(uint256,uint8)")
SEL_QUEUE=$(selector "queue(address[],uint256[],bytes[],bytes32)")
SEL_EXECUTE=$(selector "execute(address[],uint256[],bytes[],bytes32)")
SEL_WL_MEMBER=$(selector "validatorWhitelist(address)")
SEL_WL_ENABLED=$(selector "whitelistEnabled()")
SEL_ELECTION=$(selector "getValidatorElectionInfo(uint256,uint256)")
SEL_GOV_UPDATE=$(selector "updateParam(string,bytes,address)")
TOPIC_WL_UPDATED=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('ValidatorWhitelistUpdated(address,bool)')" 2>/dev/null)
TOPIC_WL_ENABLED=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('WhitelistEnabledUpdated(bool)')" 2>/dev/null)
for _s in SEL_PROPOSE SEL_CAST_VOTE SEL_QUEUE SEL_EXECUTE SEL_WL_MEMBER SEL_WL_ENABLED SEL_ELECTION SEL_GOV_UPDATE; do
  [[ "${!_s}" =~ ^[0-9a-fA-F]{8}$ ]] \
    || die "${_s}: bad selector '${!_s}' (geth attach failed?)"
done
[[ "$TOPIC_WL_UPDATED" =~ ^0x[0-9a-fA-F]{64}$ ]] \
  || die "TOPIC_WL_UPDATED: bad hash '${TOPIC_WL_UPDATED}'"
[[ "$TOPIC_WL_ENABLED" =~ ^0x[0-9a-fA-F]{64}$ ]] \
  || die "TOPIC_WL_ENABLED: bad hash '${TOPIC_WL_ENABLED}'"
log "  Selectors ready."

# Compute WHITELIST_VOTING_POWER = uint64_max × 1e10
WHITELIST_VP=$(attach_exec "$GETH" "$IPC1" \
  "web3.toBigNumber('0x' + 'ff'.repeat(8)).times(web3.toBigNumber('10000000000')).toString(10)" \
  2>/dev/null)
[[ -n "$WHITELIST_VP" && "$WHITELIST_VP" != "null" ]] \
  || die "Failed to compute WHITELIST_VOTING_POWER"
log "  WHITELIST_VP : ${WHITELIST_VP}"

# getValidatorElectionInfo(0, 10) call data
ELECTION_DATA="0x${SEL_ELECTION}$(printf '%064x' 0)$(printf '%064x' 10)"

# ── Pre-flight diagnostics (governance contract state) ─────────────────────────
log ""
log "=== Governance diagnostics ==="

code_len=$(( ( ${#code} - 2 ) / 2 ))
log "  BSCGovernor bytecode size       = ${code_len} bytes"

SEL_TOKEN=$(selector "token()")
GOV_TOKEN_RAW=$(eth_call_raw "$GOVERNOR" "0x${SEL_TOKEN}")
GOV_TOKEN="0x${GOV_TOKEN_RAW: -40}"
log "  BSCGovernor.token()             = ${GOV_TOKEN}"

SEL_TOTAL_SUPPLY=$(selector "totalSupply()")
TOTAL_SUPPLY_HEX=$(eth_call_raw "$GOV_TOKEN" "0x${SEL_TOTAL_SUPPLY}")
TOTAL_SUPPLY_DISPLAY=$(python3 -c "
v = int('${TOTAL_SUPPLY_HEX}' if '${TOTAL_SUPPLY_HEX}'.startswith('0x') else '0x0', 16)
print(f'{v/10**18:.6f} govAB  ({v} wei)')
" 2>/dev/null || echo "$TOTAL_SUPPLY_HEX")
log "  govToken.totalSupply()          = ${TOTAL_SUPPLY_DISPLAY}"

SEL_BALANCE_OF=$(selector "balanceOf(address)")
VAL1_PADDED="$(printf '%064s' "${VAL1#0x}" | tr ' ' '0')"
BALANCE_HEX=$(eth_call_raw "$GOV_TOKEN" "0x${SEL_BALANCE_OF}${VAL1_PADDED}")
BALANCE_DISPLAY=$(python3 -c "
v = int('${BALANCE_HEX}' if '${BALANCE_HEX}'.startswith('0x') else '0x0', 16)
print(f'{v/10**18:.6f} govAB  ({v} wei)')
" 2>/dev/null || echo "$BALANCE_HEX")
log "  govToken.balanceOf(val1)        = ${BALANCE_DISPLAY}"

SEL_GET_VOTES=$(selector "getVotes(address)")
VOTES_HEX=$(eth_call_raw "$GOV_TOKEN" "0x${SEL_GET_VOTES}${VAL1_PADDED}")
VOTES_DISPLAY=$(python3 -c "
v = int('${VOTES_HEX}' if '${VOTES_HEX}'.startswith('0x') else '0x0', 16)
print(f'{v/10**18:.6f} govAB  ({v} wei)')
" 2>/dev/null || echo "$VOTES_HEX")
log "  govToken.getVotes(val1)         = ${VOTES_DISPLAY}"

SEL_THRESHOLD=$(selector "proposalThreshold()")
THRESHOLD_HEX=$(eth_call_raw "$GOVERNOR" "0x${SEL_THRESHOLD}")
THRESHOLD_DISPLAY=$(python3 -c "
v = int('${THRESHOLD_HEX}' if '${THRESHOLD_HEX}'.startswith('0x') else '0x0', 16)
print(f'{v/10**18:.6f} govAB  ({v} wei)')
" 2>/dev/null || echo "$THRESHOLD_HEX")
log "  BSCGovernor.proposalThreshold() = ${THRESHOLD_DISPLAY}"

SEL_VOTING_PERIOD=$(selector "votingPeriod()")
VOTING_PERIOD_HEX=$(eth_call_raw "$GOVERNOR" "0x${SEL_VOTING_PERIOD}")
VOTING_PERIOD=$(python3 -c "print(int('${VOTING_PERIOD_HEX}' if '${VOTING_PERIOD_HEX}'.startswith('0x') else '0x0', 16))" 2>/dev/null || echo "$VOTING_PERIOD_HEX")
log "  BSCGovernor.votingPeriod()      = ${VOTING_PERIOD} blocks"

SEL_VOTING_DELAY=$(selector "votingDelay()")
VOTING_DELAY_HEX=$(eth_call_raw "$GOVERNOR" "0x${SEL_VOTING_DELAY}")
VOTING_DELAY=$(python3 -c "print(int('${VOTING_DELAY_HEX}' if '${VOTING_DELAY_HEX}'.startswith('0x') else '0x0', 16))" 2>/dev/null || echo "$VOTING_DELAY_HEX")
log "  BSCGovernor.votingDelay()       = ${VOTING_DELAY} blocks"

SEL_QUORUM=$(selector "quorumNumerator()")
QUORUM_HEX=$(eth_call_raw "$GOVERNOR" "0x${SEL_QUORUM}")
QUORUM=$(python3 -c "print(int('${QUORUM_HEX}' if '${QUORUM_HEX}'.startswith('0x') else '0x0', 16))" 2>/dev/null || echo "$QUORUM_HEX")
log "  BSCGovernor.quorumNumerator()   = ${QUORUM}"

log "=== End diagnostics ==="

# ─────────────────────────────────────────────────────────────────────────────
# T-6.h — addToValidatorWhitelist via governance
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-6.h: addToValidatorWhitelist ──────────────────────────────────────────"

# Phase 1: encode GovHub.updateParam("addToValidatorWhitelist", beef, StakeHub)
log ""
log "Phase 1 (T-6.h): encoding GovHub.updateParam calldata"

GOVHUB_CALLDATA=$(python3 -c "
sel = '${SEL_GOV_UPDATE}'
key = b'addToValidatorWhitelist'
val = bytes.fromhex('${NEW_WL_ADDR}'.replace('0x','').zfill(40))
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
log "  GovHub calldata: $((( ${#GOVHUB_CALLDATA} - 2 ) / 2)) bytes"

# Phases 2-7: run governance round
PROPOSAL_ID_HEX=""; LAST_EXEC_TX=""; LAST_EXEC_BLK_HEX=""
run_governance_round "$GOVHUB_CALLDATA" "T-6.h: addToValidatorWhitelist ${NEW_WL_ADDR}" "T-6.h" \
  || { fail "T-6.h governance round failed"; exit 1; }

# Phase 8: verify whitelist entry on-chain
log ""
log "Phase 8 (T-6.h): verifying StakeHub.validatorWhitelist(${NEW_WL_ADDR})"
padded=$(printf '%064s' "${NEW_WL_ADDR#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_MEMBER}${padded}")
if [[ "${raw: -2}" == "01" ]]; then
  ok "T-6.h: validatorWhitelist(${NEW_WL_ADDR}) == true (end-to-end governance verified)"
else
  fail "T-6.h: validatorWhitelist(${NEW_WL_ADDR}): expected true, got ${raw}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-6.i — removeFromValidatorWhitelist via governance
#
# Removes VAL1 (consensus address) from the whitelist via a real governance
# proposal.  After execution:
#   - validatorWhitelist(val1) == false
#   - getValidatorElectionInfo: val1 reverts to stake-based power
#   - ValidatorWhitelistUpdated(val1, false) event emitted
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-6.i: removeFromValidatorWhitelist ─────────────────────────────────────"

# Phase 9: encode GovHub.updateParam("removeFromValidatorWhitelist", val1, StakeHub)
log ""
log "Phase 9 (T-6.i): encoding removeFromValidatorWhitelist calldata for val1"

VAL1_CONSENSUS="${VAL1}"
GOVHUB_CALLDATA_I=$(python3 -c "
sel = '${SEL_GOV_UPDATE}'
key = b'removeFromValidatorWhitelist'
val = bytes.fromhex('${VAL1_CONSENSUS}'.replace('0x','').zfill(40))
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
log "  GovHub calldata: $((( ${#GOVHUB_CALLDATA_I} - 2 ) / 2)) bytes"

# Phase 10: governance round
PROPOSAL_ID_HEX=""; LAST_EXEC_TX=""; LAST_EXEC_BLK_HEX=""
run_governance_round "$GOVHUB_CALLDATA_I" "T-6.i: removeFromValidatorWhitelist ${VAL1_CONSENSUS}" "T-6.i" \
  || { fail "T-6.i governance round failed"; exit 1; }
T6I_EXEC_BLK_HEX="$LAST_EXEC_BLK_HEX"

# Phase 11: verify validatorWhitelist(val1) == false
log ""
log "Phase 11 (T-6.i): verifying validatorWhitelist(val1) == false"
val1_padded=$(printf '%064s' "${VAL1_CONSENSUS#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_MEMBER}${val1_padded}")
if [[ "${#raw}" -ne 66 ]]; then
  fail "T-6.i: validatorWhitelist(val1): RPC returned malformed value '${raw}'"
elif [[ "${raw: -2}" != "01" ]]; then
  ok "T-6.i: validatorWhitelist(val1) == false (whitelist entry removed)"
else
  fail "T-6.i: validatorWhitelist(val1): expected false after removal, got ${raw}"
fi

# Phase 12: verify getValidatorElectionInfo: val1 power < WHITELIST_VP
log ""
log "Phase 12 (T-6.i): verifying val1 election power < WHITELIST_VP"
raw=$(eth_call_raw "$STAKE_HUB" "$ELECTION_DATA")
_val1_power=$(parse_voting_powers "$raw" 2>/dev/null | head -1 || echo "0")
_t6i_power_ok=0
python3 -c "
import sys
vp = int('${_val1_power}' or '0')
wl = int('${WHITELIST_VP}')
sys.exit(0 if vp < wl else 1)
" 2>/dev/null || _t6i_power_ok=$?
if [[ "$_t6i_power_ok" -eq 0 ]]; then
  ok "T-6.i: val1 election power (${_val1_power}) < WHITELIST_VP (reverted to stake-based)"
else
  fail "T-6.i: val1 election power (${_val1_power}) >= WHITELIST_VP (unexpected)"
fi

wl_count=$(count_wl_validators "$raw")
if [[ "$wl_count" -eq 2 ]]; then
  ok "T-6.i: 2 validators still have WHITELIST_VP (val2 and val3, unchanged)"
else
  fail "T-6.i: expected 2 validators with WHITELIST_VP, got ${wl_count}"
fi

# Phase 13: T-6.n false path — ValidatorWhitelistUpdated(val1, false) event
log ""
log "Phase 13 (T-6.n): ValidatorWhitelistUpdated(val1, false) event from T-6.i execute block"
remove_logs=$(eth_get_logs "$STAKE_HUB" "$TOPIC_WL_UPDATED" "$T6I_EXEC_BLK_HEX" "$T6I_EXEC_BLK_HEX")
_t6n_ok=0
python3 - <<PYEOF 2>/dev/null || _t6n_ok=$?
import json, sys
logs = json.loads('''${remove_logs}''')
if len(logs) != 1:
    print(f"expected 1 ValidatorWhitelistUpdated event, got {len(logs)}", file=sys.stderr)
    sys.exit(1)
log = logs[0]
# topics[1] = indexed address (val1_consensus, 32-byte padded)
expected_topic = '${VAL1_CONSENSUS}'.lower().replace('0x','').zfill(64)
got_topic = log.get('topics', ['',''])[1].replace('0x','').lower().zfill(64)
if got_topic != expected_topic:
    print(f"topics[1] mismatch: expected {expected_topic!r}, got {got_topic!r}", file=sys.stderr)
    sys.exit(1)
# data = ABI-encoded bool false: 32 bytes, last byte 0x00
data = log.get('data', '')
if not data or data[-2:] != '00':
    print(f"data mismatch: expected last byte 00 (false), got {data!r}", file=sys.stderr)
    sys.exit(1)
PYEOF
if [[ "$_t6n_ok" -eq 0 ]]; then
  ok "T-6.n (false path): ValidatorWhitelistUpdated(val1, false) — topics[1]=val1, data[-1]=0x00"
else
  fail "T-6.n (false path): ValidatorWhitelistUpdated event mismatch after removeFromValidatorWhitelist"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-6.j — whitelistEnabled toggle via governance
#
# Part A: disable (whitelistEnabled → false)
#   All validators revert to stake-based power; WhitelistEnabledUpdated(false).
# Part B: re-enable (whitelistEnabled → true)
#   val2/val3 return to WHITELIST_VP (still whitelisted);
#   val1 remains stake-based (removed in T-6.i); WhitelistEnabledUpdated(true).
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-6.j Part A: whitelistEnabled → false ──────────────────────────────────"

# Phase 14: encode GovHub.updateParam("whitelistEnabled", 0x00, StakeHub)
log ""
log "Phase 14 (T-6.j-A): encoding whitelistEnabled=false calldata"

GOVHUB_CALLDATA_JA=$(python3 -c "
sel = '${SEL_GOV_UPDATE}'
key = b'whitelistEnabled'
val = (0).to_bytes(32, 'big')
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
log "  GovHub calldata: $((( ${#GOVHUB_CALLDATA_JA} - 2 ) / 2)) bytes"

# Phase 15: governance round
PROPOSAL_ID_HEX=""; LAST_EXEC_TX=""; LAST_EXEC_BLK_HEX=""
run_governance_round "$GOVHUB_CALLDATA_JA" "T-6.j-A: whitelistEnabled=false" "T-6.j-A" \
  || { fail "T-6.j Part A governance round failed"; exit 1; }
T6JA_EXEC_BLK_HEX="$LAST_EXEC_BLK_HEX"

# Phase 16: verify whitelistEnabled() == false
log ""
log "Phase 16 (T-6.j-A): verifying whitelistEnabled() == false"
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_ENABLED}")
if [[ "${#raw}" -ne 66 ]]; then
  fail "T-6.j-A: whitelistEnabled(): RPC returned malformed value '${raw}'"
elif [[ "${raw: -2}" != "01" ]]; then
  ok "T-6.j-A: whitelistEnabled() == false"
else
  fail "T-6.j-A: whitelistEnabled(): expected false after governance disable, got ${raw}"
fi

# Phase 17: verify all validators revert to stake-based power
log ""
log "Phase 17 (T-6.j-A): verifying all validators revert to stake-based power"
raw=$(eth_call_raw "$STAKE_HUB" "$ELECTION_DATA")
wl_count=$(count_wl_validators "$raw")
if [[ "$wl_count" -eq 0 ]]; then
  ok "T-6.j-A: 0 validators have WHITELIST_VP (all stake-based when whitelist disabled)"
else
  fail "T-6.j-A: expected 0 validators with WHITELIST_VP, got ${wl_count}"
fi

# Phase 18: WhitelistEnabledUpdated(false) event
log ""
log "Phase 18 (T-6.j-A): verifying WhitelistEnabledUpdated(false) event"
we_logs_a=$(eth_get_logs "$STAKE_HUB" "$TOPIC_WL_ENABLED" "$T6JA_EXEC_BLK_HEX" "$T6JA_EXEC_BLK_HEX")
_t6ja_ev_ok=0
python3 - <<PYEOF 2>/dev/null || _t6ja_ev_ok=$?
import json, sys
logs = json.loads('''${we_logs_a}''')
if len(logs) != 1:
    print(f"expected 1 WhitelistEnabledUpdated event, got {len(logs)}", file=sys.stderr)
    sys.exit(1)
data = logs[0].get('data', '')
if not data or data[-2:] != '00':
    print(f"data last byte: expected 00 (false), got {data!r}", file=sys.stderr)
    sys.exit(1)
PYEOF
if [[ "$_t6ja_ev_ok" -eq 0 ]]; then
  ok "T-6.j-A: WhitelistEnabledUpdated(false) event emitted (data[-1]=0x00)"
else
  fail "T-6.j-A: WhitelistEnabledUpdated event missing or data mismatch"
fi

log ""
log "── T-6.j Part B: whitelistEnabled → true ───────────────────────────────────"

# Phase 19: encode GovHub.updateParam("whitelistEnabled", 0x01, StakeHub)
log ""
log "Phase 19 (T-6.j-B): encoding whitelistEnabled=true calldata"

GOVHUB_CALLDATA_JB=$(python3 -c "
sel = '${SEL_GOV_UPDATE}'
key = b'whitelistEnabled'
val = (1).to_bytes(32, 'big')
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
log "  GovHub calldata: $((( ${#GOVHUB_CALLDATA_JB} - 2 ) / 2)) bytes"

# Phase 20: governance round
PROPOSAL_ID_HEX=""; LAST_EXEC_TX=""; LAST_EXEC_BLK_HEX=""
run_governance_round "$GOVHUB_CALLDATA_JB" "T-6.j-B: whitelistEnabled=true" "T-6.j-B" \
  || { fail "T-6.j Part B governance round failed"; exit 1; }
T6JB_EXEC_BLK_HEX="$LAST_EXEC_BLK_HEX"

# Phase 21: verify whitelistEnabled() == true
log ""
log "Phase 21 (T-6.j-B): verifying whitelistEnabled() == true"
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_ENABLED}")
if [[ "${raw: -2}" == "01" ]]; then
  ok "T-6.j-B: whitelistEnabled() == true (whitelist re-enabled)"
else
  fail "T-6.j-B: whitelistEnabled(): expected true after re-enable, got ${raw}"
fi

# Phase 22: verify val2/val3 back to WHITELIST_VP; val1 remains stake-based
log ""
log "Phase 22 (T-6.j-B): verifying election power — val2/val3 WHITELIST_VP, val1 stake-based"
raw=$(eth_call_raw "$STAKE_HUB" "$ELECTION_DATA")
wl_count=$(count_wl_validators "$raw")
# val1 was removed in T-6.i; val2/val3 still whitelisted → expect exactly 2
if [[ "$wl_count" -eq 2 ]]; then
  ok "T-6.j-B: 2 validators have WHITELIST_VP (val2 and val3; val1 still removed from whitelist)"
else
  fail "T-6.j-B: expected 2 validators with WHITELIST_VP after re-enable, got ${wl_count}"
fi

# val1 should still be < WHITELIST_VP (not in whitelist despite whitelist being enabled)
_val1_power=$(parse_voting_powers "$raw" 2>/dev/null | head -1 || echo "0")
_t6jb_power_ok=0
python3 -c "
import sys
vp = int('${_val1_power}' or '0')
wl = int('${WHITELIST_VP}')
sys.exit(0 if vp < wl else 1)
" 2>/dev/null || _t6jb_power_ok=$?
if [[ "$_t6jb_power_ok" -eq 0 ]]; then
  ok "T-6.j-B: val1 remains stake-based (power ${_val1_power} < WHITELIST_VP; whitelist removal from T-6.i persists)"
else
  fail "T-6.j-B: val1 power (${_val1_power}) >= WHITELIST_VP unexpectedly"
fi

# Phase 23: WhitelistEnabledUpdated(true) event
log ""
log "Phase 23 (T-6.j-B): verifying WhitelistEnabledUpdated(true) event"
we_logs_b=$(eth_get_logs "$STAKE_HUB" "$TOPIC_WL_ENABLED" "$T6JB_EXEC_BLK_HEX" "$T6JB_EXEC_BLK_HEX")
_t6jb_ev_ok=0
python3 - <<PYEOF 2>/dev/null || _t6jb_ev_ok=$?
import json, sys
logs = json.loads('''${we_logs_b}''')
if len(logs) != 1:
    print(f"expected 1 WhitelistEnabledUpdated event, got {len(logs)}", file=sys.stderr)
    sys.exit(1)
data = logs[0].get('data', '')
if not data or data[-2:] != '01':
    print(f"data last byte: expected 01 (true), got {data!r}", file=sys.stderr)
    sys.exit(1)
PYEOF
if [[ "$_t6jb_ev_ok" -eq 0 ]]; then
  ok "T-6.j-B: WhitelistEnabledUpdated(true) event emitted (data[-1]=0x01)"
else
  fail "T-6.j-B: WhitelistEnabledUpdated event missing or data mismatch"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
if [[ "$FAIL" -eq 0 ]]; then
  log "[ PASS ]  T-6.h/i/j governance whitelist tests: ${PASS} checks passed"
else
  log "[ FAIL ]  T-6.h/i/j governance whitelist tests: ${PASS} passed, ${FAIL} failed"
  exit 1
fi
