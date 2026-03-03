#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

for n in 1 2 3 4; do
  pidfile="$(val_dir "$n")/geth.pid"
  if [[ -f "$pidfile" ]]; then
    log "Stopping node ${n} (pidfile=${pidfile})"
    stop_pidfile "$pidfile"
  fi

done

# rpc node pidfile (if started)
if [[ -f "${DATADIR_ROOT}/rpc-v2-1/geth.pid" ]]; then
  log "Stopping rpc-v2-1"
  stop_pidfile "${DATADIR_ROOT}/rpc-v2-1/geth.pid"
fi

log "Stopped."