#!/usr/bin/env bash
# Stops running validators and removes all generated data.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

"${SCRIPT_DIR}/03-stop.sh" || true

if [[ -d "${DATADIR_ROOT}" ]]; then
  log "Removing ${DATADIR_ROOT}"
  rm -rf "${DATADIR_ROOT}"
fi

if [[ -f "${GENESIS_JSON}" ]]; then
  log "Removing ${GENESIS_JSON}"
  rm -f "${GENESIS_JSON}"
fi

log "Clean complete."
