#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

PORT_BASE=${PORT_BASE:-0}
DATADIR_ROOT=${DATADIR_ROOT:-"${SCRIPT_DIR}/data-${PORT_BASE}"}
GENESIS_JSON=${GENESIS_JSON:-"${SCRIPT_DIR}/genesis.json"}

CHAIN_ID=${CHAIN_ID:-7143}
PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK:-10}
CLIQUE_PERIOD=${CLIQUE_PERIOD:-3}
CLIQUE_EPOCH=${CLIQUE_EPOCH:-30000}
TIME_FORK_DELTA=${TIME_FORK_DELTA:-120}

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
  if [[ -z "$ABCORE_V2_GETH" ]]; then
    if [[ -x "${SCRIPT_DIR}/bin/geth-custom" ]]; then
      ABCORE_V2_GETH="${SCRIPT_DIR}/bin/geth-custom"
    elif [[ -x "${REPO_ROOT}/build/bin/geth" ]]; then
      ABCORE_V2_GETH="${REPO_ROOT}/build/bin/geth"
    fi
  fi
  [[ -n "$ABCORE_V2_GETH" ]] || die "ABCORE_V2_GETH is not set; run ./00-build-contracts.sh first"
  require_exe "$ABCORE_V2_GETH"
}

# Stable keystore dirs (do not depend on PORT_BASE).
val_keystore_dir() {
  local n="$1"
  echo "${SCRIPT_DIR}/keystore-${n}"
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
  cat "$(val_keystore_dir "$n")/address.txt"
}

val_pw() {
  local n="$1"
  echo "$(val_keystore_dir "$n")/password.txt"
}

p2p_port() {
  local n="$1"
  echo $((30310 + n + PORT_BASE))
}

http_port() {
  local n="$1"
  echo $((8540 + n + PORT_BASE))
}

authrpc_port() {
  local n="$1"
  echo $((8550 + n + PORT_BASE))
}

# find_free_port_base — walk offsets in steps of 100 until all suite ports are free.
# Prints the chosen PORT_BASE to stdout. Used by 99-run-all.sh when PORT_BASE is unset.
#
# A sentinel directory /tmp/compat-poa-posa-reserved-<base> is created atomically via
# mkdir immediately on selection so that a second run started shortly after skips this
# base even before any geth process has bound a port. The sentinel is removed by
# 04-stop.sh at the end of the run.
find_free_port_base() {
  local candidates=(30311 30312 30313 8541 8542 8543 8551 8552 8553)
  local base
  for base in $(seq 0 100 9900); do
    local ok=1
    local rel port
    for rel in "${candidates[@]}"; do
      port=$((rel + base))
      if ss -tunlp 2>/dev/null | grep -q ":${port}[[:space:]]"; then
        ok=0; break
      fi
      if nc -z 127.0.0.1 "$port" 2>/dev/null || nc -uz 127.0.0.1 "$port" 2>/dev/null; then
        ok=0; break
      fi
    done
    if [[ "$ok" -eq 1 ]]; then
      if mkdir "/tmp/compat-poa-posa-reserved-${base}" 2>/dev/null; then
        echo "$base"
        return 0
      fi
    fi
  done
  echo "find_free_port_base: no free port base found in range 0–9900" >&2
  return 1
}

wait_for_ipc() {
  local geth_bin="$1"
  local ipc_path="$2"
  local timeout_sec=${3:-60}
  local deadline=$(( $(date +%s) + timeout_sec ))

  while [[ $(date +%s) -lt $deadline ]]; do
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

wait_for_min_peers() {
  local geth_bin="$1"
  local ipc_path="$2"
  local min_peers=${3:-1}
  local timeout_sec=${4:-60}
  local deadline=$(( $(date +%s) + timeout_sec ))

  while [[ $(date +%s) -lt $deadline ]]; do
    local pc
    pc=$(peer_count "$geth_bin" "$ipc_path" 2>/dev/null || echo 0)
    if [[ "$pc" -ge "$min_peers" ]]; then
      return 0
    fi
    sleep 1
  done
  die "peer count did not reach ${min_peers} (ipc=${ipc_path})"
}

wait_for_head_at_least() {
  local geth_bin="$1"
  local ipc_path="$2"
  local target="$3"
  local timeout_sec=${4:-120}
  local deadline=$(( $(date +%s) + timeout_sec ))

  while [[ $(date +%s) -lt $deadline ]]; do
    local n
    n=$(head_number "$geth_bin" "$ipc_path" 2>/dev/null || echo 0)
    if [[ "$n" -ge "$target" ]]; then
      return 0
    fi
    sleep 1
  done
  die "head did not reach height ${target} (ipc=${ipc_path})"
}

wait_for_blocks() {
  local geth_bin="$1"
  local ipc_path="$2"
  local min_delta=${3:-2}
  local timeout_sec=${4:-60}

  local start
  start=$(head_number "$geth_bin" "$ipc_path")
  local deadline=$(( $(date +%s) + timeout_sec ))
  while [[ $(date +%s) -lt $deadline ]]; do
    local cur
    cur=$(head_number "$geth_bin" "$ipc_path")
    if [[ $((cur - start)) -ge "$min_delta" ]]; then
      return 0
    fi
    sleep 1
  done
  die "chain did not advance by ${min_delta} blocks (start=${start})"
}

check_same_head() {
  local ref_geth="$1"
  local ref_ipc="$2"
  shift 2

  local target
  target=$(head_number "$ref_geth" "$ref_ipc")

  local args=("$@")
  for ((i=0; i<${#args[@]}; i+=2)); do
    local geth_bin="${args[$i]}"
    local ipc_path="${args[$((i+1))]}"
    local n
    n=$(head_number "$geth_bin" "$ipc_path" 2>/dev/null || echo 0)
    if [[ "$n" -lt "$target" ]]; then
      target="$n"
    fi
  done

  local ref_hash
  ref_hash=$(block_hash_at "$ref_geth" "$ref_ipc" "$target")
  if [[ -z "$ref_hash" || "$ref_hash" == "null" ]]; then
    return 1
  fi

  while [[ $# -gt 0 ]]; do
    local geth_bin="$1"
    local ipc_path="$2"
    shift 2
    local h
    h=$(block_hash_at "$geth_bin" "$ipc_path" "$target")
    if [[ "$h" != "$ref_hash" ]]; then
      return 1
    fi
  done
  return 0
}

assert_same_head() {
  local ref_geth="$1"
  local ref_ipc="$2"
  shift 2

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

wait_for_same_head() {
  local ref_geth="$1"
  local ref_ipc="$2"
  local timeout_sec="$3"
  shift 3

  [[ "$timeout_sec" =~ ^[0-9]+$ ]] || die "wait_for_same_head: timeout_sec must be a number (got: ${timeout_sec})"
  local deadline=$(( $(date +%s) + timeout_sec ))

  while [[ $(date +%s) -lt $deadline ]]; do
    if check_same_head "$ref_geth" "$ref_ipc" "$@"; then
      return 0
    fi
    sleep 1
  done
  die "nodes did not converge on same head within timeout"
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
