#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

PORT_BASE=${PORT_BASE:-0}
DATADIR_ROOT=${DATADIR_ROOT:-"${SCRIPT_DIR}/data-${PORT_BASE}"}
GENESIS_JSON=${GENESIS_JSON:-"${SCRIPT_DIR}/genesis.json"}

CLIQUE_CHAIN_ID=${CLIQUE_CHAIN_ID:-7141}
CLIQUE_NETWORK_ID=${CLIQUE_NETWORK_ID:-$CLIQUE_CHAIN_ID}
CLIQUE_PERIOD=${CLIQUE_PERIOD:-3}

V1_DEFAULT="${SCRIPT_DIR}/bin/geth-v1"
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
    if [[ ! -x "$V1_DEFAULT" ]]; then
      log "v1 binary not found at ${V1_DEFAULT}, downloading..."
      "${SCRIPT_DIR}/00-get-v1-geth.sh"
    fi
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

# Ports for nodes that don't fit the validator-N scheme.
rpc_p2p_port()        { echo $((30325 + PORT_BASE)); }
rpc_http_port()       { echo $((8555  + PORT_BASE)); }
val4_p2p_port()       { echo $((30326 + PORT_BASE)); }
rollback_p2p_port()   { echo $((30327 + PORT_BASE)); }
rollback_auth_port()  { echo $((8556  + PORT_BASE)); }
rpc_v1_http_port()    { echo $((8557  + PORT_BASE)); }
rpc_v1_p2p_port()     { echo $((30328 + PORT_BASE)); }
rpc_v1_auth_port()    { echo $((8558  + PORT_BASE)); }

# find_free_port_base — walk offsets in steps of 100 until all suite ports are free.
# Prints the chosen PORT_BASE to stdout. Used by 99-run-all.sh when PORT_BASE is unset.
#
# A sentinel directory /tmp/compat-clique-reserved-<base> is created atomically via
# mkdir immediately on selection so that a second run started shortly after skips this
# base even before any geth process has bound a port.  mkdir is atomic on Linux, so
# two simultaneous callers cannot both succeed for the same base.  The sentinel lives
# in /tmp, not in DATADIR_ROOT, so 05-clean.sh removing the data directory does not
# free the reservation mid-run.  04-stop.sh removes the sentinel when the run finishes.
find_free_port_base() {
  local candidates=(30311 30312 30313 30325 30326 30327 30328 8541 8542 8543 8555 8556 8557 8558 8551 8552 8553)
  local base
  for base in $(seq 0 100 9900); do
    local ok=1
    local rel port
    for rel in "${candidates[@]}"; do
      port=$((rel + base))
      # ss is preferred; -tunlp covers both TCP and UDP listening sockets.
      # Fall back to nc (-z TCP, -uz UDP) if ss is unavailable.
      if ss -tunlp 2>/dev/null | grep -q ":${port}[[:space:]]"; then
        ok=0; break
      fi
      if nc -z 127.0.0.1 "$port" 2>/dev/null || nc -uz 127.0.0.1 "$port" 2>/dev/null; then
        ok=0; break
      fi
    done
    if [[ "$ok" -eq 1 ]]; then
      # Atomically claim this base via mkdir; skip if another process beat us to it.
      if mkdir "/tmp/compat-clique-reserved-${base}" 2>/dev/null; then
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

remove_peer() {
  local geth_bin="$1"
  local ipc_path="$2"
  local enode="$3"
  attach_exec "$geth_bin" "$ipc_path" "admin.removePeer('${enode}')"
}

# reset_disconnect_enode_set clears the disconnectEnodeSet on the given node.
# p2p/server.go maintains a set of peer IDs that were explicitly disconnected;
# any subsequent inbound connection from those peers is rejected.  Passing the
# magic sentinel enode to admin.removePeer resets the entire set to {}.
# The sentinel is defined in p2p/server.go alongside the set implementation.
_MAGIC_ENODE="enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@127.0.0.1:30303"
reset_disconnect_enode_set() {
  local geth_bin="$1"
  local ipc_path="$2"
  attach_exec "$geth_bin" "$ipc_path" "admin.removePeer('${_MAGIC_ENODE}')"
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

wait_for_min_peers() {
  local geth_bin="$1"
  local ipc_path="$2"
  local min_peers=${3:-1}
  local tries=${4:-60}

  for ((i=0; i<tries; i++)); do
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
  local tries=${4:-60}

  for ((i=0; i<tries; i++)); do
    local n
    n=$(head_number "$geth_bin" "$ipc_path" 2>/dev/null || echo 0)
    if [[ "$n" -ge "$target" ]]; then
      return 0
    fi
    sleep 1
  done
  die "head did not reach height ${target} (ipc=${ipc_path})"
}

assert_same_hash_at() {
  local height="$1"
  shift
  local ref_geth="$1"
  local ref_ipc="$2"
  shift 2

  local ref_hash
  ref_hash=$(block_hash_at "$ref_geth" "$ref_ipc" "$height")
  [[ -n "$ref_hash" && "$ref_hash" != "null" ]] || die "ref block hash is empty at height ${height} (ipc=${ref_ipc})"

  while [[ $# -gt 0 ]]; do
    local geth_bin="$1"
    local ipc_path="$2"
    shift 2
    local h
    h=$(block_hash_at "$geth_bin" "$ipc_path" "$height")
    if [[ "$h" != "$ref_hash" ]]; then
      die "block hash mismatch at height ${height}: ref=${ref_hash} other=${h} ipc=${ipc_path}"
    fi
  done
}

miner_start() {
  local geth_bin="$1"
  local ipc_path="$2"
  # abcore-v2 exposes miner.start() with no args. Some other geth variants allow
  # miner.start(1). Try both and fail loudly if neither works.
  local out
  out=$(attach_exec "$geth_bin" "$ipc_path" "(function(){try{miner.start();return 'ok'}catch(e){try{miner.start(1);return 'ok-legacy'}catch(e2){return 'err:'+e+'|'+e2}}})()" || true)
  if [[ "$out" != ok* ]]; then
    die "failed to start miner via IPC (ipc=${ipc_path}): ${out}"
  fi
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

wait_for_same_head() {
  local ref_geth="$1"
  local ref_ipc="$2"
  local tries="$3"
  shift 3

  [[ "$tries" =~ ^[0-9]+$ ]] || die "wait_for_same_head: tries must be a number"

  for ((i=0; i<tries; i++)); do
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

# wait_for_block_miner: poll until a block sealed by signer_addr appears in the last
# lookback_n blocks. Uses clique.getSigner(blockNumber) to get the actual Clique signer
# (eth.getBlock().miner is always 0x0 for Clique blocks). More reliable than
# wait_for_recent_signer when the signer set is large enough that recents rolls over.
#
# geth_bin: any v1 or v2 binary — both expose clique.getSigner via the IPC console.
# The ipc_path may belong to any running node; the IPC protocol is compatible.
wait_for_block_miner() {
  local geth_bin="$1"
  local ipc_path="$2"
  local signer_addr="$3"
  local lookback_n=${4:-12}  # how many recent blocks to scan
  local tries=${5:-90}

  local addr_lower
  addr_lower=$(echo "$signer_addr" | tr '[:upper:]' '[:lower:]')

  for ((i=0; i<tries; i++)); do
    local tip
    tip=$(head_number "$geth_bin" "$ipc_path" 2>/dev/null || echo 0)
    local start=$(( tip > lookback_n ? tip - lookback_n : 0 ))
    for ((blk=tip; blk>=start; blk--)); do
      # clique.getSigner requires a hex block number string (e.g., "0x1a")
      local blk_hex
      printf -v blk_hex '0x%x' "$blk"
      local signer
      signer=$(attach_exec "$geth_bin" "$ipc_path" "clique.getSigner('${blk_hex}')" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
      if [[ "$signer" == "$addr_lower" ]]; then
        return 0
      fi
    done
    sleep 1
  done
  die "did not observe block signed by ${signer_addr} in last ${lookback_n} blocks"
}
