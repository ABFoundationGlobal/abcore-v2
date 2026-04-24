#!/usr/bin/env bash
# T-5: Single-node rolling restart while chain is in Parlia mode.
#
# Scenario: one of the three validators (val-2) goes offline after the Parlia
# fork has completed and the chain has advanced well past the fork block.
# The remaining two validators (val-1, val-3) maintain the 2-of-3 quorum and
# continue sealing Parlia blocks.  val-2 then restarts with the same TOML
# config, syncs the missed blocks from peers, and resumes block production.
#
# Steps:
#   1. Setup: generate accounts + Clique genesis + init datadirs
#   2. Start 3 validators in Clique mode; wait for stable pre-fork history
#   3. Stop all; write TOML with OverrideParliaGenesisBlock; restart (with
#      deadlock-recovery loop identical to T-1)
#   4. Advance all 3 nodes to WELL_PAST_FORK = PGB+20 in Parlia mode
#   5. Stop val-2; let val-1 and val-3 produce OFFLINE_BLOCKS (≥10) more blocks
#   6. Restart val-2 with the same TOML; wire it into the peer mesh
#   7. Wait for val-2 to catch up to the canonical tip
#   8. Assert all 3 nodes agree on the same chain hash
#   9. Assert val-2's miner address appears in the Parlia sealer rotation
#  10. Run post-fork verification checks (05-verify.sh)
#
# Environment:
#   PARLIA_GENESIS_BLOCK  fork block height (default: 20)
#   OFFLINE_BLOCKS        Parlia blocks produced while val-2 is down (default: 12)
#   PORT_BASE             base port offset; auto-selected if unset
#   DATADIR_ROOT          test data directory; auto-selected if unset
#   KEEP_RUNNING=1        leave nodes up after PASS (for manual inspection)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

# Build v2 binary if no explicit path provided (local dev workflow).
# In CI, GETH is set to the pre-built binary and this is skipped.
if [[ -z "${GETH:-}" ]]; then
  echo "[$(date +'%H:%M:%S')] Building v2 binary (set GETH=... to skip)..."
  (cd "${_REPO_ROOT}" && CGO_CFLAGS="-O -D__BLST_PORTABLE__" CGO_CFLAGS_ALLOW="-O -D__BLST_PORTABLE__" make geth)
fi

_PORT_BASE_EXPLICIT=${PORT_BASE+set}
_DATADIR_ROOT_EXPLICIT=${DATADIR_ROOT+set}

source "${SCRIPT_DIR}/lib.sh"

if [[ "${_PORT_BASE_EXPLICIT}" != "set" ]]; then
  PORT_BASE=$(find_free_port_base)
  log "Auto-selected PORT_BASE=${PORT_BASE}"
fi
export PORT_BASE

if [[ "${_DATADIR_ROOT_EXPLICIT:-}" != "set" ]]; then
  export DATADIR_ROOT="${SCRIPT_DIR}/data-${PORT_BASE}"
fi

OFFLINE_BLOCKS=${OFFLINE_BLOCKS:-12}
TOML_CONFIG="${DATADIR_ROOT}/override.toml"

# Key block heights
PRE_STOP=$(( PARLIA_GENESIS_BLOCK - 5 ))
if [[ "$PRE_STOP" -lt 5 ]]; then PRE_STOP=5; fi
WELL_PAST_FORK=$(( PARLIA_GENESIS_BLOCK + 20 ))
OFFLINE_UNTIL=$(( WELL_PAST_FORK + OFFLINE_BLOCKS ))

log "T-5 single-node rolling restart"
log "  PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK}, OFFLINE_BLOCKS=${OFFLINE_BLOCKS}"
log "  PRE_STOP=${PRE_STOP}, WELL_PAST_FORK=${WELL_PAST_FORK}, OFFLINE_UNTIL=${OFFLINE_UNTIL}"

cleanup_on_exit() {
  local code=$?
  if [[ "$code" -ne 0 ]]; then
    echo
    if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
      echo "FAILED (exit=${code}). KEEP_RUNNING=1 — nodes remain running (logs: ${DATADIR_ROOT})." >&2
    else
      echo "FAILED (exit=${code}). Stopping nodes (logs preserved: ${DATADIR_ROOT})." >&2
      "${SCRIPT_DIR}/03-stop.sh" || true
    fi
  fi
  exit "$code"
}
trap cleanup_on_exit EXIT

run() {
  echo
  echo "==> $*"
  "$@"
}

pass() { log "  OK: $*"; }
fail() { die "FAIL: $*"; }

# ── Phase 1: setup ────────────────────────────────────────────────────────────
run "${SCRIPT_DIR}/04-clean.sh"
run "${SCRIPT_DIR}/01-setup.sh"

# ── Phase 2: start Clique network ────────────────────────────────────────────
run "${SCRIPT_DIR}/02-start.sh"

# ── Phase 3: wait for stable Clique history before the fork block ─────────────
log "Waiting for all 3 nodes to reach block ${PRE_STOP} (Clique history before fork)..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$PRE_STOP" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

wait_for_same_head --min-height "$PRE_STOP" "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

current=$(head_number "$GETH" "$(val_ipc 1)")
log "All nodes converged at block ${current}. Stopping validators..."

# ── Phase 4: stop all validators ─────────────────────────────────────────────
run "${SCRIPT_DIR}/03-stop.sh"
# Re-acquire sentinel released by 03-stop.sh so parallel runs cannot steal
# this port base while we write the TOML and restart.
mkdir "/tmp/transition-test-reserved-${PORT_BASE}" 2>/dev/null || true

# ── Phase 5: write TOML override and restart (with deadlock recovery) ─────────
log "Writing TOML override config: ${TOML_CONFIG}"
mkdir -p "${DATADIR_ROOT}"
cat > "${TOML_CONFIG}" <<TOML
[Eth]
NetworkId = ${NETWORK_ID}
SyncMode = "full"
OverrideParliaGenesisBlock = ${PARLIA_GENESIS_BLOCK}

[Eth.Miner]
GasPrice = 1000000000

[Node]
InsecureUnlockAllowed = true
NoUSB = true
TOML

# Deadlock-recovery restart loop — see 99-run-all.sh for detailed explanation.
_restart_attempt=0
while true; do
  _restart_attempt=$(( _restart_attempt + 1 ))
  log "Restart attempt ${_restart_attempt}: starting validators with ParliaGenesisBlock=${PARLIA_GENESIS_BLOCK}..."
  TOML_CONFIG="${TOML_CONFIG}" "${SCRIPT_DIR}/02-start.sh"

  _head_before=$(head_number "$GETH" "$(val_ipc 1)")
  _target=$(( _head_before + 2 ))
  if [[ "$(( PARLIA_GENESIS_BLOCK + 2 ))" -gt "$_target" ]]; then
    _target=$(( PARLIA_GENESIS_BLOCK + 2 ))
  fi
  _deadline=$(( $(date +%s) + 60 ))
  _alive=false
  while [[ $(date +%s) -lt $_deadline ]]; do
    _head_now=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo "$_head_before")
    if [[ "$_head_now" -ge "$_target" ]]; then
      _alive=true
      break
    fi
    sleep 2
  done

  if "$_alive"; then
    log "Chain is advancing (head=${_head_now} >= target=${_target}). Restart successful."
    break
  fi

  if [[ "$_restart_attempt" -ge 5 ]]; then
    die "chain did not advance after ${_restart_attempt} restart attempts — giving up"
  fi

  _head_now=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo "$_head_before")
  log "WARNING: chain stalled at head=${_head_now} (seal-race deadlock). Stopping for retry..."
  "${SCRIPT_DIR}/03-stop.sh"
  mkdir "/tmp/transition-test-reserved-${PORT_BASE}" 2>/dev/null || true
done

# ── Phase 6: advance all 3 nodes well past the fork ──────────────────────────
post_restart_head=$(head_number "$GETH" "$(val_ipc 1)")
log "Waiting for all nodes to converge post-restart (min-height=${post_restart_head})..."
wait_for_same_head --min-height "$post_restart_head" "$GETH" "$(val_ipc 1)" 120 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

log "Waiting for all 3 nodes to reach block ${WELL_PAST_FORK} (Parlia, well past fork)..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$WELL_PAST_FORK" 180 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

wait_for_same_head --min-height "$WELL_PAST_FORK" "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

log "All 3 nodes at block ${WELL_PAST_FORK} in Parlia mode. Taking val-2 offline..."

# ── Phase 7: stop val-2 ───────────────────────────────────────────────────────
V2_PID_FILE=$(val_pid 2)
V2_PID=$(cat "$V2_PID_FILE" 2>/dev/null || true)
if [[ -n "$V2_PID" ]] && kill -0 "$V2_PID" 2>/dev/null; then
  log "Stopping val-2 (pid=${V2_PID})"
  kill "$V2_PID"
  _deadline=$(( $(date +%s) + 30 ))
  while kill -0 "$V2_PID" 2>/dev/null && [[ $(date +%s) -lt $_deadline ]]; do
    sleep 0.3
  done
  kill -9 "$V2_PID" 2>/dev/null || true
  rm -f "$V2_PID_FILE"
  log "val-2 offline."
else
  log "WARNING: val-2 was not running"
fi
# Remove stale IPC socket so wait_for_ipc gets a fresh connect on restart.
rm -f "$(val_ipc 2)"

# ── Phase 8: let val-1 and val-3 produce OFFLINE_BLOCKS more blocks ───────────
log "val-1 and val-3 sealing while val-2 is offline (target: block ${OFFLINE_UNTIL})..."
_pids=()
for n in 1 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$OFFLINE_UNTIL" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
log "val-1 and val-3 at block ${OFFLINE_UNTIL} (${OFFLINE_BLOCKS} blocks produced without val-2)."

# ── Phase 9: restart val-2 with the same TOML ────────────────────────────────
log "Restarting val-2 (local DB: last block ~${WELL_PAST_FORK}; network tip: ~${OFFLINE_UNTIL})..."

V2_DIR=$(val_dir 2)
V2_ADDR=$(val_addr 2)
V2_PW=$(val_pw 2)
V2_P2P=$(p2p_port 2)
V2_HTTP=$(http_port 2)
V2_LOG=$(val_log 2)

(
  nohup "$GETH" \
    --config "$TOML_CONFIG" \
    --datadir "$V2_DIR" \
    --networkid "$NETWORK_ID" \
    --port "$V2_P2P" \
    --nat none \
    --nodiscover \
    --bootnodes "" \
    --ipcpath geth.ipc \
    --http \
    --http.addr 127.0.0.1 \
    --http.port "$V2_HTTP" \
    --http.api "eth,net,web3,clique,parlia,admin,personal,miner" \
    --syncmode full \
    --mine \
    --miner.etherbase "$V2_ADDR" \
    --unlock "$V2_ADDR" \
    --password "$V2_PW" \
    --allow-insecure-unlock \
    --nousb \
    >>"$V2_LOG" 2>&1 &
  echo $! > "$V2_PID_FILE"
)

log "Waiting for val-2 IPC..."
wait_for_ipc "$GETH" "$(val_ipc 2)" 60

# Re-wire val-2 into the peer mesh; the other nodes will not rediscover it
# automatically (nodiscover is set).
ENODE1=$(get_enode "$GETH" "$(val_ipc 1)")
ENODE3=$(get_enode "$GETH" "$(val_ipc 3)")
add_peer "$GETH" "$(val_ipc 2)" "$ENODE1" >/dev/null || true
add_peer "$GETH" "$(val_ipc 2)" "$ENODE3" >/dev/null || true
add_peer "$GETH" "$(val_ipc 1)" "$(get_enode "$GETH" "$(val_ipc 2)")" >/dev/null || true
add_peer "$GETH" "$(val_ipc 3)" "$(get_enode "$GETH" "$(val_ipc 2)")" >/dev/null || true

wait_for_min_peers "$GETH" "$(val_ipc 2)" 1 30

# ── Phase 10: wait for val-2 to catch up ─────────────────────────────────────
log "Waiting for val-2 to catch up to block ${OFFLINE_UNTIL}..."
wait_for_head_at_least "$GETH" "$(val_ipc 2)" "$OFFLINE_UNTIL" 180

log "Waiting for all 3 nodes to converge on the same head..."
wait_for_same_head --min-height "$OFFLINE_UNTIL" "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

converged=$(head_number "$GETH" "$(val_ipc 1)")
log "All 3 nodes converged at block ${converged}."

# ── Phase 11: assertions ──────────────────────────────────────────────────────
log "Running assertions..."

# 1. All nodes agree on hash at OFFLINE_UNTIL
assert_same_hash_at "$OFFLINE_UNTIL" \
  "$GETH" "$(val_ipc 1)" \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"
pass "all 3 nodes agree on hash at block ${OFFLINE_UNTIL}"

# 2. val-2's miner address appears in the Parlia sealer rotation after catch-up.
# In Parlia each validator seals every N-th block (N=validator count).  In a
# 3-validator set val-2 should appear roughly every 3 blocks; checking the last
# 20 blocks gives ample margin after the sync completes.
LOOKBACK=20
PARLIA_REJOIN_TIMEOUT=120
V2_ADDR_LOWER=$(echo "$V2_ADDR" | tr '[:upper:]' '[:lower:]')
log "Waiting for val-2 (${V2_ADDR}) to appear in Parlia sealer rotation (last ${LOOKBACK} blocks)..."

_found=false
_deadline=$(( $(date +%s) + PARLIA_REJOIN_TIMEOUT ))
while [[ $(date +%s) -lt $_deadline ]]; do
  tip=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo 0)
  _start=$(( tip > LOOKBACK ? tip - LOOKBACK : 0 ))
  for ((blk=tip; blk>=_start; blk--)); do
    miner=$(attach_exec "$GETH" "$(val_ipc 1)" "eth.getBlock(${blk}).miner" 2>/dev/null \
      | tr '[:upper:]' '[:lower:]' || true)
    if [[ "$miner" == "$V2_ADDR_LOWER" ]]; then
      log "val-2 (${V2_ADDR}) sealed block ${blk} — rejoined sealer rotation."
      _found=true
      break 2
    fi
  done
  sleep 2
done
"$_found" || fail "val-2 miner address not seen in last ${LOOKBACK} Parlia blocks within ${PARLIA_REJOIN_TIMEOUT}s"
pass "val-2 is participating in Parlia block production"

# ── Phase 12: post-fork verification ─────────────────────────────────────────
run "${SCRIPT_DIR}/05-verify.sh"

# ── Phase 13: stop ───────────────────────────────────────────────────────────
if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo
  echo "PASS. KEEP_RUNNING=1 — nodes remain running."
  exit 0
fi

echo
echo "==> Stopping nodes"
"${SCRIPT_DIR}/03-stop.sh"

echo
echo "PASS"
