#!/usr/bin/env bash
# Starts 3 Clique validators, wires peers, and waits for block production.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"
require_file "${GENESIS_JSON}"

# Optional: path to a TOML config file (used by 03-restart-fork.sh; absent on first start).
TOML_CONFIG="${TOML_CONFIG:-}"

launch_validator() {
  local n="$1"
  local dir addr pw p2p http logfile pidfile
  dir=$(val_dir "$n")
  addr=$(val_addr "$n")
  pw=$(val_pw "$n")
  p2p=$(p2p_port "$n")
  http=$(http_port "$n")
  logfile=$(val_log "$n")
  pidfile=$(val_pid "$n")

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    log "validator-${n} already running (pid=$(cat "$pidfile"))"
    return 0
  fi

  local extra_args=()
  if [[ -n "$TOML_CONFIG" ]]; then
    extra_args+=(--config "$TOML_CONFIG")
  fi

  log "Starting validator-${n} (p2p=${p2p}, http=${http})"
  (
    nohup "$GETH" \
      "${extra_args[@]}" \
      --datadir "$dir" \
      --networkid "$NETWORK_ID" \
      --port "$p2p" \
      --nat none \
      --nodiscover \
      --bootnodes "" \
      --ipcpath geth.ipc \
      --http \
      --http.addr 127.0.0.1 \
      --http.port "$http" \
      --http.api "eth,net,web3,clique,parlia,admin,personal,miner" \
      --syncmode full \
      --mine \
      --miner.etherbase "$addr" \
      --unlock "$addr" \
      --password "$pw" \
      --allow-insecure-unlock \
      --nousb \
      >>"$logfile" 2>&1 &
    echo $! > "$pidfile"
  )
}

for n in 1 2 3; do launch_validator "$n"; done

# Wait for IPC in parallel
_pids=()
for n in 1 2 3; do
  wait_for_ipc "$GETH" "$(val_ipc "$n")" 60 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

# Wire a full mesh
ENODE1=$(get_enode "$GETH" "$(val_ipc 1)")
ENODE2=$(get_enode "$GETH" "$(val_ipc 2)")
ENODE3=$(get_enode "$GETH" "$(val_ipc 3)")
log "Wiring peer mesh"
for src in 1 2 3; do
  local_ipc=$(val_ipc "$src")
  add_peer "$GETH" "$local_ipc" "$ENODE1" >/dev/null || true
  add_peer "$GETH" "$local_ipc" "$ENODE2" >/dev/null || true
  add_peer "$GETH" "$local_ipc" "$ENODE3" >/dev/null || true
done

# Wait for 2 peers each
_pids=()
for n in 1 2 3; do
  wait_for_min_peers "$GETH" "$(val_ipc "$n")" 2 30 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

# Wait for at least 3 blocks
wait_for_head_at_least "$GETH" "$(val_ipc 1)" 3 60

log "Clique network is up. Head=$(head_number "$GETH" "$(val_ipc 1)")"
