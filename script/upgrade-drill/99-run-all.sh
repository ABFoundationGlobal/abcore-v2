#!/usr/bin/env bash
# One-shot upgrade drill: init → U-1 (Clique→Parlia) → U-2 (London + BSC forks)
#                              → U-3 (Shanghai + Kepler + Feynman).
#
# Mirrors the structure of transition-test/99-run-all.sh.
# Each round leaves nodes running so the next round can read the current chain
# head — no snapshot step is needed in the automated path.
#
# Usage:
#   bash script/upgrade-drill/99-run-all.sh
#   GETH=./build/bin/geth bash script/upgrade-drill/99-run-all.sh
#   PARLIA_GENESIS_BLOCK=50 GETH=./build/bin/geth bash script/upgrade-drill/99-run-all.sh
#
# Environment:
#   GETH                  geth binary path (auto-built if unset)
#   PARLIA_GENESIS_BLOCK  U-1 Clique→Parlia fork block height (default: 30)
#   LONDON_BLOCK          U-2 London fork block height (default: U-1 head + 60)
#   FORK_TIME_OFFSET      U-3 seconds from now to Shanghai/Feynman activation (default: 120)
#   KEEP_RUNNING=1        leave nodes running after PASS (for manual inspection)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ── Build geth if no explicit path provided ───────────────────────────────────

if [[ -z "${GETH:-}" ]]; then
  _REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
  echo "[$(date +'%H:%M:%S')] Building geth (set GETH=... to skip)..."
  (cd "${_REPO_ROOT}" && \
    CGO_CFLAGS="-O -D__BLST_PORTABLE__" \
    CGO_CFLAGS_ALLOW="-O -D__BLST_PORTABLE__" \
    make geth)
fi

source "${SCRIPT_DIR}/lib.sh"

# Export all variables that child scripts source from lib.sh; this lets the
# user override DATADIR_ROOT / CHAIN_ID / etc. once on the command line and
# have every sub-script pick it up.
export GETH
export DATADIR_ROOT GENESIS_JSON TOML_CONFIG SNAPSHOT_DIR
export CHAIN_ID NETWORK_ID CLIQUE_PERIOD CLIQUE_EPOCH
export PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK:-30}
# LONDON_BLOCK and FORK_TIME are intentionally not forced here: each U-N script
# defaults to a value derived from the live chain head / current time, which
# gives the right value when it reads a running network.

log "run-all: GETH=${GETH}"
log "run-all: DATADIR_ROOT=${DATADIR_ROOT}"
log "run-all: PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK}"

# ── Cleanup on failure ────────────────────────────────────────────────────────

cleanup_on_exit() {
  local code=$?
  [[ "$code" -eq 0 ]] && return
  echo
  echo "FAILED (exit=${code}). Stopping nodes (logs preserved: ${DATADIR_ROOT})." >&2
  stop_all || true
  exit "$code"
}
trap cleanup_on_exit EXIT

run() {
  echo
  echo "==> $*"
  "$@"
}

# ── Init ──────────────────────────────────────────────────────────────────────

if [[ -d "${DATADIR_ROOT}" ]]; then
  run bash "${SCRIPT_DIR}/clean.sh"
fi
run bash "${SCRIPT_DIR}/00-init.sh"

# ── U-1: Clique→Parlia ────────────────────────────────────────────────────────

run bash "${SCRIPT_DIR}/80-run-u1-parlia-switch.sh"

# ── U-2: London + BSC forks ───────────────────────────────────────────────────
# Nodes are still running from U-1; 81-run-u2 reads the live head to compute
# LONDON_BLOCK (or uses the explicit LONDON_BLOCK env var if set).

run bash "${SCRIPT_DIR}/81-run-u2-london-forks.sh"

# ── U-3: Shanghai + Kepler + Feynman ─────────────────────────────────────────
# Nodes are still running from U-2; 82-run-u3 patches genesis.json with
# timestamp forks and does a rolling genesis reinit, then registers all 3
# validators with StakeHub (FORK_TIME_OFFSET defaults to 120s from now).

run bash "${SCRIPT_DIR}/82-run-u3-shanghai-feynman.sh"

# ── Done ──────────────────────────────────────────────────────────────────────

if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo
  echo "PASS. KEEP_RUNNING=1 — nodes remain running."
  echo "Logs: ${DATADIR_ROOT}/validator-{1,2,3}/geth.log"
  exit 0
fi

echo
echo "==> Stopping nodes"
stop_all

echo
echo "PASS"
