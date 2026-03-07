#!/usr/bin/env bash
set -euo pipefail

# Scenario 7: v1 syncing from a v2-majority network (rollback capability)
#
# Precondition: scenario 5 has run — all three validators are v2, peered,
#               and the network is live.
#
# Steps:
#   1. Stop one v2 validator (default: UPGRADE_VALIDATOR_N, same one upgraded
#      in Scenario 1 — the most natural rollback candidate).
#   2. Record the canonical head at the time of shutdown.
#   3. Restart the same node using the v1 binary (same datadir, same flags).
#   4. Re-peer it to the two remaining v2 validators.
#   5. Assert it syncs to the canonical chain (same block hash at the recorded
#      height) and that the network continues producing new blocks.
#   6. Confirm the reverted node seals at least one block, proving the v2
#      chain is accepted as canonical by v1 and Clique governance is intact.
#
# This tests rollback capability: whether an operator can safely revert a
# single node from v2 back to v1 if a post-upgrade issue is found.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

N=${UPGRADE_VALIDATOR_N:-2}
[[ "$N" -ge 1 && "$N" -le 3 ]] || die "UPGRADE_VALIDATOR_N must be 1..3"

pidfile=$(val_pid "$N")
[[ -f "$pidfile" ]] || die "validator-${N} not running (missing pidfile ${pidfile}); Scenario 5 must have completed"

# ── Shutdown ─────────────────────────────────────────────────────────────────

# Pick the other two validators as REF (primary reference) and OTHER.
# REF is used for head polling; both are used in the final convergence assertion.
if [[ "$N" -eq 1 ]]; then
  REF=2; OTHER=3
elif [[ "$N" -eq 2 ]]; then
  REF=1; OTHER=3
else
  REF=1; OTHER=2
fi

# Record canonical head before stopping target so we have a reference height.
SNAP=$(head_number "$ABCORE_V2_GETH" "$(val_ipc "$N")")
log "Canonical head before shutdown of validator-${N}: ${SNAP}"

log "Stopping v2 validator-${N}"
stop_pidfile "$pidfile"

# Let the remaining two v2 validators advance a few blocks while validator-N
# is down. This ensures the node actually has to sync forward when it comes
# back, not just verify its local chain.
TARGET=$((SNAP + 3))
log "Waiting for majority to advance to block ${TARGET}"
wait_for_head_at_least "$ABCORE_V2_GETH" "$(val_ipc "$REF")" "$TARGET" 60

# Record the canonical hash at TARGET from the reference node for later assertion.
CANONICAL_HASH=$(block_hash_at "$ABCORE_V2_GETH" "$(val_ipc "$REF")" "$TARGET")
[[ -n "$CANONICAL_HASH" && "$CANONICAL_HASH" != "null" ]] \
  || die "could not read canonical hash at height ${TARGET} from validator-${REF}"
log "Canonical hash at block ${TARGET}: ${CANONICAL_HASH:0:14}…"

# ── Restart with v1 binary ────────────────────────────────────────────────────

addr=$(val_addr "$N")
pwfile=$(val_pw "$N")
p2p=$(p2p_port "$N")
logfile=$(val_log "$N")
dir=$(val_dir "$N")

log "Starting validator-${N} with v1 binary (same datadir)"
(
  cd "$REPO_ROOT"
  nohup "$ABCORE_V1_GETH" \
    --datadir "$dir" \
    --networkid "$CLIQUE_NETWORK_ID" \
    --port "$p2p" \
    --nat none \
    --nodiscover \
    --bootnodes "" \
    --ipcpath geth.ipc \
    --syncmode full \
    --mine \
    --miner.etherbase "$addr" \
    --unlock "$addr" \
    --password "$pwfile" \
    --nousb \
    >>"$logfile" 2>&1 &
  echo $! >"$pidfile"
)

wait_for_ipc "$ABCORE_V1_GETH" "$(val_ipc "$N")"

# ── Peering ───────────────────────────────────────────────────────────────────

log "Peering reverted validator-${N} (v1) to the two v2 validators"
for peer in 1 2 3; do
  [[ "$peer" -eq "$N" ]] && continue
  enode=$(get_enode "$ABCORE_V2_GETH" "$(val_ipc "$peer")" 2>/dev/null || true)
  [[ -n "$enode" ]] || continue
  add_peer "$ABCORE_V1_GETH" "$(val_ipc "$N")" "$enode" >/dev/null || true
done
wait_for_min_peers "$ABCORE_V1_GETH" "$(val_ipc "$N")" 1 60

# ── Sync assertion ───────────────────────────────────────────────────────────

log "Waiting for reverted validator-${N} to sync to block ${TARGET}"
wait_for_head_at_least "$ABCORE_V1_GETH" "$(val_ipc "$N")" "$TARGET" 120

log "Asserting reverted validator-${N} agrees on canonical hash at block ${TARGET}"
REVERTED_HASH=$(block_hash_at "$ABCORE_V1_GETH" "$(val_ipc "$N")" "$TARGET")
if [[ "$REVERTED_HASH" != "$CANONICAL_HASH" ]]; then
  die "block hash mismatch at height ${TARGET}: canonical=${CANONICAL_HASH} reverted=${REVERTED_HASH}"
fi
log "Hash match confirmed at block ${TARGET}: ${CANONICAL_HASH:0:14}…"

# Broader head convergence across all three nodes.
log "Asserting all three validators converge on the same head"
wait_for_same_head "$ABCORE_V2_GETH" "$(val_ipc "$REF")" 120 \
  "$ABCORE_V1_GETH" "$(val_ipc "$N")" \
  "$ABCORE_V2_GETH" "$(val_ipc "$OTHER")"

# ── Sealing assertion ─────────────────────────────────────────────────────────

# Confirm the reverted v1 node resumes sealing blocks, proving the v2-produced
# chain is accepted by v1 as the canonical Clique chain and that governance
# (round-robin sealing rights) continues to function after the rollback.
log "Waiting for reverted validator-${N} to seal a block (v1 sealing on v2 chain)"
wait_for_block_miner "$ABCORE_V1_GETH" "$(val_ipc "$N")" "$(val_addr "$N")" 16 120

# Confirm the network is still live after the rollback.
wait_for_blocks "$ABCORE_V1_GETH" "$(val_ipc "$N")" 2 30

log "Scenario 7 OK: v1 node synced and sealed on a v2-produced chain"
