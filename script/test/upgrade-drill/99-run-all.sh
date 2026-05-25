#!/usr/bin/env bash
# One-shot upgrade drill: init → U-1 (Clique→Parlia) → U-2 (London + BSC forks)
#                              → U-3 (Shanghai + Kepler + Feynman)
#                              → T-6 ~ T-13 (system-contract scenario tests)
#                              → U-4 (Cancun + Haber + HaberFix)
#                              → U-5 (Bohr: variable TurnLength)
#                              → U-6 (Prague + Pascal + Lorentz + Maxwell)
#                              → U-7 (Fermi + Osaka + Mendel).
#
# Mirrors the structure of transition-test/99-run-all.sh.
# Each round leaves nodes running so the next round can read the current chain
# head — no snapshot step is needed in the automated path.
#
# T-6 ~ T-13 run against the 3-node network left up by U-3 (all Feynman system
# contracts deployed and initialised).  They are inserted before U-4 so that
# contract state is exercised on a freshly-initialised Feynman chain.
#
# Known side-effects of T-tests on subsequent upgrade rounds:
#   T-13.a removeFromValidatorWhitelist(val1): val1 was already removed by
#          T-6.i (in 88); the governance execute is idempotent (no revert) and
#          the verify check validatorWhitelist(val1)==false still passes.
#
# Usage:
#   bash script/test/upgrade-drill/99-run-all.sh
#   GETH=./build/bin/geth bash script/test/upgrade-drill/99-run-all.sh
#   PARLIA_GENESIS_BLOCK=50 GETH=./build/bin/geth bash script/test/upgrade-drill/99-run-all.sh
#
# Environment:
#   GETH                  geth binary path (auto-built if unset)
#   PARLIA_GENESIS_BLOCK  U-1 Clique→Parlia fork block height (default: 30)
#   LONDON_BLOCK          U-2 London fork block height (default: U-1 head + 60)
#   FORK_TIME_OFFSET      U-3 seconds from now to Shanghai/Feynman activation (default: 120)
#   SKIP_CONTRACT_TESTS=1 skip T-6~T-13 scenario tests (run upgrade rounds only)
#   KEEP_RUNNING=1        leave nodes running after PASS (for manual inspection)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ── Build geth if no explicit path provided ───────────────────────────────────

if [[ -z "${GETH:-}" ]]; then
  _REPO_ROOT=$(cd "${SCRIPT_DIR}/../../.." && pwd)
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
# SKIP_WHITELIST_TESTS=1 prevents 82 from running T-6 tests inline; they are
# executed as an explicit separate block below (T-6 ~ T-13).

export SKIP_WHITELIST_TESTS=1
run bash "${SCRIPT_DIR}/82-run-u3-shanghai-feynman.sh"
unset SKIP_WHITELIST_TESTS

# ── T-6 ~ T-13: system-contract scenario tests ───────────────────────────────
# Nodes remain running from U-3.  Tests are grouped by contract area; each
# script leaves the chain running for the next.  Skipped when SKIP_CONTRACT_TESTS=1.

if [[ "${SKIP_CONTRACT_TESTS:-0}" -ne 1 ]]; then
  # T-6 whitelist (read-only stateDiff phases)
  run bash "${SCRIPT_DIR}/87-run-u3-whitelist-test.sh"

  # T-6.h/i/j whitelist governance (state-mutating: removes val1 from whitelist,
  # toggles whitelistEnabled off/on)
  run bash "${SCRIPT_DIR}/88-run-u3-governance-whitelist.sh"

  # T-7 StakeHub lifecycle edits (state-mutating: editCommissionRate,
  # editDescription, editConsensusAddress, addNodeIDs/removeNodeIDs)
  run bash "${SCRIPT_DIR}/89-run-t7-stakehub-lifecycle.sh"

  # T-8 delegation lifecycle (state-mutating: delegate, undelegate, redelegate;
  # T-8.d uses stateDiff for claim dry-run)
  run bash "${SCRIPT_DIR}/90-run-t8-delegation-lifecycle.sh"

  # T-9 GovToken history and transfer restrictions (read-only + block waits)
  run bash "${SCRIPT_DIR}/91-run-t9-govtoken.sh"

  # T-10 Governor extended scenarios (governance: castVoteWithReason, cancel,
  # Defeated state, votingPeriod param change)
  run bash "${SCRIPT_DIR}/92-run-t10-governor-extended.sh"

  # T-11 BSCValidatorSet queries + maxNumOfWorkingCandidates governance
  run bash "${SCRIPT_DIR}/93-run-t11-validatorset-queries.sh"

  # T-12 SlashIndicator read-path + stateDiff + felonyThreshold governance
  run bash "${SCRIPT_DIR}/94-run-t12-slash-indicator.sh"

  # T-13 governance param matrix (6 independent proposals across 4 contracts)
  run bash "${SCRIPT_DIR}/95-run-t13-governance-param-matrix.sh"
else
  log "run-all: SKIP_CONTRACT_TESTS=1 — skipping T-6~T-13"
fi

# ── U-4: Cancun + Haber + HaberFix ───────────────────────────────────────────
# Nodes are still running from T-tests (or U-3 if tests skipped); 83-run-u4
# patches genesis.json with cancunTime/haberTime/haberFixTime and does a rolling
# genesis reinit.

run bash "${SCRIPT_DIR}/83-run-u4-cancun-haber.sh"

# ── U-5: Bohr ─────────────────────────────────────────────────────────────────
# Nodes are still running from U-4; 84-run-u5 patches genesis.json with
# bohrTime and does a rolling genesis reinit.

run bash "${SCRIPT_DIR}/84-run-u5-bohr.sh"

# ── U-6: Prague + Pascal + Lorentz + Maxwell ──────────────────────────────────
# Nodes are still running from U-5; 85-run-u6 patches genesis.json with
# pascalTime/pragueTime/lorentzTime/maxwellTime + blobSchedule.prague and does
# a rolling genesis reinit.  Three activation phases separated by 3 minutes each.

run bash "${SCRIPT_DIR}/85-run-u6-prague-maxwell.sh"

# ── U-7: Fermi + Osaka + Mendel ───────────────────────────────────────────────
# Nodes are still running from U-6; 86-run-u7 patches genesis.json with
# fermiTime/osakaTime/mendelTime and does a rolling genesis reinit.
# Two activation phases: Fermi alone, then Osaka+Mendel together 3 minutes later.

run bash "${SCRIPT_DIR}/86-run-u7-fermi-osaka-mendel.sh"

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
