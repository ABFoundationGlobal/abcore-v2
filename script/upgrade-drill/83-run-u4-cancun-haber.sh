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
#   - U-3 has completed; nodes are running with Feynman active, StakeHub registered
#   - A pre-U-4 snapshot is recommended (run 07-snapshot.sh first)
#
# Steps:
#   1. Determine FORK_TIME (default: now + 120s)
#   2. Patch genesis.json with FORK_TIME for all 3 fork fields and add
#      blobSchedule.cancun = { target:3, max:6, baseFeeUpdateFraction:3338477 }
#      (nodes remain running; genesis.json is only read at geth init time)
#   3. Rolling genesis reinit: for each validator in turn —
#        stop → geth init → restart → re-peer → wait for sync
#      2-of-3 quorum is maintained throughout.
#   4. Wait for chain block timestamp to reach FORK_TIME
#      (Cancun EIP-4844 activates; block headers gain blobGasUsed + excessBlobGas)
#   5. Wait for post-fork observation window; observe for 3 minutes
#   6. Verify: block headers contain blobGasUsed and excessBlobGas, send one
#      EIP-4844 blob transaction and confirm receipt.status == 0x1, chain advancing
#   7. Leave nodes running for U-5
#
# BlobScheduleConfig note:
#   params.ChainConfig.BlobScheduleConfig.Cancun must be set before Cancun
#   activates — VerifyEIP4844Header panics if BlobScheduleConfig == nil.
#   The values (target=3, max=6, baseFeeUpdateFraction=3338477) match
#   params.DefaultCancunBlobConfig in params/config.go.
#
# Blob transaction note:
#   TransactionArgs in internal/ethapi/transaction_args.go supports a blobs
#   field; geth computes KZG commitments and proofs from the raw blob data.
#   We send one all-zero blob (131072 bytes) via eth.sendTransaction over IPC.
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

pass() { log "  OK: $*"; PASS=$(( PASS + 1 )); }
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

# ── Phase 2: patch genesis.json while nodes are still running ────────────────
#
# Add cancunTime, haberTime, haberFixTime = FORK_TIME (all absent/nil after U-3).
# Also add blobSchedule.cancun with the standard Cancun blob parameters —
# this is required because VerifyEIP4844Header panics when BlobScheduleConfig is
# nil (see consensus/misc/eip4844/eip4844.go).
# Updating genesis.json while nodes run is safe — geth reads chainconfig from
# the database, not genesis.json at runtime.

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

# blobSchedule.cancun must be set before Cancun activates.
# Values match params.DefaultCancunBlobConfig (target=3, max=6, fraction=3338477).
old_bs = cfg.get('blobSchedule', '<nil>')
cfg.setdefault('blobSchedule', {})['cancun'] = {
    'target': 3,
    'max': 6,
    'baseFeeUpdateFraction': 3338477,
}
print(f'  blobSchedule.cancun: {old_bs} → {{target:3, max:6, fraction:3338477}}')

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

# ── Phase 4: wait for fork activation block ───────────────────────────────────
#
# wait_for_timestamp blocks until the system clock reaches FORK_TIME.
# The next block produced after FORK_TIME triggers Cancun; block headers gain
# blobGasUsed and excessBlobGas fields.

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
[[ "$ACT_BLOCK" -gt 0 ]] || die "Timed out waiting for activation block"

# Allow a couple of extra blocks to settle.
wait_for_head_at_least "$GETH" "$(val_ipc 1)" "$(( ACT_BLOCK + 2 ))" 30

# ── Phase 5: wait for post-fork observation window ───────────────────────────

POST_OBS=$(( ACT_BLOCK + 5 ))
log "Waiting for nodes to reach block ${POST_OBS} for verification..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_OBS" 180 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
log "All nodes at or past block ${POST_OBS}. Head=$(head_number "$GETH" "$(val_ipc 1)")"

log "Observing chain for 3 minutes..."
_obs_end=$(( $(date +%s) + 180 ))
while [[ $(date +%s) -lt $_obs_end ]]; do
  _rem=$(( _obs_end - $(date +%s) ))
  _h=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo "?")
  log "  ${_rem}s remaining, head=${_h}"
  sleep 30
done

# ── Phase 6: verify ──────────────────────────────────────────────────────────

IPC1=$(val_ipc 1)
log "Running U-4 verification..."

# 1. All 3 nodes agree on block hash at activation block.
ref_hash=$(block_hash_at "$GETH" "$IPC1" "$ACT_BLOCK")
for n in 2 3; do
  h=$(block_hash_at "$GETH" "$(val_ipc "$n")" "$ACT_BLOCK")
  if [[ "$h" == "$ref_hash" && -n "$h" && "$h" != "null" ]]; then
    pass "val-${n} agrees on hash at activation block ${ACT_BLOCK}: ${ref_hash:0:14}…"
  else
    fail "val-${n} hash mismatch at block ${ACT_BLOCK}: got ${h}, expected ${ref_hash}"
  fi
done

# 2. Activation block has blobGasUsed field (EIP-4844 active).
#    Before Cancun the field is absent (null); after activation it is present
#    as an integer (0 when no blob txs were included in that block).
_blob_gas_used=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock(${ACT_BLOCK}).blobGasUsed" 2>/dev/null || echo "null")
if [[ "$_blob_gas_used" != "null" && -n "$_blob_gas_used" ]]; then
  pass "Activation block has blobGasUsed=${_blob_gas_used} (Cancun EIP-4844 active)"
else
  fail "Activation block missing blobGasUsed field (Cancun activation failed?)"
fi

# 3. Activation block has excessBlobGas field.
_excess_blob_gas=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock(${ACT_BLOCK}).excessBlobGas" 2>/dev/null || echo "null")
if [[ "$_excess_blob_gas" != "null" && -n "$_excess_blob_gas" ]]; then
  pass "Activation block has excessBlobGas=${_excess_blob_gas}"
else
  fail "Activation block missing excessBlobGas field"
fi

# 4. Chain still advancing.
tip=$(head_number "$GETH" "$IPC1")
if [[ "$tip" -gt "$POST_OBS" ]]; then
  pass "Chain advancing: current head=${tip}"
else
  fail "Chain stalled at head=${tip} (expected > ${POST_OBS})"
fi

# 5. Send one EIP-4844 blob transaction and confirm receipt.status == 0x1.
#    TransactionArgs.Blobs field (internal/ethapi/transaction_args.go) accepts
#    raw blob bytes; geth computes KZG commitment and proof internally.
#    One all-zero blob (131072 bytes = 262144 hex chars).
log "Sending EIP-4844 blob transaction..."
_addr=$(val_addr 1)

_blob_hex=$(python3 -c "print('0x' + '00' * 131072)")

_blob_tx=$(attach_exec "$GETH" "$IPC1" \
  "eth.sendTransaction({from:'${_addr}',to:'${_addr}',type:'0x3',gas:'0x5208',maxFeePerGas:'0x3b9aca00',maxPriorityFeePerGas:'0x3b9aca00',maxFeePerBlobGas:'0x3b9aca00',value:'0x0',blobs:['${_blob_hex}']})" \
  2>/dev/null || echo "")

if [[ ! "$_blob_tx" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  fail "Blob tx sendTransaction rejected or returned invalid hash (got: '${_blob_tx}')"
else
  log "  blob tx sent: ${_blob_tx}"
  log "Waiting for blob transaction to be mined (5s)..."
  sleep 5
  _blob_status=$(attach_exec "$GETH" "$IPC1" \
    "(function(){var r=eth.getTransactionReceipt('${_blob_tx}');return r?r.status:null;})()" \
    2>/dev/null || echo "null")
  if [[ "$_blob_status" == "0x1" || "$_blob_status" == "1" ]]; then
    pass "EIP-4844 blob transaction confirmed (tx=${_blob_tx:0:14}…, status=0x1)"
  else
    fail "Blob tx failed or not mined (status=${_blob_status}, tx=${_blob_tx})"
  fi
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
echo "Next: bash script/upgrade-drill/07-snapshot.sh && bash script/upgrade-drill/84-run-u5-bohr.sh"
