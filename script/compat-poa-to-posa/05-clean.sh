#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

log "Stopping processes"
"${SCRIPT_DIR}/04-stop.sh" || true

log "Removing data directories and generated configs"
rm -rf "${DATADIR_ROOT}"
rm -f "${GENESIS_CLIQUE_JSON}" "${GENESIS_POSA_JSON}"
rm -f "${SCRIPT_DIR}/config/node-"*.toml
rm -f "${SCRIPT_DIR}/fork-times.env"

log "Clean complete."
