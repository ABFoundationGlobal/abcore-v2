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
# The outer loop retries the full stop→start→converge cycle up to 3 times.
# In practice, a single retry always suffices; the retry cap is a safety net.
_restart_attempt=0
while true; do
  _restart_attempt=$(( _restart_attempt + 1 ))
  log "Restart attempt ${_restart_attempt}: starting validators with ParliaGenesisBlock=${PARLIA_GENESIS_BLOCK}..."
  TOML_CONFIG="${TOML_CONFIG}" "${SCRIPT_DIR}/02-start.sh"

  # Check whether the chain is advancing.  If the head doesn't move within
  # 20 seconds, the validators are deadlocked and we need to retry.
  _head_before=$(head_number "$GETH" "$(val_ipc 1)")
  _deadline=$(( $(date +%s) + 20 ))
  _alive=false
  while [[ $(date +%s) -lt $_deadline ]]; do
    _head_now=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo "$_head_before")
    if [[ "$_head_now" -gt "$_head_before" ]]; then
      _alive=true
      break
    fi
    sleep 2
  done

  if "$_alive"; then
    log "Chain is advancing (head moved from ${_head_before} to ${_head_now}). Restart successful."
    break
  fi

  if [[ "$_restart_attempt" -ge 3 ]]; then
    die "chain did not advance after ${_restart_attempt} restart attempts — giving up"
  fi

  log "WARNING: chain stalled at head=${_head_before} (Clique seal-race deadlock). Stopping for retry..."
  "${SCRIPT_DIR}/03-stop.sh"
done

# ── Phase 6: wait for convergence after successful restart ───────────────────
post_restart_head=$(head_number "$GETH" "$(val_ipc 1)")
log "Waiting for all nodes to converge post-restart (min-height=${post_restart_head})..."
wait_for_same_head --min-height "$post_restart_head" "$GETH" "$(val_ipc 1)" 60 \
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

# ── Phase 8: stop and clean ───────────────────────────────────────────────────
if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo
  echo "PASS. KEEP_RUNNING=1 — nodes remain running."
  exit 0
fi

echo
echo "==> Stopping nodes"
"${SCRIPT_DIR}/03-stop.sh"

echo
echo "PASS"
