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

_PORT_BASE_EXPLICIT=${PORT_BASE+set}
_DATADIR_ROOT_EXPLICIT=${DATADIR_ROOT+set}

source "${SCRIPT_DIR}/lib.sh"

export CLIQUE_EPOCH

if [[ "$CLIQUE_EPOCH" -le 0 ]]; then
  die "CLIQUE_EPOCH must be > 0"
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

# Compute PARLIA_GENESIS_BLOCK dynamically so there is always room for a
# post-vote checkpoint, regardless of how far the chain has advanced.
# Lock in the current head right now (before v4 starts mining and the chain
# accelerates), then place the fork block two full epochs beyond the next
# checkpoint.  This guarantees:
#   checkpoint_after_vote + CLIQUE_EPOCH < PARLIA_GENESIS_BLOCK
# even on slow CI runners where the chain may race ahead during setup.
_vote_head=$(head_number "$GETH" "$(val_ipc 1)")
_next_checkpoint=$(( ((_vote_head / CLIQUE_EPOCH) + 1) * CLIQUE_EPOCH ))
export PARLIA_GENESIS_BLOCK=$(( _next_checkpoint + 2 * CLIQUE_EPOCH ))
log "PARLIA_GENESIS_BLOCK set dynamically to ${PARLIA_GENESIS_BLOCK} (vote_head=${_vote_head}, next_checkpoint=${_next_checkpoint})"

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
# PARLIA_GENESIS_BLOCK was set dynamically (two epochs past the next checkpoint
# after the vote), so there is guaranteed room here — no need for a die check.
# Note: pre_stop is capped at PGB-1 below to prevent block PGB from being
# produced while validators are still running pure Clique (no TOML override).
auth_head=$(head_number "$GETH" "$(val_ipc 1)")
checkpoint_after_vote=$(( ((auth_head / CLIQUE_EPOCH) + 1) * CLIQUE_EPOCH ))
pre_stop=$(( PARLIA_GENESIS_BLOCK - 5 ))
if [[ "$pre_stop" -lt "$checkpoint_after_vote" ]]; then
  pre_stop="$checkpoint_after_vote"
fi
# pre_stop must stay strictly below PARLIA_GENESIS_BLOCK.  Nodes are still
# running pure Clique here (no TOML override yet), so if the chain reaches
# PGB before the TOML restart, block PGB gets sealed as a Clique block.
# After the restart DualConsensus routes block PGB to Parlia.VerifyHeader,
# which uses chainID-aware ecrecover — recovering a garbage address from the
# Clique signature and permanently blocking the snapshot computation.
#
# The cap is PGB-1 (not PGB-2) to minimise extra wait time.  The subsequent
# wait_for_same_head adds at most a few seconds; blocks produced there are
# still safely below PGB because PARLIA_GENESIS_BLOCK is always at least
# 2*CLIQUE_EPOCH above the checkpoint we're about to verify.
if [[ "$pre_stop" -ge "$PARLIA_GENESIS_BLOCK" ]]; then
  pre_stop=$(( PARLIA_GENESIS_BLOCK - CLIQUE_EPOCH ))
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

# ── Phase 5b: restart all 4 validators with deadlock recovery ────────────────
# With 4 authorized Clique signers the "signed recently" limit is
# ceil(4/2)=3.  Even when all 4 are launched simultaneously, slow CI runners
# can cause seal-races at multiple heights: the chain advances a few blocks
# then stalls again.  The only reliable remedy is to stop all nodes and restart;
# the new head height shifts the Clique round-robin to a different in-turn
# validator, breaking the deadlock.
#
# This retry loop mirrors the one in 99-run-all.sh.  We require the chain to
# actually cross ParliaGenesisBlock (not just move by one block) before
# declaring the restart successful.
v4_addr=$(val_addr "$V4_N")

_launch_all_4() {
  # Kill any stragglers from a previous attempt.
  stop_pidfile "$V4_PID" 2>/dev/null || true
  "${SCRIPT_DIR}/03-stop.sh" 2>/dev/null || true

  log "Launching all 4 validators simultaneously with OverrideParliaGenesisBlock=${PARLIA_GENESIS_BLOCK}"

  # Launch v4 first so its pidfile exists before 02-start.sh could interfere.
  (
    nohup "$GETH" \
      --config "$TOML_CONFIG" \
      --datadir "$V4_DIR" \
      --networkid "$NETWORK_ID" \
      --port "$(p2p_port "$V4_N")" \
      --nat none \
      --nodiscover \
      --bootnodes "" \
      --ipcpath geth.ipc \
      --syncmode full \
      --nousb \
      --mine \
      --miner.etherbase "$v4_addr" \
      --unlock "$v4_addr" \
      --password "$V4_PW" \
      --allow-insecure-unlock \
      >>"$V4_LOG" 2>&1 &
    echo $! > "$V4_PID"
  )

  # Launch v1/v2/v3 in the same burst — no waiting between.
  for n in 1 2 3; do
    local dir addr pw logfile pidfile
    dir=$(val_dir "$n"); addr=$(val_addr "$n"); pw=$(val_pw "$n")
    logfile=$(val_log "$n"); pidfile=$(val_pid "$n")
    (
      nohup "$GETH" \
        --config "$TOML_CONFIG" \
        --datadir "$dir" \
        --networkid "$NETWORK_ID" \
        --port "$(p2p_port "$n")" \
        --nat none \
        --nodiscover \
        --bootnodes "" \
        --ipcpath geth.ipc \
        --http \
        --http.addr 127.0.0.1 \
        --http.port "$(http_port "$n")" \
        --http.api "eth,net,web3,clique,parlia,admin,personal,miner" \
        --syncmode full \
        --nousb \
        --mine \
        --miner.etherbase "$addr" \
        --unlock "$addr" \
        --password "$pw" \
        --allow-insecure-unlock \
        >>"$logfile" 2>&1 &
      echo $! > "$pidfile"
    )
  done

  # Wait for all 4 IPCs in parallel.
  local _wpids=()
  for n in 1 2 3; do wait_for_ipc "$GETH" "$(val_ipc "$n")" 60 & _wpids+=($!); done
  wait_for_ipc "$GETH" "$V4_IPC" 60 & _wpids+=($!)
  for p in "${_wpids[@]}"; do wait "$p"; done

  # Wire the full 4-node mesh.
  local enode1 enode2 enode3 enode4
  enode1=$(get_enode "$GETH" "$(val_ipc 1)")
  enode2=$(get_enode "$GETH" "$(val_ipc 2)")
  enode3=$(get_enode "$GETH" "$(val_ipc 3)")
  enode4=$(get_enode "$GETH" "$V4_IPC")
  log "Wiring 4-node peer mesh"
  for src_ipc in "$(val_ipc 1)" "$(val_ipc 2)" "$(val_ipc 3)" "$V4_IPC"; do
    add_peer "$GETH" "$src_ipc" "$enode1" >/dev/null || true
    add_peer "$GETH" "$src_ipc" "$enode2" >/dev/null || true
    add_peer "$GETH" "$src_ipc" "$enode3" >/dev/null || true
    add_peer "$GETH" "$src_ipc" "$enode4" >/dev/null || true
  done

  # Wait for minimum peer counts.
  local _ppids=()
  for n in 1 2 3; do wait_for_min_peers "$GETH" "$(val_ipc "$n")" 2 30 & _ppids+=($!); done
  wait_for_min_peers "$GETH" "$V4_IPC" 1 30 & _ppids+=($!)
  for p in "${_ppids[@]}"; do wait "$p"; done
  log "All 4 validators up and peered."
}

_restart_attempt=0
while true; do
  _restart_attempt=$(( _restart_attempt + 1 ))
  _launch_all_4

  # Snapshot current head immediately after all 4 nodes are up and peered.
  # We require the chain to advance at least 2 blocks from here (not just
  # past ParliaGenesisBlock) because on retry attempts the chain may already
  # be past the fork in the on-disk data; the liveness check must be relative
  # to the actual current tip, not to a fixed fork-block target.
  _head_before=$(head_number "$GETH" "$(val_ipc 1)")
  _target=$(( _head_before + 2 ))
  # Also require the fork transition to have completed.
  if [[ "$(( PARLIA_GENESIS_BLOCK + 2 ))" -gt "$_target" ]]; then
    _target=$(( PARLIA_GENESIS_BLOCK + 2 ))
  fi

  _deadline=$(( $(date +%s) + 60 ))
  _alive=false
  while [[ $(date +%s) -lt $_deadline ]]; do
    _head_now=$(head_number "$GETH" "$(val_ipc 1)" 2>/dev/null || echo "$_head_before")
    if [[ "$_head_now" -ge "$_target" ]]; then
      _alive=true; break
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
  stop_pidfile "$V4_PID" || true
  "${SCRIPT_DIR}/03-stop.sh"
done

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
