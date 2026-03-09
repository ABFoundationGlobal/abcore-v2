#!/usr/bin/env bash
set -euo pipefail

# Scenario 4:
# - upgrade the remaining v1 validators to v2 with a coordinated stop/start
#   (stop both v1s, then start both v2s)
# - confirm the fully-v2 3-validator network continues producing blocks
# - confirm each upgraded validator seals at least one block
#
# Precondition: scenarios 1-3 have run.
#   - validator-UPGRADE_VALIDATOR_N is already v2 (scenario 1)
#   - validator-4 was voted in then voted back out and stopped (scenario 3)
#   - active signers are validators 1, 2, 3 only (3-signer set)
#
# Important: stop BOTH remaining v1 validators before starting EITHER v2 replacement.
# With 3 active signers the Clique majority threshold is 2. Stopping both v1s at once
# temporarily drops the network to 1 active signer (the v2 validator already upgraded
# in Scenario 1), pausing block production briefly until the v2 replacements come up.
# A sequential stop-then-start per validator would also satisfy the majority threshold
# at each step, but the batch approach is simpler to implement and the brief pause is
# acceptable here.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

# After scenarios 1-3:
#   one of validators 1, 2, or 3 is already v2 (controlled by UPGRADE_VALIDATOR_N, default 2)
#   validator-4: stopped and evicted (scenario 3 voted it back out)
#
# The remaining v1 validators are "all of {1,2,3} except UPGRADE_VALIDATOR_N".
UPGRADE_N="${UPGRADE_VALIDATOR_N:-2}"
case "$UPGRADE_N" in
  1|2|3) ;;
  *) die "UPGRADE_VALIDATOR_N must be 1, 2, or 3 (got: ${UPGRADE_N})" ;;
esac
REMAINING_V1=()
for N in 1 2 3; do
  if [[ "$N" -ne "$UPGRADE_N" ]]; then
    REMAINING_V1+=("$N")
  fi
done

# Phase 1: stop all remaining v1 validators before starting any v2 replacements.
# This temporarily drops the network to 1 active signer (the already-upgraded v2
# from Scenario 1), pausing block production briefly until the new v2 nodes start.
for N in "${REMAINING_V1[@]}"; do
  pidfile=$(val_pid "$N")
  [[ -f "$pidfile" ]] || die "validator-${N} not running (missing pidfile ${pidfile})"
  log "Stopping v1 validator-${N}"
  stop_pidfile "$pidfile"
done

# Phase 2: start all v2 replacements.
for N in "${REMAINING_V1[@]}"; do
  addr=$(val_addr "$N")
  pwfile=$(val_pw "$N")
  p2p=$(p2p_port "$N")
  logfile=$(val_log "$N")
  dir=$(val_dir "$N")
  pidfile=$(val_pid "$N")

  log "Starting validator-${N} with v2 binary (same datadir)"
  (
    cd "$REPO_ROOT"
    nohup "$ABCORE_V2_GETH" \
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
done

# Phase 3: wait for IPC and peer each new v2 node.
for N in "${REMAINING_V1[@]}"; do
  wait_for_ipc "$ABCORE_V2_GETH" "$(val_ipc "$N")"

  # Peer to all other running validators (skip self). validator-4 is stopped.
  for peer in 1 2 3; do
    [[ "$peer" -eq "$N" ]] && continue
    peer_ipc=$(val_ipc "$peer")
    [[ -S "$peer_ipc" ]] || continue
    enode=$(get_enode "$ABCORE_V2_GETH" "$peer_ipc" 2>/dev/null || true)
    [[ -n "$enode" ]] || continue
    add_peer "$ABCORE_V2_GETH" "$(val_ipc "$N")" "$enode" >/dev/null || true
  done
  wait_for_min_peers "$ABCORE_V2_GETH" "$(val_ipc "$N")" 1 60

  log "validator-${N} upgraded to v2 and peered"
done

log "Waiting for chain to advance on fully-v2 network"
wait_for_blocks "$ABCORE_V2_GETH" "$(val_ipc "$UPGRADE_N")" 3 90

log "Waiting for all 3 v2 validators to converge on same head"
wait_for_same_head "$ABCORE_V2_GETH" "$(val_ipc 1)" 120 \
  "$ABCORE_V2_GETH" "$(val_ipc 2)" \
  "$ABCORE_V2_GETH" "$(val_ipc 3)"

# Confirm each newly upgraded validator sealed at least one block.
# Use wait_for_block_miner rather than wait_for_recent_signer: with 3 signers the
# Clique recents window is only 2 slots, so a validator's recent entry can roll over
# before we check it. Scanning block headers via clique.getSigner() is more reliable.
for N in "${REMAINING_V1[@]}"; do
  addr=$(val_addr "$N")
  log "Checking that validator-${N} has sealed a block"
  wait_for_block_miner "$ABCORE_V2_GETH" "$(val_ipc "$UPGRADE_N")" "$addr" 16 120
done

# Sleep long enough for the RPC node's dial-history entry (dialHistoryExpiration=35s)
# to expire and reconnect to the freshly-restarted v2 validators.  This stress-tests
# scn5: if the isolation loop does not account for the RPC node's inbound connection
# to val-1, peer_count will stay at 1 and the isolation will time out.
log "Sleeping 35s so RPC node can reconnect before scn5 runs (stress test)"
sleep 35

log "Scenario 4 OK: all validators running v2, network healthy"
