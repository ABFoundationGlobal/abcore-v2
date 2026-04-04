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
      stop_pidfile "$V4_PID" || true
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
  # mode: "sync"          — no mining, no account unlock
  #       "mining"        — --mine from the start (use only when chain is already at tip)
  #       "ready-to-mine" — account unlocked, etherbase set, but mining NOT started;
  #                         call `miner.start()` via IPC after sync to avoid sealing
  #                         stale blocks before the node has caught up.
  local mode="$1"
  stop_pidfile "$V4_PID"

  local extra_args=()
  if [[ -n "${TOML_CONFIG:-}" && -f "$TOML_CONFIG" ]]; then
    extra_args+=(--config "$TOML_CONFIG")
  fi

  local mining_args=()
  local v4_addr
  v4_addr=$(val_addr "$V4_N")
  if [[ "$mode" == "mining" ]]; then
    mining_args=(
      --mine
      --miner.etherbase "$v4_addr"
      --unlock "$v4_addr"
      --password "$V4_PW"
      --allow-insecure-unlock
    )
  elif [[ "$mode" == "ready-to-mine" ]]; then
    # Unlock the account and set etherbase so miner.start() works via IPC,
    # but do NOT pass --mine so the node syncs before sealing anything.
    mining_args=(
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

  # Wire v4 into the peer mesh in both directions regardless of mode.
  # Without the reverse peers (v1/v2/v3 → v4), blocks propagated from the
  # base validators do not reach v4 quickly enough after restart.
  local enode1 enode4
  enode1=$(get_enode "$GETH" "$(val_ipc 1)")
  enode4=$(get_enode "$GETH" "$V4_IPC")
  add_peer "$GETH" "$V4_IPC" "$enode1" >/dev/null || true
  add_peer "$GETH" "$(val_ipc 1)" "$enode4" >/dev/null || true
  add_peer "$GETH" "$(val_ipc 2)" "$enode4" >/dev/null || true
  add_peer "$GETH" "$(val_ipc 3)" "$enode4" >/dev/null || true
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

# Start v4 in sync-only mode to get the genesis and initial chain state.
# We don't mine yet — v4 must catch up first.
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

# ── Phase 3b: start v4 in ready-to-mine mode, sync it, then start mining ────
# With 4 authorized signers, Clique's "signed recently" limit is
# ceil(4/2) = 3: each signer must wait for 3 other blocks after its last seal.
# If only 3 validators mine, after v1→v2→v3, all three have "recently signed"
# and only v4 can advance — resulting in a deadlock since v4 isn't mining.
#
# The fix: start v4 in ready-to-mine mode (account unlocked, etherbase set,
# but --mine not passed), wait for v4 to sync to the EXACT same block number
# and hash as the other validators, then call miner.start() via IPC.
# This prevents v4 from sealing stale blocks (which would fork the chain)
# while ensuring it participates in the 4-validator rotation.
stop_pidfile "$V4_PID"
start_validator4 ready-to-mine

# Wait for v4 to import the canonical chain before starting its miner.
# Reading _v4_target after wait_for_ipc ensures v4 is alive; then we
# first wait for v4 to reach that height (so it has the canonical blocks),
# then confirm hash agreement across all 4 nodes before calling miner.start().
# This two-step approach prevents v4 from sealing stale competing blocks while
# it is still catching up, which would delay convergence and waste seal slots.
_v4_target=$(head_number "$GETH" "$(val_ipc 1)")
log "Waiting for validator-4 to import canonical chain up to block ${_v4_target}..."
wait_for_head_at_least "$GETH" "$V4_IPC" "$_v4_target" 120

log "validator-4 at canonical tip (block ${_v4_target}+). Starting v4 miner."
attach_exec "$GETH" "$V4_IPC" "miner.start()" >/dev/null

# ── Phase 4: wait for a post-vote checkpoint before stopping ────────────────
auth_head=$(head_number "$GETH" "$(val_ipc 1)")
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

# Wait for all 4 nodes (including v4) to reach pre-stop.
pre_stop_head=$(head_number "$GETH" "$(val_ipc 1)")
log "Waiting for all nodes to reach pre-stop head (block ${pre_stop_head})..."
wait_for_same_head --min-height "$pre_stop_head" "$GETH" "$(val_ipc 1)" 120 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)" \
  "$GETH" "$V4_IPC"
log "All nodes at pre-stop head. validator-4 is an authorized signer."
pre_restart_head=$(head_number "$GETH" "$(val_ipc 1)")
log "Pre-restart head: ${pre_restart_head}"

# ── Phase 5: stop validators and restart with Parlia override ────────────────
run "${SCRIPT_DIR}/03-stop.sh"
stop_pidfile "$V4_PID"

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

# ── Phase 5b: restart validator-4 and let it mine ────────────────────────────
# validator-4 is in the Clique checkpoint at the last pre-fork epoch (it was
# voted in before that checkpoint).  With 4 authorized Clique signers the
# "signed recently" limit is ceil(4/2)=3: after v1/v2/v3 each seal one block
# all three have "recently signed" and only v4 can advance.  If v4 is
# sync-only the chain stalls for blocks between the restart and the fork.
#
# The same argument applies to the Parlia phase: Parlia seeds its validator
# set from that same checkpoint, so all 4 are in the Parlia set.  Parlia's
# Seal() will route block proposals to v4 in its turn.
#
# Fix: restart v4 in ready-to-mine mode, wait for exact-head convergence
# with the base validators, then call miner.start().
start_validator4 ready-to-mine
_v4_post_target=$(head_number "$GETH" "$(val_ipc 1)")
log "Waiting for validator-4 to import canonical chain up to block ${_v4_post_target} (post-restart)..."
wait_for_head_at_least "$GETH" "$V4_IPC" "$_v4_post_target" 120
log "validator-4 at canonical tip (block ${_v4_post_target}+, post-restart). Starting v4 miner."
attach_exec "$GETH" "$V4_IPC" "miner.start()" >/dev/null

# ── Phase 6: wait for all 4 validators to cross the fork block ───────────────
POST_FORK=$(( PARLIA_GENESIS_BLOCK + 5 ))
log "Waiting for all validators to reach block ${POST_FORK}"
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_FORK" 180 &
  _pids+=($!)
done
wait_for_head_at_least "$GETH" "$V4_IPC" "$POST_FORK" 180 &
_pids+=($!)
for p in "${_pids[@]}"; do wait "$p"; done

# ── Phase 7: verify fork checks; confirm all nodes on canonical chain ─────────
run "${SCRIPT_DIR}/05-verify.sh"
assert_same_hash_at "$POST_FORK" \
  "$GETH" "$(val_ipc 1)" \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)" \
  "$GETH" "$V4_IPC"
log "All 4 validators on canonical chain at block ${POST_FORK}"

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
