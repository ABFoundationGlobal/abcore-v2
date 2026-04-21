#!/usr/bin/env bash
# End-to-end Clique→Parlia transition test (T-1).
#
# Scope: snapshot correctness, fork block transition, validator continuity,
# system contract deployment, pre-fork vote-change (98-run-vote-change.sh).
# NOT covered here: rolling/one-by-one validator restart (T-2), Parlia epoch
# boundary at block 200 (getCurrentValidators system contract call path),
# transaction submission after the fork. See README.md for full details.
#
# Steps:
#   1. Setup: generate accounts + Clique genesis + init datadirs
#   2. Start 3 validators in Clique mode, wait for block production
#   3. Wait until chain reaches (PARLIA_GENESIS_BLOCK - 5) to ensure a stable Clique history
#   4. Stop all validators
#   5. Write a TOML config with OverrideParliaGenesisBlock and restart
#   6. Assert all nodes have converged on the same pre-fork chain tip
#   7. Wait for the chain to cross PARLIA_GENESIS_BLOCK
#   8. Run verification checks
#   9. Stop and clean up
#
# Environment:
#   PARLIA_GENESIS_BLOCK  block at which the fork fires (default: 20)
#   PORT_BASE             base port offset; auto-selected if unset
#   KEEP_RUNNING=1        leave nodes up after PASS (for manual inspection)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

# Build v2 binary if no explicit path provided (local dev workflow).
# In CI, GETH is set to the pre-built binary and this is skipped.
if [[ -z "${GETH:-}" ]]; then
  echo "[$(date +'%H:%M:%S')] Building v2 binary (set GETH=... to skip)..."
  (cd "${_REPO_ROOT}" && CGO_CFLAGS="-O -D__BLST_PORTABLE__" CGO_CFLAGS_ALLOW="-O -D__BLST_PORTABLE__" make geth)
fi

_PORT_BASE_EXPLICIT=${PORT_BASE+set}
_DATADIR_ROOT_EXPLICIT=${DATADIR_ROOT+set}

source "${SCRIPT_DIR}/lib.sh"

if [[ "${_PORT_BASE_EXPLICIT}" != "set" ]]; then
  PORT_BASE=$(find_free_port_base)
  log "Auto-selected PORT_BASE=${PORT_BASE}"
fi
export PORT_BASE

if [[ "${_DATADIR_ROOT_EXPLICIT:-}" != "set" ]]; then
  export DATADIR_ROOT="${SCRIPT_DIR}/data-${PORT_BASE}"
fi

TOML_CONFIG="${DATADIR_ROOT}/override.toml"

cleanup_on_exit() {
  local code=$?
  if [[ "$code" -ne 0 ]]; then
    echo
    if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
      echo "FAILED (exit=${code}). KEEP_RUNNING=1 — nodes remain running (logs: ${DATADIR_ROOT})." >&2
    else
      echo "FAILED (exit=${code}). Stopping nodes (logs preserved: ${DATADIR_ROOT})." >&2
      "${SCRIPT_DIR}/03-stop.sh" || true
    fi
  fi
  exit "$code"
}
trap cleanup_on_exit EXIT

run() {
  echo
  echo "==> $*"
  "$@"
}

# ── Phase 1: setup ────────────────────────────────────────────────────────────
run "${SCRIPT_DIR}/04-clean.sh"
run "${SCRIPT_DIR}/01-setup.sh"

# ── Phase 2: start Clique network ────────────────────────────────────────────
run "${SCRIPT_DIR}/02-start.sh"

# ── Phase 3: wait for stable Clique history before the fork block ────────────
PRE_STOP=$(( PARLIA_GENESIS_BLOCK - 5 ))
if [[ "$PRE_STOP" -lt 5 ]]; then PRE_STOP=5; fi
log "Waiting for all 3 nodes to reach block ${PRE_STOP} (Clique history before fork)..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$PRE_STOP" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

# Verify all nodes agree on the same canonical head before stopping.
# If one node is ahead (e.g. has sealed a block the others haven't yet imported),
# stopping and restarting with --mine will cause that node to re-seal the same
# block height with a fresh timestamp, racing with the other nodes.  This seal
# race creates competing block N+1 hashes that put all 3 validators in
# "signed recently" state simultaneously — permanent deadlock for block N+2.
#
# Use PRE_STOP (not the live head) as min-height to avoid chasing a moving target
# while simultaneously waiting: all nodes are already at >= PRE_STOP, so we just
# need hash agreement at the shared minimum.
wait_for_same_head --min-height "$PRE_STOP" "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

current=$(head_number "$GETH" "$(val_ipc 1)")
log "All nodes converged at block ${current}. Stopping validators..."

# ── Phase 4: stop all validators ─────────────────────────────────────────────
run "${SCRIPT_DIR}/03-stop.sh"

# ── Phase 5: write TOML override and restart ─────────────────────────────────
log "Writing TOML override config: ${TOML_CONFIG}"
mkdir -p "${DATADIR_ROOT}"
cat > "${TOML_CONFIG}" <<TOML
[Eth]
NetworkId = ${NETWORK_ID}
SyncMode = "full"
OverrideParliaGenesisBlock = ${PARLIA_GENESIS_BLOCK}

[Eth.Miner]
GasPrice = 1000000000

[Node]
InsecureUnlockAllowed = true
NoUSB = true
TOML

# Restart with deadlock recovery.
#
# On slow machines (CI), all 3 validators can seal the same block before
# propagating to each other.  The competing reorgs corrupt the Clique snapshot
# cache, leaving every validator stuck in "signed recently" — a permanent
# deadlock.  When this happens the only remedy is to stop all validators and
# restart again; the new head height shifts the Clique round-robin so a
# different validator is in-turn, breaking the deadlock.
#
# The outer loop retries the full stop→start→converge cycle up to 5 times.
# In practice, a single retry always suffices; the retry cap is a safety net.
_restart_attempt=0
while true; do
  _restart_attempt=$(( _restart_attempt + 1 ))
  log "Restart attempt ${_restart_attempt}: starting validators with ParliaGenesisBlock=${PARLIA_GENESIS_BLOCK}..."
  TOML_CONFIG="${TOML_CONFIG}" "${SCRIPT_DIR}/02-start.sh"

  # Require the chain to advance at least 2 blocks from the current tip AND
  # past ParliaGenesisBlock+2 (so the fork transition has completed).
  # Using current_head+2 rather than a fixed PGB+2 target ensures that even
  # if on-disk data is already past the fork, a retry still detects liveness.
  _head_before=$(head_number "$GETH" "$(val_ipc 1)")
  _target=$(( _head_before + 2 ))
  if [[ "$(( PARLIA_GENESIS_BLOCK + 2 ))" -gt "$_target" ]]; then
    _target=$(( PARLIA_GENESIS_BLOCK + 2 ))
  fi
  _deadline=$(( $(date +%s) + 60 ))
  _alive=false
  while [[ $(date +%s) -lt $_deadline ]]; do
    _head_now=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo "$_head_before")
    if [[ "$_head_now" -ge "$_target" ]]; then
      _alive=true
      break
    fi
    sleep 2
  done

  if "$_alive"; then
    log "Chain is advancing (head=${_head_now} >= target=${_target}). Restart successful."
    break
  fi

  if [[ "$_restart_attempt" -ge 5 ]]; then
    die "chain did not advance after ${_restart_attempt} restart attempts — giving up"
  fi

  _head_now=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo "$_head_before")
  log "WARNING: chain stalled at head=${_head_now} (seal-race deadlock). Stopping for retry..."
  "${SCRIPT_DIR}/03-stop.sh"
done

# ── Phase 6: wait for convergence after successful restart ───────────────────
post_restart_head=$(head_number "$GETH" "$(val_ipc 1)")
log "Waiting for all nodes to converge post-restart (min-height=${post_restart_head})..."
wait_for_same_head --min-height "$post_restart_head" "$GETH" "$(val_ipc 1)" 120 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

# ── Phase 7: wait for the chain to cross the fork block ──────────────────────
POST_FORK=$(( PARLIA_GENESIS_BLOCK + 5 ))
log "Waiting for all nodes to reach block ${POST_FORK} (post-fork)..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_FORK" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
log "All nodes past fork block."

# ── Phase 7: verify ───────────────────────────────────────────────────────────
run "${SCRIPT_DIR}/05-verify.sh"

# ── Phase 8: stop T-1 nodes ───────────────────────────────────────────────────
if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo
  echo "PASS (T-1). KEEP_RUNNING=1 — nodes remain running; sub-tests skipped."
  exit 0
fi

echo
echo "==> Stopping nodes"
"${SCRIPT_DIR}/03-stop.sh"

# ── T-3: transaction across fork boundary ─────────────────────────────────────
echo
log "Running T-3 tx-across-fork test..."
PORT_BASE="$PORT_BASE" \
DATADIR_ROOT="${DATADIR_ROOT}-tx" \
GETH="$GETH" \
PARLIA_GENESIS_BLOCK="$PARLIA_GENESIS_BLOCK" \
"${SCRIPT_DIR}/94-run-tx-test.sh"

# ── T-2: Parlia epoch boundary (opt-in; ~3 minutes) ───────────────────────────
if [[ "${RUN_EPOCH_TEST:-0}" -eq 1 ]]; then
  # T-2 uses EPOCH_LENGTH=50 and requires PARLIA_GENESIS_BLOCK < 50.
  # Skip with a clear message if the caller has set a larger fork block.
  if [[ "${PARLIA_GENESIS_BLOCK:-20}" -ge 50 ]]; then
    log "Skipping T-2: PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK:-20} >= EPOCH_LENGTH=50; run 95-run-epoch-test.sh directly with a compatible fork block"
  else
    echo
    log "Running T-2 epoch boundary test (RUN_EPOCH_TEST=1)..."
    EPOCH_LENGTH=50 \
    PORT_BASE="$PORT_BASE" \
    DATADIR_ROOT="${DATADIR_ROOT}-epoch" \
    GETH="$GETH" \
    PARLIA_GENESIS_BLOCK="$PARLIA_GENESIS_BLOCK" \
    "${SCRIPT_DIR}/95-run-epoch-test.sh"
  fi
fi

# ── Clique-epoch-fork: fork block == Clique epoch boundary (opt-in) ───────────
if [[ "${RUN_CLIQUE_EPOCH_FORK_TEST:-0}" -eq 1 ]]; then
  echo
  log "Running Clique-epoch-fork test (RUN_CLIQUE_EPOCH_FORK_TEST=1)..."
  # PARLIA_GENESIS_BLOCK is explicitly unset so 93-run-clique-epoch-fork-test.sh
  # defaults to EPOCH_LENGTH (the invariant it requires: PGB == EPOCH_LENGTH).
  # Without this, a caller-supplied PGB that is not a multiple of EPOCH_LENGTH=20
  # would cause the script to die unexpectedly.
  EPOCH_LENGTH=20 \
  PORT_BASE="$PORT_BASE" \
  DATADIR_ROOT="${DATADIR_ROOT}-clique-epoch-fork" \
  GETH="$GETH" \
  bash -c 'unset PARLIA_GENESIS_BLOCK; exec "$0" "$@"' \
    "${SCRIPT_DIR}/93-run-clique-epoch-fork-test.sh"
fi

echo
echo "PASS"
