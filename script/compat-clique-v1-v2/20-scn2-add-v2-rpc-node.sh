#!/usr/bin/env bash
set -euo pipefail

# Scenario 2:
# - add a new v2 node as an RPC node
# - it should join and sync to the current head

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries
require_file "${GENESIS_JSON}"

RPC_DIR="${DATADIR_ROOT}/rpc-v2-1"
RPC_IPC="${RPC_DIR}/geth.ipc"
RPC_PID="${RPC_DIR}/geth.pid"
RPC_LOG="${RPC_DIR}/geth.log"

mkdir -p "$RPC_DIR"

if [[ ! -d "${RPC_DIR}/geth" ]]; then
  log "Initializing rpc-v2-1 datadir"
  "$ABCORE_V2_GETH" init --datadir "$RPC_DIR" "${GENESIS_JSON}"
fi

if [[ -f "$RPC_PID" ]] && kill -0 "$(cat "$RPC_PID")" >/dev/null 2>&1; then
  log "rpc-v2-1 already running (pid=$(cat "$RPC_PID"))"
else
  log "Starting rpc-v2-1 with HTTP enabled"
  (
    cd "$REPO_ROOT"
    nohup "$ABCORE_V2_GETH" \
      --datadir "$RPC_DIR" \
      --networkid "$CLIQUE_NETWORK_ID" \
      --port 30325 \
      --nat none \
      --nodiscover \
      --bootnodes "" \
      --ipcpath geth.ipc \
      --syncmode full \
      --http --http.addr 127.0.0.1 --http.port 8555 \
      --http.api eth,net,web3 \
      --nousb \
      >>"$RPC_LOG" 2>&1 &
    echo $! >"$RPC_PID"
  )
fi

wait_for_ipc "$ABCORE_V2_GETH" "$RPC_IPC"

# Peer it to validator-1.
ENODE1=$(get_enode "$ABCORE_V1_GETH" "$(val_ipc 1)")
ENODE2=$(get_enode "$ABCORE_V1_GETH" "$(val_ipc 2)")
ENODE3=$(get_enode "$ABCORE_V1_GETH" "$(val_ipc 3)")
add_peer "$ABCORE_V2_GETH" "$RPC_IPC" "$ENODE1" >/dev/null || true
add_peer "$ABCORE_V2_GETH" "$RPC_IPC" "$ENODE2" >/dev/null || true
add_peer "$ABCORE_V2_GETH" "$RPC_IPC" "$ENODE3" >/dev/null || true

wait_for_min_peers "$ABCORE_V2_GETH" "$RPC_IPC" 1 60

log "Waiting for rpc-v2-1 to sync to validators"
ref_head=$(head_number "$ABCORE_V1_GETH" "$(val_ipc 1)")
checkpoint=$((ref_head > 2 ? ref_head - 2 : ref_head))
wait_for_head_at_least "$ABCORE_V2_GETH" "$RPC_IPC" "$ref_head" 120
assert_same_hash_at "$checkpoint" \
  "$ABCORE_V1_GETH" "$(val_ipc 1)" \
  "$ABCORE_V2_GETH" "$RPC_IPC"

log "rpc-v2-1 synced (checkpoint=${checkpoint})"
log "Scenario 2 OK"