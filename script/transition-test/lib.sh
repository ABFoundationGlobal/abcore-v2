#!/usr/bin/env bash
# Shared utilities for the Clique→Parlia transition test suite.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

PORT_BASE=${PORT_BASE:-0}
DATADIR_ROOT=${DATADIR_ROOT:-"${SCRIPT_DIR}/data-${PORT_BASE}"}
GENESIS_JSON=${GENESIS_JSON:-"${SCRIPT_DIR}/genesis.json"}

# Chain parameters — test chain, not ABCore mainnet.
# Uses a throwaway chain ID so the genesis hash falls through to defaultNet
# bytecodes in applyParliaGenesisUpgrade.
CHAIN_ID=${CHAIN_ID:-99988}
NETWORK_ID=${NETWORK_ID:-$CHAIN_ID}
CLIQUE_PERIOD=${CLIQUE_PERIOD:-1}   # 1s blocks for fast tests
CLIQUE_EPOCH=${CLIQUE_EPOCH:-30000}

# Block at which ParliaGenesisBlock is set in the override config.
# Must be > 10 so Clique produces enough history for a legible checkpoint.
PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK:-20}

GETH="${GETH:-${REPO_ROOT}/build/bin/geth}"

log() {
  echo "[$(date +'%H:%M:%S')] $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || die "missing file: $1"
}

require_exe() {
  [[ -x "$1" ]] || die "missing executable: $1"
}

val_dir() { echo "${DATADIR_ROOT}/validator-${1}"; }
val_ipc()  { echo "$(val_dir "$1")/geth.ipc"; }
val_log()  { echo "$(val_dir "$1")/geth.log"; }
val_pid()  { echo "$(val_dir "$1")/geth.pid"; }
val_addr() { cat "$(val_dir "$1")/address.txt"; }
val_pw()   { echo "$(val_dir "$1")/password.txt"; }

p2p_port()  { echo $((30380 + $1 + PORT_BASE)); }
http_port() { echo $((8580 + $1 + PORT_BASE)); }
auth_port() { echo $((8590 + $1 + PORT_BASE)); }

attach_exec() {
  local geth="$1" ipc="$2" js="$3"
  "$geth" attach --exec "$js" "$ipc" 2>/dev/null \
    | tr -d '\r\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//'
}

get_enode() {
  attach_exec "$1" "$2" "admin.nodeInfo.enode"
}

add_peer() {
  attach_exec "$1" "$2" "admin.addPeer('${3}')"
}

head_number() {
  attach_exec "$1" "$2" "eth.getBlock('latest').number"
}

block_hash_at() {
  attach_exec "$1" "$2" "eth.getBlock(${3}).hash"
}

peer_count() {
  attach_exec "$1" "$2" "admin.peers.length"
}

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
  die "head did not reach height ${target} (ipc=${ipc})"
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
  die "peer count did not reach ${min} (ipc=${ipc})"
}

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

assert_same_hash_at() {
  local height="$1"; shift
  local ref_geth="$1" ref_ipc="$2"; shift 2
  local ref_hash
  ref_hash=$(block_hash_at "$ref_geth" "$ref_ipc" "$height")
  [[ -n "$ref_hash" && "$ref_hash" != "null" ]] || die "ref block hash empty at height ${height}"
  while [[ $# -gt 0 ]]; do
    local geth="$1" ipc="$2"; shift 2
    local h
    h=$(block_hash_at "$geth" "$ipc" "$height")
    [[ "$h" == "$ref_hash" ]] || die "hash mismatch at height ${height}: ref=${ref_hash} other=${h}"
  done
  log "All nodes agree on hash at height ${height}: ${ref_hash}"
}

# find_free_port_base: pick a PORT_BASE where all test ports are free.
# Uses a sentinel dir in /tmp to prevent races between parallel runs.
find_free_port_base() {
  local candidates=(30381 30382 30383 8581 8582 8583 8591 8592 8593)
  for base in $(seq 0 100 9900); do
    local ok=1
    for rel in "${candidates[@]}"; do
      local port=$((rel + base))
      if ss -tunlp 2>/dev/null | grep -q ":${port}[[:space:]]" || nc -z 127.0.0.1 "$port" 2>/dev/null; then
        ok=0; break
      fi
    done
    if [[ "$ok" -eq 1 ]]; then
      if mkdir "/tmp/transition-test-reserved-${base}" 2>/dev/null; then
        echo "$base"
        return 0
      fi
    fi
  done
  echo "find_free_port_base: no free port base found" >&2
  return 1
}
