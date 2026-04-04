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

log "Restarting validators with --config ${TOML_CONFIG} (OverrideParliaGenesisBlock=${PARLIA_GENESIS_BLOCK})"
TOML_CONFIG="${TOML_CONFIG}" run "${SCRIPT_DIR}/02-start.sh"

# ── Phase 6: assert all nodes have the same post-restart chain tip ────────────
# After restart nodes may race to seal the first new block. Clique's fork-choice
# (heaviest TD) resolves the split: the minority-fork node drops its block via
# the downloader once the re-queue attempts are exhausted (see block_fetcher.go).
# We wait for full head convergence before proceeding to the fork block.
#
# Use the head AFTER restart (not the pre-restart head) as min-height, so that
# the check requires all nodes to have produced at least one new block and agree
# on its hash — not just agree on the pre-restart canonical chain.
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
