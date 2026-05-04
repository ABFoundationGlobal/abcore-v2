#!/usr/bin/env bash
set -euo pipefail

# Starts 3 v1 validators, forces peering, and waits for block production.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries
require_file "${GENESIS_JSON}"

launch_validator_v1() {
  local n="$1"
  local dir
  dir=$(val_dir "$n")

  require_file "${dir}/address.txt"
  require_file "${dir}/password.txt"

  local addr pwfile p2p
  addr=$(val_addr "$n")
  pwfile=$(val_pw "$n")
  p2p=$(p2p_port "$n")

  local logfile pidfile
  logfile=$(val_log "$n")
  pidfile=$(val_pid "$n")

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" >/dev/null 2>&1; then
    log "validator-${n} already running (pid=$(cat "$pidfile"))"
    return 0
  fi

  log "Starting v1 validator-${n} (p2p=${p2p})"
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
      --authrpc.addr 127.0.0.1 \
      --authrpc.port "$(authrpc_port "$n")" \
      --syncmode full \
      --mine \
      --miner.etherbase "$addr" \
      --unlock "$addr" \
      --password "$pwfile" \
      --nousb \
      >>"$logfile" 2>&1 &
    echo $! >"$pidfile"
  )
}

# Launch all validators without waiting, then wait for IPC in parallel.
for n in 1 2 3; do
  launch_validator_v1 "$n"
done
_ipc_pids=()
for n in 1 2 3; do
  wait_for_ipc "$ABCORE_V1_GETH" "$(val_ipc "$n")" &
  _ipc_pids+=($!)
done
for _pid in "${_ipc_pids[@]}"; do wait "$_pid"; done

# Force a full mesh using admin.addPeer.
ENODE1=$(get_enode "$ABCORE_V1_GETH" "$(val_ipc 1)")
ENODE2=$(get_enode "$ABCORE_V1_GETH" "$(val_ipc 2)")
ENODE3=$(get_enode "$ABCORE_V1_GETH" "$(val_ipc 3)")

log "Wiring peers via admin.addPeer"
for src in 1 2 3; do
  ipc=$(val_ipc "$src")
  add_peer "$ABCORE_V1_GETH" "$ipc" "$ENODE1" >/dev/null || true
  add_peer "$ABCORE_V1_GETH" "$ipc" "$ENODE2" >/dev/null || true
  add_peer "$ABCORE_V1_GETH" "$ipc" "$ENODE3" >/dev/null || true
done
# Wait for all nodes to reach at least 2 peers in parallel.
_peer_pids=()
for src in 1 2 3; do
  wait_for_min_peers "$ABCORE_V1_GETH" "$(val_ipc "$src")" 2 30 &
  _peer_pids+=($!)
done
for _pid in "${_peer_pids[@]}"; do wait "$_pid"; done
for src in 1 2 3; do
  log "validator-${src}: peers=$(peer_count "$ABCORE_V1_GETH" "$(val_ipc "$src")" || echo 0)"
done

log "Waiting for blocks to advance"
wait_for_blocks "$ABCORE_V1_GETH" "$(val_ipc 1)" 2 60

wait_for_same_head "$ABCORE_V1_GETH" "$(val_ipc 1)" 60 \
  "$ABCORE_V1_GETH" "$(val_ipc 2)" \
  "$ABCORE_V1_GETH" "$(val_ipc 3)"

log "v1 network is up. Next: ./10-scn1-upgrade-validator.sh"