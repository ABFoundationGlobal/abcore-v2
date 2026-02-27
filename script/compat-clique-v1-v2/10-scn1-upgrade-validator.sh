#!/usr/bin/env bash
set -euo pipefail

# Scenario 1:
# - stop an old (v1) validator
# - relaunch it with v2 binary using the same datadir
# - it should validate and also be able to seal blocks

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

N=${UPGRADE_VALIDATOR_N:-2}
[[ "$N" -ge 1 && "$N" -le 3 ]] || die "UPGRADE_VALIDATOR_N must be 1..3"

pidfile=$(val_pid "$N")
[[ -f "$pidfile" ]] || die "validator-${N} not running (missing pidfile ${pidfile}); run ./02-start-v1-validators.sh first"

log "Stopping v1 validator-${N}"
stop_pidfile "$pidfile"

addr=$(val_addr "$N")
pwfile=$(val_pw "$N")
p2p=$(p2p_port "$N")
logfile=$(val_log "$N")

dir=$(val_dir "$N")

log "Starting validator-${N} with v2 binary (same datadir)"
(
  cd "$REPO_ROOT"
  nohup "$ABCORE_V2_GETH" \
    --datadir "$dir" \
    --networkid "$CLIQUE_NETWORK_ID" \
    --port "$p2p" \
    --nat none \
    --nodiscover \
    --bootnodes "" \
    --ipcpath geth.ipc \
    --syncmode full \
    --mine \
    --miner.etherbase "$addr" \
    --unlock "$addr" \
    --password "$pwfile" \
    --nousb \
    >>"$logfile" 2>&1 &
  echo $! >"$pidfile"
)

wait_for_ipc "$ABCORE_V2_GETH" "$(val_ipc "$N")"

# Ensure it's peered.
ENODE1=$(get_enode "$ABCORE_V1_GETH" "$(val_ipc 1)")
add_peer "$ABCORE_V2_GETH" "$(val_ipc "$N")" "$ENODE1" >/dev/null || true

log "Waiting for chain to advance"
wait_for_blocks "$ABCORE_V1_GETH" "$(val_ipc 1)" 3 90

# Heads should match.
assert_same_head "$ABCORE_V1_GETH" "$(val_ipc 1)" \
  "$ABCORE_V1_GETH" "$(val_ipc 3)" \
  "$ABCORE_V2_GETH" "$(val_ipc "$N")"

# Confirm the upgraded validator sealed at least one recent block.
log "Checking that validator-${N} appears in clique snapshot recents"
wait_for_recent_signer "$ABCORE_V1_GETH" "$(val_ipc 1)" "$addr" 90

log "Scenario 1 OK"