#!/usr/bin/env bash
set -euo pipefail

# Scenario 4:
# - upgrade the remaining v1 validators (1 and 3) to v2 with a coordinated stop/start
#   (stop both v1s, then start both v2s)
# - confirm the fully-v2 4-validator network continues producing blocks
# - confirm each upgraded validator seals at least one block
#
# Precondition: scenarios 1-3 have run (validator-2 and validator-4 are already v2).
#
# Important: stop BOTH v1 validators before starting EITHER v2 replacement. With 4
# signers the Clique majority threshold is 3. A sequential stop-then-start loop would
# leave only 2 active validators while the second node is being restarted, causing the
# network to stall permanently (all recents slots fill and no new block clears them).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

# After scenarios 1-3:
#   one of validators 1, 2, or 3 is already v2 (controlled by UPGRADE_VALIDATOR_N, default 2)
#   validator-4: v2 (voted in via scn3)
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
# This keeps validators 2 and 4 (both v2) running throughout — the network drops to
# 2-of-4 signers momentarily, which is below the Clique signing threshold, so blocks
# pause briefly. That is acceptable; the network resumes as soon as v2 nodes come up.
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

  # Peer to all other running validators (skip self).
  for peer in 1 2 3 4; do
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
wait_for_blocks "$ABCORE_V2_GETH" "$(val_ipc 4)" 3 90

log "Waiting for all 4 v2 validators to converge on same head"
wait_for_same_head "$ABCORE_V2_GETH" "$(val_ipc 4)" 120 \
  "$ABCORE_V2_GETH" "$(val_ipc 1)" \
  "$ABCORE_V2_GETH" "$(val_ipc 2)" \
  "$ABCORE_V2_GETH" "$(val_ipc 3)"

# Confirm each newly upgraded validator sealed at least one block.
# Use wait_for_block_miner rather than wait_for_recent_signer: with 4 signers the
# Clique recents window is only 3 slots, so a validator's recent entry can roll over
# before we check it. Scanning block headers via clique.getSigner() is more reliable.
for N in "${REMAINING_V1[@]}"; do
  addr=$(val_addr "$N")
  log "Checking that validator-${N} has sealed a block"
  wait_for_block_miner "$ABCORE_V2_GETH" "$(val_ipc 4)" "$addr" 16 120
done

log "Scenario 4 OK: all validators running v2, network healthy"
