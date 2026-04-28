#!/usr/bin/env bash
# Shared utilities for the local 3-node phased upgrade drill (U-series).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

DATADIR_ROOT=${DATADIR_ROOT:-"${SCRIPT_DIR}/data"}
GENESIS_JSON=${GENESIS_JSON:-"${DATADIR_ROOT}/genesis.json"}
TOML_CONFIG=${TOML_CONFIG:-"${DATADIR_ROOT}/config.toml"}
SNAPSHOT_DIR=${SNAPSHOT_DIR:-"${SCRIPT_DIR}/snapshots"}

CHAIN_ID=${CHAIN_ID:-99988}
NETWORK_ID=${NETWORK_ID:-$CHAIN_ID}
CLIQUE_PERIOD=${CLIQUE_PERIOD:-1}
CLIQUE_EPOCH=${CLIQUE_EPOCH:-30000}

GETH="${GETH:-${REPO_ROOT}/build/bin/geth}"

log() { echo "[$(date +'%H:%M:%S')] $*"; }

die() { echo "ERROR: $*" >&2; exit 1; }

require_file() { [[ -f "$1" ]] || die "missing file: $1"; }

require_exe() { [[ -x "$1" ]] || die "missing executable: $1"; }

# ── Node path helpers ─────────────────────────────────────────────────────────

val_dir()  { echo "${DATADIR_ROOT}/validator-${1}"; }
val_ipc()  { echo "$(val_dir "$1")/geth.ipc"; }
val_log()  { echo "$(val_dir "$1")/geth.log"; }
val_pid()  { echo "$(val_dir "$1")/geth.pid"; }
val_addr() { cat "$(val_dir "$1")/address.txt"; }
val_pw()   { echo "$(val_dir "$1")/password.txt"; }

p2p_port()  { echo $((30480 + $1)); }
http_port() { echo $((8680 + $1)); }
auth_port() { echo $((8690 + $1)); }

# ── Chain interaction helpers ─────────────────────────────────────────────────

attach_exec() {
  local geth="$1" ipc="$2" js="$3"
  "$geth" attach --exec "$js" "$ipc" 2>/dev/null \
    | tr -d '\r\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//'
}

get_enode()     { attach_exec "$1" "$2" "admin.nodeInfo.enode"; }
add_peer()      { attach_exec "$1" "$2" "admin.addPeer('${3}')"; }
head_number()   { attach_exec "$1" "$2" "eth.getBlock('latest').number"; }
block_hash_at() { attach_exec "$1" "$2" "eth.getBlock(${3}).hash"; }
peer_count()    { attach_exec "$1" "$2" "admin.peers.length"; }

# ── Wait helpers ──────────────────────────────────────────────────────────────

wait_for_ipc() {
  local geth="$1" ipc="$2" timeout="${3:-60}"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    if [[ -e "$ipc" ]] && "$geth" attach --exec "web3.clientVersion" "$ipc" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "IPC not ready: $ipc"
}

wait_for_head_at_least() {
  local geth="$1" ipc="$2" target="$3" timeout="${4:-120}"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    local n
    n=$(head_number "$geth" "$ipc" 2>/dev/null || echo 0)
    [[ "$n" -ge "$target" ]] && return 0
    sleep 1
  done
  die "head did not reach ${target} within ${timeout}s (ipc=${ipc})"
}

wait_for_min_peers() {
  local geth="$1" ipc="$2" min="${3:-1}" timeout="${4:-60}"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    local pc
    pc=$(peer_count "$geth" "$ipc" 2>/dev/null || echo 0)
    [[ "$pc" -ge "$min" ]] && return 0
    sleep 1
  done
  die "peer count did not reach ${min} within ${timeout}s (ipc=${ipc})"
}

check_same_head() {
  local min_height=1
  if [[ "${1:-}" == "--min-height" ]]; then
    min_height="$2"; shift 2
  fi
  local ref_geth="$1" ref_ipc="$2"; shift 2
  local ref_n
  ref_n=$(head_number "$ref_geth" "$ref_ipc" 2>/dev/null || echo 0)
  [[ "$ref_n" -ge "$min_height" ]] || return 1
  local target="$ref_n"
  local args=("$@")
  for ((i=0; i<${#args[@]}; i+=2)); do
    local n
    n=$(head_number "${args[$i]}" "${args[$((i+1))]}" 2>/dev/null || echo 0)
    [[ "$n" -ge "$min_height" ]] || return 1
    [[ "$n" -lt "$target" ]] && target="$n"
  done
  local ref_hash
  ref_hash=$(block_hash_at "$ref_geth" "$ref_ipc" "$target")
  [[ -n "$ref_hash" && "$ref_hash" != "null" ]] || return 1
  while [[ $# -gt 0 ]]; do
    local h
    h=$(block_hash_at "$1" "$2" "$target"); shift 2
    [[ "$h" == "$ref_hash" ]] || return 1
  done
  return 0
}

wait_for_same_head() {
  local min_height_arg=()
  if [[ "${1:-}" == "--min-height" ]]; then
    min_height_arg=("--min-height" "$2"); shift 2
  fi
  local ref_geth="$1" ref_ipc="$2" timeout="${3:-60}"; shift 3
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    check_same_head "${min_height_arg[@]}" "$ref_geth" "$ref_ipc" "$@" && return 0
    sleep 1
  done
  die "nodes did not converge on the same head within ${timeout}s"
}

# wait_for_timestamp <unix_ts> [timeout_s]
# Polls until the system clock reaches unix_ts.  Reports progress every 30 s.
wait_for_timestamp() {
  local target_ts="$1" timeout="${2:-900}"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    local now remaining
    now=$(date +%s)
    if [[ "$now" -ge "$target_ts" ]]; then
      log "Activation timestamp ${target_ts} reached."
      return 0
    fi
    remaining=$(( target_ts - now ))
    log "Waiting for activation timestamp ${target_ts} (${remaining}s remaining)..."
    local sleep_s=$(( remaining > 30 ? 30 : remaining ))
    sleep "$sleep_s"
  done
  die "activation timestamp ${target_ts} not reached within ${timeout}s"
}

# ── Process management ────────────────────────────────────────────────────────

stop_pidfile() {
  local pidfile="$1"
  [[ -f "$pidfile" ]] || return 0
  local pid
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    local deadline=$(( $(date +%s) + 30 ))
    while kill -0 "$pid" 2>/dev/null && [[ $(date +%s) -lt $deadline ]]; do
      sleep 0.5
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"
}

stop_all() {
  local -a pids=()
  shopt -s nullglob
  for pidfile in "${DATADIR_ROOT}"/validator-*/geth.pid; do
    local name pid
    name=$(basename "$(dirname "$pidfile")")
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log "Stopping ${name} (pid=${pid})"
      kill "$pid" 2>/dev/null || true
      pids+=("$pid")
    else
      rm -f "$pidfile"
    fi
  done
  shopt -u nullglob

  if [[ "${#pids[@]}" -gt 0 ]]; then
    # Wait up to 30 s for graceful shutdown before SIGKILL.
    local deadline=$(( $(date +%s) + 30 ))
    while [[ $(date +%s) -lt $deadline ]]; do
      local running=0
      for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null && running=$(( running + 1 )) || true
      done
      [[ "$running" -eq 0 ]] && break
      sleep 0.5
    done
    for pid in "${pids[@]}"; do
      kill -9 "$pid" 2>/dev/null || true
    done
    shopt -s nullglob
    rm -f "${DATADIR_ROOT}"/validator-*/geth.pid
    shopt -u nullglob
  fi
  log "All validators stopped."
}

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
  if [[ -n "${TOML_CONFIG:-}" && -f "${TOML_CONFIG}" ]]; then
    extra_args+=(--config "${TOML_CONFIG}")
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
      --http.api "eth,net,web3,clique,parlia,admin,personal,miner,debug" \
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

wire_mesh() {
  local enode1 enode2 enode3
  enode1=$(get_enode "$GETH" "$(val_ipc 1)")
  enode2=$(get_enode "$GETH" "$(val_ipc 2)")
  enode3=$(get_enode "$GETH" "$(val_ipc 3)")
  log "Wiring peer mesh"
  for src in 1 2 3; do
    local ipc; ipc=$(val_ipc "$src")
    add_peer "$GETH" "$ipc" "$enode1" >/dev/null 2>&1 || true
    add_peer "$GETH" "$ipc" "$enode2" >/dev/null 2>&1 || true
    add_peer "$GETH" "$ipc" "$enode3" >/dev/null 2>&1 || true
  done
}

start_all() {
  local min_blocks="${1:-3}"
  for n in 1 2 3; do launch_validator "$n"; done

  local _pids=()
  for n in 1 2 3; do
    wait_for_ipc "$GETH" "$(val_ipc "$n")" 60 &
    _pids+=($!)
  done
  for p in "${_pids[@]}"; do wait "$p"; done

  wire_mesh

  local _pids=()
  for n in 1 2 3; do
    wait_for_min_peers "$GETH" "$(val_ipc "$n")" 2 30 &
    _pids+=($!)
  done
  for p in "${_pids[@]}"; do wait "$p"; done

  wait_for_head_at_least "$GETH" "$(val_ipc 1)" "$min_blocks" 60
  log "Network up. Head=$(head_number "$GETH" "$(val_ipc 1)")"
}

# rolling_restart: restart validators one by one.
# Assumes TOML_CONFIG has already been updated before this call.
# Each node is stopped, restarted with the new TOML, then synced before
# moving to the next node to keep 2-of-3 quorum throughout.
rolling_restart() {
  for n in 1 2 3; do
    local ref=$(( n == 1 ? 2 : 1 ))
    log "Rolling restart: stopping validator-${n}..."
    stop_pidfile "$(val_pid "$n")"
    sleep 1

    log "Rolling restart: starting validator-${n} with updated config..."
    launch_validator "$n"
    wait_for_ipc "$GETH" "$(val_ipc "$n")" 60

    # Re-wire peers from this node's perspective
    for peer in 1 2 3; do
      [[ "$peer" -eq "$n" ]] && continue
      local peer_enode
      peer_enode=$(get_enode "$GETH" "$(val_ipc "$peer")" 2>/dev/null || true)
      [[ -n "$peer_enode" ]] && add_peer "$GETH" "$(val_ipc "$n")" "$peer_enode" >/dev/null 2>&1 || true
    done

    # Wait until the restarted node catches up to the reference
    local target
    target=$(head_number "$GETH" "$(val_ipc "$ref")" 2>/dev/null || echo 1)
    log "Rolling restart: waiting for validator-${n} to reach head ${target}..."
    wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$target" 120
    log "Rolling restart: validator-${n} ready (head=$(head_number "$GETH" "$(val_ipc "$n")"))."
  done

  wait_for_same_head "$GETH" "$(val_ipc 1)" 60 \
    "$GETH" "$(val_ipc 2)" \
    "$GETH" "$(val_ipc 3)"
  log "Rolling restart complete. All nodes converged at head=$(head_number "$GETH" "$(val_ipc 1)")."
}

# reinit_genesis: update stored chainconfig by re-initialising all 3 datadirs
# with a new genesis.json.  The genesis block itself must remain unchanged
# (same chainId, alloc, extraData, gasLimit, difficulty) — only chainconfig
# fork parameters differ.  geth init stores chainconfig separately from the
# genesis block hash, so this succeeds without wiping data.
reinit_genesis() {
  require_file "${GENESIS_JSON}"
  for n in 1 2 3; do
    log "reinit_genesis: geth init validator-${n}"
    "$GETH" init --datadir "$(val_dir "$n")" "${GENESIS_JSON}" 2>/dev/null
  done
  log "reinit_genesis: chainconfig updated for all 3 validators."
}
