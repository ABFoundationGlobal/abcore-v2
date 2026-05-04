#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

log "Stopping processes"
"${SCRIPT_DIR}/04-stop.sh" || true

log "Removing data + genesis"
rm -rf "${DATADIR_ROOT}"
rm -f "${GENESIS_JSON}"

log "Clean complete."