#!/usr/bin/env bash
# U-5: Bohr (timestamp activation).
#
# Corresponds to devnet Upgrade 5 (v0.6.0 analogue).
# Local parameter default: FORK_TIME = now + 120 s
#
# Fork activation:
#   bohrTime
#
# Key Bohr changes verified here:
#   - ParentBeaconRoot changes from nil to the zero hash (0x000…0)
#   - Epoch-block extra data gains a 1-byte TurnLength field
#   - Default TurnLength = 1 (no governance call required for local drill)
#
# Prerequisites:
#   - U-4 has completed; nodes are running with Cancun + Haber + HaberFix active
#   - A pre-U-5 snapshot is recommended (run 07-snapshot.sh first)
#
# Steps:
#   1. Determine FORK_TIME (default: now + 120s)
#   2. Patch genesis.json with bohrTime = FORK_TIME
#      (nodes remain running; genesis.json is only read at geth init time)
#   3. Rolling genesis reinit: for each validator in turn —
#        stop → geth init → restart → re-peer → wait for sync
#      2-of-3 quorum is maintained throughout.
#   4. Wait for chain block timestamp to reach FORK_TIME
#   5. Verify:
#      - parentBeaconRoot in first post-Bohr block is 0x000…0 (not nil)
#      - parentBeaconRoot in last pre-Bohr block is nil/null
#      - If epoch block reachable within EPOCH_WAIT_TIMEOUT: extra data length
#        reflects the added TurnLength byte
#      - All 3 nodes agree on hash at activation block
#      - Chain still advancing
#   6. Leave nodes running for U-6
#
# Environment:
#   FORK_TIME_OFFSET      seconds from now to activation (default: 120)
#   FORK_TIME             explicit activation timestamp (overrides FORK_TIME_OFFSET)
#   EPOCH_WAIT_TIMEOUT    max seconds to wait for an epoch block (default: 60)
#   KEEP_RUNNING=1        leave nodes running after PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"
[[ -d "${DATADIR_ROOT}" ]] || die "DATADIR_ROOT not found: ${DATADIR_ROOT} — run 00-init.sh and U-1/U-2/U-3/U-4 first"
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
"$_any_running" || die "No validators are running. U-4 must complete successfully before U-5."

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

log "U-5 Bohr"
log "  FORK_TIME=${FORK_TIME}"

_now=$(date +%s)
if [[ "$_now" -ge "$FORK_TIME" ]]; then
  die "FORK_TIME (${FORK_TIME}) is in the past. Set FORK_TIME to a future timestamp."
fi

# ── Phase 2: patch genesis.json while nodes are still running ─────────────────
#
# Add bohrTime = FORK_TIME.
# cancunTime/haberTime/haberFixTime were written by U-4; bohrTime was absent (nil).
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
old = cfg.get('bohrTime', '<nil>')
cfg['bohrTime'] = fork_time
print(f'  bohrTime: {old} → {fork_time}')

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

# ── Phase 5: brief observation window ────────────────────────────────────────

POST_OBS=$(( ACT_BLOCK + 3 ))
log "Waiting for chain to reach block ${POST_OBS} (post-fork stability check)..."
_deadline=$(( $(date +%s) + 60 ))
while [[ $(date +%s) -lt $_deadline ]]; do
  _h=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo "?")
  [[ "$_h" =~ ^[0-9]+$ ]] && [[ "$_h" -ge "$POST_OBS" ]] && break
  sleep 2
done

# ── Phase 6: verify ───────────────────────────────────────────────────────────

log "Running U-5 verification..."
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

# 2. Post-Bohr block: parentBeaconRoot must be the zero hash (0x000…0).
#    Bohr changes parentBeaconRoot from nil to the zero hash in every block header.
ZERO_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
pbr=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock(${ACT_BLOCK}).parentBeaconRoot" 2>/dev/null || true)
if [[ "$pbr" == "$ZERO_HASH" ]]; then
  pass "block ${ACT_BLOCK} parentBeaconRoot=${ZERO_HASH:0:14}… (Bohr active)"
else
  fail "block ${ACT_BLOCK} parentBeaconRoot=${pbr} (expected ${ZERO_HASH:0:14}…)"
fi

# 3. Pre-Bohr block: parentBeaconRoot must be nil/null (not the zero hash).
PRE_BLOCK=$(( ACT_BLOCK - 1 ))
pre_pbr=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock(${PRE_BLOCK}).parentBeaconRoot" 2>/dev/null || true)
if [[ -z "$pre_pbr" || "$pre_pbr" == "null" || "$pre_pbr" == "undefined" ]]; then
  pass "block ${PRE_BLOCK} parentBeaconRoot=nil (pre-Bohr, expected)"
else
  fail "block ${PRE_BLOCK} parentBeaconRoot=${pre_pbr} (Bohr activated too early)"
fi

# 4. Chain still advancing.
tip=$(head_number "$GETH" "$IPC1")
if [[ "$tip" -ge "$POST_OBS" ]]; then
  pass "Chain advancing: current head=${tip}"
else
  fail "Chain stalled at head=${tip} (expected ≥ ${POST_OBS})"
fi

# 5. Epoch-block TurnLength byte check.
#
#    In Bohr, a 1-byte TurnLength field is appended to the validator list in epoch
#    block extra data (before the 65-byte seal).  With 3 validators and BLS keys
#    (enabled since Luban/U-2), the post-Bohr epoch extra data layout is:
#      32 vanity + 3×(20 addr + 48 BLS) + 1 TurnLength + 65 seal = 302 bytes
#    Pre-Bohr epoch extra:
#      32 vanity + 3×(20 addr + 48 BLS) + 65 seal               = 301 bytes
#
#    We wait for the first epoch block after ACT_BLOCK; if it does not arrive
#    within EPOCH_WAIT_TIMEOUT (default: 60s) we log a warning and skip.

EPOCH_LENGTH=$(python3 -c \
  "import json; g=json.load(open('${GENESIS_JSON}')); print(g['config']['parlia']['epoch'])" \
  2>/dev/null || echo 0)
EPOCH_WAIT_TIMEOUT=${EPOCH_WAIT_TIMEOUT:-60}

if [[ "$EPOCH_LENGTH" -gt 0 ]]; then
  _rem=$(( EPOCH_LENGTH - ACT_BLOCK % EPOCH_LENGTH ))
  [[ "$_rem" -eq "$EPOCH_LENGTH" ]] && _rem=0
  NEXT_EPOCH=$(( ACT_BLOCK + _rem ))

  log "Epoch length=${EPOCH_LENGTH}. First epoch block at or after activation: ${NEXT_EPOCH}."
  log "Waiting up to ${EPOCH_WAIT_TIMEOUT}s for epoch block ${NEXT_EPOCH}..."

  _epoch_deadline=$(( $(date +%s) + EPOCH_WAIT_TIMEOUT ))
  _got_epoch=false
  while [[ $(date +%s) -lt $_epoch_deadline ]]; do
    _h=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
    if [[ "$_h" -ge "$NEXT_EPOCH" ]]; then
      _got_epoch=true
      break
    fi
    sleep 2
  done

  if "$_got_epoch"; then
    _extra=$(attach_exec "$GETH" "$IPC1" \
      "eth.getBlock(${NEXT_EPOCH}).extraData" 2>/dev/null || true)
    _extra_len=${#_extra}
    # Post-Bohr epoch extra (3 validators with BLS): 2 + 302*2 = 606 chars
    # Post-Bohr epoch extra validity: (len - 2) must equal 0 mod 2 and total bytes
    # must satisfy: (total - 32 - 65 - 1) % 68 == 0
    _extra_bytes=$(( (_extra_len - 2) / 2 ))
    _check=$(python3 -c "
total = ${_extra_bytes}
# subtract vanity(32) + turnLen(1) + seal(65) = 98
inner = total - 98
# each validator = 20 addr + 48 BLS = 68 bytes
ok = inner > 0 and inner % 68 == 0
print('ok' if ok else f'fail:inner={inner}')
" 2>/dev/null || echo "fail:py_error")
    if [[ "$_check" == "ok" ]]; then
      _n_vals=$(( (_extra_bytes - 98) / 68 ))
      pass "Epoch block ${NEXT_EPOCH} extra data length=${_extra_bytes} bytes (${_n_vals} validators + TurnLength byte, Bohr layout)"
    else
      fail "Epoch block ${NEXT_EPOCH} extra data length=${_extra_bytes} bytes does not match Bohr layout (${_check})"
    fi
  else
    log "  SKIP: epoch block ${NEXT_EPOCH} not reached within ${EPOCH_WAIT_TIMEOUT}s (epoch=${EPOCH_LENGTH}). Re-run with EPOCH_WAIT_TIMEOUT=<higher> or use CLIQUE_EPOCH=<smaller> in 00-init.sh."
  fi
else
  log "  SKIP: could not read epoch from genesis.json; skipping TurnLength byte check."
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "===================================="
echo "  U-5 results: PASS=${PASS} FAIL=${FAIL}"
echo "===================================="

if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED" >&2
  exit 1
fi

if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo "PASS (U-5). Nodes remain running. Run 07-snapshot.sh before U-6."
  exit 0
fi

echo "PASS (U-5). Nodes remain running in Bohr mode."
echo "Next: bash script/test/upgrade-drill/07-snapshot.sh && bash script/test/upgrade-drill/85-run-u6-prague-maxwell.sh"
