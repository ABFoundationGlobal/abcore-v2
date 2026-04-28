#!/usr/bin/env bash
# Stop all validators and remove all generated data (DATADIR_ROOT).
# Snapshots in SNAPSHOT_DIR are NOT removed.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

stop_all 2>/dev/null || true

if [[ -d "${DATADIR_ROOT}" ]]; then
  log "Removing ${DATADIR_ROOT}"
  rm -rf "${DATADIR_ROOT}"
fi

log "Clean complete. Snapshots in ${SNAPSHOT_DIR} are preserved."
