#!/usr/bin/env bash
set -euo pipefail

# Scenario 8: Epoch boundary with short epoch (CLIQUE_EPOCH=10)
#
# Re-runs the upgrade sequence (Scenarios 1–4) with a very short epoch so that
# epoch checkpoint blocks are produced while v1 and v2 nodes coexist.  Two
# assertions are made:
#
#   Checkpoint A (block 10) — mixed v1/v2: validator-1 (v1), validator-2 (v2),
#     validator-3 (v1).  assert_epoch_extradata verifies that all three nodes
#     agree on the extraData encoding of the checkpoint block.
#
#   Checkpoint B (block 20) — all v2: all validators have been upgraded.
#     Same assertion, this time purely between v2 nodes.
#
# This scenario runs in a fully isolated environment (own PORT_BASE, DATADIR_ROOT,
# GENESIS_JSON) so it does not interfere with the main suite.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

# ---------------------------------------------------------------------------
# Isolated environment: pick a free port base and derive independent paths.
# ---------------------------------------------------------------------------
SCN8_BASE=$(find_free_port_base)
log "scn8: using PORT_BASE=${SCN8_BASE}"

export PORT_BASE="${SCN8_BASE}"
export DATADIR_ROOT="${SCRIPT_DIR}/data-scn8-${SCN8_BASE}"
export GENESIS_JSON="${DATADIR_ROOT}/genesis.json"
export CLIQUE_EPOCH=10

# Ensure DATADIR_ROOT exists so that 05-clean.sh and 01-setup.sh can write into it.
mkdir -p "${DATADIR_ROOT}"

# ---------------------------------------------------------------------------
# Cleanup: stop all nodes and release the port sentinel on exit.
# ---------------------------------------------------------------------------
scn8_cleanup() {
  local code=$?
  log "scn8: cleanup (exit=${code})"

  # Collect all candidate pidfiles in scn8's isolated datadir.
  local _live_pids=()
  local _live_pidfiles=()
  for pidfile in \
      "${DATADIR_ROOT}/validator-1/geth.pid" \
      "${DATADIR_ROOT}/validator-2/geth.pid" \
      "${DATADIR_ROOT}/validator-3/geth.pid" \
      "${DATADIR_ROOT}/validator-4/geth.pid" \
      "${DATADIR_ROOT}/rpc-node/geth.pid" \
      "${DATADIR_ROOT}/rpc-v2-1/geth.pid"; do
    [[ -f "$pidfile" ]] || continue
    local pid
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      _live_pids+=("$pid")
      _live_pidfiles+=("$pidfile")
    else
      rm -f "$pidfile"
    fi
  done

  # Wait for all processes to exit with a shared 30-second deadline, then SIGKILL stragglers.
  if [[ ${#_live_pids[@]} -gt 0 ]]; then
    local deadline=$(( $(date +%s) + 30 ))
    for pid in "${_live_pids[@]}"; do
      while kill -0 "$pid" 2>/dev/null && [[ $(date +%s) -lt $deadline ]]; do
        sleep 0.3
      done
      kill -9 "$pid" 2>/dev/null || true
    done
    for pidfile in "${_live_pidfiles[@]}"; do
      rm -f "$pidfile"
    done
  fi

  # Release the sentinel so parallel runs can reuse this port base.
  rmdir "/tmp/compat-clique-reserved-${SCN8_BASE}" 2>/dev/null || true
  exit "$code"
}
trap scn8_cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: run a subscript, inheriting our modified env.
# ---------------------------------------------------------------------------
run() {
  echo
  echo "==> [scn8] $*"
  "$@"
}

# ---------------------------------------------------------------------------
# Phase 1: setup and start v1 validators, then upgrade one to v2 (scn1).
# ---------------------------------------------------------------------------
run "${SCRIPT_DIR}/05-clean.sh"
# 05-clean.sh calls 04-stop.sh which releases the sentinel; re-acquire it so
# the reservation holds for the rest of this run.
mkdir "/tmp/compat-clique-reserved-${SCN8_BASE}" 2>/dev/null || true
run "${SCRIPT_DIR}/01-setup.sh"
run "${SCRIPT_DIR}/02-start-v1-validators.sh"
run "${SCRIPT_DIR}/10-scn1-upgrade-validator.sh"

# After scn1 with the default UPGRADE_VALIDATOR_N=2:
#   validator-1 → v1
#   validator-2 → v2
#   validator-3 → v1

# ---------------------------------------------------------------------------
# Checkpoint A: epoch block 10, mixed v1/v2 network.
# ---------------------------------------------------------------------------
log "scn8: waiting for block 11 (epoch boundary at block 10)"
wait_for_head_at_least "$ABCORE_V2_GETH" "$(val_ipc 2)" 11 120
wait_for_head_at_least "$ABCORE_V1_GETH" "$(val_ipc 1)" 11 120
wait_for_head_at_least "$ABCORE_V1_GETH" "$(val_ipc 3)" 11 120

log "scn8: asserting extraData at epoch block 10 (mixed v1/v2)"
assert_epoch_extradata 10 \
  "$ABCORE_V1_GETH" "$(val_ipc 1)" \
  "$ABCORE_V2_GETH" "$(val_ipc 2)" \
  "$ABCORE_V1_GETH" "$(val_ipc 3)"

log "scn8: asserting block hash at epoch block 10 (mixed v1/v2)"
assert_same_hash_at 10 \
  "$ABCORE_V1_GETH" "$(val_ipc 1)" \
  "$ABCORE_V2_GETH" "$(val_ipc 2)" \
  "$ABCORE_V1_GETH" "$(val_ipc 3)"

# ---------------------------------------------------------------------------
# Phase 2: continue upgrade sequence (scn2, scn3, scn6, scn4).
# ---------------------------------------------------------------------------
run "${SCRIPT_DIR}/20-scn2-add-v2-rpc-node.sh"
run "${SCRIPT_DIR}/30-scn3-add-v2-validator-vote.sh"
run "${SCRIPT_DIR}/35-scn6-tx-propagation.sh"
run "${SCRIPT_DIR}/40-scn4-all-validators-v2.sh"

# After scn4 all validators are v2.

# ---------------------------------------------------------------------------
# Checkpoint B: epoch block 20, all-v2 network.
# ---------------------------------------------------------------------------
log "scn8: waiting for block 21 (epoch boundary at block 20)"
wait_for_head_at_least "$ABCORE_V2_GETH" "$(val_ipc 1)" 21 120

log "scn8: asserting extraData at epoch block 20 (all v2)"
assert_epoch_extradata 20 \
  "$ABCORE_V2_GETH" "$(val_ipc 1)" \
  "$ABCORE_V2_GETH" "$(val_ipc 2)" \
  "$ABCORE_V2_GETH" "$(val_ipc 3)"

log "scn8: asserting block hash at epoch block 20 (all v2)"
assert_same_hash_at 20 \
  "$ABCORE_V2_GETH" "$(val_ipc 1)" \
  "$ABCORE_V2_GETH" "$(val_ipc 2)" \
  "$ABCORE_V2_GETH" "$(val_ipc 3)"

log "scn8 PASS"
