#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Capture whether PORT_BASE was explicitly set by the caller before lib.sh applies its
# default of 0. We do this before sourcing lib.sh so we can tell the difference between
# "caller set PORT_BASE=0" and "lib.sh defaulted it to 0".
_PORT_BASE_EXPLICIT=${PORT_BASE+set}
_DATADIR_ROOT_EXPLICIT=${DATADIR_ROOT+set}

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Auto-select a free PORT_BASE if the caller did not provide one explicitly.
if [[ "${_PORT_BASE_EXPLICIT}" != "set" ]]; then
  PORT_BASE=$(find_free_port_base)
  echo "[$(date +'%H:%M:%S')] Auto-selected PORT_BASE=${PORT_BASE}"
fi
export PORT_BASE
# Re-derive DATADIR_ROOT from the final PORT_BASE unless the caller explicitly provided
# one. We cannot use ${DATADIR_ROOT:-...} here because lib.sh already set DATADIR_ROOT
# to data-0 before find_free_port_base had a chance to update PORT_BASE.
if [[ "${_DATADIR_ROOT_EXPLICIT:-}" != "set" ]]; then
  export DATADIR_ROOT="${SCRIPT_DIR}/data-${PORT_BASE}"
fi

run() {
  echo
  echo "==> $*"
  "$@"
}

cleanup_on_exit() {
  local code=$?
  if [[ "$code" -ne 0 ]]; then
    echo
    if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
      echo "FAILED (exit=${code}). KEEP_RUNNING=1 so nodes remain running (logs under ${DATADIR_ROOT})." >&2
    else
      echo "FAILED (exit=${code}). Stopping nodes (logs preserved under ${DATADIR_ROOT})." >&2
      "${SCRIPT_DIR}/04-stop.sh" || true
    fi
  fi
  exit "$code"
}
trap cleanup_on_exit EXIT

run "${SCRIPT_DIR}/05-clean.sh"
run "${SCRIPT_DIR}/01-setup.sh"
run "${SCRIPT_DIR}/02-start-v1-validators.sh"
run "${SCRIPT_DIR}/10-scn1-upgrade-validator.sh"
run "${SCRIPT_DIR}/20-scn2-add-v2-rpc-node.sh"
run "${SCRIPT_DIR}/30-scn3-add-v2-validator-vote.sh"
# scn6 runs here (before scn4) because it requires a mixed v1/v2 environment;
# after scn4 all validators are v2 and cross-version propagation cannot be tested.
run "${SCRIPT_DIR}/35-scn6-tx-propagation.sh"
run "${SCRIPT_DIR}/40-scn4-all-validators-v2.sh"
run "${SCRIPT_DIR}/50-scn5-reorg-resilience.sh"
run "${SCRIPT_DIR}/60-scn7-rollback-v1-sync.sh"
run "${SCRIPT_DIR}/80-scn8-epoch-boundary.sh"
run "${SCRIPT_DIR}/70-scn9-rpc-parity.sh"

if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo
  echo "PASS. KEEP_RUNNING=1 so nodes remain running."
  exit 0
fi

echo
echo "PASS. Stopping nodes."
"${SCRIPT_DIR}/04-stop.sh"
