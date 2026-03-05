#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Auto-select a free PORT_BASE if not explicitly set, then derive DATADIR_ROOT.
if [[ -z "${PORT_BASE:-}" ]]; then
  PORT_BASE=$(find_free_port_base)
  echo "[$(date +'%H:%M:%S')] Auto-selected PORT_BASE=${PORT_BASE}"
fi
export PORT_BASE
export DATADIR_ROOT="${DATADIR_ROOT:-${SCRIPT_DIR}/data-${PORT_BASE}}"

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
run "${SCRIPT_DIR}/40-scn4-all-validators-v2.sh"
run "${SCRIPT_DIR}/50-scn5-reorg-resilience.sh"

if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo
  echo "PASS. KEEP_RUNNING=1 so nodes remain running."
  exit 0
fi

echo
echo "PASS. Stopping nodes."
"${SCRIPT_DIR}/04-stop.sh"
