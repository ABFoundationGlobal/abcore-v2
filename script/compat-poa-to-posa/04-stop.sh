#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Collect all candidate pidfiles.
_all_pidfiles=()
for n in 1 2 3; do
  _all_pidfiles+=("$(val_dir "$n")/geth.pid")
done

# 1. Send SIGTERM to all running processes simultaneously.
_live_pids=()
_live_pidfiles=()
for pidfile in "${_all_pidfiles[@]}"; do
  [[ -f "$pidfile" ]] || continue
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    log "Stopping pid ${pid} (${pidfile})"
    kill "$pid" 2>/dev/null || true
    _live_pids+=("$pid")
    _live_pidfiles+=("$pidfile")
  else
    rm -f "$pidfile"
  fi
done

# 2. Wait for all processes to exit with a shared 30-second deadline, then SIGKILL stragglers.
if [[ ${#_live_pids[@]} -gt 0 ]]; then
  deadline=$(( $(date +%s) + 30 ))
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

log "Stopped."

# Release the port-base reservation created by find_free_port_base (if any).
rmdir "/tmp/compat-poa-posa-reserved-${PORT_BASE}" 2>/dev/null || true
