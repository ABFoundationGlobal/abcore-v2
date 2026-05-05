#!/usr/bin/env bash
# U-4: Cancun + Haber + HaberFix (timestamp activation).
#
# Corresponds to devnet Upgrade 4 (v0.5.0 analogue).
# Local parameter default: FORK_TIME = now + 120 s
#
# Fork activations (all set to FORK_TIME):
#   cancunTime, haberTime, haberFixTime
#
# Prerequisites:
#   - U-3 has completed; nodes are running with Shanghai + Feynman active
#   - A pre-U-4 snapshot is recommended (run 07-snapshot.sh first)
#
# Steps:
#   1. Determine FORK_TIME (default: now + 120s)
#   2. Patch genesis.json with FORK_TIME for all 3 fork fields
#      (nodes remain running; genesis.json is only read at geth init time)
#   3. Rolling genesis reinit: for each validator in turn —
#        stop → geth init → restart → re-peer → wait for sync
#      2-of-3 quorum is maintained throughout.
#   4. Wait for chain block timestamp to reach FORK_TIME
#      (EIP-4844 blob fields appear in block headers on the first activation block)
#   5. Verify:
#      - blobGasUsed field present in first post-fork block header
#      - excessBlobGas field present in first post-fork block header
#      - Pre-fork block has neither field
#      - All 3 nodes agree on hash at activation block
#      - Chain still advancing
#   6. Leave nodes running for U-5
#
# Environment:
#   FORK_TIME_OFFSET  seconds from now to activation (default: 120)
#   FORK_TIME         explicit activation timestamp (overrides FORK_TIME_OFFSET)
#   KEEP_RUNNING=1    leave nodes running after PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"
[[ -d "${DATADIR_ROOT}" ]] || die "DATADIR_ROOT not found: ${DATADIR_ROOT} — run 00-init.sh and U-1/U-2/U-3 first"
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
"$_any_running" || die "No validators are running. U-3 must complete successfully before U-4."

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

# ── Phase 1: determine FORK_TIME ─────────────────────────────────────────────

wait_for_ipc "$GETH" "$(val_ipc 1)" 30

if [[ -z "${FORK_TIME:-}" ]]; then
  FORK_TIME=$(( $(date +%s) + ${FORK_TIME_OFFSET:-120} ))
  log "FORK_TIME not set — defaulting to now + ${FORK_TIME_OFFSET:-120}s = ${FORK_TIME}"
fi

log "U-4 Cancun + Haber + HaberFix"
log "  FORK_TIME=${FORK_TIME}"

_now=$(date +%s)
if [[ "$_now" -ge "$FORK_TIME" ]]; then
  die "FORK_TIME (${FORK_TIME}) is in the past. Set FORK_TIME to a future timestamp."
fi

# ── Phase 2: patch genesis.json while nodes are still running ─────────────────
#
# Add cancunTime, haberTime, haberFixTime = FORK_TIME.
# shanghaiTime/feynmanTime were written by U-3; cancunTime was absent (nil).
# Updating the file while nodes run is safe — geth reads chainconfig from the
# database, not genesis.json at runtime.

export GENESIS_JSON FORK_TIME
python3 - <<'PY'
import json, os

genesis_path = os.environ['GENESIS_JSON']
fork_time = int(os.environ['FORK_TIME'])

with open(genesis_path) as f:
    genesis = json.load(f)

cfg = genesis['config']
for field in ('cancunTime', 'haberTime', 'haberFixTime'):
    old = cfg.get(field, '<nil>')
    cfg[field] = fork_time
    print(f'  {field}: {old} → {fork_time}')

# blobSchedule.cancun is required by CheckConfigForkOrder when cancunTime is set.
# Use BSC default: target=3, max=6, updateFraction=3338477.
if 'blobSchedule' not in cfg:
    cfg['blobSchedule'] = {}
if 'cancun' not in cfg['blobSchedule']:
    cfg['blobSchedule']['cancun'] = {'target': 3, 'max': 6, 'baseFeeUpdateFraction': 3338477}
    print(f"  blobSchedule.cancun: <nil> → {{target:3, max:6, baseFeeUpdateFraction:3338477}}")

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

# ── Phase 4: wait for fork activation block ────────────────────────────────────

_now=$(date +%s)
_wait_timeout=$(( FORK_TIME > _now ? (FORK_TIME - _now + 30) : 30 ))
log "Waiting for activation timestamp ${FORK_TIME} (timeout=${_wait_timeout}s)..."
wait_for_timestamp "$FORK_TIME" "$_wait_timeout"

log "Waiting for chain to include activation block (timestamp ≥ ${FORK_TIME})..."
_deadline=$(( $(date +%s) + 60 ))
ACT_BLOCK=0
while [[ $(date +%s) -lt $_deadline ]]; do
  _ts=$(attach_exec "$GETH" "$(val_ipc 1)" "eth.getBlock('latest').timestamp" 2>/dev/null || echo 0)
  _bn=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo 0)
  if [[ "${_ts:-0}" -ge "${FORK_TIME}" ]]; then
    ACT_BLOCK=$_bn
    log "Activation block included: block=${ACT_BLOCK}, timestamp=${_ts}."
    break
  fi
  sleep 1
done

if [[ "$ACT_BLOCK" -eq 0 ]]; then
  die "Activation block not produced within 60s of FORK_TIME=${FORK_TIME}"
fi

# ── Phase 5: brief observation window ─────────────────────────────────────────
#
# Wait for a few more blocks to confirm Cancun sealing is stable after the fork.

POST_OBS=$(( ACT_BLOCK + 3 ))
log "Waiting for chain to reach block ${POST_OBS} (post-fork stability check)..."
_rem=$(( FORK_TIME - $(date +%s) + 90 ))
_deadline=$(( $(date +%s) + 60 ))
while [[ $(date +%s) -lt $_deadline ]]; do
  _h=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo "?")
  [[ "$_h" =~ ^[0-9]+$ ]] && [[ "$_h" -ge "$POST_OBS" ]] && break
  sleep 2
done

# ── Phase 6: verify ───────────────────────────────────────────────────────────

log "Running U-4 verification..."
IPC1=$(val_ipc 1)

# 1. All 3 nodes agree on hash at activation block.
ref_hash=$(block_hash_at "$GETH" "$IPC1" "$ACT_BLOCK")
for n in 2 3; do
  h=$(block_hash_at "$GETH" "$(val_ipc "$n")" "$ACT_BLOCK")
  if [[ "$h" == "$ref_hash" && -n "$h" && "$h" != "null" ]]; then
    pass "val-${n} agrees on hash at activation block ${ACT_BLOCK}: ${ref_hash:0:14}…"
  else
    fail "val-${n} hash mismatch at block ${ACT_BLOCK}: got ${h}, expected ${ref_hash}"
  fi
done

# 2. blobGasUsed field must be present in the first post-fork block.
#    On BSC/Parlia, blobs are not used by the protocol itself, but the header
#    field is required by EIP-4844 from Cancun onward (value = 0 is valid).
blob_gas=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock(${ACT_BLOCK}).blobGasUsed" 2>/dev/null || true)
if [[ -z "$blob_gas" || "$blob_gas" == "null" || "$blob_gas" == "undefined" ]]; then
  fail "block ${ACT_BLOCK} blobGasUsed absent: '${blob_gas}' (Cancun not activated?)"
else
  pass "block ${ACT_BLOCK} blobGasUsed=${blob_gas} (EIP-4844 header field present)"
fi

# 3. excessBlobGas field must be present in the first post-fork block.
excess_blob=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock(${ACT_BLOCK}).excessBlobGas" 2>/dev/null || true)
if [[ -z "$excess_blob" || "$excess_blob" == "null" || "$excess_blob" == "undefined" ]]; then
  fail "block ${ACT_BLOCK} excessBlobGas absent: '${excess_blob}' (Cancun not activated?)"
else
  pass "block ${ACT_BLOCK} excessBlobGas=${excess_blob} (EIP-4844 header field present)"
fi

# 4. Pre-fork block must NOT have blobGasUsed or excessBlobGas.
PRE_BLOCK=$(( ACT_BLOCK - 1 ))
pre_blob=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock(${PRE_BLOCK}).blobGasUsed" 2>/dev/null || true)
if [[ -z "$pre_blob" || "$pre_blob" == "null" || "$pre_blob" == "undefined" ]]; then
  pass "block ${PRE_BLOCK} has no blobGasUsed (pre-Cancun, expected)"
else
  fail "block ${PRE_BLOCK} blobGasUsed=${pre_blob} (Cancun activated too early)"
fi
pre_excess=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock(${PRE_BLOCK}).excessBlobGas" 2>/dev/null || true)
if [[ -z "$pre_excess" || "$pre_excess" == "null" || "$pre_excess" == "undefined" ]]; then
  pass "block ${PRE_BLOCK} has no excessBlobGas (pre-Cancun, expected)"
else
  fail "block ${PRE_BLOCK} excessBlobGas=${pre_excess} (Cancun activated too early)"
fi

# 5. Chain still advancing.
tip=$(head_number "$GETH" "$IPC1")
if [[ "$tip" -gt "$POST_OBS" ]]; then
  pass "Chain advancing: current head=${tip}"
else
  fail "Chain stalled at head=${tip} (expected > ${POST_OBS})"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "===================================="
echo "  U-4 results: PASS=${PASS} FAIL=${FAIL}"
echo "===================================="

if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED" >&2
  exit 1
fi

if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo "PASS (U-4). Nodes remain running. Run 07-snapshot.sh before U-5."
  exit 0
fi

echo "PASS (U-4). Nodes remain running in Cancun mode."
echo "After ALL nodes complete U-4:"
echo "  1. Verify blobGasUsed=0 in blocks (Parlia does not produce blob txs by default)."
echo "  2. Observe ≥48h on DevNet before proceeding to U-5 (Bohr, 3s→450ms)."
echo "Next: bash script/upgrade-drill/07-snapshot.sh && bash script/upgrade-drill/84-run-u5-bohr.sh"
