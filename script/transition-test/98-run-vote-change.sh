#!/usr/bin/env bash
# End-to-end Clique→Parlia transition test with a pre-fork Clique vote-in.
#
# This scenario proves that Parlia seeds from the last Clique checkpoint, not
# from genesis: a fourth validator is voted in before the fork, a post-vote
# checkpoint is produced, then the network forks to Parlia and must expose the
# updated 4-validator set via parlia_getValidators.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

: "${CLIQUE_EPOCH:=10}"
: "${PARLIA_GENESIS_BLOCK:=35}"

_PORT_BASE_EXPLICIT=${PORT_BASE+set}
_DATADIR_ROOT_EXPLICIT=${DATADIR_ROOT+set}

source "${SCRIPT_DIR}/lib.sh"

export CLIQUE_EPOCH PARLIA_GENESIS_BLOCK

if [[ "$CLIQUE_EPOCH" -le 0 ]]; then
  die "CLIQUE_EPOCH must be > 0"
fi
if [[ "$PARLIA_GENESIS_BLOCK" -le 5 ]]; then
  die "PARLIA_GENESIS_BLOCK must be > 5"
fi

if [[ "${_PORT_BASE_EXPLICIT}" != "set" ]]; then
  PORT_BASE=$(find_free_port_base)
  log "Auto-selected PORT_BASE=${PORT_BASE}"
fi
export PORT_BASE

if [[ "${_DATADIR_ROOT_EXPLICIT:-}" != "set" ]]; then
  export DATADIR_ROOT="${SCRIPT_DIR}/data-${PORT_BASE}"
fi

TOML_CONFIG="${DATADIR_ROOT}/override.toml"
V4_N=4
V4_DIR=$(val_dir "$V4_N")
V4_IPC=$(val_ipc "$V4_N")
V4_LOG=$(val_log "$V4_N")
V4_PID=$(val_pid "$V4_N")
V4_PW=$(val_pw "$V4_N")

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

ensure_validator4() {
  mkdir -p "$V4_DIR"
  [[ -f "$V4_PW" ]] || printf "password\n" > "$V4_PW"
  if [[ ! -f "${V4_DIR}/address.txt" ]]; then
    log "Creating validator-4 account"
    out=$("$GETH" account new --datadir "$V4_DIR" --password "$V4_PW")
    addr=$(echo "$out" | grep -oE "0x[0-9a-fA-F]{40}" | head -n1 || true)
    [[ -n "$addr" ]] || die "failed to parse validator-4 address: ${out}"
    echo "$addr" > "${V4_DIR}/address.txt"
  fi
  if [[ ! -d "${V4_DIR}/geth" ]]; then
    log "Initializing validator-4 datadir"
    "$GETH" init --datadir "$V4_DIR" "$GENESIS_JSON" 2>/dev/null
  fi
}

start_validator4() {
  local mode="$1"
  stop_pidfile "$V4_PID"

  local extra_args=()
  if [[ -n "${TOML_CONFIG:-}" && -f "$TOML_CONFIG" ]]; then
    extra_args+=(--config "$TOML_CONFIG")
  fi

  local mining_args=()
  if [[ "$mode" == "mining" ]]; then
    local v4_addr
    v4_addr=$(val_addr "$V4_N")
    mining_args=(
      --mine
      --miner.etherbase "$v4_addr"
      --unlock "$v4_addr"
      --password "$V4_PW"
      --allow-insecure-unlock
    )
  fi

  log "Starting validator-4 (${mode})"
  (
    nohup "$GETH" \
      "${extra_args[@]}" \
      --datadir "$V4_DIR" \
      --networkid "$NETWORK_ID" \
      --port "$(p2p_port "$V4_N")" \
      --nat none \
      --nodiscover \
      --bootnodes "" \
      --ipcpath geth.ipc \
      --syncmode full \
      --nousb \
      "${mining_args[@]}" \
      >>"$V4_LOG" 2>&1 &
    echo $! > "$V4_PID"
  )
  wait_for_ipc "$GETH" "$V4_IPC" 60

  local enode1 enode4
  enode1=$(get_enode "$GETH" "$(val_ipc 1)")
  add_peer "$GETH" "$V4_IPC" "$enode1" >/dev/null || true
  if [[ "$mode" == "mining" ]]; then
    enode4=$(get_enode "$GETH" "$V4_IPC")
    add_peer "$GETH" "$(val_ipc 1)" "$enode4" >/dev/null || true
  fi
  wait_for_min_peers "$GETH" "$V4_IPC" 1 60
}

verify_checkpoint_contains_validator4() {
  local checkpoint_block="$1"
  local checkpoint_ed checkpoint_hex v4_hex
  checkpoint_ed=$(attach_exec "$GETH" "$(val_ipc 1)" "eth.getBlock(${checkpoint_block}).extraData")
  checkpoint_hex=$(echo "${checkpoint_ed#0x}" | tr '[:upper:]' '[:lower:]')
  v4_hex=$(echo "$(val_addr "$V4_N")" | tr '[:upper:]' '[:lower:]')
  v4_hex=${v4_hex#0x}
  if ! echo "$checkpoint_hex" | grep -q "$v4_hex"; then
    die "validator-4 missing from checkpoint ${checkpoint_block} extraData"
  fi
  log "Checkpoint ${checkpoint_block} extraData includes validator-4"
}

# ── Phase 1: setup ────────────────────────────────────────────────────────────
run "${SCRIPT_DIR}/04-clean.sh"
run "${SCRIPT_DIR}/01-setup.sh"

# ── Phase 2: start base Clique network ───────────────────────────────────────
run "${SCRIPT_DIR}/02-start.sh"

# ── Phase 3: vote validator-4 into Clique before the fork ────────────────────
ensure_validator4
start_validator4 sync

V4_ADDR=$(val_addr "$V4_N")
log "Proposing validator-4 (${V4_ADDR}) on validator-1 and validator-2"
attach_exec "$GETH" "$(val_ipc 1)" "clique.propose('${V4_ADDR}', true)" >/dev/null
attach_exec "$GETH" "$(val_ipc 2)" "clique.propose('${V4_ADDR}', true)" >/dev/null

log "Waiting for validator-4 to appear in clique.getSigners()"
deadline=$(( $(date +%s) + 120 ))
while [[ $(date +%s) -lt $deadline ]]; do
  signers=$(attach_exec "$GETH" "$(val_ipc 1)" "JSON.stringify(clique.getSigners())" || true)
  if echo "$signers" | grep -qi "$V4_ADDR"; then
    log "validator-4 is now an authorized signer"
    break
  fi
  sleep 1
done
signers=$(attach_exec "$GETH" "$(val_ipc 1)" "JSON.stringify(clique.getSigners())" || true)
if ! echo "$signers" | grep -qi "$V4_ADDR"; then
  die "validator-4 never became an authorized signer"
fi

start_validator4 mining
auth_head=$(head_number "$GETH" "$(val_ipc 1)")

# ── Phase 4: wait for a post-vote checkpoint before stopping ────────────────
checkpoint_after_vote=$(( ((auth_head / CLIQUE_EPOCH) + 1) * CLIQUE_EPOCH ))
pre_stop=$(( PARLIA_GENESIS_BLOCK - 5 ))
if [[ "$pre_stop" -lt "$checkpoint_after_vote" ]]; then
  pre_stop="$checkpoint_after_vote"
fi
if [[ "$pre_stop" -ge "$PARLIA_GENESIS_BLOCK" ]]; then
  die "not enough room before fork: need a post-vote checkpoint before ParliaGenesisBlock"
fi

log "Waiting for block ${pre_stop} so the voted-in signer reaches a pre-fork checkpoint"
wait_for_head_at_least "$GETH" "$(val_ipc 1)" "$pre_stop" 180
last_checkpoint=$(( pre_stop - (pre_stop % CLIQUE_EPOCH) ))
verify_checkpoint_contains_validator4 "$last_checkpoint"
wait_for_block_miner "$GETH" "$(val_ipc 1)" "$V4_ADDR" 20 180
wait_for_same_head "$GETH" "$(val_ipc 1)" 120 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)" \
  "$GETH" "$V4_IPC"
log "validator-4 sealed a Clique block before the fork"

# ── Phase 5: stop validators and restart with Parlia override ────────────────
run "${SCRIPT_DIR}/03-stop.sh"

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

log "Restarting base validators with OverrideParliaGenesisBlock=${PARLIA_GENESIS_BLOCK}"
TOML_CONFIG="${TOML_CONFIG}" run "${SCRIPT_DIR}/02-start.sh"
start_validator4 mining

# ── Phase 5b: wait for all nodes to converge post-restart ────────────────────
# Same as 99-run-all.sh Phase 6: after stop-all-restart the re-queue loop can
# cause a temporary fork split. Wait for all four nodes to agree on the same
# head before the fork block fires.
log "Waiting for all nodes to converge post-restart..."
wait_for_same_head "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)" \
  "$GETH" "$V4_IPC"

# ── Phase 6: wait until the fork is crossed on all validators ────────────────
POST_FORK=$(( PARLIA_GENESIS_BLOCK + 5 ))
log "Waiting for all four validators to reach block ${POST_FORK}"
_pids=()
for n in 1 2 3 4; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_FORK" 180 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

# ── Phase 7: verify the standard fork checks plus validator-4 convergence ───
run "${SCRIPT_DIR}/05-verify.sh"
assert_same_hash_at "$POST_FORK" \
  "$GETH" "$(val_ipc 1)" \
  "$GETH" "$V4_IPC"
wait_for_same_head "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)" \
  "$GETH" "$V4_IPC"
log "validator-4 remained on the canonical chain after the Parlia fork"

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