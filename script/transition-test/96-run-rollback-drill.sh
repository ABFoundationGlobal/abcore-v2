#!/usr/bin/env bash
# T-1.6: Coordinated rollback drill.
#
# Scenario:
#   1. Reuse the proven T-1 fork path (99-run-all.sh) to cross ParliaGenesisBlock.
#   2. Record the last pre-fork Clique block hash (N-1), the post-fork Parlia block hash (N),
#      and the Clique validator set anchored at N-1.
#   3. Stop all validators, restart them in maintenance mode with the same PGB=N config,
#      and rewind each local chain to N-1 via debug.setHead().
#   4. Stop again and restart without the Parlia override (pure Clique).
#   5. Verify the canonical chain at N-1 is preserved, block N is re-mined under Clique,
#      the ValidatorSet system contract is absent at block N, and the validator set matches
#      the original Clique signers.
#
# This is the operational rollback path for "fork crossed, chain needs to return to Clique".
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

if [[ -z "${GETH:-}" ]]; then
  echo "[$(date +'%H:%M:%S')] Building v2 binary (set GETH=... to skip)..."
  (cd "${_REPO_ROOT}" && CGO_CFLAGS="-O -D__BLST_PORTABLE__" CGO_CFLAGS_ALLOW="-O -D__BLST_PORTABLE__" make geth)
fi

_PORT_BASE_EXPLICIT=${PORT_BASE+set}
_DATADIR_ROOT_EXPLICIT=${DATADIR_ROOT+set}
_KEEP_RUNNING=${KEEP_RUNNING:-0}

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
VALIDATOR_CONTRACT="0x0000000000000000000000000000000000001000"
ROLLBACK_TO=$(( PARLIA_GENESIS_BLOCK - 1 ))
POST_FORK_TARGET=$(( PARLIA_GENESIS_BLOCK + 5 ))
POST_ROLLBACK_TARGET=$(( PARLIA_GENESIS_BLOCK + 3 ))

if [[ "${ROLLBACK_TO}" -lt 1 ]]; then
  die "PARLIA_GENESIS_BLOCK must be >= 2"
fi

cleanup_on_exit() {
  local code=$?
  if [[ "$code" -ne 0 ]]; then
    echo
    if [[ "${_KEEP_RUNNING}" -eq 1 ]]; then
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

signers_csv() {
  local ipc="$1"
  local selector="$2"
  attach_exec "$GETH" "$ipc" "(function(){ var vals = clique.getSigners(${selector}) || []; vals = vals.map(function(v){ return v.toLowerCase(); }).sort(); return vals.join(','); })()"
}

start_maintenance_validator() {
  local n="$1"
  local dir p2p logfile pidfile
  dir=$(val_dir "$n")
  p2p=$(p2p_port "$n")
  logfile=$(val_log "$n")
  pidfile=$(val_pid "$n")

  stop_pidfile "$pidfile"

  log "Starting validator-${n} in maintenance mode"
  (
    nohup "$GETH" \
      --config "$TOML_CONFIG" \
      --datadir "$dir" \
      --networkid "$NETWORK_ID" \
      --port "$p2p" \
      --nat none \
      --nodiscover \
      --bootnodes "" \
      --ipcpath geth.ipc \
      --syncmode full \
      --nousb \
      >>"$logfile" 2>&1 &
    echo $! > "$pidfile"
  )
}

start_maintenance_cluster() {
  local _pids=()
  for n in 1 2 3; do
    start_maintenance_validator "$n"
  done
  for n in 1 2 3; do
    wait_for_ipc "$GETH" "$(val_ipc "$n")" 60 &
    _pids+=($!)
  done
  for pid in "${_pids[@]}"; do
    wait "$pid"
  done
}

rewind_validator() {
  local n="$1"
  local target="$2"
  local ipc current deadline
  local target_hex
  ipc=$(val_ipc "$n")
  current=$(head_number "$GETH" "$ipc" 2>/dev/null || echo 0)
  [[ "$current" -gt "$target" ]] || die "validator-${n} head ${current} is not above rollback target ${target}"
  target_hex=$(printf '0x%x' "$target")

  log "Rewinding validator-${n}: ${current} -> ${target}"
  attach_exec "$GETH" "$ipc" "debug.setHead('${target_hex}')" >/dev/null

  deadline=$(( $(date +%s) + 30 ))
  while [[ $(date +%s) -lt $deadline ]]; do
    current=$(head_number "$GETH" "$ipc" 2>/dev/null || echo 0)
    if [[ "$current" -eq "$target" ]]; then
      return 0
    fi
    sleep 1
  done
  die "validator-${n} head did not rewind to ${target}"
}

ROLLBACK_HEX=$(printf '0x%x' "$ROLLBACK_TO")
FORK_HEX=$(printf '0x%x' "$PARLIA_GENESIS_BLOCK")

# ── Phase 1: proven fork path (T-1) ─────────────────────────────────────────
log "Running T-1 fork path and keeping post-fork validators alive for rollback drill..."
KEEP_RUNNING=1 \
PORT_BASE="$PORT_BASE" \
DATADIR_ROOT="$DATADIR_ROOT" \
GETH="$GETH" \
PARLIA_GENESIS_BLOCK="$PARLIA_GENESIS_BLOCK" \
CLIQUE_EPOCH="$CLIQUE_EPOCH" \
"${SCRIPT_DIR}/99-run-all.sh"

IPC1=$(val_ipc 1)

log "Waiting for all validators to remain converged past block ${POST_FORK_TARGET}..."
wait_for_same_head --min-height "$POST_FORK_TARGET" "$GETH" "$IPC1" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

pre_rollback_hash=$(block_hash_at "$GETH" "$IPC1" "$ROLLBACK_TO")
parlia_fork_hash=$(block_hash_at "$GETH" "$IPC1" "$PARLIA_GENESIS_BLOCK")
[[ -n "$pre_rollback_hash" && "$pre_rollback_hash" != "null" ]] || die "rollback anchor block ${ROLLBACK_TO} not found"
[[ -n "$parlia_fork_hash" && "$parlia_fork_hash" != "null" ]] || die "Parlia fork block ${PARLIA_GENESIS_BLOCK} not found"

pre_signers=$(signers_csv "$IPC1" "'${ROLLBACK_HEX}'")
[[ -n "$pre_signers" ]] || die "failed to read Clique signers at block ${ROLLBACK_TO}"

log "Rollback anchor block ${ROLLBACK_TO}: ${pre_rollback_hash}"
log "Post-fork Parlia block ${PARLIA_GENESIS_BLOCK}: ${parlia_fork_hash}"
log "Clique validator set at rollback anchor: $(echo "$pre_signers" | tr ',' ' ')"

# ── Phase 2: coordinated rewind to N-1 ──────────────────────────────────────
run "${SCRIPT_DIR}/03-stop.sh"
require_file "$TOML_CONFIG"
start_maintenance_cluster

for n in 1 2 3; do
  rewind_validator "$n" "$ROLLBACK_TO"
done

assert_same_hash_at "$ROLLBACK_TO" \
  "$GETH" "$IPC1" \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

rewound_hash=$(block_hash_at "$GETH" "$IPC1" "$ROLLBACK_TO")
[[ "$rewound_hash" == "$pre_rollback_hash" ]] || die "rollback anchor hash changed after rewind"
log "All validators rewound to block ${ROLLBACK_TO} with preserved canonical hash"

# ── Phase 3: restart in pure Clique mode ─────────────────────────────────────
run "${SCRIPT_DIR}/03-stop.sh"

log "Restarting validators in pure Clique mode (no Parlia override)..."
TOML_CONFIG="" "${SCRIPT_DIR}/02-start.sh"

log "Waiting for all validators to reach block ${POST_ROLLBACK_TARGET} after rollback..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_ROLLBACK_TARGET" 120 &
  _pids+=($!)
done
for pid in "${_pids[@]}"; do
  wait "$pid"
done

wait_for_same_head --min-height "$POST_ROLLBACK_TARGET" "$GETH" "$IPC1" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

assert_same_hash_at "$ROLLBACK_TO" \
  "$GETH" "$IPC1" \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

clique_fork_hash=$(block_hash_at "$GETH" "$IPC1" "$PARLIA_GENESIS_BLOCK")
[[ -n "$clique_fork_hash" && "$clique_fork_hash" != "null" ]] || die "rolled-back Clique block ${PARLIA_GENESIS_BLOCK} not found"
if [[ "$clique_fork_hash" == "$parlia_fork_hash" ]]; then
  die "fork block hash ${PARLIA_GENESIS_BLOCK} was not replaced by the Clique rollback path"
fi

current_signers=$(signers_csv "$IPC1" "")
if [[ "$current_signers" != "$pre_signers" ]]; then
  echo "Expected signers:" >&2
  echo "$pre_signers" | tr ',' '\n' >&2
  echo "Current signers:" >&2
  echo "$current_signers" | tr ',' '\n' >&2
  die "Clique validator set after rollback does not match the pre-fork set"
fi

fork_signer=$(attach_exec "$GETH" "$IPC1" "clique.getSigner('${FORK_HEX}')" | tr '[:upper:]' '[:lower:]')
if ! echo "$pre_signers" | tr ',' '\n' | grep -qx "$fork_signer"; then
  die "Clique-signed block ${PARLIA_GENESIS_BLOCK} signer ${fork_signer} is not in the restored validator set"
fi

validator_code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${VALIDATOR_CONTRACT}', ${PARLIA_GENESIS_BLOCK})")
if [[ "$validator_code" != "0x" ]]; then
  die "ValidatorSet contract unexpectedly present at block ${PARLIA_GENESIS_BLOCK} after rollback: ${validator_code}"
fi

log "Rollback drill succeeded:"
log "  - block ${ROLLBACK_TO} hash preserved: ${pre_rollback_hash}"
log "  - block ${PARLIA_GENESIS_BLOCK} re-mined under Clique: ${clique_fork_hash}"
log "  - validator set restored: $(echo "$current_signers" | tr ',' ' ')"
log "  - ValidatorSet contract absent at rolled-back block ${PARLIA_GENESIS_BLOCK}"

if [[ "${_KEEP_RUNNING}" -eq 1 ]]; then
  echo
  echo "PASS. KEEP_RUNNING=1 — rolled-back Clique validators remain running."
  exit 0
fi

echo
echo "==> Stopping nodes"
"${SCRIPT_DIR}/03-stop.sh"

echo
echo "PASS"
