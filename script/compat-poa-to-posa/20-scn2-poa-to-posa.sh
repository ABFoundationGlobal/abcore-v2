#!/usr/bin/env bash
set -euo pipefail

# Scenario 2: Stop validators, restart with node-posa-N.toml (Parlia config),
# and verify the transition at PARLIA_GENESIS_BLOCK.
# Asserts:
#   - chain advances past PARLIA_GENESIS_BLOCK
#   - clique.getSnapshot fails for blocks >= PARLIA_GENESIS_BLOCK + 1
#   - all nodes converge on the same head

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/validator-addrs.env"

ADDRS=("" "$VAL1_ADDR" "$VAL2_ADDR" "$VAL3_ADDR")

# ---- Step 1: Stop all validators ----
log "[scn2] Stopping all validators"
_all_pidfiles=()
for n in 1 2 3; do
  _all_pidfiles+=("$(val_pid "$n")")
done

_live_pids=()
_live_pidfiles=()
for pidfile in "${_all_pidfiles[@]}"; do
  [[ -f "$pidfile" ]] || continue
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    log "  stopping pid ${pid}"
    kill "$pid" 2>/dev/null || true
    _live_pids+=("$pid")
    _live_pidfiles+=("$pidfile")
  else
    rm -f "$pidfile"
  fi
done

if [[ ${#_live_pids[@]} -gt 0 ]]; then
  deadline=$(( $(date +%s) + 30 ))
  for pid in "${_live_pids[@]}"; do
    while kill -0 "$pid" 2>/dev/null && [[ $(date +%s) -lt $deadline ]]; do
      sleep 0.3
    done
    kill -9 "$pid" 2>/dev/null || true
  done
  for pidfile in "${_live_pidfiles[@]}"; do
    rm -f "$pidfile"
  done
fi
log "[scn2] All validators stopped"

# ---- Step 2: Re-init datadirs with Parlia genesis (same block hash, updated config) ----
log "[scn2] Running geth init with genesis-posa.json to apply upgrade config"
for n in 1 2 3; do
  "${ABCORE_V2_GETH}" init --datadir "$(val_dir "$n")" "${GENESIS_POSA_JSON}" 2>&1 | tail -2
done

# ---- Step 3: Restart with node-posa-N.toml ----
launch_validator_posa() {
  local n="$1"
  local cfg="${SCRIPT_DIR}/config/node-${n}.toml"
  require_file "$cfg"

  local dir addr pwfile logfile pidfile
  dir=$(val_dir "$n")
  addr="${ADDRS[$n]}"
  pwfile=$(val_pw "$n")
  logfile=$(val_log "$n")
  pidfile=$(val_pid "$n")

  log "[scn2] Starting validator-${n} with Parlia config (p2p=$(p2p_port "$n"))"
  (
    cd "${REPO_ROOT}"
    nohup "${ABCORE_V2_GETH}" \
      --config "$cfg" \
      --mine \
      --miner.etherbase "$addr" \
      --unlock "$addr" \
      --password "$pwfile" \
      --allow-insecure-unlock \
      >>"$logfile" 2>&1 &
    echo $! >"$pidfile"
  )
}

for n in 1 2 3; do
  launch_validator_posa "$n"
done

# Wait for IPC sockets.
_ipc_pids=()
for n in 1 2 3; do
  wait_for_ipc "${ABCORE_V2_GETH}" "$(val_ipc "$n")" 90 &
  _ipc_pids+=($!)
done
for _pid in "${_ipc_pids[@]}"; do wait "$_pid"; done

# Re-wire peer mesh (new process, new peer table).
ENODE1=$(get_enode "${ABCORE_V2_GETH}" "$(val_ipc 1)")
ENODE2=$(get_enode "${ABCORE_V2_GETH}" "$(val_ipc 2)")
ENODE3=$(get_enode "${ABCORE_V2_GETH}" "$(val_ipc 3)")

log "[scn2] Re-wiring peers"
for src in 1 2 3; do
  ipc=$(val_ipc "$src")
  add_peer "${ABCORE_V2_GETH}" "$ipc" "$ENODE1" >/dev/null || true
  add_peer "${ABCORE_V2_GETH}" "$ipc" "$ENODE2" >/dev/null || true
  add_peer "${ABCORE_V2_GETH}" "$ipc" "$ENODE3" >/dev/null || true
done

_peer_pids=()
for src in 1 2 3; do
  wait_for_min_peers "${ABCORE_V2_GETH}" "$(val_ipc "$src")" 2 30 &
  _peer_pids+=($!)
done
for _pid in "${_peer_pids[@]}"; do wait "$_pid"; done

# ---- Step 3: Wait for chain to advance past PARLIA_GENESIS_BLOCK ----
TARGET=$(( PARLIA_GENESIS_BLOCK + 3 ))
log "[scn2] Waiting for head >= ${TARGET} (PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK})"
wait_for_head_at_least "${ABCORE_V2_GETH}" "$(val_ipc 1)" "$TARGET" 120

for n in 1 2 3; do
  h=$(head_number "${ABCORE_V2_GETH}" "$(val_ipc "$n")")
  log "validator-${n}: head=${h}"
done

# ---- Step 4: Assert clique.getSnapshot fails for Parlia blocks ----
PARLIA_BLOCK=$(( PARLIA_GENESIS_BLOCK + 1 ))
log "[scn2] Verifying clique.getSnapshot returns error for block ${PARLIA_BLOCK} (Parlia phase)"
snap=$(attach_exec "${ABCORE_V2_GETH}" "$(val_ipc 1)" \
  "JSON.stringify(clique.getSnapshot(${PARLIA_BLOCK}))" 2>&1 || true)
log "  clique.getSnapshot(${PARLIA_BLOCK}) output: ${snap}"
# In Parlia mode clique API calls return an error or empty result.
# Accept any of: empty string, "null", error-containing output.
if echo "$snap" | grep -qiE "^(\{\"number\":)"; then
  die "clique.getSnapshot(${PARLIA_BLOCK}) unexpectedly returned a valid snapshot — Parlia switch may not have occurred"
fi
log "[scn2] clique.getSnapshot correctly fails for Parlia-phase block"

# ---- Step 5: Verify all nodes converge ----
log "[scn2] Waiting for all nodes to converge"
wait_for_same_head "${ABCORE_V2_GETH}" "$(val_ipc 1)" 60 \
  "${ABCORE_V2_GETH}" "$(val_ipc 2)" \
  "${ABCORE_V2_GETH}" "$(val_ipc 3)"

log "[scn2] PASS: Parlia switch occurred at block ${PARLIA_GENESIS_BLOCK}, all nodes converged"
