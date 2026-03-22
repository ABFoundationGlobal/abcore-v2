#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Capture whether PORT_BASE / DATADIR_ROOT were explicitly set by the caller
# before lib.sh applies its defaults.
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
run "${SCRIPT_DIR}/10-scn1-v2-no-genesis-startup.sh"
run "${SCRIPT_DIR}/20-scn2-v2-clique-sealing.sh"

if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo
  echo "PASS. KEEP_RUNNING=1 so nodes remain running."
  exit 0
fi

echo
echo "PASS. Stopping nodes."
"${SCRIPT_DIR}/04-stop.sh"
