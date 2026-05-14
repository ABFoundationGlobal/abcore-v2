#!/usr/bin/env bash
# T-1.7: Partial-upgrade failure + startup-check-triggered rollback.
#
# Scenario:
#   Simulates the real-world failure where an operator upgrades only 1 of 3
#   validators to ParliaGenesisBlock=N before the fork height is reached:
#
#   Phase 1 — setup (pure Clique):
#     All 3 validators start in pure Clique mode (no PGB override).
#
#   Phase 2 — partial upgrade (1 of 3 upgraded):
#     val-3 alone is stopped and restarted with PGB=N.
#     val-1 and val-2 remain on pure Clique (PGB=nil).
#     The chain crosses height N: val-1 and val-2 continue sealing Clique-form
#     blocks at and past N (2-of-3 Clique majority is maintained).
#     val-3 cannot import these Clique-form blocks at height N under Parlia rules
#     and falls behind.
#
#   Phase 3 — late upgrade triggers startup check (PR #86):
#     val-1 and val-2 are stopped and the operator applies PGB=N to them.
#     On restart, PR #86's startup check fires on both: their databases have a
#     Clique-form block at ParliaGenesisBlock. Both refuse to start with the
#     "dual-consensus startup check: refusing to start" error.
#     This phase asserts that the check fires, verifies the error message, and
#     confirms neither node starts.
#
#   Phase 4 — recovery rollback (three sub-steps):
#     4a. Operators first try maintenance mode (no --mine) with PGB=N on val-1/val-2.
#         The startup check fires again: it is engine-level and independent of
#         whether mining is enabled. This sub-phase asserts the same error appears.
#     4b. val-1/val-2 restart in maintenance mode with PGB=nil (startup check
#         bypassed: ParliaGenesisBlock == nil → check is a no-op). Both call
#         debug.setHead(N-1).
#     4c. val-3 restarts in maintenance mode with PGB=N (startup check passes:
#         head is at N-1 or Parlia-form block N → not Clique-form at PGB). This
#         shows the PGB=nil workaround is only needed for nodes that have a
#         Clique-form block at ParliaGenesisBlock on disk.
#     All 3 restart in pure Clique mode. The chain recovers.
#
#   Phase 5 — verify:
#     Block N-1 hash preserved; block N re-mined under Clique; ValidatorSet
#     contract absent; Clique signer set restored.
#
# This script exercises the rollback path documented in:
#   docs/ops/consensus-switch-rollback-runbook.md
# specifically the "startup check fires after partial-upgrade failure" branch
# where val-1/val-2 must use PGB=nil maintenance mode instead of PGB=N.
#
# Environment:
#   PARLIA_GENESIS_BLOCK  fork block (default: 20)
#   PORT_BASE             base port offset; auto-selected if unset
#   KEEP_RUNNING=1        leave nodes up after PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_REPO_ROOT=$(cd "${SCRIPT_DIR}/../../.." && pwd)

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
# How far past the fork val-1/val-2 must reach before we stop them.
# Enough blocks to ensure a stable Clique-form block sits at PGB on disk.
POST_FORK_WAIT=$(( PARLIA_GENESIS_BLOCK + 8 ))
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
  local ipc="$1" selector="$2"
  attach_exec "$GETH" "$ipc" \
    "(function(){ var vals = clique.getSigners(${selector}) || []; vals = vals.map(function(v){ return v.toLowerCase(); }).sort(); return vals.join(','); })()"
}

# Launch a single validator with the given TOML config (or no TOML if empty).
launch_validator() {
  local n="$1" toml="${2:-}"
  local dir addr pw p2p http logfile pidfile
  dir=$(val_dir "$n")
  addr=$(val_addr "$n")
  pw=$(val_pw "$n")
  p2p=$(p2p_port "$n")
  http=$(http_port "$n")
  logfile=$(val_log "$n")
  pidfile=$(val_pid "$n")

  local extra_args=()
  [[ -n "$toml" ]] && extra_args+=(--config "$toml")

  log "Starting validator-${n}$([ -n "$toml" ] && echo " (with TOML)" || echo " (pure Clique)")"
  (
    nohup "$GETH" \
      "${extra_args[@]}" \
      --datadir "$dir" \
      --networkid "$NETWORK_ID" \
      --port "$p2p" \
      --nat none \
      --nodiscover \
      --bootnodes "" \
      --ipcpath geth.ipc \
      --http \
      --http.addr 127.0.0.1 \
      --http.port "$http" \
      --http.api "eth,net,web3,clique,parlia,admin,personal,miner,debug" \
      --syncmode full \
      --mine \
      --miner.etherbase "$addr" \
      --unlock "$addr" \
      --password "$pw" \
      --allow-insecure-unlock \
      --nousb \
      >>"$logfile" 2>&1 &
    echo $! > "$pidfile"
  )
}

# Start a validator in maintenance mode (no --mine, IPC + HTTP only).
# Used for debug.setHead during the rollback phase.
start_maintenance_validator() {
  local n="$1" toml="${2:-}"
  local dir p2p logfile pidfile
  dir=$(val_dir "$n")
  p2p=$(p2p_port "$n")
  logfile=$(val_log "$n")
  pidfile=$(val_pid "$n")

  stop_pidfile "$pidfile"

  local extra_args=()
  [[ -n "$toml" ]] && extra_args+=(--config "$toml")

  log "Starting validator-${n} in maintenance mode$([ -n "$toml" ] && echo " (with TOML)" || echo " (pure Clique)")"
  (
    nohup "$GETH" \
      "${extra_args[@]}" \
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

rewind_validator() {
  local n="$1" target="$2"
  local ipc current target_hex
  ipc=$(val_ipc "$n")
  current=$(head_number "$GETH" "$ipc" || echo 0)
  target_hex=$(printf '0x%x' "$target")

  if [[ "$current" -gt "$target" ]]; then
    log "Rewinding validator-${n}: ${current} → ${target}"
    attach_exec "$GETH" "$ipc" "debug.setHead('${target_hex}')" >/dev/null
  else
    log "validator-${n} already at or below target (head=${current}, target=${target}); skipping setHead"
  fi

  local deadline=$(( $(date +%s) + 30 ))
  while [[ $(date +%s) -lt $deadline ]]; do
    current=$(head_number "$GETH" "$ipc" || echo 0)
    if [[ "$current" -eq "$target" ]]; then
      return 0
    fi
    sleep 1
  done
  die "validator-${n} head did not settle at ${target} (current=${current})"
}

# Try to start a validator with PGB=N config; assert the startup check fires
# and rejects it within the timeout.
#
# Each call writes geth output to a fresh per-attempt temp log, then appends
# it to the validator's main log. This avoids false-positive grep matches from
# prior calls (Phase 3 entries would otherwise satisfy the Phase 4a greps).
#
# Optional 3rd argument: human-readable label for log output (e.g. "mining" /
# "maintenance"). Defaults to "maintenance".
assert_startup_check_fires() {
  local n="$1" toml="$2" label="${3:-maintenance}"
  local dir p2p logfile attempt_log
  dir=$(val_dir "$n")
  p2p=$(p2p_port "$n")
  logfile=$(val_log "$n")
  attempt_log="${dir}/geth-startup-check-attempt-$$.log"

  log "Attempting ${label}-mode start for validator-${n} with PGB=${PARLIA_GENESIS_BLOCK} (expect startup check to fire)..."

  # The startup check fires right after core.NewBlockChain returns (before any
  # peer or RPC subsystem starts). The binary should exit 1 within a few seconds.
  "$GETH" \
    --config "$toml" \
    --datadir "$dir" \
    --networkid "$NETWORK_ID" \
    --port "$p2p" \
    --nat none \
    --nodiscover \
    --bootnodes "" \
    --ipcpath geth.ipc \
    --syncmode full \
    --nousb \
    >>"$attempt_log" 2>&1 &
  local startup_pid=$!

  local deadline=$(( $(date +%s) + 20 ))
  local exited=false
  while [[ $(date +%s) -lt $deadline ]]; do
    if ! kill -0 "$startup_pid" 2>/dev/null; then
      exited=true
      break
    fi
    sleep 0.5
  done

  # Always flush attempt log to the main log before any die call.
  cat "$attempt_log" >> "$logfile" 2>/dev/null || true
  rm -f "$attempt_log"

  if ! "$exited"; then
    kill "$startup_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$startup_pid" 2>/dev/null || true
    die "validator-${n}: startup check did NOT fire in ${label} mode — process still running after 20s with PGB=${PARLIA_GENESIS_BLOCK} and a Clique-form block at that height. PR #86 check may be missing or bypassed."
  fi

  # Grep the attempt log (now appended to main log) for the expected error.
  # Use tail to restrict the search to the lines just appended, avoiding false
  # positives from earlier phases.
  local recent
  recent=$(tail -50 "$logfile")
  if ! echo "$recent" | grep -q "dual-consensus startup check"; then
    die "validator-${n}: process exited in ${label} mode but 'dual-consensus startup check' not found in recent log. Unexpected error — see ${logfile}"
  fi
  if ! echo "$recent" | grep -q "refusing to start"; then
    die "validator-${n}: process exited in ${label} mode but 'refusing to start' not found in recent log. Unexpected error — see ${logfile}"
  fi

  log "validator-${n}: startup check correctly fired in ${label} mode (Clique-form block at PGB=${PARLIA_GENESIS_BLOCK} detected)"
}

ROLLBACK_HEX=$(printf '0x%x' "$ROLLBACK_TO")
FORK_HEX=$(printf '0x%x' "$PARLIA_GENESIS_BLOCK")

IPC1=$(val_ipc 1)
IPC2=$(val_ipc 2)
IPC3=$(val_ipc 3)

# ── Phase 1: setup + start all 3 in pure Clique ──────────────────────────────
run "${SCRIPT_DIR}/04-clean.sh"
run "${SCRIPT_DIR}/01-setup.sh"
run "${SCRIPT_DIR}/02-start.sh"

# Wait for stable Clique history before upgrading val-3.
# Must be well below PGB so val-3 doesn't race the fork block during restart.
PRE_UPGRADE=$(( PARLIA_GENESIS_BLOCK - 8 ))
if [[ "$PRE_UPGRADE" -lt 5 ]]; then PRE_UPGRADE=5; fi
log "Waiting for all nodes to reach block ${PRE_UPGRADE} (stable pre-fork Clique history)..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$PRE_UPGRADE" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
wait_for_same_head --min-height "$PRE_UPGRADE" "$GETH" "$IPC1" 30 \
  "$GETH" "$IPC2" "$GETH" "$IPC3"
log "All 3 at block ${PRE_UPGRADE}, converged. Starting partial upgrade..."

# ── Phase 2: upgrade val-3 only; let val-1/val-2 produce Clique blocks past N ─
log "Writing TOML override with ParliaGenesisBlock=${PARLIA_GENESIS_BLOCK}"
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

log "Stopping val-3 only (val-1 and val-2 remain on pure Clique)..."
stop_pidfile "$(val_pid 3)"
rm -f "$IPC3"

log "Restarting val-3 with PGB=${PARLIA_GENESIS_BLOCK} (1 of 3 upgraded)..."
launch_validator 3 "$TOML_CONFIG"
wait_for_ipc "$GETH" "$IPC3" 60

# Re-wire val-3 into the peer mesh after restart.
ENODE1=$(get_enode "$GETH" "$IPC1")
ENODE2=$(get_enode "$GETH" "$IPC2")
add_peer "$GETH" "$IPC3" "$ENODE1" >/dev/null || true
add_peer "$GETH" "$IPC3" "$ENODE2" >/dev/null || true
add_peer "$GETH" "$IPC1" "$(get_enode "$GETH" "$IPC3")" >/dev/null || true
add_peer "$GETH" "$IPC2" "$(get_enode "$GETH" "$IPC3")" >/dev/null || true
wait_for_min_peers "$GETH" "$IPC3" 1 30

# Now wait for val-1 and val-2 to produce Clique blocks PAST the fork height
# and converge on the same chain. With 2 of 3 Clique validators active they
# maintain a 2/3 majority and keep sealing. Val-3 (PGB=N, DualConsensus) will
# reject Clique-form blocks at height N under Parlia rules and diverge.
log "Waiting for val-1 and val-2 to converge past block ${POST_FORK_WAIT} (past fork height ${PARLIA_GENESIS_BLOCK})..."
wait_for_same_head --min-height "$POST_FORK_WAIT" "$GETH" "$IPC1" 180 \
  "$GETH" "$IPC2"

# val-1 and val-2 are now confirmed to agree on the Clique fork block.
val1_fork_hash=$(block_hash_at "$GETH" "$IPC1" "$PARLIA_GENESIS_BLOCK")
[[ -n "$val1_fork_hash" && "$val1_fork_hash" != "null" ]] || die "val-1 has no block at PGB=${PARLIA_GENESIS_BLOCK}"
log "val-1 and val-2 agree on Clique-form block ${PARLIA_GENESIS_BLOCK}: ${val1_fork_hash}"

# Check that val-3 diverged: it should have a different view of the fork block
# (either stuck at N-1, or on a solo-Parlia fork where block N is Parlia-form).
# Confirm val-3's IPC is responsive before querying — if it crashed or is
# overloaded, block_hash_at silently returns "null" and hides the real error.
wait_for_ipc "$GETH" "$IPC3" 15
val3_head=$(head_number "$GETH" "$IPC3" || echo 0)
log "val-3 head: ${val3_head} (expected to be stuck below or diverged at PGB=${PARLIA_GENESIS_BLOCK})"

val3_fork_hash=$(block_hash_at "$GETH" "$IPC3" "$PARLIA_GENESIS_BLOCK" 2>/dev/null || echo "null")
if [[ "$val3_fork_hash" != "null" && "$val3_fork_hash" == "$val1_fork_hash" ]]; then
  # If val-3 somehow accepted the Clique-form block at N, the split did not occur.
  # This would mean PR #86 startup check is already meaningless (val-3 agreed on
  # the Clique chain past N), which contradicts the scenario we are testing.
  die "val-3 has the same block hash as val-1 at height ${PARLIA_GENESIS_BLOCK} (${val3_fork_hash}). The network did not split — verify that val-3 is actually running with PGB=${PARLIA_GENESIS_BLOCK}."
fi
log "val-3 diverged at block ${PARLIA_GENESIS_BLOCK} (hash=${val3_fork_hash:-<N/A, stuck before fork>}) — network split confirmed"

# Record the pre-rollback anchor data.
pre_rollback_hash=$(block_hash_at "$GETH" "$IPC1" "$ROLLBACK_TO")
[[ -n "$pre_rollback_hash" && "$pre_rollback_hash" != "null" ]] || die "block ${ROLLBACK_TO} not found on val-1"
pre_signers=$(signers_csv "$IPC1" "'${ROLLBACK_HEX}'")
[[ -n "$pre_signers" ]] || die "failed to read Clique signers at block ${ROLLBACK_TO}"
log "Rollback anchor block ${ROLLBACK_TO}: ${pre_rollback_hash}"
log "Clique validator set at rollback anchor: $(echo "$pre_signers" | tr ',' ' ')"

# ── Phase 3: stop val-1/val-2, apply PGB=N, assert startup check fires ────────
log "Stopping val-1 and val-2 for late upgrade to PGB=${PARLIA_GENESIS_BLOCK}..."
stop_pidfile "$(val_pid 1)"
stop_pidfile "$(val_pid 2)"
rm -f "$IPC1" "$IPC2"

# val-3 is also stopped now to freeze the state cleanly before recovery.
stop_pidfile "$(val_pid 3)"
rm -f "$IPC3"

# Re-acquire port sentinel after stopping (03-stop was not called).
mkdir "/tmp/transition-test-reserved-${PORT_BASE}" 2>/dev/null || true

log "=== ASSERTING STARTUP CHECK FIRES IN MINING MODE (Phase 3) ==="
log "val-1 and val-2 have Clique-form block ${PARLIA_GENESIS_BLOCK} on disk."
log "Restarting them with PGB=${PARLIA_GENESIS_BLOCK} must trigger 'refusing to start'."

assert_startup_check_fires 1 "$TOML_CONFIG" "mining"
assert_startup_check_fires 2 "$TOML_CONFIG" "mining"

log "Both val-1 and val-2 correctly refused to start in mining mode."

# ── Phase 4: recovery rollback ────────────────────────────────────────────────
#
# Phase 4a — assert startup check also fires in maintenance mode (no --mine):
#   An operator's first instinct is to restart with the existing PGB=N config
#   but without --mine. The startup check fires regardless of mining mode, so
#   this also fails. This sub-phase confirms that PGB=nil is truly required.
#
# Phase 4b — val-1/val-2: PGB=nil maintenance mode (startup check bypassed):
#   ParliaGenesisBlock == nil → startup check is a no-op. Nodes start cleanly
#   with the Clique engine regardless of what is on disk at height N.
#
# Phase 4c — val-3: PGB=N maintenance mode (startup check passes naturally):
#   val-3's head is either at N-1 (head < PGB → no-op) or on a solo-Parlia
#   fork (block N is Parlia-form → check passes). Either way, no bypass needed.
#   This demonstrates that only nodes with a Clique-form block at PGB require
#   the PGB=nil workaround.

log "=== ASSERTING STARTUP CHECK FIRES IN MAINTENANCE MODE (Phase 4a) ==="
log "Even without --mine, the startup check rejects val-1/val-2 with PGB=N."

assert_startup_check_fires 1 "$TOML_CONFIG" "maintenance"
assert_startup_check_fires 2 "$TOML_CONFIG" "maintenance"

log "Confirmed: startup check fires in maintenance mode too. PGB=nil is the only path for val-1/val-2."

log "=== RECOVERY ROLLBACK (Phase 4b + 4c) ==="
log "val-1/val-2: maintenance mode with PGB=nil (startup check bypassed)."
log "val-3:       maintenance mode with PGB=N  (startup check passes — no Clique-form block at PGB)."

for n in 1 2 3; do
  echo "--- maintenance mode restart (Phase 4b/4c) ---" >> "$(val_log "$n")"
done

_maint_pids=()
# val-1/val-2: no TOML → PGB=nil → startup check no-op
for n in 1 2; do
  start_maintenance_validator "$n"
done
# val-3: keep PGB=N TOML → startup check passes (head ≤ N-1 or Parlia-form block N)
start_maintenance_validator 3 "$TOML_CONFIG"

for n in 1 2 3; do
  wait_for_ipc "$GETH" "$(val_ipc "$n")" 60 &
  _maint_pids+=($!)
done
for p in "${_maint_pids[@]}"; do
  wait "$p"
done
log "All 3 validators up in maintenance mode (val-1/val-2: PGB=nil; val-3: PGB=N)"

for n in 1 2 3; do
  rewind_validator "$n" "$ROLLBACK_TO"
done

# Verify all nodes agree on the rollback anchor before proceeding.
assert_same_hash_at "$ROLLBACK_TO" \
  "$GETH" "$IPC1" \
  "$GETH" "$IPC2" \
  "$GETH" "$IPC3"

rewound_hash=$(block_hash_at "$GETH" "$IPC1" "$ROLLBACK_TO")
[[ "$rewound_hash" == "$pre_rollback_hash" ]] || \
  die "rollback anchor hash changed after rewind: expected ${pre_rollback_hash}, got ${rewound_hash}"
log "All 3 nodes at block ${ROLLBACK_TO} with preserved canonical hash ${pre_rollback_hash}"

# ── Phase 5: restart in pure Clique; verify chain recovery ───────────────────
run "${SCRIPT_DIR}/03-stop.sh"
mkdir "/tmp/transition-test-reserved-${PORT_BASE}" 2>/dev/null || true

log "Restarting all 3 validators in pure Clique mode (no TOML, no PGB)..."
TOML_CONFIG="" "${SCRIPT_DIR}/02-start.sh"

log "Waiting for all 3 nodes to reach block ${POST_ROLLBACK_TARGET} after rollback..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_ROLLBACK_TARGET" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

wait_for_same_head --min-height "$POST_ROLLBACK_TARGET" "$GETH" "$IPC1" 60 \
  "$GETH" "$IPC2" \
  "$GETH" "$IPC3"

# Block N-1 hash preserved.
assert_same_hash_at "$ROLLBACK_TO" \
  "$GETH" "$IPC1" \
  "$GETH" "$IPC2" \
  "$GETH" "$IPC3"

final_anchor_hash=$(block_hash_at "$GETH" "$IPC1" "$ROLLBACK_TO")
[[ "$final_anchor_hash" == "$pre_rollback_hash" ]] || \
  die "block ${ROLLBACK_TO} hash changed after pure Clique restart: expected ${pre_rollback_hash}, got ${final_anchor_hash}"

# Block N must have been re-mined under Clique with a different hash: the chain
# was rewound to N-1 and all 3 validators re-sealed block N from scratch. The
# new block N has a later timestamp (significant wall time elapsed during the
# test), so its hash cannot equal the original Clique block N from Phase 2.
clique_fork_hash=$(block_hash_at "$GETH" "$IPC1" "$PARLIA_GENESIS_BLOCK")
[[ -n "$clique_fork_hash" && "$clique_fork_hash" != "null" ]] || \
  die "rolled-back Clique block ${PARLIA_GENESIS_BLOCK} not found"
if [[ "$clique_fork_hash" == "$val1_fork_hash" ]]; then
  die "block ${PARLIA_GENESIS_BLOCK} hash unchanged after rollback (${clique_fork_hash}). debug.setHead(${ROLLBACK_TO}) may not have rewound the chain — the rollback did not take effect."
fi

# Clique signer set must be restored.
current_signers=$(signers_csv "$IPC1" "")
if [[ "$current_signers" != "$pre_signers" ]]; then
  echo "Expected signers: $pre_signers" >&2
  echo "Current signers:  $current_signers" >&2
  die "Clique validator set after rollback does not match the pre-fork set"
fi

# The signer of the rolled-back block N must be a member of the restored set.
fork_signer=$(attach_exec "$GETH" "$IPC1" "clique.getSigner('${FORK_HEX}')" | tr '[:upper:]' '[:lower:]')
if ! echo "$pre_signers" | tr ',' '\n' | grep -qx "$fork_signer"; then
  die "Clique-signed block ${PARLIA_GENESIS_BLOCK} signer ${fork_signer} is not in the restored validator set (${pre_signers})"
fi

# ValidatorSet contract must be absent at block N (no Parlia genesis init ran).
validator_code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${VALIDATOR_CONTRACT}', ${PARLIA_GENESIS_BLOCK})")
if [[ "$validator_code" != "0x" ]]; then
  die "ValidatorSet contract unexpectedly present at block ${PARLIA_GENESIS_BLOCK} after rollback: ${validator_code}"
fi

log "T-1.7 partial-upgrade rollback succeeded:"
log "  - Network split confirmed: val-3 diverged at block ${PARLIA_GENESIS_BLOCK}"
log "  - Phase 3: startup check fired on val-1/val-2 in mining mode"
log "  - Phase 4a: startup check fired on val-1/val-2 in maintenance mode (no --mine)"
log "  - Phase 4b: PGB=nil maintenance mode bypassed check on val-1/val-2 → setHead(${ROLLBACK_TO}) succeeded"
log "  - Phase 4c: PGB=N maintenance mode worked on val-3 (no Clique-form block at PGB)"
log "  - Block ${ROLLBACK_TO} hash preserved: ${final_anchor_hash}"
log "  - Block ${PARLIA_GENESIS_BLOCK} re-mined under Clique: ${clique_fork_hash}"
log "  - Block ${PARLIA_GENESIS_BLOCK} signer ${fork_signer} is in the restored validator set"
log "  - Validator set restored: $(echo "$current_signers" | tr ',' ' ')"
log "  - ValidatorSet contract absent at block ${PARLIA_GENESIS_BLOCK}"

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
