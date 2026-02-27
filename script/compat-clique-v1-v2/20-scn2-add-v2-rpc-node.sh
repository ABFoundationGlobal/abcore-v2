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
add_peer "$ABCORE_V2_GETH" "$RPC_IPC" "$ENODE1" >/dev/null || true

log "Waiting for rpc-v2-1 to sync to current head"
for ((i=0; i<120; i++)); do
  h1=$(head_hash "$ABCORE_V1_GETH" "$(val_ipc 1)")
  hr=$(head_hash "$ABCORE_V2_GETH" "$RPC_IPC")
  if [[ "$h1" == "$hr" ]]; then
    log "rpc-v2-1 synced (head=${hr})"
    log "Scenario 2 OK"
    exit 0
  fi
  sleep 1

done

die "rpc-v2-1 did not sync to validator-1 head within timeout"