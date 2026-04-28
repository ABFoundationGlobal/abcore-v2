#!/usr/bin/env bash
# U-2: London + 13 BSC block forks (block height activation).
#
# Corresponds to devnet Upgrade 2 (v0.3.0, fork block = 60001).
# Local parameter default: LONDON_BLOCK = current head + 20.
#
# Fork activations (all set to LONDON_BLOCK):
#   londonBlock, ramanujanBlock, nielsBlock, mirrorSyncBlock, brunoBlock,
#   eulerBlock, gibbsBlock, nanoBlock, moranBlock, planckBlock, lubanBlock,
#   platoBlock, hertzBlock, hertzfixBlock
#
# Prerequisites:
#   - U-1 has completed; nodes are running in Parlia mode
#   - A pre-U-2 snapshot is recommended (run 07-snapshot.sh first)
#
# Steps:
#   1. Determine LONDON_BLOCK (default: current head + 20)
#   2. Wait for chain to reach LONDON_BLOCK - 5 (preparation window)
#   3. Stop all validators
#   4. Update genesis.json with LONDON_BLOCK for all 14 fork parameters
#   5. reinit_genesis() to update stored chainconfig in all 3 datadirs
#   6. Start all validators; wait for peer mesh
#   7. Wait for chain to cross LONDON_BLOCK
#   8. Verify: chain agreement, baseFeePerGas present in post-fork block
#   9. Leave nodes running for U-3
#
# Environment:
#   LONDON_BLOCK  fork block height (default: current head + 20)
#   KEEP_RUNNING=1
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"
[[ -d "${DATADIR_ROOT}" ]] || die "DATADIR_ROOT not found: ${DATADIR_ROOT} — run 00-init.sh and U-1 first"
require_file "${GENESIS_JSON}"
require_file "${TOML_CONFIG}"

# Verify at least one node is running (U-1 should have left them up).
_any_running=false
for n in 1 2 3; do
  pidfile=$(val_pid "$n")
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    _any_running=true
    break
  fi
done
"$_any_running" || die "No validators are running. U-1 must complete successfully before U-2."

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

# ── Phase 1: determine LONDON_BLOCK ──────────────────────────────────────────

if [[ -z "${LONDON_BLOCK:-}" ]]; then
  _cur=$(head_number "$GETH" "$(val_ipc 1)")
  LONDON_BLOCK=$(( _cur + 20 ))
  log "LONDON_BLOCK not set — defaulting to current head + 20 = ${LONDON_BLOCK}"
fi

PREP_STOP=$(( LONDON_BLOCK - 5 ))
[[ "$PREP_STOP" -lt 1 ]] && PREP_STOP=1
POST_FORK=$(( LONDON_BLOCK + 3 ))

log "U-2 London + BSC block forks"
log "  LONDON_BLOCK=${LONDON_BLOCK}, PREP_STOP=${PREP_STOP}, POST_FORK=${POST_FORK}"

# Sanity: LONDON_BLOCK must be ahead of current chain tip.
_head=$(head_number "$GETH" "$(val_ipc 1)")
if [[ "$_head" -ge "$LONDON_BLOCK" ]]; then
  die "Current head (${_head}) is already past LONDON_BLOCK (${LONDON_BLOCK}).
Set LONDON_BLOCK to a higher value, e.g. LONDON_BLOCK=$(( _head + 50 ))"
fi

# ── Phase 2: wait for preparation window ─────────────────────────────────────

log "Waiting for head to reach ${PREP_STOP} (5 blocks before fork)..."
wait_for_head_at_least "$GETH" "$(val_ipc 1)" "$PREP_STOP" 120

# Drain any in-flight blocks so all nodes are at the same tip before stopping.
wait_for_same_head --min-height "$PREP_STOP" "$GETH" "$(val_ipc 1)" 30 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

log "All nodes converged at $(head_number "$GETH" "$(val_ipc 1)"). Stopping for genesis reinit..."

# ── Phase 3: stop all validators ─────────────────────────────────────────────

stop_all

# ── Phase 4: update genesis.json with LONDON_BLOCK ───────────────────────────
#
# We lower all 12 fork parameters from their placeholder values (9_999_999)
# to LONDON_BLOCK.  Only these fields are modified; everything else (chainId,
# alloc, extraData, clique/parlia period/epoch) stays the same so the genesis
# block hash remains unchanged and geth init succeeds.

export GENESIS_JSON LONDON_BLOCK
python3 - <<'PY'
import json, os

genesis_path = os.environ['GENESIS_JSON']
london_block = int(os.environ['LONDON_BLOCK'])

with open(genesis_path) as f:
    genesis = json.load(f)

cfg = genesis['config']
fork_fields = [
    'londonBlock',
    'ramanujanBlock',
    'nielsBlock',
    'mirrorSyncBlock',
    'brunoBlock',
    'eulerBlock',
    'gibbsBlock',
    'nanoBlock',
    'moranBlock',
    'planckBlock',
    'lubanBlock',
    'platoBlock',
    'hertzBlock',
    'hertzfixBlock',
]
for field in fork_fields:
    old = cfg.get(field, '<nil>')
    cfg[field] = london_block
    print(f'  {field}: {old} → {london_block}')

with open(genesis_path, 'w') as f:
    json.dump(genesis, f, indent=2)
    f.write('\n')
print(f'Updated {genesis_path}')
PY

# ── Phase 5: reinit all datadirs to update stored chainconfig ─────────────────

reinit_genesis

# ── Phase 6: start all validators ─────────────────────────────────────────────

log "Starting validators with updated chainconfig (London at block ${LONDON_BLOCK})..."
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

log "Network up. Head=$(head_number "$GETH" "$(val_ipc 1)")"

# ── Phase 7: wait for the fork block ──────────────────────────────────────────

log "Waiting for all nodes to cross London fork block ${LONDON_BLOCK}..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_FORK" 180 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
log "All nodes past London fork. Head=$(head_number "$GETH" "$(val_ipc 1)")"

# ── Phase 8: verify ───────────────────────────────────────────────────────────

log "Running U-2 verification..."
IPC1=$(val_ipc 1)
CHECK_AT=$(( LONDON_BLOCK + 1 ))

# 1. All nodes agree on hash at CHECK_AT
ref_hash=$(block_hash_at "$GETH" "$IPC1" "$CHECK_AT")
for n in 2 3; do
  h=$(block_hash_at "$GETH" "$(val_ipc "$n")" "$CHECK_AT")
  if [[ "$h" == "$ref_hash" && -n "$h" && "$h" != "null" ]]; then
    pass "val-${n} agrees on hash at block ${CHECK_AT}: ${ref_hash:0:14}…"
  else
    fail "val-${n} hash mismatch at block ${CHECK_AT}: got ${h}, expected ${ref_hash}"
  fi
done

# 2. baseFeePerGas field must be present in the first post-fork block.
#    On BSC, London initialises baseFeePerGas to 0 (not the standard ~1 Gwei),
#    so accept 0 as valid — the field being present is the activation indicator.
basefee=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${CHECK_AT}).baseFeePerGas" 2>/dev/null || true)
if [[ -z "$basefee" || "$basefee" == "null" || "$basefee" == "undefined" ]]; then
  fail "block ${CHECK_AT} baseFeePerGas absent: ${basefee} (London not activated?)"
else
  pass "block ${CHECK_AT} baseFeePerGas=${basefee} (EIP-1559 field present)"
fi

# 3. Pre-fork block must NOT have baseFeePerGas.
#    geth JS console returns undefined (not null) for absent fields.
pre_basefee=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBlock($(( LONDON_BLOCK - 1 ))).baseFeePerGas" 2>/dev/null || true)
if [[ -z "$pre_basefee" || "$pre_basefee" == "null" || "$pre_basefee" == "undefined" ]]; then
  pass "block $(( LONDON_BLOCK - 1 )) has no baseFeePerGas (pre-London, expected)"
else
  fail "block $(( LONDON_BLOCK - 1 )) baseFeePerGas=${pre_basefee} (London activated too early)"
fi

# 4. Chain is still producing blocks (no consensus breakage)
tip=$(head_number "$GETH" "$IPC1")
if [[ "$tip" -ge "$POST_FORK" ]]; then
  pass "Chain advancing past fork: current head=${tip}"
else
  fail "Chain stalled at head=${tip} (expected ≥ ${POST_FORK})"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "===================================="
echo "  U-2 results: PASS=${PASS} FAIL=${FAIL}"
echo "===================================="

if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED" >&2
  exit 1
fi

if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo "PASS (U-2). Nodes remain running."
  exit 0
fi

echo "PASS (U-2). Nodes remain running."
echo "Next: bash script/upgrade-drill/07-snapshot.sh && bash script/upgrade-drill/82-run-u3-shanghai-feynman.sh"
