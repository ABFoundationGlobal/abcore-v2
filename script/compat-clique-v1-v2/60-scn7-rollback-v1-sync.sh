#!/usr/bin/env bash
set -euo pipefail

# Scenario 7: v1 syncing from a v2-majority network (rollback capability)
#
# Precondition: scenario 5 has run — all three validators are v2, peered,
#               and the network is live.
#
# Steps:
#   1. Start a fresh v1 node (new datadir, same genesis, no mining) and peer
#      it to the running v2 validators.
#   2. Assert it syncs to the canonical chain: block hash at the v2 head
#      matches the v2 reference.
#   3. Stop the fresh v1 node.
#
# NOTE: in-place downgrade (reusing a v2-written datadir with v1) is not
# possible because v2 upgrades the freezer table metadata to a v2 format
# (extra fields in the RLP) that v1 cannot decode.  In a real rollback an
# operator would provision a fresh node and let it sync — which is exactly
# what this scenario tests.
#
# This confirms that a v1 node can join and sync a chain that has been
# extended entirely by v2 validators — the critical property for safe
# rollback if an issue is found post-upgrade.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries
require_file "${GENESIS_JSON}"

# ── Setup fresh v1 node ──────────────────────────────────────────────────────

V1_ROLLBACK_DIR="${DATADIR_ROOT}/v1-rollback"
V1_ROLLBACK_IPC="${V1_ROLLBACK_DIR}/geth.ipc"
V1_ROLLBACK_PID="${V1_ROLLBACK_DIR}/geth.pid"
V1_ROLLBACK_LOG="${V1_ROLLBACK_DIR}/geth.log"

V1_ROLLBACK_PORT=$(rollback_p2p_port)
V1_ROLLBACK_AUTH=$(rollback_auth_port)

mkdir -p "$V1_ROLLBACK_DIR"

log "Initializing fresh v1 rollback datadir"
"$ABCORE_V1_GETH" init --datadir "$V1_ROLLBACK_DIR" "${GENESIS_JSON}" \
  >/dev/null 2>&1

# ── Record canonical head on v2 network before starting v1 node ──────────────

# Ensure all v2 validators agree on the same canonical chain before we sample it.
# With fast polling between scenarios, Clique out-of-turn blocks can leave a node
# on a transient fork; waiting for convergence here prevents a false hash mismatch.
log "Waiting for all v2 validators to agree on canonical head"
wait_for_same_head "$ABCORE_V2_GETH" "$(val_ipc 1)" 60 \
  "$ABCORE_V2_GETH" "$(val_ipc 2)" \
  "$ABCORE_V2_GETH" "$(val_ipc 3)"

# Use the minimum head across all validators: guaranteed to be on the canonical chain
# and present on every node, preventing a race where one node is 1 block ahead.
REF=1
T1=$(head_number "$ABCORE_V2_GETH" "$(val_ipc 1)")
T2=$(head_number "$ABCORE_V2_GETH" "$(val_ipc 2)")
T3=$(head_number "$ABCORE_V2_GETH" "$(val_ipc 3)")
TARGET=$T1
[[ "$T2" -lt "$TARGET" ]] && TARGET=$T2
[[ "$T3" -lt "$TARGET" ]] && TARGET=$T3
log "Current v2 canonical head: block ${TARGET}"

CANONICAL_HASH=$(block_hash_at "$ABCORE_V2_GETH" "$(val_ipc "$REF")" "$TARGET")
[[ -n "$CANONICAL_HASH" && "$CANONICAL_HASH" != "null" ]] \
  || die "could not read canonical hash at height ${TARGET} from validator-${REF}"
log "Canonical hash at block ${TARGET}: ${CANONICAL_HASH:0:14}…"

# ── Start fresh v1 node ───────────────────────────────────────────────────────

log "Starting fresh v1 rollback node (sync only, no mining)"
(
  cd "$REPO_ROOT"
  nohup "$ABCORE_V1_GETH" \
    --datadir "$V1_ROLLBACK_DIR" \
    --networkid "$CLIQUE_NETWORK_ID" \
    --port "$V1_ROLLBACK_PORT" \
    --authrpc.port "$V1_ROLLBACK_AUTH" \
    --nat none \
    --nodiscover \
    --bootnodes "" \
    --ipcpath geth.ipc \
    --syncmode full \
    --nousb \
    >>"$V1_ROLLBACK_LOG" 2>&1 &
  echo $! >"$V1_ROLLBACK_PID"
)

wait_for_ipc "$ABCORE_V1_GETH" "$V1_ROLLBACK_IPC"

# ── Peer to all three v2 validators ───────────────────────────────────────────

log "Peering v1 rollback node to v2 validators"
for peer in 1 2 3; do
  enode=$(get_enode "$ABCORE_V2_GETH" "$(val_ipc "$peer")" 2>/dev/null || true)
  [[ -n "$enode" ]] || continue
  add_peer "$ABCORE_V1_GETH" "$V1_ROLLBACK_IPC" "$enode" >/dev/null || true
done
wait_for_min_peers "$ABCORE_V1_GETH" "$V1_ROLLBACK_IPC" 1 60

# ── Sync assertion ────────────────────────────────────────────────────────────

log "Waiting for v1 rollback node to sync to block ${TARGET}"
wait_for_head_at_least "$ABCORE_V1_GETH" "$V1_ROLLBACK_IPC" "$TARGET" 120

log "Asserting v1 rollback node agrees on canonical hash at block ${TARGET}"
ROLLBACK_HASH=$(block_hash_at "$ABCORE_V1_GETH" "$V1_ROLLBACK_IPC" "$TARGET")
if [[ "$ROLLBACK_HASH" != "$CANONICAL_HASH" ]]; then
  die "block hash mismatch at height ${TARGET}: canonical=${CANONICAL_HASH} rollback=${ROLLBACK_HASH}"
fi
log "Hash match confirmed at block ${TARGET}: ${CANONICAL_HASH:0:14}…"

# Confirm the v2 network is still live while the v1 node is syncing.
wait_for_blocks "$ABCORE_V2_GETH" "$(val_ipc "$REF")" 2 30

# ── Cleanup ───────────────────────────────────────────────────────────────────

log "Stopping v1 rollback node"
stop_pidfile "$V1_ROLLBACK_PID"

log "Scenario 7 OK: fresh v1 node synced the v2-produced chain successfully"
