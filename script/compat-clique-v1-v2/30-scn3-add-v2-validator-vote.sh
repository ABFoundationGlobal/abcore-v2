#!/usr/bin/env bash
set -euo pipefail

# Scenario 3:
# - add a new v2 validator
# - vote it in via clique.propose
# - confirm it seals blocks

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries
require_file "${GENESIS_JSON}"

N=4
V4_DIR=$(val_dir "$N")
V4_IPC=$(val_ipc "$N")
V4_PID=$(val_pid "$N")
V4_LOG=$(val_log "$N")
V4_PW=$(val_pw "$N")

mkdir -p "$V4_DIR"

if [[ ! -f "$V4_PW" ]]; then
  printf "password\n" >"$V4_PW"
fi

if [[ ! -f "${V4_DIR}/address.txt" ]]; then
  log "Creating validator-4 account (v2)"
  out=$("$ABCORE_V2_GETH" account new --datadir "$V4_DIR" --password "$V4_PW")
  addr=$(echo "$out" | grep -oE "0x[0-9a-fA-F]{40}" | head -n1 || true)
  [[ -n "$addr" ]] || die "failed to parse validator-4 address: $out"
  echo "$addr" >"${V4_DIR}/address.txt"
fi
V4_ADDR=$(cat "${V4_DIR}/address.txt")
log "validator-4 address: ${V4_ADDR}"

if [[ ! -d "${V4_DIR}/geth" ]]; then
  log "Initializing validator-4 datadir"
  "$ABCORE_V2_GETH" init --datadir "$V4_DIR" "${GENESIS_JSON}"
fi

# Start validator-4 as a syncing node (not mining yet).
if [[ -f "$V4_PID" ]] && kill -0 "$(cat "$V4_PID")" >/dev/null 2>&1; then
  log "validator-4 already running (pid=$(cat "$V4_PID"))"
else
  log "Starting validator-4 (v2) syncing only"
  (
    cd "$REPO_ROOT"
    nohup "$ABCORE_V2_GETH" \
      --datadir "$V4_DIR" \
      --networkid "$CLIQUE_NETWORK_ID" \
      --port 30326 \
      --nat none \
      --nodiscover \
      --bootnodes "" \
      --ipcpath geth.ipc \
      --syncmode full \
      --nousb \
      >>"$V4_LOG" 2>&1 &
    echo $! >"$V4_PID"
  )
fi

wait_for_ipc "$ABCORE_V2_GETH" "$V4_IPC"

# Peer it to validator-1.
ENODE1=$(get_enode "$ABCORE_V1_GETH" "$(val_ipc 1)")
add_peer "$ABCORE_V2_GETH" "$V4_IPC" "$ENODE1" >/dev/null || true

# Vote it in: need majority (2/3) proposals.
log "Proposing new signer on validator-1 and validator-3"
attach_exec "$ABCORE_V1_GETH" "$(val_ipc 1)" "clique.propose('${V4_ADDR}', true)" >/dev/null
attach_exec "$ABCORE_V1_GETH" "$(val_ipc 3)" "clique.propose('${V4_ADDR}', true)" >/dev/null

log "Waiting for validator-4 to appear in clique.getSigners()"
for ((i=0; i<120; i++)); do
  signers=$(attach_exec "$ABCORE_V1_GETH" "$(val_ipc 1)" "JSON.stringify(clique.getSigners())" || true)
  if echo "$signers" | grep -qi "$V4_ADDR"; then
    log "validator-4 is now an authorized signer"
    break
  fi
  sleep 1

done

signers=$(attach_exec "$ABCORE_V1_GETH" "$(val_ipc 1)" "JSON.stringify(clique.getSigners())" || true)
if ! echo "$signers" | grep -qi "$V4_ADDR"; then
  die "validator-4 never became an authorized signer"
fi

# Restart validator-4 with mining enabled.
log "Restarting validator-4 with mining enabled"
stop_pidfile "$V4_PID"
(
  cd "$REPO_ROOT"
  nohup "$ABCORE_V2_GETH" \
    --datadir "$V4_DIR" \
    --networkid "$CLIQUE_NETWORK_ID" \
    --port 30326 \
    --nat none \
    --nodiscover \
    --bootnodes "" \
    --ipcpath geth.ipc \
    --syncmode full \
    --mine \
    --miner.etherbase "$V4_ADDR" \
    --unlock "$V4_ADDR" \
    --password "$V4_PW" \
    --nousb \
    >>"$V4_LOG" 2>&1 &
  echo $! >"$V4_PID"
)
wait_for_ipc "$ABCORE_V2_GETH" "$V4_IPC"

# Ensure it's peered.
add_peer "$ABCORE_V2_GETH" "$V4_IPC" "$ENODE1" >/dev/null || true

log "Waiting for validator-4 to seal at least one recent block"
wait_for_recent_signer "$ABCORE_V1_GETH" "$(val_ipc 1)" "$V4_ADDR" 180

# All nodes should still be on same head.
assert_same_head "$ABCORE_V1_GETH" "$(val_ipc 1)" \
  "$ABCORE_V2_GETH" "$(val_ipc 2)" \
  "$ABCORE_V1_GETH" "$(val_ipc 3)" \
  "$ABCORE_V2_GETH" "$V4_IPC"

log "Scenario 3 OK"