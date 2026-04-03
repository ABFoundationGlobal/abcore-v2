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
log "Waiting for block ${PRE_STOP} (Clique history before fork)..."
wait_for_head_at_least "$GETH" "$(val_ipc 1)" "$PRE_STOP" 120

current=$(head_number "$GETH" "$(val_ipc 1)")
log "Clique chain at block ${current}. Stopping validators..."

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

# ── Phase 6: assert all nodes have the same pre-fork chain tip ────────────────
# wait_for_min_peers succeeds as soon as P2P connections are up (~1 s), but nodes
# may still be replaying Clique history to rebuild their Parlia snapshot.  If one
# validator finishes first it can start sealing before the others are ready,
# causing a divergence at the fork boundary.  Assert consensus on the last
# pre-fork block before allowing any node to advance past it.
log "Asserting all nodes agree on pre-fork chain tip (block ${current})..."
assert_same_hash_at "$current" \
  "$GETH" "$(val_ipc 1)" \
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
