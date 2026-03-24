#!/usr/bin/env bash
set -euo pipefail

# Stops all nodes from both scenarios.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

log "Stopping all no-genesis-v2 nodes..."

# Each function re-evaluates DATADIR_ROOT at call time, so the pidfile paths
# are always correct even if PORT_BASE was updated after lib.sh was sourced.
stop_pidfile "$(scn1_v1_pid)"
stop_pidfile "$(scn1_v2_pid)"
stop_pidfile "$(scn2_v1_pid)"
stop_pidfile "$(scn2_v2_pid)"

# Release the port reservation created by find_free_port_base.
rmdir "/tmp/compat-clique-reserved-${PORT_BASE}" 2>/dev/null || true

log "All nodes stopped."
