#!/usr/bin/env bash
# U-7: Fermi + Osaka + Mendel (multi-phase timestamp activation).
#
# Corresponds to devnet Upgrade 7 (v0.8.0 analogue).
# Local parameter defaults:
#   FermiTime              = now + 60 s
#   OsakaTime = MendelTime = now + 240 s  (Fermi + 3 min)
#
# Fork activations:
#   Phase 1 (T+60s):  fermiTime
#   Phase 2 (T+240s): osakaTime + mendelTime (simultaneous)
#
# Key changes verified here:
#   - Fermi: system contract upgrade fires at activation block —
#       log line "Apply upgrade fermi at height <N>" on all 3 nodes
#   - Osaka (EIP-7823): bigModExp reverts when base/exp/mod length > 1024 bytes
#   - Osaka (EIP-7951): p256Verify at 0x100 gas increases from 3450 → 6900
#   - Mendel (BEP-657): non-eligible blocks (N%5≠0) must have blobGasUsed=0
#
# Prerequisites:
#   - U-6 has completed; nodes are running with Maxwell active
#   - A pre-U-7 snapshot is recommended (run 07-snapshot.sh first)
#
# Steps:
#   1. Determine fork timestamps
#   2. Patch genesis.json with fermiTime, osakaTime, mendelTime + blobSchedule.osaka
#      (nodes remain running; genesis.json is only read at geth init time)
#   3. Rolling genesis reinit: for each validator in turn —
#        stop → geth init → restart → re-peer → wait for sync
#      2-of-3 quorum is maintained throughout.
#   4. Wait for Fermi activation (Phase 1)
#   5. Verify Fermi: "Apply upgrade fermi" log line on all 3 nodes
#   6. Measure pre-Osaka p256Verify gas baseline (during Fermi observation window)
#   7. Wait for Osaka+Mendel activation (Phase 2)
#   8. Verify Osaka EIP-7823: bigModExp reverts with modLen=1025 > 1024
#   9. Verify Osaka EIP-7951: p256Verify gas increased by 3450 (3450→6900)
#  10. Verify Mendel BEP-657: non-eligible blocks have blobGasUsed=0
#  11. Leave nodes running (next round or manual inspection)
#
# Environment:
#   PHASE1_OFFSET   seconds from now to Fermi activation (default: 60)
#   PHASE2_OFFSET   additional seconds to Osaka+Mendel after Fermi (default: 180)
#   FORK_TIME       explicit Fermi timestamp (overrides PHASE1_OFFSET)
#   KEEP_RUNNING=1  leave nodes running after PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"
[[ -d "${DATADIR_ROOT}" ]] || die "DATADIR_ROOT not found: ${DATADIR_ROOT} — run 00-init.sh and U-1 through U-6 first"
require_file "${GENESIS_JSON}"
require_file "${TOML_CONFIG}"

_any_running=false
for n in 1 2 3; do
  pidfile=$(val_pid "$n")
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    _any_running=true
    break
  fi
done
"$_any_running" || die "No validators are running. U-6 must complete successfully before U-7."

pass() { log "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { log "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }
PASS=0
FAIL=0

cleanup_on_exit() {
  local code=$?
  [[ "$code" -eq 0 ]] && return
  echo
  if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
    echo "FAILED (exit=${code}). KEEP_RUNNING=1 — nodes remain running." >&2
  else
    echo "FAILED (exit=${code}). Stopping nodes (logs preserved: ${DATADIR_ROOT})." >&2
    stop_all || true
  fi
  exit "$code"
}
trap cleanup_on_exit EXIT

# ── Phase 1: determine fork timestamps ───────────────────────────────────────

wait_for_ipc "$GETH" "$(val_ipc 1)" 30

if [[ -z "${FORK_TIME:-}" ]]; then
  FERMI_TIME=$(( $(date +%s) + ${PHASE1_OFFSET:-60} ))
  log "FORK_TIME not set — Fermi defaulting to now + ${PHASE1_OFFSET:-60}s = ${FERMI_TIME}"
else
  FERMI_TIME=${FORK_TIME}
fi
OSAKA_TIME=$(( FERMI_TIME + ${PHASE2_OFFSET:-180} ))
MENDEL_TIME=$OSAKA_TIME

log "U-7 Fermi + Osaka + Mendel"
log "  FERMI_TIME=${FERMI_TIME}"
log "  OSAKA_TIME=${OSAKA_TIME}  (= MENDEL_TIME)"

_now=$(date +%s)
if [[ "$_now" -ge "$FERMI_TIME" ]]; then
  die "FERMI_TIME (${FERMI_TIME}) is in the past. Set FORK_TIME to a future timestamp."
fi

# ── Phase 2: patch genesis.json while nodes are still running ─────────────────
#
# Add fermiTime, osakaTime, mendelTime, and blobSchedule.osaka.
# Osaka requires blobSchedule.osaka (enforced by CheckConfigForkOrder), same as
# Prague required blobSchedule.prague.  Default values: target=6, max=9,
# baseFeeUpdateFraction=5007716 (EIP-7691 / Pectra, same as Prague).
# Updating genesis.json while nodes run is safe — geth reads chainconfig from
# the database, not genesis.json at runtime.

export GENESIS_JSON FERMI_TIME OSAKA_TIME MENDEL_TIME
python3 - <<'PY'
import json, os

genesis_path = os.environ['GENESIS_JSON']
fermi_time   = int(os.environ['FERMI_TIME'])
osaka_time   = int(os.environ['OSAKA_TIME'])
mendel_time  = int(os.environ['MENDEL_TIME'])

with open(genesis_path) as f:
    genesis = json.load(f)

cfg = genesis['config']

for field, val in [
    ('fermiTime',  fermi_time),
    ('osakaTime',  osaka_time),
    ('mendelTime', mendel_time),
]:
    old = cfg.get(field, '<nil>')
    cfg[field] = val
    print(f'  {field}: {old} → {val}')

# Osaka requires blobSchedule.osaka (enforced by CheckConfigForkOrder).
# Default: target=6, max=9, baseFeeUpdateFraction=5007716 (same as Prague / EIP-7691).
if 'blobSchedule' not in cfg:
    cfg['blobSchedule'] = {}
if 'osaka' not in cfg['blobSchedule']:
    cfg['blobSchedule']['osaka'] = {
        'target': 6, 'max': 9, 'baseFeeUpdateFraction': 5007716
    }
    print('  blobSchedule.osaka: <nil> → {target:6, max:9, baseFeeUpdateFraction:5007716}')

with open(genesis_path, 'w') as f:
    json.dump(genesis, f, indent=2)
    f.write('\n')
print(f'Updated {genesis_path}')
PY

# ── Phase 3: rolling genesis reinit ──────────────────────────────────────────
#
# Stop each validator, run geth init to store the updated chainconfig, restart
# and wait for sync.  2-of-3 quorum maintained throughout.

log "Starting rolling genesis reinit (2-of-3 quorum maintained throughout)..."
for n in 1 2 3; do
  ref=$(( n == 1 ? 2 : 1 ))

  log "Rolling reinit: stopping validator-${n}..."
  stop_pidfile "$(val_pid "$n")"

  log "Rolling reinit: geth init validator-${n}..."
  "$GETH" init --datadir "$(val_dir "$n")" "${GENESIS_JSON}" 2>/dev/null

  log "Rolling reinit: starting validator-${n}..."
  launch_validator "$n"
  wait_for_ipc "$GETH" "$(val_ipc "$n")" 60

  for peer in 1 2 3; do
    [[ "$peer" -eq "$n" ]] && continue
    _enode=$(get_enode "$GETH" "$(val_ipc "$peer")" 2>/dev/null || true)
    [[ -n "$_enode" ]] && add_peer "$GETH" "$(val_ipc "$n")" "$_enode" >/dev/null 2>&1 || true
  done

  _target=$(head_number "$GETH" "$(val_ipc "$ref")" 2>/dev/null || echo 1)
  log "Rolling reinit: waiting for validator-${n} to reach head ${_target}..."
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$_target" 120
  log "Rolling reinit: validator-${n} ready (head=$(head_number "$GETH" "$(val_ipc "$n")"))."
done

wait_for_same_head "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"
log "Rolling reinit complete. Head=$(head_number "$GETH" "$(val_ipc 1)")"

# ── Phase 4a: wait for Fermi activation ──────────────────────────────────────

IPC1=$(val_ipc 1)

_now=$(date +%s)
_wait_timeout=$(( FERMI_TIME > _now ? (FERMI_TIME - _now + 30) : 30 ))
log "Waiting for Fermi activation timestamp ${FERMI_TIME} (timeout=${_wait_timeout}s)..."
wait_for_timestamp "$FERMI_TIME" "$_wait_timeout"

log "Waiting for chain to include Fermi activation block (timestamp ≥ ${FERMI_TIME})..."
_deadline=$(( $(date +%s) + 60 ))
ACT_BLOCK_F=0
while [[ $(date +%s) -lt $_deadline ]]; do
  _ts=$(attach_exec "$GETH" "$IPC1" "eth.getBlock('latest').timestamp" 2>/dev/null || echo 0)
  _bn=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
  if [[ "${_ts:-0}" -ge "${FERMI_TIME}" ]]; then
    ACT_BLOCK_F=$_bn
    log "Fermi activation block: block=${ACT_BLOCK_F}, timestamp=${_ts}."
    break
  fi
  sleep 1
done
[[ "$ACT_BLOCK_F" -eq 0 ]] && die "Fermi activation block not produced within 60s of FERMI_TIME=${FERMI_TIME}"

# Walk back to the true first Fermi fork block.
while [[ "$ACT_BLOCK_F" -gt 1 ]]; do
  _prev_ts=$(attach_exec "$GETH" "$IPC1" \
    "eth.getBlock($(( ACT_BLOCK_F - 1 ))).timestamp" 2>/dev/null || echo 0)
  [[ "${_prev_ts:-0}" -ge "${FERMI_TIME}" ]] || break
  ACT_BLOCK_F=$(( ACT_BLOCK_F - 1 ))
done
log "First Fermi fork block: ${ACT_BLOCK_F}."

# ── Phase 5a: Fermi verification + brief stability window ────────────────────

POST_FERMI=$(( ACT_BLOCK_F + 3 ))
log "Waiting for chain to reach block ${POST_FERMI} (post-Fermi stability check)..."
_deadline=$(( $(date +%s) + 60 ))
while [[ $(date +%s) -lt $_deadline ]]; do
  _h=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
  [[ "$_h" =~ ^[0-9]+$ ]] && [[ "$_h" -ge "$POST_FERMI" ]] && break
  sleep 1
done

log "Running Fermi verification..."

# 1. All 3 node logs must contain "Apply upgrade fermi at height <N>".
#    Emitted by core/systemcontracts/upgrade.go via applySystemContractUpgrade.
#    Retry up to 3 times (1s apart) in case the log is flushed slightly after
#    the block is committed and we race with the writer.
for n in 1 2 3; do
  _logfile=$(val_log "$n")
  _found=false
  for _retry in 1 2 3; do
    grep -q "Apply upgrade fermi" "$_logfile" 2>/dev/null && { _found=true; break; }
    sleep 1
  done
  if "$_found"; then
    pass "val-${n}: 'Apply upgrade fermi at height ...' found in log"
  else
    fail "val-${n}: 'Apply upgrade fermi' not found in log (${_logfile})"
  fi
done

# 2. All 3 nodes agree on hash at Fermi activation block.
ref_hash_f=$(block_hash_at "$GETH" "$IPC1" "$ACT_BLOCK_F")
[[ -n "$ref_hash_f" && "$ref_hash_f" != "null" ]] || die "Failed to read block hash at Fermi block ${ACT_BLOCK_F} from val-1"
for n in 2 3; do
  h=$(block_hash_at "$GETH" "$(val_ipc "$n")" "$ACT_BLOCK_F")
  if [[ "$h" == "$ref_hash_f" && -n "$h" && "$h" != "null" ]]; then
    pass "val-${n} agrees on hash at Fermi block ${ACT_BLOCK_F}: ${ref_hash_f:0:14}…"
  else
    fail "val-${n} hash mismatch at Fermi block ${ACT_BLOCK_F}: got ${h}, expected ${ref_hash_f}"
  fi
done

# 3. Chain still advancing.
tip=$(head_number "$GETH" "$IPC1")
if [[ "$tip" -ge "$POST_FERMI" ]]; then
  pass "Chain advancing after Fermi: current head=${tip}"
else
  fail "Chain stalled after Fermi at head=${tip} (expected ≥ ${POST_FERMI})"
fi

# ── Pre-Osaka p256Verify gas baseline (measured during Fermi observation window) ─
#
# Prague added p256Verify at 0x100 with RequiredGas=3450 (eip7951=false).
# Osaka raises it to 6900 (P256VerifyGas, EIP-7951).  We measure now so
# we can compute the delta after Osaka activates.
# Input: 160 zero bytes (invalid sig → returns false, no revert).
# Estimated gas: 21000 (base) + 160*4 (zero-byte calldata) + 3450 (precompile) = 25090.
#
# Guard: if Fermi verification or rolling reinit consumed more time than expected
# and Osaka has already activated, the baseline would reflect the post-Osaka gas
# (6900) and the subsequent delta check would report 0 instead of 3450.

_now=$(date +%s)
if [[ "$_now" -ge "$OSAKA_TIME" ]]; then
  die "Osaka has already activated (now=${_now} >= OSAKA_TIME=${OSAKA_TIME}) before the p256Verify baseline could be measured. Increase PHASE2_OFFSET (current: ${PHASE2_OFFSET:-180}s)."
fi

_P256_ADDR='0x0000000000000000000000000000000000000100'
_P256_DATA="0x$(python3 -c "import sys; sys.stdout.write('00'*160)")"

GAS_P256_PRE=$(attach_exec "$GETH" "$IPC1" \
  "eth.estimateGas({to:'${_P256_ADDR}', data:'${_P256_DATA}'})" 2>/dev/null || echo 0)
log "Pre-Osaka p256Verify gas estimate: ${GAS_P256_PRE} (expected ≈ 25090 before EIP-7951)"

# Pre-compute bigModExp EIP-7823 test data.
# Input: baseLen=1, expLen=1, modLen=1025 (> 1024), base=0x02, exp=0x01, mod=0x00...03.
# Pre-Osaka:  2^1 mod 3 = 2, returns 1025-byte result.
# Post-Osaka: EIP-7823 active → max(1,1,1025)=1025 > 1024 → revert.
BIGMODEXP_DATA=$(python3 -c "
import sys
b, e, m = 1, 1, 1025
data = b.to_bytes(32,'big') + e.to_bytes(32,'big') + m.to_bytes(32,'big')
data += bytes([2]) + bytes([1]) + bytes(1024) + bytes([3])
sys.stdout.write('0x' + data.hex())
")

# ── Phase 4c: wait for Osaka+Mendel activation ────────────────────────────────

_now=$(date +%s)
_wait_timeout=$(( OSAKA_TIME > _now ? (OSAKA_TIME - _now + 30) : 30 ))
log "Waiting for Osaka+Mendel activation timestamp ${OSAKA_TIME} (timeout=${_wait_timeout}s)..."
wait_for_timestamp "$OSAKA_TIME" "$_wait_timeout"

log "Waiting for chain to include Osaka+Mendel activation block (timestamp ≥ ${OSAKA_TIME})..."
_deadline=$(( $(date +%s) + 90 ))
ACT_BLOCK_O=0
while [[ $(date +%s) -lt $_deadline ]]; do
  _ts=$(attach_exec "$GETH" "$IPC1" "eth.getBlock('latest').timestamp" 2>/dev/null || echo 0)
  _bn=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
  if [[ "${_ts:-0}" -ge "${OSAKA_TIME}" ]]; then
    ACT_BLOCK_O=$_bn
    log "Osaka+Mendel activation block: block=${ACT_BLOCK_O}, timestamp=${_ts}."
    break
  fi
  sleep 1
done
[[ "$ACT_BLOCK_O" -eq 0 ]] && die "Osaka+Mendel activation block not produced within 90s of OSAKA_TIME=${OSAKA_TIME}"

# Walk back to the true first Osaka/Mendel fork block.
while [[ "$ACT_BLOCK_O" -gt 1 ]]; do
  _prev_ts=$(attach_exec "$GETH" "$IPC1" \
    "eth.getBlock($(( ACT_BLOCK_O - 1 ))).timestamp" 2>/dev/null || echo 0)
  [[ "${_prev_ts:-0}" -ge "${OSAKA_TIME}" ]] || break
  ACT_BLOCK_O=$(( ACT_BLOCK_O - 1 ))
done
log "First Osaka+Mendel fork block: ${ACT_BLOCK_O}."

# ── Phase 5b: Osaka EIP-7823 verification ─────────────────────────────────────
#
# bigModExp (0x05) must revert when any of base/exp/mod length > 1024 bytes.
# core/vm/contracts.go:872-874: if eip7823 && max(baseLen,expLen,modLen) > 1024 → error.

log "Running Osaka (EIP-7823) verification..."
_bigmod_js="var _r='no-revert'; try { eth.call({to:'0x0000000000000000000000000000000000000005', data:'${BIGMODEXP_DATA}'}); } catch(e){ _r='reverted'; } _r"
_bigmod_result=$(attach_exec "$GETH" "$IPC1" "$_bigmod_js" 2>/dev/null || echo "error")
if [[ "$_bigmod_result" == "reverted" ]]; then
  pass "bigModExp with modLen=1025 reverted after Osaka (EIP-7823 active)"
else
  fail "bigModExp with modLen=1025 returned '${_bigmod_result}' (expected revert — EIP-7823 not active?)"
fi

# ── Phase 5c: Osaka EIP-7951 verification ─────────────────────────────────────
#
# p256Verify (0x100) RequiredGas: Prague=3450, Osaka=6900 (P256VerifyGas).
# params/protocol_params.go:179, core/vm/contracts.go:1749-1757.
# Compare against baseline measured during Fermi observation window.

log "Running Osaka (EIP-7951) verification..."
GAS_P256_POST=$(attach_exec "$GETH" "$IPC1" \
  "eth.estimateGas({to:'${_P256_ADDR}', data:'${_P256_DATA}'})" 2>/dev/null || echo 0)
log "Post-Osaka p256Verify gas estimate: ${GAS_P256_POST} (expected ≈ 28540 after EIP-7951)"

if [[ "$GAS_P256_PRE" -gt 0 && "$GAS_P256_POST" -gt 0 ]]; then
  GAS_DIFF=$(( GAS_P256_POST - GAS_P256_PRE ))
  if [[ "$GAS_DIFF" -eq 3450 ]]; then
    pass "p256Verify gas increased by ${GAS_DIFF} (${GAS_P256_PRE}→${GAS_P256_POST}): EIP-7951 active"
  else
    fail "p256Verify gas diff=${GAS_DIFF} (${GAS_P256_PRE}→${GAS_P256_POST}): expected +3450 for EIP-7951"
  fi
else
  fail "p256Verify gas estimate unavailable (pre=${GAS_P256_PRE}, post=${GAS_P256_POST})"
fi

# ── Phase 5d: Mendel BEP-657 verification ─────────────────────────────────────
#
# BEP-657: only blocks where N%BlobEligibleBlockInterval==0 (i.e. N%5==0) may
# include blob transactions.  Non-eligible blocks must have blobGasUsed=0.
# params/protocol_params.go:193, consensus/misc/eip4844/eip4844.go:113-118.
#
# We scan 10 consecutive blocks after Mendel activation and verify that
# non-eligible blocks (N%5≠0) carry blobGasUsed=0.  Eligible blocks also show
# blobGasUsed=0 in this drill (no blob transactions submitted), but that is not
# required by the protocol.

log "Running Mendel (BEP-657) verification..."

POST_MENDEL=$(( ACT_BLOCK_O + 10 ))
log "Waiting for chain to reach block ${POST_MENDEL} (Mendel BEP-657 sample window)..."
_deadline=$(( $(date +%s) + 120 ))
while [[ $(date +%s) -lt $_deadline ]]; do
  _h=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
  [[ "$_h" =~ ^[0-9]+$ ]] && [[ "$_h" -ge "$POST_MENDEL" ]] && break
  sleep 2
done

_bad_blob_blocks=0
_checked_noneligible=0
for blk in $(seq $(( ACT_BLOCK_O + 1 )) $(( ACT_BLOCK_O + 10 ))); do
  _rem=$(( blk % 5 ))
  if [[ "$_rem" -ne 0 ]]; then
    _bgused=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${blk}).blobGasUsed" 2>/dev/null || true)
    _checked_noneligible=$(( _checked_noneligible + 1 ))
    if [[ "${_bgused}" == "0" ]]; then
      : # ok: non-eligible block correctly has blobGasUsed=0
    elif [[ -z "${_bgused}" || "${_bgused}" == "null" || "${_bgused}" == "undefined" ]]; then
      _bad_blob_blocks=$(( _bad_blob_blocks + 1 ))
      log "  block ${blk} (N%%5=${_rem}): blobGasUsed unreadable (RPC failure or field missing)"
    else
      _bad_blob_blocks=$(( _bad_blob_blocks + 1 ))
      log "  block ${blk} (N%%5=${_rem}): blobGasUsed=${_bgused} (BEP-657 violation: non-eligible block must have 0)"
    fi
  fi
done

if [[ "$_checked_noneligible" -gt 0 && "$_bad_blob_blocks" -eq 0 ]]; then
  pass "Mendel BEP-657: ${_checked_noneligible} non-eligible blocks (N%%5≠0) all have blobGasUsed=0"
elif [[ "$_checked_noneligible" -eq 0 ]]; then
  fail "Mendel BEP-657: no non-eligible blocks found in sample range (ACT_BLOCK_O=${ACT_BLOCK_O})"
else
  fail "Mendel BEP-657: ${_bad_blob_blocks}/${_checked_noneligible} non-eligible blocks had blobGasUsed≠0"
fi

# All 3 nodes agree on hash at Osaka+Mendel activation block.
ref_hash_o=$(block_hash_at "$GETH" "$IPC1" "$ACT_BLOCK_O")
[[ -n "$ref_hash_o" && "$ref_hash_o" != "null" ]] || die "Failed to read block hash at Osaka+Mendel block ${ACT_BLOCK_O} from val-1"
for n in 2 3; do
  h=$(block_hash_at "$GETH" "$(val_ipc "$n")" "$ACT_BLOCK_O")
  if [[ "$h" == "$ref_hash_o" && -n "$h" && "$h" != "null" ]]; then
    pass "val-${n} agrees on hash at Osaka+Mendel block ${ACT_BLOCK_O}: ${ref_hash_o:0:14}…"
  else
    fail "val-${n} hash mismatch at Osaka+Mendel block ${ACT_BLOCK_O}: got ${h}, expected ${ref_hash_o}"
  fi
done

# Chain still advancing.
tip=$(head_number "$GETH" "$IPC1")
if [[ "$tip" -ge "$POST_MENDEL" ]]; then
  pass "Chain advancing after Mendel: current head=${tip}"
else
  fail "Chain stalled after Mendel at head=${tip} (expected ≥ ${POST_MENDEL})"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "===================================="
echo "  U-7 results: PASS=${PASS} FAIL=${FAIL}"
echo "===================================="

if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED" >&2
  exit 1
fi

if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo "PASS (U-7). Nodes remain running. Run 07-snapshot.sh before next round."
  exit 0
fi

echo "PASS (U-7). Nodes remain running in Mendel mode."
echo "Next: bash script/test/upgrade-drill/07-snapshot.sh"
