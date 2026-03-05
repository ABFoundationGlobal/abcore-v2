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

# Collect enodes before the partition.
ENODE1=$(get_enode "$ABCORE_V2_GETH" "$(val_ipc 1)")
ENODE2=$(get_enode "$ABCORE_V2_GETH" "$(val_ipc 2)")
ENODE3=$(get_enode "$ABCORE_V2_GETH" "$(val_ipc 3)")

# Ensure val-2 and val-3 have a direct connection before we cut val-1 out.
# Scn4 only guarantees >=1 peer per node; without this, val-2 and val-3 might
# only know each other via val-1 and the "majority" would be isolated too.
log "Ensuring direct val-2 ↔ val-3 peering before partition"
add_peer "$ABCORE_V2_GETH" "$(val_ipc 2)" "$ENODE3" >/dev/null || true
add_peer "$ABCORE_V2_GETH" "$(val_ipc 3)" "$ENODE2" >/dev/null || true

# Explicitly assert that val-2 sees val-3 and val-3 sees val-2 in admin.peers.
# wait_for_min_peers alone is insufficient — a count >=1 can be satisfied by
# the val-1 connection, leaving the "majority" isolated once val-1 is removed.
ENODE3_ID=${ENODE3%%@*}
ENODE2_ID=${ENODE2%%@*}
log "Verifying val-2 is directly peered with val-3"
connected=false
for ((i=0; i<30; i++)); do
  peers_output=$("$ABCORE_V2_GETH" attach "$(val_ipc 2)" --exec 'admin.peers' 2>/dev/null || echo "")
  if grep -q "$ENODE3_ID" <<<"$peers_output"; then
    connected=true
    log "val-2 reports direct peer val-3"
    break
  fi
  sleep 1
done
[[ "$connected" == true ]] || die "val-2 does not list val-3 as a direct peer after 30s"

log "Verifying val-3 is directly peered with val-2"
connected=false
for ((i=0; i<30; i++)); do
  peers_output=$("$ABCORE_V2_GETH" attach "$(val_ipc 3)" --exec 'admin.peers' 2>/dev/null || echo "")
  if grep -q "$ENODE2_ID" <<<"$peers_output"; then
    connected=true
    log "val-3 reports direct peer val-2"
    break
  fi
  sleep 1
done
[[ "$connected" == true ]] || die "val-3 does not list val-2 as a direct peer after 30s"

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

# Record the fork base height AFTER isolation is confirmed.  Sampling before
# the partition means blocks sealed during setup can make TARGET reachable
# before the split, weakening the reorg assertion.
H=$(head_number "$ABCORE_V2_GETH" "$(val_ipc 1)")
log "Fork base (post-isolation head of validator-1): ${H}"

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
