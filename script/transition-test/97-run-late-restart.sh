#!/usr/bin/env bash
# T-1.5: Late-restart scenario — node stops before the fork block and restarts
# after the chain has already crossed it.
#
# Scenario 3 from the fork-crossing analysis:
#   A validator stops at block <N (e.g. hardware fault during the upgrade window).
#   When it restarts, the other validators have already produced blocks past N.
#   The late-starter must sync Clique blocks up to N-1, deploy system contracts at
#   N, run the DualConsensus snapshot reseed path (parlia.go:932-972), then verify
#   Parlia blocks N+1..tip and finally participate in block production.
#
# Steps:
#   1. Setup: generate accounts + Clique genesis + init datadirs
#   2. Start 3 validators with TOML ParliaGenesisBlock=N
#   3. Wait for val-3 to reach a few Clique blocks (<<N), then stop it
#   4. Let val-1 and val-2 cross the fork and reach N+15
#   5. Restart val-3 (same TOML config, same PGB=N); its local DB has only
#      pre-fork Clique blocks; network head is already in Parlia territory
#   6. Wait for val-3 to sync through the fork and catch up
#   7. Assert all 3 nodes agree on the same block hash
#
# Environment:
#   PARLIA_GENESIS_BLOCK  block at which the fork fires (default: 20)
#   PORT_BASE             base port offset; auto-selected if unset
#   KEEP_RUNNING=1        leave nodes up after PASS
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

TOML_CONFIG="${DATADIR_ROOT}/override.toml"

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

# ── Phase 1: setup ────────────────────────────────────────────────────────────
run "${SCRIPT_DIR}/04-clean.sh"
run "${SCRIPT_DIR}/01-setup.sh"

# ── Phase 2: write TOML with ParliaGenesisBlock and start all 3 validators ───
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

log "Starting 3 validators with ParliaGenesisBlock=${PARLIA_GENESIS_BLOCK}"
echo
echo "==> ${SCRIPT_DIR}/02-start.sh"
TOML_CONFIG="${TOML_CONFIG}" "${SCRIPT_DIR}/02-start.sh"

# ── Phase 3: wait for a few Clique blocks, then stop val-3 BEFORE the fork ───
# The scenario: val-3 goes offline while the chain is still in Clique mode.
# val-1 and val-2 will cross the fork block on their own; val-3 restarts later
# when the chain is already in Parlia territory.
PRE_STOP=$(( PARLIA_GENESIS_BLOCK / 2 ))
if [[ "$PRE_STOP" -lt 3 ]]; then PRE_STOP=3; fi
log "Waiting for val-3 to reach block ${PRE_STOP} (pre-fork Clique), then stopping it..."
wait_for_head_at_least "$GETH" "$(val_ipc 3)" "$PRE_STOP" 60

V3_PID_FILE=$(val_pid 3)
V3_PID=$(cat "$V3_PID_FILE" 2>/dev/null || true)
if [[ -n "$V3_PID" ]] && kill -0 "$V3_PID" 2>/dev/null; then
  log "Stopping val-3 at pre-fork block (pid=${V3_PID})"
  kill "$V3_PID"
  local_deadline=$(( $(date +%s) + 30 ))
  while kill -0 "$V3_PID" 2>/dev/null && [[ $(date +%s) -lt $local_deadline ]]; do
    sleep 0.3
  done
  kill -9 "$V3_PID" 2>/dev/null || true
  rm -f "$V3_PID_FILE"
  log "val-3 offline. Last known head ≈ ${PRE_STOP} (pre-fork)."
else
  log "WARNING: val-3 was not running"
fi

# Remove val-3's IPC socket so wait_for_ipc below gets a fresh connect.
rm -f "$(val_ipc 3)"

# ── Phase 4: advance val-1 and val-2 past the fork block ─────────────────────
AHEAD=$(( PARLIA_GENESIS_BLOCK + 15 ))
log "Waiting for val-1 and val-2 to reach block ${AHEAD} (past fork) while val-3 is down..."
_pids=()
for n in 1 2; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$AHEAD" 180 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
log "val-1 and val-2 at block ${AHEAD} (Parlia). val-3 still offline at pre-fork height."

# ── Phase 5: restart val-3 with same TOML (chain is already >N) ──────────────
# val-3's local DB has only Clique blocks up to ~PRE_STOP.
# On restart it must: sync Clique blocks up to N-1, process fork block N
# (system contract deployment), run the DualConsensus snapshot reseed path
# (parlia.go:932-972), then verify Parlia blocks N+1..AHEAD and mine.
log "Restarting val-3 (local DB: pre-fork Clique only; network head: ${AHEAD}, past ParliaGenesisBlock=${PARLIA_GENESIS_BLOCK})"

V3_DIR=$(val_dir 3)
V3_ADDR=$(val_addr 3)
V3_PW=$(val_pw 3)
V3_P2P=$(p2p_port 3)
V3_HTTP=$(http_port 3)
V3_LOG=$(val_log 3)

(
  nohup "$GETH" \
    --config "$TOML_CONFIG" \
    --datadir "$V3_DIR" \
    --networkid "$NETWORK_ID" \
    --port "$V3_P2P" \
    --nat none \
    --nodiscover \
    --bootnodes "" \
    --ipcpath geth.ipc \
    --http \
    --http.addr 127.0.0.1 \
    --http.port "$V3_HTTP" \
    --http.api "eth,net,web3,clique,parlia,admin,personal,miner" \
    --syncmode full \
    --mine \
    --miner.etherbase "$V3_ADDR" \
    --unlock "$V3_ADDR" \
    --password "$V3_PW" \
    --allow-insecure-unlock \
    --nousb \
    >>"$V3_LOG" 2>&1 &
  echo $! > "$V3_PID_FILE"
)

log "Waiting for val-3 IPC..."
wait_for_ipc "$GETH" "$(val_ipc 3)" 60

# Re-wire val-3 into the peer mesh (the other two nodes may not rediscover it).
ENODE1=$(get_enode "$GETH" "$(val_ipc 1)")
ENODE2=$(get_enode "$GETH" "$(val_ipc 2)")
add_peer "$GETH" "$(val_ipc 3)" "$ENODE1" >/dev/null || true
add_peer "$GETH" "$(val_ipc 3)" "$ENODE2" >/dev/null || true
add_peer "$GETH" "$(val_ipc 1)" "$(get_enode "$GETH" "$(val_ipc 3)")" >/dev/null || true
add_peer "$GETH" "$(val_ipc 2)" "$(get_enode "$GETH" "$(val_ipc 3)")" >/dev/null || true

wait_for_min_peers "$GETH" "$(val_ipc 3)" 1 30

# ── Phase 6: wait for val-3 to sync and all 3 to converge ────────────────────
# val-3 needs to sync Clique history up to N-1, cross the fork, then Parlia
# blocks N+1..AHEAD. Give generous time since it processes the full range.
CATCHUP=$(( AHEAD ))
log "Waiting for val-3 to catch up to block ${CATCHUP}..."
wait_for_head_at_least "$GETH" "$(val_ipc 3)" "$CATCHUP" 180

log "Waiting for all 3 nodes to converge on the same head..."
wait_for_same_head --min-height "$CATCHUP" "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

converged=$(head_number "$GETH" "$(val_ipc 1)")
log "All 3 nodes converged at block ${converged} (including val-3 late-restart)."

# ── Phase 7: verify ───────────────────────────────────────────────────────────
run "${SCRIPT_DIR}/05-verify.sh"

# ── Phase 8: stop and clean ───────────────────────────────────────────────────
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
