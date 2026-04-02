#!/usr/bin/env bash
# Stops all running validators.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

_live_pids=()
_live_pidfiles=()
shopt -s nullglob
for pidfile in "${DATADIR_ROOT}"/validator-*/geth.pid; do
  validator_name=$(basename "$(dirname "$pidfile")")
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    log "Stopping ${validator_name} (pid=${pid})"
    kill "$pid" 2>/dev/null || true
    _live_pids+=("$pid")
    _live_pidfiles+=("$pidfile")
  else
    rm -f "$pidfile"
  fi
done
shopt -u nullglob

if [[ ${#_live_pids[@]} -gt 0 ]]; then
  local_deadline=$(( $(date +%s) + 30 ))
  for pid in "${_live_pids[@]}"; do
    while kill -0 "$pid" 2>/dev/null && [[ $(date +%s) -lt $local_deadline ]]; do
      sleep 0.3
    done
    kill -9 "$pid" 2>/dev/null || true
  done
  for pf in "${_live_pidfiles[@]}"; do rm -f "$pf"; done
fi

log "All validators stopped."
rmdir "/tmp/transition-test-reserved-${PORT_BASE}" 2>/dev/null || true
