#!/usr/bin/env bash
set -euo pipefail

# Starts 3 validators with node-clique-N.toml (Clique PoA phase),
# forces peering, and waits for block production.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries
require_file "${GENESIS_JSON}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/validator-addrs.env"

ADDRS=("" "$VAL1_ADDR" "$VAL2_ADDR" "$VAL3_ADDR")

launch_validator() {
  local n="$1"
  local cfg="${SCRIPT_DIR}/config/node-clique-${n}.toml"
  require_file "$cfg"

  local dir addr pwfile logfile pidfile
  dir=$(val_dir "$n")
  addr="${ADDRS[$n]}"
  pwfile=$(val_pw "$n")
  logfile=$(val_log "$n")
  pidfile=$(val_pid "$n")

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" >/dev/null 2>&1; then
    log "validator-${n} already running (pid=$(cat "$pidfile"))"
    return 0
  fi

  log "Starting validator-${n} (clique, p2p=$(p2p_port "$n"))"
  (
    cd "${REPO_ROOT}"
    nohup "${ABCORE_V2_GETH}" \
      --config "$cfg" \
      --mine \
      --miner.etherbase "$addr" \
      --unlock "$addr" \
      --password "$pwfile" \
      --allow-insecure-unlock \
      >>"$logfile" 2>&1 &
    echo $! >"$pidfile"
  )
}

# Launch all validators without waiting.
for n in 1 2 3; do
  launch_validator "$n"
done

# Wait for IPC sockets in parallel.
_ipc_pids=()
for n in 1 2 3; do
  wait_for_ipc "${ABCORE_V2_GETH}" "$(val_ipc "$n")" 90 &
  _ipc_pids+=($!)
done
for _pid in "${_ipc_pids[@]}"; do wait "$_pid"; done

# Force full mesh via admin.addPeer.
ENODE1=$(get_enode "${ABCORE_V2_GETH}" "$(val_ipc 1)")
ENODE2=$(get_enode "${ABCORE_V2_GETH}" "$(val_ipc 2)")
ENODE3=$(get_enode "${ABCORE_V2_GETH}" "$(val_ipc 3)")

log "Wiring peers via admin.addPeer"
for src in 1 2 3; do
  ipc=$(val_ipc "$src")
  add_peer "${ABCORE_V2_GETH}" "$ipc" "$ENODE1" >/dev/null || true
  add_peer "${ABCORE_V2_GETH}" "$ipc" "$ENODE2" >/dev/null || true
  add_peer "${ABCORE_V2_GETH}" "$ipc" "$ENODE3" >/dev/null || true
done

# Wait for all nodes to reach at least 2 peers.
_peer_pids=()
for src in 1 2 3; do
  wait_for_min_peers "${ABCORE_V2_GETH}" "$(val_ipc "$src")" 2 30 &
  _peer_pids+=($!)
done
for _pid in "${_peer_pids[@]}"; do wait "$_pid"; done

for src in 1 2 3; do
  log "validator-${src}: peers=$(peer_count "${ABCORE_V2_GETH}" "$(val_ipc "$src")" || echo 0)"
done

log "Waiting for blocks to advance"
wait_for_blocks "${ABCORE_V2_GETH}" "$(val_ipc 1)" 3 60

wait_for_same_head "${ABCORE_V2_GETH}" "$(val_ipc 1)" 30 \
  "${ABCORE_V2_GETH}" "$(val_ipc 2)" \
  "${ABCORE_V2_GETH}" "$(val_ipc 3)"

log "Clique PoA network is up. Next: ./10-scn1-pre-fork-poa.sh"
