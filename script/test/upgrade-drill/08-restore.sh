#!/usr/bin/env bash
# Restore the 3-node network from a snapshot archive.
#
# Stops all running validators, removes the current DATADIR_ROOT, then extracts
# the specified snapshot.  Leaves nodes stopped; run the appropriate upgrade
# round script to restart.
#
# Usage:
#   SNAPSHOT=<path/to/snapshot-*.tar.gz> bash 08-restore.sh
#
# Environment:
#   SNAPSHOT       (required) path to the .tar.gz archive to restore
#   DATADIR_ROOT   node data root (default: <script-dir>/data)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

# ── Validate inputs ───────────────────────────────────────────────────────────

[[ -n "${SNAPSHOT:-}" ]] || die "SNAPSHOT is not set.
Usage: SNAPSHOT=<path/to/snapshot-*.tar.gz> bash 08-restore.sh"

require_file "${SNAPSHOT}"

# Guard against restoring into an unrelated directory by verifying the archive
# contains a path that looks like the expected DATADIR_ROOT basename.
DATADIR_BASENAME=$(basename "${DATADIR_ROOT}")
if ! tar tzf "${SNAPSHOT}" 2>/dev/null | grep -q "^${DATADIR_BASENAME}/"; then
  die "Snapshot does not contain '${DATADIR_BASENAME}/' — wrong archive or wrong DATADIR_ROOT?
  Snapshot: ${SNAPSHOT}
  DATADIR_ROOT: ${DATADIR_ROOT}"
fi

# ── Stop nodes ────────────────────────────────────────────────────────────────

log "Stopping all validators before restore..."
stop_all

# ── Restore ───────────────────────────────────────────────────────────────────

PARENT=$(dirname "${DATADIR_ROOT}")

if [[ -d "${DATADIR_ROOT}" ]]; then
  log "Removing current DATADIR_ROOT: ${DATADIR_ROOT}"
  rm -rf "${DATADIR_ROOT}"
fi

log "Restoring from: ${SNAPSHOT}"
tar xzf "${SNAPSHOT}" -C "${PARENT}"

log "Restore complete: ${DATADIR_ROOT}"
log "Nodes are stopped. Run the appropriate upgrade round script to restart."
