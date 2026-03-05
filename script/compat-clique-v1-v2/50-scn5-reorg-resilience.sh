#!/usr/bin/env bash
set -euo pipefail

# Scenario 5: re-org resilience
#
# Precondition: scenario 4 has run — all three validators are v2 and peered.
#
# Steps:
#   1. Isolate validator-1 by removing it as a peer from validators 2 and 3.
#   2. Let the majority fork (val-2 + val-3, 2-of-3 signers) advance 4+ blocks.
#   3. Reconnect validator-1 to the network.
#   4. Assert validator-1 reorgs to the majority chain (same block hash at H+4).
#   5. Confirm the network is still live post-reorg.
#
# This tests that Clique's highest-difficulty fork selection works identically
# on v2 nodes, which is the critical property for a safe rolling upgrade.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

# ── Isolation ────────────────────────────────────────────────────────────────

# Record the common head before the split.
H=$(head_number "$ABCORE_V2_GETH" "$(val_ipc 1)")
log "Common head before partition: ${H}"

# Collect enodes.
ENODE1=$(get_enode "$ABCORE_V2_GETH" "$(val_ipc 1)")
ENODE2=$(get_enode "$ABCORE_V2_GETH" "$(val_ipc 2)")
ENODE3=$(get_enode "$ABCORE_V2_GETH" "$(val_ipc 3)")

log "Isolating validator-1 from validators 2 and 3"
remove_peer "$ABCORE_V2_GETH" "$(val_ipc 2)" "$ENODE1" >/dev/null || true
remove_peer "$ABCORE_V2_GETH" "$(val_ipc 3)" "$ENODE1" >/dev/null || true
remove_peer "$ABCORE_V2_GETH" "$(val_ipc 1)" "$ENODE2" >/dev/null || true
remove_peer "$ABCORE_V2_GETH" "$(val_ipc 1)" "$ENODE3" >/dev/null || true

# Wait for validator-1 to have no peers (true isolation).
log "Waiting for validator-1 peer count to reach 0"
for ((i=0; i<30; i++)); do
  pc=$(peer_count "$ABCORE_V2_GETH" "$(val_ipc 1)" 2>/dev/null || echo 0)
  if [[ "$pc" -eq 0 ]]; then
    log "validator-1 isolated (peer_count=0)"
    break
  fi
  sleep 1
done
pc=$(peer_count "$ABCORE_V2_GETH" "$(val_ipc 1)" 2>/dev/null || echo 0)
[[ "$pc" -eq 0 ]] || die "validator-1 still has peers after isolation attempt (peer_count=${pc})"

# ── Diverge ───────────────────────────────────────────────────────────────────

# Let the majority fork (val-2 + val-3) advance 4 blocks past H.
# 2-of-3 signers is above the Clique majority threshold so they continue sealing.
TARGET=$((H + 4))
log "Waiting for majority fork to reach block ${TARGET}"
wait_for_head_at_least "$ABCORE_V2_GETH" "$(val_ipc 2)" "$TARGET" 60

MAJORITY_HEAD=$(head_number "$ABCORE_V2_GETH" "$(val_ipc 2)")
ISOLATED_HEAD=$(head_number "$ABCORE_V2_GETH" "$(val_ipc 1)" 2>/dev/null || echo "?")
log "Majority fork head: ${MAJORITY_HEAD}, isolated val-1 head: ${ISOLATED_HEAD}"

# ── Reconnect ─────────────────────────────────────────────────────────────────

log "Reconnecting validator-1 to validator-2"
add_peer "$ABCORE_V2_GETH" "$(val_ipc 1)" "$ENODE2" >/dev/null || true
wait_for_min_peers "$ABCORE_V2_GETH" "$(val_ipc 1)" 1 30

# ── Assert convergence ────────────────────────────────────────────────────────

log "Waiting for validator-1 to sync to majority head (block ${TARGET})"
wait_for_head_at_least "$ABCORE_V2_GETH" "$(val_ipc 1)" "$TARGET" 120

log "Asserting all validators agree on block hash at height ${TARGET}"
assert_same_hash_at "$TARGET" \
  "$ABCORE_V2_GETH" "$(val_ipc 1)" \
  "$ABCORE_V2_GETH" "$(val_ipc 2)" \
  "$ABCORE_V2_GETH" "$(val_ipc 3)"

# Re-peer val-1 to val-3 for the rest of the suite.
add_peer "$ABCORE_V2_GETH" "$(val_ipc 1)" "$ENODE3" >/dev/null || true

# Confirm chain is still live after the reorg.
wait_for_blocks "$ABCORE_V2_GETH" "$(val_ipc 1)" 2 30

log "Scenario 5 OK"
