#!/usr/bin/env bash
# U-1: Clique→Parlia switch (block height activation).
#
# Corresponds to devnet Upgrade 1 (v0.2.0, ParliaGenesisBlock = 30001).
# Local parameter default: PARLIA_GENESIS_BLOCK=30.
#
# Prerequisites:
#   - 00-init.sh has been run (DATADIR_ROOT and config.toml exist)
#   - Nodes are stopped
#
# Steps:
#   1. Start 3 validators in Clique mode; wait for block production
#   2. Wait for PRE_STOP blocks to build stable Clique history
#   3. Wait for all nodes to converge on the same head
#   4. Stop all validators
#   5. Append OverrideParliaGenesisBlock to config.toml; restart with
#      deadlock-recovery loop (Clique seal-race can stall the chain on restart)
#   6. Wait for all nodes to cross the fork block
#   7. Verify: chain agreement, non-zero miner, parlia_getValidators,
#              ValidatorSet contract deployed at fork block
#   8. Leave nodes running for U-2
#
# Environment:
#   PARLIA_GENESIS_BLOCK  fork block height (default: 30)
#   KEEP_RUNNING=1        leave nodes up after PASS even on failure
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK:-30}
PRE_STOP=$(( PARLIA_GENESIS_BLOCK - 5 ))
[[ "$PRE_STOP" -lt 5 ]] && PRE_STOP=5
POST_FORK=$(( PARLIA_GENESIS_BLOCK + 5 ))

log "U-1 Clique→Parlia switch"
log "  PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK}"
log "  PRE_STOP=${PRE_STOP}, POST_FORK=${POST_FORK}"

require_exe "$GETH"
[[ -d "${DATADIR_ROOT}" ]] || die "DATADIR_ROOT not found: ${DATADIR_ROOT} — run 00-init.sh first"
require_file "${TOML_CONFIG}"

# Guard against re-running on an already-upgraded chain.
for n in 1 2 3; do
  pidfile=$(val_pid "$n")
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    die "validator-${n} is already running. Stop nodes first (stop_all or clean.sh)."
  fi
done

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

# ── Phase 1: start Clique network ────────────────────────────────────────────

log "Starting 3-validator Clique network..."
for n in 1 2 3; do launch_validator "$n"; done

_pids=()
for n in 1 2 3; do
  wait_for_ipc "$GETH" "$(val_ipc "$n")" 60 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

wire_mesh

_pids=()
for n in 1 2 3; do
  wait_for_min_peers "$GETH" "$(val_ipc "$n")" 2 30 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

wait_for_head_at_least "$GETH" "$(val_ipc 1)" 3 60
log "Clique network up. Head=$(head_number "$GETH" "$(val_ipc 1)")"

# ── Phase 2: wait for stable Clique history before the fork ──────────────────

log "Waiting for all nodes to reach block ${PRE_STOP} (pre-fork Clique history)..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$PRE_STOP" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

# ── Phase 3: wait for convergence before stopping ────────────────────────────
#
# If one node is ahead, stopping and restarting with --mine causes it to
# re-seal the same block height with a fresh timestamp.  The competing
# reorgs put all 3 validators in "signed recently" — permanent deadlock.
wait_for_same_head --min-height "$PRE_STOP" "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

log "All nodes converged at block $(head_number "$GETH" "$(val_ipc 1)"). Stopping..."

# ── Phase 4: stop all validators ─────────────────────────────────────────────

stop_all

# ── Phase 5: append override to TOML and restart with deadlock recovery ──────
#
# Rewrite [Eth] section with OverrideParliaGenesisBlock added.  We rewrite
# rather than append so the field lands in the correct [Eth] section.

python3 - <<PY
import re, sys

cfg = open('${TOML_CONFIG}').read()

# Insert OverrideParliaGenesisBlock after the [Eth] section header if not
# already present.
field = 'OverrideParliaGenesisBlock = ${PARLIA_GENESIS_BLOCK}'
if 'OverrideParliaGenesisBlock' in cfg:
    cfg = re.sub(r'OverrideParliaGenesisBlock\s*=\s*\d+', field, cfg)
else:
    cfg = re.sub(r'(\[Eth\]\n)', r'\1' + field + '\n', cfg)

open('${TOML_CONFIG}', 'w').write(cfg)
print('Updated TOML: OverrideParliaGenesisBlock = ${PARLIA_GENESIS_BLOCK}')
PY

log "TOML updated: ${TOML_CONFIG}"

# Deadlock-recovery restart loop.  On slow machines all 3 validators can seal
# the same block before propagating to each other; competing reorgs corrupt
# the Clique snapshot cache and leave every node stuck in "signed recently".
# The only remedy is to stop-all and restart; the new head height shifts the
# round-robin so a different validator is in-turn, breaking the deadlock.
_attempt=0
while true; do
  _attempt=$(( _attempt + 1 ))
  log "Restart attempt ${_attempt} with ParliaGenesisBlock=${PARLIA_GENESIS_BLOCK}..."

  for n in 1 2 3; do launch_validator "$n"; done

  _pids=()
  for n in 1 2 3; do
    wait_for_ipc "$GETH" "$(val_ipc "$n")" 60 &
    _pids+=($!)
  done
  for p in "${_pids[@]}"; do wait "$p"; done

  wire_mesh

  _pids=()
  for n in 1 2 3; do
    wait_for_min_peers "$GETH" "$(val_ipc "$n")" 2 30 &
    _pids+=($!)
  done
  for p in "${_pids[@]}"; do wait "$p"; done

  # Wait up to 60 s for the chain to advance past PARLIA_GENESIS_BLOCK+2.
  _head_before=$(head_number "$GETH" "$(val_ipc 1)")
  _target=$(( PARLIA_GENESIS_BLOCK + 2 ))
  [[ $(( _head_before + 2 )) -gt "$_target" ]] && _target=$(( _head_before + 2 ))

  _alive=false
  _deadline=$(( $(date +%s) + 60 ))
  while [[ $(date +%s) -lt $_deadline ]]; do
    _head=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo 0)
    if [[ "$_head" -ge "$_target" ]]; then _alive=true; break; fi
    sleep 2
  done

  if "$_alive"; then
    log "Chain advancing (head=${_head} ≥ target=${_target}). Restart successful."
    break
  fi

  if [[ "$_attempt" -ge 5 ]]; then
    die "chain did not advance after ${_attempt} restart attempts — giving up"
  fi

  log "WARNING: chain stalled (Clique seal-race deadlock). Stopping for retry..."
  stop_all
done

# ── Phase 6: wait for all nodes to cross the fork block ──────────────────────

post_restart_head=$(head_number "$GETH" "$(val_ipc 1)")
log "Waiting for all nodes to converge post-restart (min-height=${post_restart_head})..."
wait_for_same_head --min-height "$post_restart_head" "$GETH" "$(val_ipc 1)" 120 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

log "Waiting for all nodes to reach block ${POST_FORK} (post-fork)..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_FORK" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
log "All nodes past fork block. Head=$(head_number "$GETH" "$(val_ipc 1)")"

# ── Phase 7: verify ───────────────────────────────────────────────────────────

log "Running U-1 verification..."
IPC1=$(val_ipc 1)
CHECK_AT=$(( PARLIA_GENESIS_BLOCK + 3 ))

# 1. All nodes agree on hash at CHECK_AT
for n in 2 3; do
  h=$(block_hash_at "$GETH" "$(val_ipc "$n")" "$CHECK_AT")
  ref=$(block_hash_at "$GETH" "$IPC1" "$CHECK_AT")
  if [[ "$h" == "$ref" && -n "$h" && "$h" != "null" ]]; then
    pass "val-${n} agrees on hash at block ${CHECK_AT}: ${ref:0:14}…"
  else
    fail "val-${n} hash mismatch at block ${CHECK_AT}: got ${h}, expected ${ref}"
  fi
done

# 2. Post-fork block has non-zero miner (Parlia sealing proven)
post_miner=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock($(( PARLIA_GENESIS_BLOCK + 1 ))).miner" 2>/dev/null || true)
post_miner_lower=$(echo "$post_miner" | tr '[:upper:]' '[:lower:]')
if [[ "$post_miner_lower" == "0x0000000000000000000000000000000000000000" || \
      -z "$post_miner_lower" || "$post_miner_lower" == "null" ]]; then
  fail "block $(( PARLIA_GENESIS_BLOCK + 1 )) miner is zero — Parlia not sealing"
else
  pass "block $(( PARLIA_GENESIS_BLOCK + 1 )) miner=${post_miner} (non-zero → Parlia sealing)"
fi

# 3. parlia_getValidators at fork block returns the 3 validator addresses
HTTP1="http://127.0.0.1:$(http_port 1)"
parlia_raw=$(curl -sS -X POST "$HTTP1" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"parlia_getValidators\",\"params\":[\"0x$(printf '%x' "$PARLIA_GENESIS_BLOCK")\"],\"id\":1}" \
  2>/dev/null || true)

if echo "$parlia_raw" | grep -q '"result"'; then
  parlia_count=$(echo "$parlia_raw" | python3 -c \
    "import json,sys; print(len(json.load(sys.stdin).get('result') or []))" 2>/dev/null || echo 0)
  if [[ "$parlia_count" -eq 3 ]]; then
    pass "parlia_getValidators(${PARLIA_GENESIS_BLOCK}) returned ${parlia_count} validators"
  else
    fail "parlia_getValidators(${PARLIA_GENESIS_BLOCK}) returned ${parlia_count} validators (expected 3)"
  fi
else
  fail "parlia_getValidators HTTP call failed: ${parlia_raw}"
fi

# 4. ValidatorSet system contract deployed at fork block
VALIDATOR_CONTRACT="0x0000000000000000000000000000000000001000"
code=$(attach_exec "$GETH" "$IPC1" \
  "eth.getCode('${VALIDATOR_CONTRACT}', ${PARLIA_GENESIS_BLOCK})")
code_len=$(( (${#code} - 2) / 2 ))
if [[ "$code_len" -gt 100 ]]; then
  pass "ValidatorSet deployed at block ${PARLIA_GENESIS_BLOCK} (${code_len} bytes)"
else
  fail "ValidatorSet code at block ${PARLIA_GENESIS_BLOCK} too short or empty (code=${code})"
fi

pre_code=$(attach_exec "$GETH" "$IPC1" \
  "eth.getCode('${VALIDATOR_CONTRACT}', $(( PARLIA_GENESIS_BLOCK - 1 )))")
if [[ "$pre_code" == "0x" ]]; then
  pass "ValidatorSet absent at block $(( PARLIA_GENESIS_BLOCK - 1 )) (pre-fork)"
else
  fail "ValidatorSet unexpectedly present before fork: ${pre_code}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "===================================="
echo "  U-1 results: PASS=${PASS} FAIL=${FAIL}"
echo "===================================="

if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED" >&2
  exit 1
fi

if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo "PASS (U-1). Nodes remain running. Run 07-snapshot.sh before U-2."
  exit 0
fi

echo "PASS (U-1). Nodes remain running in Parlia mode."
echo "Next: bash script/upgrade-drill/07-snapshot.sh && bash script/upgrade-drill/81-run-u2-london-forks.sh"
