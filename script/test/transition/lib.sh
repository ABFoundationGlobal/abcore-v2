#!/usr/bin/env bash
# Shared utilities for the Clique→Parlia transition test suite.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../../.." && pwd)

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

# ensure_python_deps <pip-package> [...]
# Installs any listed packages that are not already importable.
# Must be called from an activated venv; fails fast to avoid polluting the
# system Python on PEP-668 systems.
ensure_python_deps() {
  [[ -n "${VIRTUAL_ENV:-}" ]] || \
    die "ensure_python_deps: no active venv detected (VIRTUAL_ENV is unset). Activate a venv before calling this function."
  local missing=()
  for pkg in "$@"; do
    local mod="${pkg//-/_}"
    python3 -c "import ${mod}" 2>/dev/null || missing+=("$pkg")
  done
  [[ "${#missing[@]}" -eq 0 ]] && return 0

  log "Installing missing Python packages: ${missing[*]}"
  python3 -m pip install --quiet "${missing[@]}" || \
    die "Failed to install Python packages: ${missing[*]}"

  for pkg in "$@"; do
    local mod="${pkg//-/_}"
    python3 -c "import ${mod}" 2>/dev/null \
      || die "Package installed but import still fails: ${mod}"
  done
  log "Python packages ready: $*"
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

wait_for_blocks() {
  local geth="$1" ipc="$2" min_delta="${3:-2}" timeout="${4:-60}"
  local start
  start=$(head_number "$geth" "$ipc")
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    local cur
    cur=$(head_number "$geth" "$ipc")
    [[ $((cur - start)) -ge "$min_delta" ]] && return 0
    sleep 1
  done
  die "chain did not advance by ${min_delta} blocks (start=${start}, ipc=${ipc})"
}

assert_same_head() {
  local ref_geth="$1" ref_ipc="$2"
  shift 2

  local target
  target=$(head_number "$ref_geth" "$ref_ipc")
  local args=("$@")
  for ((i=0; i<${#args[@]}; i+=2)); do
    local geth="${args[$i]}"
    local ipc="${args[$((i+1))]}"
    local n
    n=$(head_number "$geth" "$ipc")
    if [[ "$n" -lt "$target" ]]; then
      target="$n"
    fi
  done

  local ref_hash
  ref_hash=$(block_hash_at "$ref_geth" "$ref_ipc" "$target")
  [[ -n "$ref_hash" && "$ref_hash" != "null" ]] || die "ref head hash empty at height ${target}"

  while [[ $# -gt 0 ]]; do
    local geth="$1" ipc="$2"
    shift 2
    local h
    h=$(block_hash_at "$geth" "$ipc" "$target")
    [[ "$h" == "$ref_hash" ]] || die "head hash mismatch at height ${target}: ref=${ref_hash} other=${h} ipc=${ipc}"
  done
}

# check_same_head [--min-height N] ref_geth ref_ipc [geth ipc ...]
# Returns 0 only when ALL nodes have head >= N (default 1) and all agree on
# the same block hash at their shared minimum height.  Without --min-height,
# nodes that just restarted report head=0 (genesis), causing a false-positive
# convergence at block 0 where everyone trivially agrees.
check_same_head() {
  local min_height=1
  if [[ "${1:-}" == "--min-height" ]]; then
    min_height="$2"
    shift 2
  fi

  local ref_geth="$1" ref_ipc="$2"
  shift 2

  local ref_n
  ref_n=$(head_number "$ref_geth" "$ref_ipc" 2>/dev/null || echo 0)
  [[ "$ref_n" -ge "$min_height" ]] || return 1

  local target="$ref_n"
  local args=("$@")
  for ((i=0; i<${#args[@]}; i+=2)); do
    local geth="${args[$i]}"
    local ipc="${args[$((i+1))]}"
    local n
    n=$(head_number "$geth" "$ipc" 2>/dev/null || echo 0)
    [[ "$n" -ge "$min_height" ]] || return 1
    if [[ "$n" -lt "$target" ]]; then
      target="$n"
    fi
  done

  local ref_hash
  ref_hash=$(block_hash_at "$ref_geth" "$ref_ipc" "$target")
  [[ -n "$ref_hash" && "$ref_hash" != "null" ]] || return 1

  while [[ $# -gt 0 ]]; do
    local geth="$1" ipc="$2"
    shift 2
    local h
    h=$(block_hash_at "$geth" "$ipc" "$target")
    [[ "$h" == "$ref_hash" ]] || return 1
  done
  return 0
}

# wait_for_same_head [--min-height N] ref_geth ref_ipc timeout [geth ipc ...]
wait_for_same_head() {
  local min_height_arg=()
  if [[ "${1:-}" == "--min-height" ]]; then
    min_height_arg=("--min-height" "$2")
    shift 2
  fi

  local ref_geth="$1" ref_ipc="$2" timeout="${3:-60}"
  shift 3

  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    if check_same_head "${min_height_arg[@]}" "$ref_geth" "$ref_ipc" "$@"; then
      return 0
    fi
    sleep 1
  done
  die "nodes did not converge on the same head within ${timeout}s"
}

wait_for_block_miner() {
  local geth="$1" ipc="$2" signer_addr="$3" lookback_n="${4:-12}" timeout="${5:-90}"
  local addr_lower
  addr_lower=$(echo "$signer_addr" | tr '[:upper:]' '[:lower:]')
  local deadline=$(( $(date +%s) + timeout ))

  while [[ $(date +%s) -lt $deadline ]]; do
    local tip
    tip=$(head_number "$geth" "$ipc" 2>/dev/null || echo 0)
    local start=$(( tip > lookback_n ? tip - lookback_n : 0 ))
    for ((blk=tip; blk>=start; blk--)); do
      local blk_hex signer
      printf -v blk_hex '0x%x' "$blk"
      signer=$(attach_exec "$geth" "$ipc" "clique.getSigner('${blk_hex}')" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
      if [[ "$signer" == "$addr_lower" ]]; then
        return 0
      fi
    done
    sleep 1
  done
  die "did not observe block signed by ${signer_addr} in the last ${lookback_n} blocks"
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

# partial_clean: wipe chain data but preserve keystores and address.txt so
# that validator addresses remain consistent with baked-in bytecodes.
partial_clean() {
  "${SCRIPT_DIR}/03-stop.sh" || true
  # 03-stop.sh removes the PORT_BASE sentinel; re-acquire it so parallel runs
  # cannot steal this port base while we are still using it.
  mkdir -p "/tmp/transition-test-reserved-${PORT_BASE}" 2>/dev/null || true
  for n in 1 2 3; do
    local d; d=$(val_dir "$n")
    rm -rf "${d}/geth" "${d}/geth.ipc" "${d}/geth.log" "${d}/geth.pid"
  done
  rm -f "${DATADIR_ROOT}/override.toml"
  rm -f "${GENESIS_JSON}"
  log "partial_clean: chain data removed, keystores preserved"
}

# find_free_port_base: pick a PORT_BASE where all test ports are free.
# Uses a sentinel dir in /tmp to prevent races between parallel runs.
find_free_port_base() {
  local candidates=(30381 30382 30383 30384 8581 8582 8583 8591 8592 8593)
  for base in $(seq 0 100 9900); do
    local ok=1
    for rel in "${candidates[@]}"; do
      local port=$((rel + base))
      if ss -tunlp 2>/dev/null | grep -q ":${port}[[:space:]]" || nc -z 127.0.0.1 "$port" 2>/dev/null || nc -uz 127.0.0.1 "$port" 2>/dev/null; then
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

# persisted_head_number <datadir>
#
# Reads the on-disk head block number for a stopped geth datadir. Pure offline
# read using `geth db metadata` (gives head block hash) plus `geth db get H<hash>`
# (rawdb headerNumberPrefix maps hash → uint64 big-endian). Does not start a
# geth process, so it is fast (~1s) and side-effect-free.
#
# Echoes the head block number as a decimal string on stdout, or empty on
# failure. The caller must distinguish "no datadir / no chain yet" from "real
# error" via context.
persisted_head_number() {
  local datadir="$1"
  [[ -d "${datadir}/geth/chaindata" ]] || return 1

  # 1. Pull head hash from the metadata table (LastHeader pebble key).
  local hash
  hash=$("$GETH" db metadata --datadir "$datadir" 2>/dev/null \
    | awk -F'|' '/headBlockHash/ { gsub(/[ \t]/, "", $3); print $3; exit }')
  [[ "$hash" =~ ^0x[0-9a-fA-F]{64}$ ]] || return 1

  # 2. Look up the block number for that hash.
  #    rawdb key: headerNumberPrefix ("H" = 0x48) + 32-byte hash
  #    Value:     8-byte big-endian uint64
  local key value
  key="0x48${hash#0x}"
  value=$("$GETH" db get --datadir "$datadir" "$key" 2>/dev/null \
    | awk '/^key /{ sub(/^.*: /,""); print; exit }')
  [[ "$value" =~ ^0x[0-9a-fA-F]+$ ]] || return 1

  # Convert hex (lowercase, no 0x) to decimal.
  printf '%d\n' "$value"
}

# stop_below_pgb_or_die <ceiling>
#
# Stops every running validator under DATADIR_ROOT, then asserts that no
# validator's persisted on-disk head reached <ceiling>.
#
# Why this matters: scripts that restart the network with a new
# OverrideParliaGenesisBlock = ceiling assume every validator's on-disk head
# is < ceiling. With Clique period=1s and serial SIGTERM, the
# convergence-check → SIGTERM window can easily cross the fork block: a
# validator may seal one more Clique-form block at height==ceiling between
# the convergence check and the SIGTERM landing, persist it to disk, and then
# exit. After restart with the new chain config, that block is re-interpreted
# under Parlia rules — extraData fails errInvalidSpanValidators — and the
# chain deadlocks at the fork block forever.
#
# This helper turns that silent corruption into an immediate, descriptive
# test failure. It must be called *instead of* 03-stop.sh, before writing
# any TOML override.
#
# Implementation: stop all validators FIRST (via 03-stop.sh, which sends
# SIGTERM and waits for graceful exit), then read each validator's persisted
# disk head via `geth db metadata` + `geth db get`. This gives the *real*
# upper bound on what landed on disk — covering the race window where a
# validator seals one extra block after any pre-stop snapshot but before
# its SIGTERM lands. (The earlier in-memory pre-stop snapshot was vulnerable
# to exactly this race; flagged by Copilot review on PR #84.)
stop_below_pgb_or_die() {
  local ceiling="$1"
  [[ "$ceiling" =~ ^[0-9]+$ ]] || die "stop_below_pgb_or_die: ceiling must be a non-negative integer (got: ${ceiling})"

  # Collect names of validators that were running before stop, so we can
  # cross-check we successfully read disk head for each of them.
  local -a expected_names
  shopt -s nullglob
  for pidfile in "${DATADIR_ROOT}"/validator-*/geth.pid; do
    local name pid
    name=$(basename "$(dirname "$pidfile")")
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      expected_names+=("$name")
    fi
  done
  shopt -u nullglob

  # Stop all validators first. SIGTERM gives geth a chance to flush in-memory
  # head to disk gracefully; the disk read below is the actual invariant check.
  "${SCRIPT_DIR}/03-stop.sh"

  # Now read each validator's persisted head from disk and compare to ceiling.
  # Because the geth process has fully exited, this is the authoritative
  # answer about what landed on chain — not a probabilistic in-memory snapshot.
  local -a violators=() unreadable=()
  for name in "${expected_names[@]:-}"; do
    [[ -n "$name" ]] || continue
    local datadir="${DATADIR_ROOT}/${name}"
    local h
    h=$(persisted_head_number "$datadir" 2>/dev/null || echo "")
    if [[ -z "$h" ]]; then
      # Reading disk head should always succeed for a stopped node that was
      # previously running and producing blocks. Treat read failure as a
      # check failure rather than silently skipping (Copilot review on PR #84).
      unreadable+=("${name}")
      continue
    fi
    if [[ "$h" -ge "$ceiling" ]]; then
      violators+=("${name} head=${h}")
    fi
  done

  if [[ ${#unreadable[@]} -gt 0 ]]; then
    die "stop_below_pgb_or_die: could not read persisted head for: $(IFS=', '; echo "${unreadable[*]}"). Refusing to proceed without verifying the stop-window invariant."
  fi
  if [[ ${#violators[@]} -gt 0 ]]; then
    die "stop_below_pgb_or_die: $(IFS=', '; echo "${violators[*]}") reached or passed PGB ceiling=${ceiling} on disk after stop. The chain crossed the fork block during the stop window — restarting with the new chain config would deadlock. Increase PRE_STOP buffer, choose a higher PARLIA_GENESIS_BLOCK, or stop nodes earlier."
  fi
}
