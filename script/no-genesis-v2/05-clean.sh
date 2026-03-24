#!/usr/bin/env bash
set -euo pipefail

# Removes all test data for the no-genesis-v2 suite.
# Runs 04-stop.sh first to ensure no processes hold file locks.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

"${SCRIPT_DIR}/04-stop.sh" 2>/dev/null || true

if [[ -d "${DATADIR_ROOT}" ]]; then
  log "Removing ${DATADIR_ROOT}"
  rm -rf "${DATADIR_ROOT}"
fi

log "Clean complete."
