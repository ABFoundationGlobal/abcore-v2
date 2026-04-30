#!/usr/bin/env bash
# Full snapshot of the 3-node network state.
#
# Stops all running validators, archives DATADIR_ROOT to a timestamped tar.gz
# in SNAPSHOT_DIR, then exits leaving nodes stopped.  The calling upgrade round
# script is responsible for restarting nodes after the snapshot.
#
# Environment:
#   DATADIR_ROOT   node data root (default: <script-dir>/data)
#   SNAPSHOT_DIR   destination directory for archives (default: <script-dir>/snapshots)
#
# Output: prints the absolute path of the created snapshot archive.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

[[ -d "${DATADIR_ROOT}" ]] || die "DATADIR_ROOT not found: ${DATADIR_ROOT} — run 00-init.sh first"

# ── Stop nodes ────────────────────────────────────────────────────────────────

log "Stopping all validators before snapshot..."
stop_all

# ── Create snapshot ───────────────────────────────────────────────────────────

mkdir -p "${SNAPSHOT_DIR}"

TIMESTAMP=$(date +'%Y%m%d-%H%M%S')
ARCHIVE="${SNAPSHOT_DIR}/snapshot-${TIMESTAMP}.tar.gz"

log "Creating snapshot: ${ARCHIVE}"
log "Source: ${DATADIR_ROOT}"

# Exclude ephemeral runtime files that will be recreated on next start.
tar czf "${ARCHIVE}" \
  --exclude='*/geth.pid' \
  --exclude='*/geth.ipc' \
  -C "$(dirname "${DATADIR_ROOT}")" \
  "$(basename "${DATADIR_ROOT}")"

SIZE=$(du -sh "${ARCHIVE}" | cut -f1)
log "Snapshot complete: ${ARCHIVE} (${SIZE})"
log "Nodes are stopped. Run the next upgrade round script to restart."

echo "${ARCHIVE}"
