#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Capture whether PORT_BASE / DATADIR_ROOT were explicitly set by the caller
# before lib.sh applies its defaults.
_PORT_BASE_EXPLICIT=${PORT_BASE+set}
_DATADIR_ROOT_EXPLICIT=${DATADIR_ROOT+set}

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# ---- Suite-specific port-availability helpers --------------------------------

# Check whether a TCP port is currently listening on localhost.
# Returns 0 if the port is in use (LISTEN), 1 if it appears free.
is_port_listening() {
  local port=$1

  if ss -tunlp 2>/dev/null | grep -q ":${port}[[:space:]]"; then
    return 0
  fi
  if nc -z 127.0.0.1 "$port" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Returns 0 if all no-genesis-v2 suite ports for a given base are free.
# Ports checked: 30410+base … 30413+base (scn1/scn2 p2p ports from lib.sh).
no_genesis_v2_ports_available() {
  local base=$1
  local offset port

  # Offsets 0–3 correspond to scn1-v1, scn1-v2, scn2-v1, scn2-v2 p2p ports
  # (30410+base through 30413+base) defined in lib.sh.
  for offset in 0 1 2 3; do
    port=$((30410 + base + offset))
    if is_port_listening "${port}"; then
      return 1
    fi
  done

  return 0
}

# Find a PORT_BASE that is safe for this no-genesis-v2 suite.
# Uses find_free_port_base (from compat lib) as a first candidate, then
# additionally verifies the no-genesis-v2 suite ports (30410–30413 + base)
# are conflict-free before committing to that base.
find_no_genesis_v2_port_base() {
  local candidate base

  candidate=$(find_free_port_base)
  if no_genesis_v2_ports_available "${candidate}"; then
    echo "${candidate}"
    return 0
  fi

  # The candidate's no-genesis ports are busy; release its sentinel and search
  # for a base where the no-genesis-v2 suite ports are also conflict-free.
  rmdir "/tmp/compat-clique-reserved-${candidate}" 2>/dev/null || true

  # Walk the same 100-step search space as find_free_port_base (0, 100, …, 9900)
  # so port ranges for different parallel runs stay well separated.
  for base in $(seq 0 100 9900); do
    [[ "${base}" -eq "${candidate}" ]] && continue
    if no_genesis_v2_ports_available "${base}"; then
      if mkdir "/tmp/compat-clique-reserved-${base}" 2>/dev/null; then
        echo "${base}"
        return 0
      fi
    fi
  done

  echo "[$(date +'%H:%M:%S')] ERROR: could not find a conflict-free PORT_BASE for no-genesis-v2 suite." >&2
  exit 1
}

# Auto-select a free PORT_BASE if the caller did not provide one explicitly.
if [[ "${_PORT_BASE_EXPLICIT}" != "set" ]]; then
  PORT_BASE=$(find_no_genesis_v2_port_base)
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

# Re-create the PORT_BASE reservation sentinel removed by 05-clean.sh/04-stop.sh
# so that this run keeps its reserved port range for its full duration.
mkdir "/tmp/compat-clique-reserved-${PORT_BASE}" 2>/dev/null || true

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
