#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

DATADIR_ROOT=${DATADIR_ROOT:-"${SCRIPT_DIR}/data"}
GENESIS_JSON=${GENESIS_JSON:-"${SCRIPT_DIR}/genesis.json"}

CLIQUE_CHAIN_ID=${CLIQUE_CHAIN_ID:-7141}
CLIQUE_NETWORK_ID=${CLIQUE_NETWORK_ID:-$CLIQUE_CHAIN_ID}
CLIQUE_PERIOD=${CLIQUE_PERIOD:-3}

V1_DEFAULT="/data/kai/workspace/ab/abcore/build/bin/geth"
V2_DEFAULT="${REPO_ROOT}/build/bin/geth"

ABCORE_V1_GETH=${ABCORE_V1_GETH:-""}
ABCORE_V2_GETH=${ABCORE_V2_GETH:-""}

log() {
  echo "[$(date +'%H:%M:%S')] $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  local f="$1"
  [[ -f "$f" ]] || die "missing file: $f"
}

require_exe() {
  local f="$1"
  [[ -x "$f" ]] || die "missing executable: $f"
}

resolve_binaries() {
  if [[ -z "$ABCORE_V1_GETH" ]]; then
    if [[ -x "$V1_DEFAULT" ]]; then
      ABCORE_V1_GETH="$V1_DEFAULT"
    fi
  fi
  if [[ -z "$ABCORE_V2_GETH" ]]; then
    if [[ -x "$V2_DEFAULT" ]]; then
      ABCORE_V2_GETH="$V2_DEFAULT"
    fi
  fi
  [[ -n "$ABCORE_V1_GETH" ]] || die "ABCORE_V1_GETH is not set and default not found at $V1_DEFAULT"
  [[ -n "$ABCORE_V2_GETH" ]] || die "ABCORE_V2_GETH is not set and default not found at $V2_DEFAULT"
  require_exe "$ABCORE_V1_GETH"
  require_exe "$ABCORE_V2_GETH"
}

val_dir() {
  local n="$1"
  echo "${DATADIR_ROOT}/validator-${n}"
}

val_ipc() {
  local n="$1"
  echo "$(val_dir "$n")/geth.ipc"
}

val_log() {
  local n="$1"
  echo "$(val_dir "$n")/geth.log"
}

val_pid() {
  local n="$1"
  echo "$(val_dir "$n")/geth.pid"
}

val_addr() {
  local n="$1"
  cat "$(val_dir "$n")/address.txt"
}

val_pw() {
  local n="$1"
  echo "$(val_dir "$n")/password.txt"
}

p2p_port() {
  local n="$1"
  echo $((30310 + n))
}

http_port() {
  local n="$1"
  echo $((8540 + n))
}

authrpc_port() {
  local n="$1"
  echo $((8550 + n))
}

wait_for_ipc() {
  local geth_bin="$1"
  local ipc_path="$2"
  local tries=${3:-60}

  for ((i=0; i<tries; i++)); do
    if [[ -e "$ipc_path" ]] && "$geth_bin" attach --exec "web3.clientVersion" "$ipc_path" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "IPC not ready: $ipc_path"
}

attach_exec() {
  local geth_bin="$1"
  local ipc_path="$2"
  local js="$3"
  # `geth attach --exec` output differs across abcore versions:
  # - strings are often printed with surrounding quotes
  # - long strings (e.g., enode URLs) may be line-wrapped
  # Normalize to a single line and strip a single pair of surrounding quotes.
  "$geth_bin" attach --exec "$js" "$ipc_path" 2>/dev/null \
    | tr -d '\r\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//'
}

get_enode() {
  local geth_bin="$1"
  local ipc_path="$2"
  attach_exec "$geth_bin" "$ipc_path" "admin.nodeInfo.enode"
}

add_peer() {
  local geth_bin="$1"
  local ipc_path="$2"
  local enode="$3"
  attach_exec "$geth_bin" "$ipc_path" "admin.addPeer('${enode}')"
}

peer_count() {
  local geth_bin="$1"
  local ipc_path="$2"
  attach_exec "$geth_bin" "$ipc_path" "admin.peers.length"
}

head_number() {
  local geth_bin="$1"
  local ipc_path="$2"
  attach_exec "$geth_bin" "$ipc_path" "eth.getBlock('latest').number"
}

head_hash() {
  local geth_bin="$1"
  local ipc_path="$2"
  attach_exec "$geth_bin" "$ipc_path" "eth.getBlock('latest').hash"
}

block_hash_at() {
  local geth_bin="$1"
  local ipc_path="$2"
  local number="$3"
  attach_exec "$geth_bin" "$ipc_path" "eth.getBlock(${number}).hash"
}

wait_for_blocks() {
  local geth_bin="$1"
  local ipc_path="$2"
  local min_delta=${3:-2}
  local tries=${4:-60}

  local start
  start=$(head_number "$geth_bin" "$ipc_path")
  for ((i=0; i<tries; i++)); do
    local cur
    cur=$(head_number "$geth_bin" "$ipc_path")
    if [[ $((cur - start)) -ge "$min_delta" ]]; then
      return 0
    fi
    sleep 1
  done
  die "chain did not advance by ${min_delta} blocks (start=${start})"
}

assert_same_head() {
  local ref_geth="$1"
  local ref_ipc="$2"
  shift 2

  # Comparing 'latest' hashes is racey on a live chain (nodes can differ by 1
  # block just due to timing). Instead, compare the block hash at a common
  # height (min head across all nodes).
  local target
  target=$(head_number "$ref_geth" "$ref_ipc")

  local args=("$@")
  for ((i=0; i<${#args[@]}; i+=2)); do
    local geth_bin="${args[$i]}"
    local ipc_path="${args[$((i+1))]}"
    local n
    n=$(head_number "$geth_bin" "$ipc_path")
    if [[ "$n" -lt "$target" ]]; then
      target="$n"
    fi
  done

  local ref_hash
  ref_hash=$(block_hash_at "$ref_geth" "$ref_ipc" "$target")

  while [[ $# -gt 0 ]]; do
    local geth_bin="$1"
    local ipc_path="$2"
    shift 2

    local h
    h=$(block_hash_at "$geth_bin" "$ipc_path" "$target")
    if [[ "$h" != "$ref_hash" ]]; then
      die "head hash mismatch at height ${target}: ref=${ref_hash} other=${h} ipc=${ipc_path}"
    fi
  done
}

stop_pidfile() {
  local pidfile="$1"
  if [[ ! -f "$pidfile" ]]; then
    return 0
  fi
  local pid
  pid=$(cat "$pidfile" || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" || true
    for ((i=0; i<30; i++)); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        rm -f "$pidfile"
        return 0
      fi
      sleep 1
    done
    kill -9 "$pid" || true
  fi
  rm -f "$pidfile"
}

snapshot_recents_json() {
  local geth_bin="$1"
  local ipc_path="$2"
  attach_exec "$geth_bin" "$ipc_path" "JSON.stringify(clique.getSnapshot('latest').recents)"
}

wait_for_recent_signer() {
  local geth_bin="$1"
  local ipc_path="$2"
  local signer_addr="$3"
  local tries=${4:-60}

  for ((i=0; i<tries; i++)); do
    local recents
    recents=$(snapshot_recents_json "$geth_bin" "$ipc_path" || true)
    if echo "$recents" | grep -qi "$signer_addr"; then
      return 0
    fi
    sleep 1
  done
  die "did not observe signer in recents: $signer_addr"
}
