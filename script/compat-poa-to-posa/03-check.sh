#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

for n in 1 2 3; do
  ipc=$(val_ipc "$n")
  if [[ -S "$ipc" ]]; then
    bn=$(head_number "${ABCORE_V2_GETH}" "$ipc" || true)
    hh=$(head_hash  "${ABCORE_V2_GETH}" "$ipc" || true)
    pc=$(peer_count "${ABCORE_V2_GETH}" "$ipc" || true)
    log "validator-${n}: block=${bn} peers=${pc} head=${hh}"
  else
    log "validator-${n}: IPC missing (${ipc})"
  fi
done
