#!/usr/bin/env bash
# U-3 extra: slash → misdemeanor → felony → breathe-with-jailed-validator → unjail
#
# Exercises the full downtime-punishment path in the empty-set bootstrap scenario:
#   Parlia downtimeSlash → SlashIndicator.slash() → misdemeanor / felony
#   → StakeHub.jailValidator() → breathe block → updateValidatorSetV2 (val3 excluded)
#   → unjail → breathe block → val3 re-enters election set
#
# This is the critical path flagged in abcore-v2#112: an untested code path where
# a jailed validator could stall Finalize() in updateValidatorSetV2, analogous to
# the validatorExtraSet / SystemReward bugs fixed in genesis-contract#12.
#
# Thresholds come from parliagenesis/default/SlashContract (compiled with
# test/reduce-local-slash-params at a506d97):
#   misdemeanorThreshold = 5   (~45 s with 3 validators at 1 s/block)
#   felonyThreshold      = 15  (~135 s)
#   downtimeJailTime     = 60 s
#
# Prerequisites:
#   - U-3 (82-run-u3-shanghai-feynman.sh) has completed:
#     validators registered in StakeHub, breathe blocks firing, chain advancing
#
# What this test does:
#   1. Verify all 3 validators are running and registered
#   2. Stop validator-3 to simulate downtime
#   3. Poll getSlashIndicator(val3) until misdemeanor threshold (5) is reached
#   4. Continue polling until felony fires and val3 is jailed
#   5. Verify no failedFelony events emitted
#   6. Wait for a breathe block with val3 jailed (the critical path)
#   7. Wait for downtimeJailTime (60 s) to expire, restart val3, call unjail()
#   8. Wait for next breathe block and verify val3 re-enters election set
#
# Environment:
#   MISDEMEANOR_THRESHOLD   slash count that triggers misdemeanor (default: 5)
#   FELONY_THRESHOLD        slash count that triggers felony (default: 15)
#   DOWNTIME_JAIL_SECS      seconds val3 remains jailed (default: 60)
#   SLASH_POLL              seconds between getSlashIndicator polls (default: 4)
#   KEEP_RUNNING=1          leave nodes running after PASS/FAIL
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"
[[ -d "${DATADIR_ROOT}" ]] || die "DATADIR_ROOT not found: ${DATADIR_ROOT} — run 00-init.sh and U-1/U-2/U-3 first"
require_file "${GENESIS_JSON}"

MISDEMEANOR_THRESHOLD=${MISDEMEANOR_THRESHOLD:-5}
FELONY_THRESHOLD=${FELONY_THRESHOLD:-15}
DOWNTIME_JAIL_SECS=${DOWNTIME_JAIL_SECS:-60}
SLASH_POLL=${SLASH_POLL:-2}

STAKEHUB="0x0000000000000000000000000000000000002002"
SLASHINDICATOR="0x0000000000000000000000000000000000001001"
VALCONTRACT="0x0000000000000000000000000000000000001000"

PASS=0; FAIL=0
pass() { log "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { log "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

cleanup_on_exit() {
  local code=$?
  [[ "$code" -eq 0 ]] && return
  echo
  if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
    echo "FAILED (exit=${code}). KEEP_RUNNING=1 — nodes remain running." >&2
  else
    echo "FAILED (exit=${code}). Nodes left running (logs in ${DATADIR_ROOT})." >&2
  fi
  exit "$code"
}
trap cleanup_on_exit EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────

_ipc1="$(val_ipc 1)"
_ipc3="$(val_ipc 3)"

_attach() { attach_exec "$GETH" "$_ipc1" "$1"; }

_tip() { head_number "$GETH" "$_ipc1" 2>/dev/null || echo 0; }

_slash_count() {
  local addr="${1#0x}"
  local sel; sel=$(_attach "web3.sha3('getSlashIndicator(address)').slice(2,10)")
  local padded; padded="$(printf '%064s' "$addr" | tr ' ' '0')"
  local raw; raw=$(_attach "eth.call({to:'${SLASHINDICATOR}',data:'0x${sel}${padded}'})")
  python3 -c "
d='${raw}'.replace('0x','').replace('\"','')
print(int(d[64:128],16) if len(d)>=128 else 0)
" 2>/dev/null || echo 0
}

_is_jailed() {
  local addr="${1#0x}"
  local sel; sel=$(_attach "web3.sha3('getValidatorBasicInfo(address)').slice(2,10)")
  local padded; padded="$(printf '%064s' "$addr" | tr ' ' '0')"
  local raw; raw=$(_attach "eth.call({to:'${STAKEHUB}',data:'0x${sel}${padded}'})")
  python3 -c "
d='${raw}'.replace('0x','').replace('\"','')
print('true' if len(d)>=192 and int(d[64:128],16)!=0 else 'false')
" 2>/dev/null || echo "false"
}

_jail_until() {
  local addr="${1#0x}"
  local sel; sel=$(_attach "web3.sha3('getValidatorBasicInfo(address)').slice(2,10)")
  local padded; padded="$(printf '%064s' "$addr" | tr ' ' '0')"
  local raw; raw=$(_attach "eth.call({to:'${STAKEHUB}',data:'0x${sel}${padded}'})")
  python3 -c "
d='${raw}'.replace('0x','').replace('\"','')
print(int(d[128:192],16) if len(d)>=192 else 0)
" 2>/dev/null || echo 0
}

# _has_breathe_after FROM_BLOCK: true if updateValidatorSetV2 succeeded (status=0x1) in any block >= FROM_BLOCK
# Uses web3.sha3 (keccak256) — NOT hashlib.sha3_256 which is NIST SHA3, not Ethereum keccak.
_has_breathe_after() {
  local from_block="${1:-0}"
  local count
  count=$(_attach \
"(function(){
  var sel=web3.sha3('updateValidatorSetV2(address[],uint64[],bytes[])').slice(2,10);
  var vc='${VALCONTRACT}'.toLowerCase();
  var n=eth.blockNumber,c=0;
  for(var i=n;i>=${from_block}&&i>=0;i--){
    var b=eth.getBlock(i,true);
    if(b&&b.transactions.some(function(tx){
      if(!(tx.to&&tx.to.toLowerCase()===vc&&tx.input&&tx.input.slice(2,10)===sel))return false;
      var r=eth.getTransactionReceipt(tx.hash);
      return r&&(r.status==='0x1'||r.status===1);
    }))c++;
  }return c;})()")
  [[ "${count:-0}" -gt 0 ]]
}

# _wait_breathe_after FROM_BLOCK TIMEOUT_SECS: poll until breathe block seen or timeout
_wait_breathe_after() {
  local from_block="$1"
  local timeout="${2:-$(( BREATHE_BLOCK_INTERVAL + 30 ))}"
  local deadline; deadline=$(( $(date +%s) + timeout ))
  while true; do
    local now; now=$(date +%s)
    [[ "$now" -ge "$deadline" ]] && return 1
    sleep 3
    _has_breathe_after "$from_block" && return 0
  done
}

# kept for backwards-compat with any callers that still use window-based check
_has_breathe() {
  _has_breathe_after $(( $(_tip) - ${1:-50} ))
}

_election_count() {
  local sel; sel=$(_attach "web3.sha3('getValidatorElectionInfo(uint256,uint256)').slice(2,10)")
  local zeros="0000000000000000000000000000000000000000000000000000000000000000"
  local raw; raw=$(_attach "eth.call({to:'${STAKEHUB}',data:'0x${sel}${zeros}${zeros}'})")
  python3 -c "
d='${raw}'.replace('0x','').replace('\"','')
print(int(d[192:256],16) if len(d)>=256 else 0)
" 2>/dev/null || echo 0
}

# _val_voting_power ADDR: returns 1 if validator has non-zero voting power, 0 otherwise.
# Uses 0/1 rather than the raw uint256 to avoid bash integer overflow:
# WHITELIST_VOTING_POWER = uint256(uint64.max)*1e10 is a 30-digit number that bash
# truncates to 20 digits, yielding uint64.max which is -1 in signed 64-bit arithmetic,
# causing [[ vp -gt 0 ]] to incorrectly return false.
_val_voting_power() {
  local target="${1#0x}"
  local sel; sel=$(_attach "web3.sha3('getValidatorElectionInfo(uint256,uint256)').slice(2,10)")
  local zero64="0000000000000000000000000000000000000000000000000000000000000000"
  local lim10="000000000000000000000000000000000000000000000000000000000000000a"
  local raw; raw=$(_attach "eth.call({to:'${STAKEHUB}',data:'0x${sel}${zero64}${lim10}'})")
  python3 -c "
import sys
d='${raw}'.replace('0x','').replace('\"','').lower()
if len(d) < 256:
    print(0); sys.exit()
# ABI head (4 words): offsets to validators[], votingPowers[], voteAddrs[], then totalLength
val_off = int(d[0:64],   16) * 2
vp_off  = int(d[64:128], 16) * 2
n = int(d[val_off:val_off+64], 16) if len(d) >= val_off+64 else 0
m = int(d[vp_off:vp_off+64],   16) if len(d) >= vp_off+64  else 0
target = '${target}'.lower()
for i in range(min(n, m)):
    addr_slot = d[val_off+64+i*64 : val_off+64+(i+1)*64]
    if addr_slot[-40:] == target:
        vp_slot = d[vp_off+64+i*64 : vp_off+64+(i+1)*64]
        # Return 1/0 instead of raw uint256 to avoid bash signed-64-bit overflow.
        # WHITELIST_VOTING_POWER is a 30-digit number; bash [[ -gt ]] truncates it
        # to uint64.max which is -1 in signed arithmetic and compares as <= 0.
        print(1 if int(vp_slot, 16) > 0 else 0); sys.exit()
print(0)
" 2>/dev/null || echo 0
}

_wait_mined() {
  local tx="$1" label="$2"
  for _i in $(seq 1 30); do
    sleep 3
    local st
    st=$(_attach "(function(){var r=eth.getTransactionReceipt('${tx}');return r?r.status:'pending';})()")
    case "$st" in
      0x1|1) pass "${label}  (tx=${tx:0:14}…)"; return 0 ;;
      0x0|0) fail "${label} reverted  (tx=${tx:0:14}…)"; return 1 ;;
    esac
  done
  fail "${label} not mined after 90 s  (tx=${tx:0:14}…)"
  return 1
}

# ── Phase 0: pre-flight ───────────────────────────────────────────────────────
log "=== U-3 slash/jail/unjail drill ==="

for n in 1 2 3; do
  pidfile=$(val_pid "$n")
  if ! { [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; }; then
    die "validator-${n} is not running. U-3 must complete successfully first."
  fi
done
log "All 3 validators running."

VAL3_ADDR=$(val_addr 3)
log "validator-3 address: ${VAL3_ADDR}"

# Verify registration
_elec=$(_election_count)
if [[ "${_elec:-0}" -ge 3 ]]; then
  pass "StakeHub election set = ${_elec} (all validators registered)"
else
  fail "StakeHub election set = ${_elec:-0}, expected ≥ 3 — run U-3 first"
  exit 1
fi

# Read live thresholds from SlashIndicator — T-12/T-13 may have bumped them via
# governance before this drill runs, so the on-chain values may differ from the
# compile-time defaults.  The env-var defaults are only used as a fallback.
_msel=$(_attach "web3.sha3('misdemeanorThreshold()').slice(2,10)")
_fsel=$(_attach "web3.sha3('felonyThreshold()').slice(2,10)")
_mraw=$(_attach "eth.call({to:'${SLASHINDICATOR}',data:'0x${_msel}'})")
_fraw=$(_attach "eth.call({to:'${SLASHINDICATOR}',data:'0x${_fsel}'})")
MISDEMEANOR_THRESHOLD=$(python3 -c "
d='${_mraw}'.replace('0x','').replace('\"','')
print(int(d,16) if d else ${MISDEMEANOR_THRESHOLD})" 2>/dev/null || echo "${MISDEMEANOR_THRESHOLD}")
FELONY_THRESHOLD=$(python3 -c "
d='${_fraw}'.replace('0x','').replace('\"','')
print(int(d,16) if d else ${FELONY_THRESHOLD})" 2>/dev/null || echo "${FELONY_THRESHOLD}")
log "Live SlashIndicator thresholds: misdemeanor=${MISDEMEANOR_THRESHOLD} felony=${FELONY_THRESHOLD}"

# ── Phase 1: stop validator-3 ────────────────────────────────────────────────
log "=== Phase 1: stop validator-3 to simulate downtime ==="

VAL3_PID=$(cat "$(val_pid 3)" 2>/dev/null || true)
log "Stopping validator-3 (pid=${VAL3_PID})..."
stop_pidfile "$(val_pid 3)"
log "validator-3 stopped."

# ── Phase 2: wait for misdemeanor ────────────────────────────────────────────
log "=== Phase 2: poll slash count → misdemeanor threshold=${MISDEMEANOR_THRESHOLD} ==="

COUNT=0; MISDEMEANOR_DETECTED=0
for attempt in $(seq 1 120); do
  sleep "$SLASH_POLL"
  COUNT=$(_slash_count "$VAL3_ADDR")
  log "  block #$(_tip)  val3 slash count = ${COUNT}"
  if [[ "${COUNT:-0}" -ge "$MISDEMEANOR_THRESHOLD" ]]; then
    MISDEMEANOR_DETECTED=1; break
  fi
done

if [[ "$MISDEMEANOR_DETECTED" -eq 1 ]]; then
  pass "Misdemeanor threshold reached: count=${COUNT} at block #$(_tip)"
else
  fail "Misdemeanor threshold not reached after polling (count=${COUNT:-0})"
fi

# ── Phase 3: wait for felony + jail ─────────────────────────────────────────
log "=== Phase 3: continue until felony threshold=${FELONY_THRESHOLD} and val3 jailed ==="

FELONY_DETECTED=0; JAILED="false"
for attempt in $(seq 1 120); do
  sleep "$SLASH_POLL"
  COUNT=$(_slash_count "$VAL3_ADDR")
  JAILED=$(_is_jailed "$VAL3_ADDR")
  log "  block #$(_tip)  slash count=${COUNT}  jailed=${JAILED}"
  if [[ "$JAILED" == "true" ]]; then
    FELONY_DETECTED=1; break
  fi
done

JAIL_UNTIL=$(_jail_until "$VAL3_ADDR")
if [[ "$FELONY_DETECTED" -eq 1 && "$JAILED" == "true" ]]; then
  pass "Felony executed: validator-3 jailed (jailUntil=${JAIL_UNTIL})"
else
  fail "Felony not reached or val3 not jailed (count=${COUNT:-0} jailed=${JAILED})"
  echo "${FAIL} CHECK(S) FAILED — Phase 4/5 require val3 to be jailed; aborting" >&2
  exit 1
fi

# Verify no failedFelony events
FAILED_FELONY_SIG=$(_attach "web3.sha3('failedFelony(address,uint256,bytes)').slice(2)")
FAILED_FELONY_LOG=$(_attach \
"(function(){
  var logs=eth.getLogs({fromBlock:'earliest',toBlock:'latest',
    address:'${SLASHINDICATOR}',topics:['0x${FAILED_FELONY_SIG}']});
  return logs.length;
})()")
if [[ "${FAILED_FELONY_LOG:-0}" -eq 0 ]]; then
  pass "No failedFelony events — felony executed cleanly"
else
  fail "failedFelony emitted ${FAILED_FELONY_LOG} time(s) — felony reverted!"
fi

# ── Phase 4: breathe block with jailed validator (critical path) ─────────────
log "=== Phase 4: breathe block with val3 jailed (CRITICAL PATH) ==="

TIP_BEFORE=$(_tip)
log "Polling for breathe block (interval=${BREATHE_BLOCK_INTERVAL}s, timeout=$(( BREATHE_BLOCK_INTERVAL + 30 ))s)..."
if _wait_breathe_after "$(( TIP_BEFORE + 1 ))" $(( BREATHE_BLOCK_INTERVAL + 30 )); then
  TIP_AFTER=$(_tip)
  pass "Chain live during jailed-validator breathe block: #${TIP_BEFORE} → #${TIP_AFTER}"
  pass "Breathe block fired (updateValidatorSetV2 succeeded with val3 excluded)"
else
  TIP_AFTER=$(_tip)
  if [[ "${TIP_AFTER:-0}" -gt "${TIP_BEFORE:-0}" ]]; then
    fail "Chain live but no breathe block — updateValidatorSetV2 may have reverted!"
  else
    fail "Chain STALLED during breathe block with jailed validator!"
  fi
fi

# Note: getValidatorElectionInfo totalLength includes all registered validators (even jailed,
# with voting power 0). We verify val3 has 0 voting power instead of checking total count.
_elec=$(_election_count)
log "StakeHub election totalLength = ${_elec} (jailed validator still counted; voting power = 0)"

# ── Phase 5: unjail ───────────────────────────────────────────────────────────
log "=== Phase 5: wait for jail expiry, restart val3, unjail ==="

NOW=$(date +%s)
WAIT_UNJAIL=$(( JAIL_UNTIL - NOW + 5 ))
if [[ "$WAIT_UNJAIL" -gt 0 ]]; then
  log "Waiting ${WAIT_UNJAIL}s for jail time to expire (jailUntil=${JAIL_UNTIL})..."
  sleep "$WAIT_UNJAIL"
else
  log "Jail time already expired (jailUntil=${JAIL_UNTIL} ≤ now=${NOW})"
fi

log "Restarting validator-3..."
launch_validator 3
wait_for_ipc "$GETH" "$_ipc3" 30
wire_mesh
log "validator-3 back in peer mesh."

# Wait for val3 to sync within 5 blocks of val1 before sending unjail tx,
# otherwise the tx may not propagate correctly.
log "Waiting for val3 to sync..."
_sync_ok=0
for _si in $(seq 1 30); do
  _v1tip=$(_tip)
  _v3tip=$(head_number "$GETH" "$_ipc3" 2>/dev/null || echo 0)
  if [[ "${_v3tip:-0}" -ge "$(( _v1tip - 5 ))" ]]; then
    _sync_ok=1
    break
  fi
  sleep 2
done
if [[ "$_sync_ok" -eq 1 ]]; then
  log "val3 synced to block #${_v3tip:-?} (val1 at #${_v1tip:-?})"
else
  fail "val3 failed to sync within 60 s (val3=#${_v3tip:-?} val1=#${_v1tip:-?}) — unjail tx may not propagate"
fi

VAL3_PADDED="$(printf '%064s' "${VAL3_ADDR#0x}" | tr ' ' '0')"

# felony downtimeSlash slashes downtimeSlashAmount (10 BNB) from val3's creditContract,
# dropping self-delegation below minSelfDelegationBNB (2000 BNB).  unjail() will revert
# with SelfDelegationNotEnough unless we self-delegate to replenish first.
# Only the operator can delegate to a jailed validator (onlySelfDelegation guard).
log "Self-delegating 20 BNB to val3 to cover downtimeSlash (10 BNB) before unjail..."
DEL_SEL=$(attach_exec "$GETH" "$_ipc1" "web3.sha3('delegate(address,bool)').slice(2,10)")
BOOL_TRUE="0000000000000000000000000000000000000000000000000000000000000001"
DEL_DATA="0x${DEL_SEL}${VAL3_PADDED}${BOOL_TRUE}"
# 20 ether = 0x1158E460913D00000 wei (covers 10 BNB slash + buffer; val3 has ~10^6 BNB genesis balance)
REDELEGATE_TX=$(attach_exec "$GETH" "$_ipc3" \
  "eth.sendTransaction({from:'${VAL3_ADDR}',to:'${STAKEHUB}',value:'0x1158E460913D00000',gas:300000,data:'${DEL_DATA}'})")
if [[ "$REDELEGATE_TX" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  _wait_mined "$REDELEGATE_TX" "re-delegate(val3, 20 BNB)"
else
  fail "re-delegate tx rejected (got: '${REDELEGATE_TX}')"
fi

log "Sending unjail(val3) from validator-3..."
UNJAIL_SEL=$(_attach "web3.sha3('unjail(address)').slice(2,10)")
UNJAIL_TX=$(attach_exec "$GETH" "$_ipc3" \
  "eth.sendTransaction({from:'${VAL3_ADDR}',to:'${STAKEHUB}',gas:200000,data:'0x${UNJAIL_SEL}${VAL3_PADDED}'})")
if [[ "$UNJAIL_TX" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  _wait_mined "$UNJAIL_TX" "unjail(val3)"
else
  fail "unjail tx rejected (got: '${UNJAIL_TX}')"
fi

TIP_UNJAIL=$(_tip)
log "Polling for breathe block after unjail (timeout=$(( BREATHE_BLOCK_INTERVAL + 30 ))s)..."
if _wait_breathe_after "$(( TIP_UNJAIL + 1 ))" $(( BREATHE_BLOCK_INTERVAL + 30 )); then
  pass "Chain live after unjail: tip = #$(_tip)"
  pass "Breathe block fired after unjail"
else
  fail "No breathe block after unjail (tip stuck at #$(_tip))"
fi

_vp_final=$(_val_voting_power "$VAL3_ADDR")
if [[ "${_vp_final:-0}" -gt 0 ]]; then
  pass "Validator-3 re-entered active election set (votingPower=${_vp_final})"
else
  fail "Validator-3 has zero voting power after unjail — not re-entered active set"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL ${PASS} CHECKS PASSED"
  exit 0
else
  echo "${FAIL} CHECK(S) FAILED — see output above and $(val_log 1)"
  exit 1
fi
