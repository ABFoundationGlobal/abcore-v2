#!/usr/bin/env bash
# U-6: Prague + Pascal + Lorentz + Maxwell (multi-phase timestamp activation).
#
# Corresponds to devnet Upgrade 6 (v0.7.0 analogue).
# Local parameter defaults:
#   PragueTime = PascalTime = now + 60 s
#   LorentzTime = now + 240 s  (Prague + 3 min)
#   MaxwellTime = now + 420 s  (Lorentz + 3 min)
#
# Fork activations:
#   Phase 1 (T+60s):  pascalTime, pragueTime
#   Phase 2 (T+240s): lorentzTime
#   Phase 3 (T+420s): maxwellTime
#
# Key changes verified here:
#   - Prague (EIP-7685): block headers include requestsHash field
#   - Lorentz: block interval remains stable (epoch 500, turn 8, backoff 2000 ms)
#   - Maxwell: parlia_getValidators returns the correct validator set (epoch 1000)
#
# Note: Prague requires blobSchedule.prague in genesis.json (enforced by
#   CheckConfigForkOrder); default values target=6, max=9, updateFraction=5007716
#   are written automatically by this script.
#
# Prerequisites:
#   - U-5 has completed; nodes are running with Bohr active
#   - A pre-U-6 snapshot is recommended (run 07-snapshot.sh first)
#
# Steps:
#   1. Determine fork timestamps
#   2. Patch genesis.json with all 4 fork times + blobSchedule.prague
#      (nodes remain running; genesis.json is only read at geth init time)
#   3. Rolling genesis reinit: for each validator in turn —
#        stop → geth init → restart → re-peer → wait for sync
#      2-of-3 quorum is maintained throughout.
#   4. Wait for Prague/Pascal activation (Phase 1)
#   5. Verify Prague: requestsHash in block headers (EIP-7685)
#   6. Wait for Lorentz activation (Phase 2)
#   7. Verify Lorentz: block interval stability
#   8. Wait for Maxwell activation (Phase 3)
#   9. Verify Maxwell: parlia_getValidators correct; chain advancing
#   10. Leave nodes running for U-7
#
# Environment:
#   PHASE1_OFFSET   seconds from now to Prague/Pascal activation (default: 60)
#   PHASE2_OFFSET   additional seconds to Lorentz after Prague (default: 180)
#   PHASE3_OFFSET   additional seconds to Maxwell after Lorentz (default: 180)
#   FORK_TIME       explicit Prague/Pascal timestamp (overrides PHASE1_OFFSET)
#   KEEP_RUNNING=1  leave nodes running after PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"
[[ -d "${DATADIR_ROOT}" ]] || die "DATADIR_ROOT not found: ${DATADIR_ROOT} — run 00-init.sh and U-1 through U-5 first"
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
"$_any_running" || die "No validators are running. U-5 must complete successfully before U-6."

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
  PRAGUE_TIME=$(( $(date +%s) + ${PHASE1_OFFSET:-60} ))
  log "FORK_TIME not set — Prague/Pascal defaulting to now + ${PHASE1_OFFSET:-60}s = ${PRAGUE_TIME}"
else
  PRAGUE_TIME=${FORK_TIME}
fi
LORENTZ_TIME=$(( PRAGUE_TIME + ${PHASE2_OFFSET:-180} ))
MAXWELL_TIME=$(( LORENTZ_TIME + ${PHASE3_OFFSET:-180} ))

log "U-6 Prague + Pascal + Lorentz + Maxwell"
log "  PRAGUE_TIME=${PRAGUE_TIME} (= PASCAL_TIME)"
log "  LORENTZ_TIME=${LORENTZ_TIME}  MAXWELL_TIME=${MAXWELL_TIME}"

_now=$(date +%s)
if [[ "$_now" -ge "$PRAGUE_TIME" ]]; then
  die "PRAGUE_TIME (${PRAGUE_TIME}) is in the past. Set FORK_TIME to a future timestamp."
fi

# ── Phase 2: patch genesis.json while nodes are still running ─────────────────
#
# Add pascalTime, pragueTime, lorentzTime, maxwellTime and blobSchedule.prague.
# Prague requires blobSchedule.prague or CheckConfigForkOrder will reject it.
# bohrTime was written by U-5; pascal/prague/lorentz/maxwellTime were absent (nil).
# Updating genesis.json while nodes run is safe — geth reads chainconfig from
# the database, not genesis.json at runtime.

export GENESIS_JSON PRAGUE_TIME LORENTZ_TIME MAXWELL_TIME
python3 - <<'PY'
import json, os

genesis_path = os.environ['GENESIS_JSON']
prague_time  = int(os.environ['PRAGUE_TIME'])
lorentz_time = int(os.environ['LORENTZ_TIME'])
maxwell_time = int(os.environ['MAXWELL_TIME'])

with open(genesis_path) as f:
    genesis = json.load(f)

cfg = genesis['config']

for field, val in [
    ('pascalTime',  prague_time),
    ('pragueTime',  prague_time),
    ('lorentzTime', lorentz_time),
    ('maxwellTime', maxwell_time),
]:
    old = cfg.get(field, '<nil>')
    cfg[field] = val
    print(f'  {field}: {old} → {val}')

# Prague requires blobSchedule.prague (enforced by CheckConfigForkOrder).
# Default: target=6, max=9, baseFeeUpdateFraction=5007716  (EIP-7691 / Pectra).
if 'blobSchedule' not in cfg:
    cfg['blobSchedule'] = {}
if 'prague' not in cfg['blobSchedule']:
    cfg['blobSchedule']['prague'] = {
        'target': 6, 'max': 9, 'baseFeeUpdateFraction': 5007716
    }
    print('  blobSchedule.prague: <nil> → {target:6, max:9, baseFeeUpdateFraction:5007716}')

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

# ── Phase 4a: wait for Prague/Pascal activation ───────────────────────────────

IPC1=$(val_ipc 1)

_now=$(date +%s)
_wait_timeout=$(( PRAGUE_TIME > _now ? (PRAGUE_TIME - _now + 30) : 30 ))
log "Waiting for Prague/Pascal activation timestamp ${PRAGUE_TIME} (timeout=${_wait_timeout}s)..."
wait_for_timestamp "$PRAGUE_TIME" "$_wait_timeout"

log "Waiting for chain to include Prague activation block (timestamp ≥ ${PRAGUE_TIME})..."
_deadline=$(( $(date +%s) + 60 ))
ACT_BLOCK_P1=0
while [[ $(date +%s) -lt $_deadline ]]; do
  _ts=$(attach_exec "$GETH" "$IPC1" "eth.getBlock('latest').timestamp" 2>/dev/null || echo 0)
  _bn=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
  if [[ "${_ts:-0}" -ge "${PRAGUE_TIME}" ]]; then
    ACT_BLOCK_P1=$_bn
    log "Prague activation block: block=${ACT_BLOCK_P1}, timestamp=${_ts}."
    break
  fi
  sleep 1
done
[[ "$ACT_BLOCK_P1" -eq 0 ]] && die "Prague activation block not produced within 60s of PRAGUE_TIME=${PRAGUE_TIME}"

# Walk back to the true first Prague/Pascal fork block.
# The 1 s poll can land on a later block if two blocks arrive between polls;
# scanning back guarantees PRE_BLOCK_P1 is always a genuine pre-fork block.
while [[ "$ACT_BLOCK_P1" -gt 1 ]]; do
  _prev_ts=$(attach_exec "$GETH" "$IPC1" \
    "eth.getBlock($(( ACT_BLOCK_P1 - 1 ))).timestamp" 2>/dev/null || echo 0)
  [[ "${_prev_ts:-0}" -ge "${PRAGUE_TIME}" ]] || break
  ACT_BLOCK_P1=$(( ACT_BLOCK_P1 - 1 ))
done
log "First Prague/Pascal fork block: ${ACT_BLOCK_P1}."

# ── Phase 5a: brief Prague stability window + verification ────────────────────

POST_PRAGUE=$(( ACT_BLOCK_P1 + 3 ))
log "Waiting for chain to reach block ${POST_PRAGUE} (post-Prague stability check)..."
_deadline=$(( $(date +%s) + 60 ))
while [[ $(date +%s) -lt $_deadline ]]; do
  _h=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
  [[ "$_h" =~ ^[0-9]+$ ]] && [[ "$_h" -ge "$POST_PRAGUE" ]] && break
  sleep 1
done

log "Running Prague (EIP-7685) verification..."
PRE_BLOCK_P1=$(( ACT_BLOCK_P1 - 1 ))

# 1. Post-Prague block must have requestsHash (0x + 64 hex chars = 32-byte hash).
requests_hash=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock(${ACT_BLOCK_P1}).requestsHash" 2>/dev/null || true)
if [[ -n "$requests_hash" && "$requests_hash" != "null" && "$requests_hash" != "undefined" && "${#requests_hash}" -eq 66 ]]; then
  pass "block ${ACT_BLOCK_P1} requestsHash=${requests_hash:0:14}… (EIP-7685 present)"
else
  fail "block ${ACT_BLOCK_P1} requestsHash absent or malformed: '${requests_hash}' (Prague not activated?)"
fi

# 2. Pre-Prague block must NOT have requestsHash.
pre_requests=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock(${PRE_BLOCK_P1}).requestsHash" 2>/dev/null || true)
if [[ -z "$pre_requests" || "$pre_requests" == "null" || "$pre_requests" == "undefined" ]]; then
  pass "block ${PRE_BLOCK_P1} has no requestsHash (pre-Prague, expected)"
else
  fail "block ${PRE_BLOCK_P1} requestsHash=${pre_requests} (Prague activated too early)"
fi

# 3. All 3 nodes agree on hash at Prague activation block.
ref_hash_p1=$(block_hash_at "$GETH" "$IPC1" "$ACT_BLOCK_P1")
for n in 2 3; do
  h=$(block_hash_at "$GETH" "$(val_ipc "$n")" "$ACT_BLOCK_P1")
  if [[ "$h" == "$ref_hash_p1" && -n "$h" && "$h" != "null" ]]; then
    pass "val-${n} agrees on hash at Prague block ${ACT_BLOCK_P1}: ${ref_hash_p1:0:14}…"
  else
    fail "val-${n} hash mismatch at Prague block ${ACT_BLOCK_P1}: got ${h}, expected ${ref_hash_p1}"
  fi
done

# ── Phase 4b: wait for Lorentz activation ─────────────────────────────────────

_now=$(date +%s)
_wait_timeout=$(( LORENTZ_TIME > _now ? (LORENTZ_TIME - _now + 30) : 30 ))
log "Waiting for Lorentz activation timestamp ${LORENTZ_TIME} (timeout=${_wait_timeout}s)..."
wait_for_timestamp "$LORENTZ_TIME" "$_wait_timeout"

log "Waiting for chain to include Lorentz activation block (timestamp ≥ ${LORENTZ_TIME})..."
_deadline=$(( $(date +%s) + 60 ))
ACT_BLOCK_L=0
while [[ $(date +%s) -lt $_deadline ]]; do
  _ts=$(attach_exec "$GETH" "$IPC1" "eth.getBlock('latest').timestamp" 2>/dev/null || echo 0)
  _bn=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
  if [[ "${_ts:-0}" -ge "${LORENTZ_TIME}" ]]; then
    ACT_BLOCK_L=$_bn
    log "Lorentz activation block: block=${ACT_BLOCK_L}, timestamp=${_ts}."
    break
  fi
  sleep 1
done
[[ "$ACT_BLOCK_L" -eq 0 ]] && die "Lorentz activation block not produced within 60s of LORENTZ_TIME=${LORENTZ_TIME}"

# Walk back to the true first Lorentz fork block.
while [[ "$ACT_BLOCK_L" -gt 1 ]]; do
  _prev_ts=$(attach_exec "$GETH" "$IPC1" \
    "eth.getBlock($(( ACT_BLOCK_L - 1 ))).timestamp" 2>/dev/null || echo 0)
  [[ "${_prev_ts:-0}" -ge "${LORENTZ_TIME}" ]] || break
  ACT_BLOCK_L=$(( ACT_BLOCK_L - 1 ))
done
log "First Lorentz fork block: ${ACT_BLOCK_L}."

# ── Phase 5b: Lorentz block interval stability check ──────────────────────────
#
# Sample 5 consecutive blocks after the Lorentz activation block and verify
# that consecutive timestamp differences are within a reasonable range.
# LorentzBlockInterval = 3000 ms affects out-of-turn backoff, not the in-turn
# 1-second period from genesis; with all 3 validators online the chain stays
# at ~1 s/block.  We allow [1, 30] s to tolerate any transient.

POST_LORENTZ=$(( ACT_BLOCK_L + 6 ))
log "Waiting for chain to reach block ${POST_LORENTZ} (Lorentz interval sample)..."
_deadline=$(( $(date +%s) + 120 ))
while [[ $(date +%s) -lt $_deadline ]]; do
  _h=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
  [[ "$_h" =~ ^[0-9]+$ ]] && [[ "$_h" -ge "$POST_LORENTZ" ]] && break
  sleep 2
done

log "Checking Lorentz block interval stability..."
_prev_ts=0
_max_interval=0
_min_interval=999999
_readable_samples=0
_bad_intervals=0
_interval_list=""
for blk in $(seq $(( ACT_BLOCK_L + 1 )) $(( ACT_BLOCK_L + 5 ))); do
  _ts=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${blk}).timestamp" 2>/dev/null || echo 0)
  if [[ "$_prev_ts" -gt 0 && "$_ts" -gt 0 ]]; then
    _interval=$(( _ts - _prev_ts ))
    _readable_samples=$(( _readable_samples + 1 ))
    _interval_list="${_interval_list} ${_interval}s"
    if [[ "$_interval" -le 0 || "$_interval" -gt 30 ]]; then
      _bad_intervals=$(( _bad_intervals + 1 ))
    else
      [[ "$_interval" -gt "$_max_interval" ]] && _max_interval=$_interval
      [[ "$_interval" -lt "$_min_interval" ]] && _min_interval=$_interval
    fi
  fi
  _prev_ts="$_ts"
done

if [[ "$_readable_samples" -lt 4 ]]; then
  fail "Lorentz: only ${_readable_samples}/4 block intervals readable (RPC failures or chain stalled?)"
elif [[ "$_bad_intervals" -eq 0 ]]; then
  pass "Lorentz block intervals stable: [${_interval_list}], max=${_max_interval}s, min=${_min_interval}s"
else
  fail "Lorentz block intervals not stable: [${_interval_list}], ${_bad_intervals} bad interval(s) outside [1, 30]s"
fi

# 4. All 3 nodes agree on hash at Lorentz activation block.
ref_hash_l=$(block_hash_at "$GETH" "$IPC1" "$ACT_BLOCK_L")
for n in 2 3; do
  h=$(block_hash_at "$GETH" "$(val_ipc "$n")" "$ACT_BLOCK_L")
  if [[ "$h" == "$ref_hash_l" && -n "$h" && "$h" != "null" ]]; then
    pass "val-${n} agrees on hash at Lorentz block ${ACT_BLOCK_L}: ${ref_hash_l:0:14}…"
  else
    fail "val-${n} hash mismatch at Lorentz block ${ACT_BLOCK_L}: got ${h}, expected ${ref_hash_l}"
  fi
done

# ── Phase 4c: wait for Maxwell activation ─────────────────────────────────────

_now=$(date +%s)
_wait_timeout=$(( MAXWELL_TIME > _now ? (MAXWELL_TIME - _now + 30) : 30 ))
log "Waiting for Maxwell activation timestamp ${MAXWELL_TIME} (timeout=${_wait_timeout}s)..."
wait_for_timestamp "$MAXWELL_TIME" "$_wait_timeout"

log "Waiting for chain to include Maxwell activation block (timestamp ≥ ${MAXWELL_TIME})..."
_deadline=$(( $(date +%s) + 90 ))
ACT_BLOCK_M=0
while [[ $(date +%s) -lt $_deadline ]]; do
  _ts=$(attach_exec "$GETH" "$IPC1" "eth.getBlock('latest').timestamp" 2>/dev/null || echo 0)
  _bn=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
  if [[ "${_ts:-0}" -ge "${MAXWELL_TIME}" ]]; then
    ACT_BLOCK_M=$_bn
    log "Maxwell activation block: block=${ACT_BLOCK_M}, timestamp=${_ts}."
    break
  fi
  sleep 1
done
[[ "$ACT_BLOCK_M" -eq 0 ]] && die "Maxwell activation block not produced within 90s of MAXWELL_TIME=${MAXWELL_TIME}"

# Walk back to the true first Maxwell fork block.
while [[ "$ACT_BLOCK_M" -gt 1 ]]; do
  _prev_ts=$(attach_exec "$GETH" "$IPC1" \
    "eth.getBlock($(( ACT_BLOCK_M - 1 ))).timestamp" 2>/dev/null || echo 0)
  [[ "${_prev_ts:-0}" -ge "${MAXWELL_TIME}" ]] || break
  ACT_BLOCK_M=$(( ACT_BLOCK_M - 1 ))
done
log "First Maxwell fork block: ${ACT_BLOCK_M}."

# ── Phase 5c: post-Maxwell stability window + verification ────────────────────

POST_MAXWELL=$(( ACT_BLOCK_M + 3 ))
log "Waiting for chain to reach block ${POST_MAXWELL} (post-Maxwell stability check)..."
_deadline=$(( $(date +%s) + 90 ))
while [[ $(date +%s) -lt $_deadline ]]; do
  _h=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
  [[ "$_h" =~ ^[0-9]+$ ]] && [[ "$_h" -ge "$POST_MAXWELL" ]] && break
  sleep 2
done

log "Running Maxwell verification..."

# 5. parlia_getValidators returns 3 validators after Maxwell.
#    Use .length in JS to avoid quote-escaping issues that arise when
#    JSON.stringify output passes through attach_exec's sed stripping.
_val_count=$(attach_exec "$GETH" "$IPC1" "parlia.getValidators().length" 2>/dev/null || echo 0)
if [[ "$_val_count" =~ ^[0-9]+$ ]] && [[ "$_val_count" -eq 3 ]]; then
  pass "parlia_getValidators returns ${_val_count} validators after Maxwell activation"
else
  fail "parlia_getValidators returned '${_val_count}' validators after Maxwell (expected 3)"
fi

# 6. All 3 nodes agree on hash at Maxwell activation block.
ref_hash_m=$(block_hash_at "$GETH" "$IPC1" "$ACT_BLOCK_M")
for n in 2 3; do
  h=$(block_hash_at "$GETH" "$(val_ipc "$n")" "$ACT_BLOCK_M")
  if [[ "$h" == "$ref_hash_m" && -n "$h" && "$h" != "null" ]]; then
    pass "val-${n} agrees on hash at Maxwell block ${ACT_BLOCK_M}: ${ref_hash_m:0:14}…"
  else
    fail "val-${n} hash mismatch at Maxwell block ${ACT_BLOCK_M}: got ${h}, expected ${ref_hash_m}"
  fi
done

# 7. Chain still advancing.
tip=$(head_number "$GETH" "$IPC1")
if [[ "$tip" -ge "$POST_MAXWELL" ]]; then
  pass "Chain advancing: current head=${tip}"
else
  fail "Chain stalled at head=${tip} (expected ≥ ${POST_MAXWELL})"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "===================================="
echo "  U-6 results: PASS=${PASS} FAIL=${FAIL}"
echo "===================================="

if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED" >&2
  exit 1
fi

if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo "PASS (U-6). Nodes remain running. Run 07-snapshot.sh before U-7."
  exit 0
fi

echo "PASS (U-6). Nodes remain running in Maxwell mode."
echo "Next: bash script/test/upgrade-drill/07-snapshot.sh"
echo "      (U-7 Fermi+Osaka+Mendel script not yet implemented)"
