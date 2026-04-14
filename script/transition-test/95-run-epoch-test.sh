#!/usr/bin/env bash
# T-2: Parlia epoch boundary test.
#
# Scope: verifies that the chain continues to produce blocks across the first
# and second Parlia epoch boundaries after a Clique→Parlia fork transition.
# At each epoch boundary, prepareValidators() calls BSCValidatorSet.getValidators()
# to read the active validator set from contract storage and encodes it into
# header.Extra; the snapshot switches the signer set at epoch+1.  If the addresses
# baked into the bytecode differ from the actual sealing nodes, the chain halts.
#
# This script uses the fixed dev keystores in
#   core/systemcontracts/parliagenesis/default/keystores/
# which match the INIT_VALIDATORSET_BYTES baked into
#   core/systemcontracts/parliagenesis/default/ValidatorContract
# ensuring address consistency across fork and epoch transitions.
#
# Environment:
#   GETH                  path to geth binary (required)
#   EPOCH_LENGTH          CLIQUE_EPOCH and Parlia epochLength (default: 50)
#   PARLIA_GENESIS_BLOCK  fork block (default: 20; must be < EPOCH_LENGTH)
#   PORT_BASE             base port offset; auto-selected if unset
#   DATADIR_ROOT          test data dir; auto-selected if unset
#   KEEP_RUNNING=1        leave nodes up after PASS (for manual inspection)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

# Build v2 binary if no explicit path provided (local dev workflow).
if [[ -z "${GETH:-}" ]]; then
  echo "[$(date +'%H:%M:%S')] Building v2 binary (set GETH=... to skip)..."
  (cd "${REPO_ROOT}" && CGO_CFLAGS="-O -D__BLST_PORTABLE__" CGO_CFLAGS_ALLOW="-O -D__BLST_PORTABLE__" make geth)
fi

_PORT_BASE_EXPLICIT=${PORT_BASE+set}
_DATADIR_ROOT_EXPLICIT=${DATADIR_ROOT+set}

# CLIQUE_EPOCH must be set before sourcing lib.sh so genesis gets the right epoch.
EPOCH_LENGTH=${EPOCH_LENGTH:-50}
export CLIQUE_EPOCH="$EPOCH_LENGTH"

source "${SCRIPT_DIR}/lib.sh"

if [[ "${_PORT_BASE_EXPLICIT}" != "set" ]]; then
  PORT_BASE=$(find_free_port_base)
  log "Auto-selected PORT_BASE=${PORT_BASE}"
fi
export PORT_BASE

if [[ "${_DATADIR_ROOT_EXPLICIT:-}" != "set" ]]; then
  export DATADIR_ROOT="${SCRIPT_DIR}/data-${PORT_BASE}"
fi

# PARLIA_GENESIS_BLOCK must be less than EPOCH_LENGTH
if [[ "${PARLIA_GENESIS_BLOCK}" -ge "${EPOCH_LENGTH}" ]]; then
  die "PARLIA_GENESIS_BLOCK (${PARLIA_GENESIS_BLOCK}) must be less than EPOCH_LENGTH (${EPOCH_LENGTH})"
fi

TOML_CONFIG="${DATADIR_ROOT}/override.toml"

# Key block heights
PRE_STOP=$(( PARLIA_GENESIS_BLOCK - 5 ))
if [[ "$PRE_STOP" -lt 5 ]]; then PRE_STOP=5; fi
POST_FORK=$(( PARLIA_GENESIS_BLOCK + 5 ))
EPOCH_BOUNDARY="$EPOCH_LENGTH"                              # = 50
POST_EPOCH=$(( EPOCH_BOUNDARY + EPOCH_LENGTH / 2 ))         # = 75
SECOND_EPOCH_BOUNDARY=$(( 2 * EPOCH_LENGTH ))               # = 100
POST_SECOND_EPOCH=$(( SECOND_EPOCH_BOUNDARY + 5 ))          # = 105

log "T-2 epoch boundary test"
log "  EPOCH_LENGTH=${EPOCH_LENGTH}, PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK}"
log "  PRE_STOP=${PRE_STOP}, POST_FORK=${POST_FORK}"
log "  EPOCH_BOUNDARY=${EPOCH_BOUNDARY}, POST_EPOCH=${POST_EPOCH}"
log "  SECOND_EPOCH_BOUNDARY=${SECOND_EPOCH_BOUNDARY}, POST_SECOND_EPOCH=${POST_SECOND_EPOCH}"

DEV_KEYSTORES="${REPO_ROOT}/core/systemcontracts/parliagenesis/default/keystores"

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

# ── Phase 1: setup ─────────────────────────────────────────────────────────────
# Copy fixed dev keystores so 01-setup.sh reuses them (skips geth account new).
# These addresses match INIT_VALIDATORSET_BYTES in default/ValidatorContract.
log "Copying fixed dev keystores from ${DEV_KEYSTORES}"
for n in 1 2 3; do
  d=$(val_dir "$n")
  mkdir -p "$d"
  if [[ -d "${DEV_KEYSTORES}/validator-${n}" ]]; then
    # Copy the entire keystore dir; address.txt presence makes 01-setup.sh skip account creation
    src="${DEV_KEYSTORES}/validator-${n}"
    # Copy keystore files (the actual key JSON)
    if ls "${src}"/UTC--* >/dev/null 2>&1; then
      mkdir -p "${d}/keystore"
      cp "${src}"/UTC--* "${d}/keystore/"
    fi
    cp "${src}/address.txt" "${d}/address.txt"
    cp "${src}/password.txt" "${d}/password.txt" 2>/dev/null || printf 'password\n' > "${d}/password.txt"
    log "validator-${n}: $(cat "${d}/address.txt")"
  else
    die "dev keystore for validator-${n} not found at ${DEV_KEYSTORES}/validator-${n}"
  fi
done

# partial_clean wipes chain data but preserves keystores we just copied
partial_clean
run "${SCRIPT_DIR}/01-setup.sh"

# ── Phase 2: start Clique network ──────────────────────────────────────────────
run "${SCRIPT_DIR}/02-start.sh"

# ── Phase 3: wait for stable Clique history before fork ───────────────────────
log "Waiting for all 3 nodes to reach block ${PRE_STOP} (Clique history)..."
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

# ── Phase 4: stop all validators ──────────────────────────────────────────────
run "${SCRIPT_DIR}/03-stop.sh"
# Re-acquire sentinel released by 03-stop.sh
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

# ── Phase 6: wait for convergence after restart ────────────────────────────────
post_restart_head=$(head_number "$GETH" "$(val_ipc 1)")
log "Waiting for all nodes to converge post-restart (min-height=${post_restart_head})..."
wait_for_same_head --min-height "$post_restart_head" "$GETH" "$(val_ipc 1)" 120 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

# ── Phase 7: wait for the chain to cross the fork block ────────────────────────
log "Waiting for all nodes to reach block ${POST_FORK} (post-fork)..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_FORK" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
log "All nodes past fork block."

# ── Phase 8: cross first epoch boundary ────────────────────────────────────────
log "Waiting for all nodes to reach block ${POST_EPOCH} (past first epoch boundary at ${EPOCH_BOUNDARY})..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_EPOCH" 300 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
wait_for_same_head --min-height "$POST_EPOCH" "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"
log "All nodes past first epoch boundary."

# ── Phase 9: cross second epoch boundary ───────────────────────────────────────
log "Waiting for all nodes to reach block ${POST_SECOND_EPOCH} (past second epoch boundary at ${SECOND_EPOCH_BOUNDARY})..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_SECOND_EPOCH" 300 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
wait_for_same_head --min-height "$POST_SECOND_EPOCH" "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"
log "All nodes past second epoch boundary."

# ── Phase 10: verify ───────────────────────────────────────────────────────────
IPC1="$(val_ipc 1)"

run "${SCRIPT_DIR}/05-verify.sh"

# ── Epoch boundary assertions ──────────────────────────────────────────────────
pass() { log "  OK: $*"; }
fail() { die "FAIL: $*"; }

# 1. Epoch boundary block exists
log "Checking epoch boundary block ${EPOCH_BOUNDARY}..."
epoch_hash=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${EPOCH_BOUNDARY}).hash")
[[ "$epoch_hash" != "null" && -n "$epoch_hash" ]] || fail "epoch boundary block ${EPOCH_BOUNDARY} missing"
pass "epoch boundary block ${EPOCH_BOUNDARY} exists: ${epoch_hash:0:14}..."

# 2. Block epoch+1 exists (chain continued past boundary)
post_epoch_hash=$(attach_exec "$GETH" "$IPC1" "eth.getBlock($((EPOCH_BOUNDARY+1))).hash")
[[ "$post_epoch_hash" != "null" && -n "$post_epoch_hash" ]] || \
  fail "post-epoch block $((EPOCH_BOUNDARY+1)) missing — chain likely halted at epoch boundary"
pass "post-epoch block $((EPOCH_BOUNDARY+1)) exists: ${post_epoch_hash:0:14}..."

# 3. Epoch block extraData contains validator set
# pre-Luban: 32B vanity + 3×20B addrs + 65B seal = 117 bytes = 234 hex chars (+ "0x" = 236 total)
epoch_extra=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${EPOCH_BOUNDARY}).extraData")
epoch_hex="${epoch_extra#0x}"
[[ "${#epoch_hex}" -gt 194 ]] || \
  fail "epoch block extraData too short (${#epoch_hex} hex chars); expected > 194 for 3 validators"
pass "epoch block extraData length OK: ${#epoch_hex} hex chars"

# 4. parlia_getValidators at epoch boundary returns 3 validators
log "Checking parlia_getValidators at block ${EPOCH_BOUNDARY}..."
parlia_resp=$(curl -sS -X POST "http://127.0.0.1:$(http_port 1)" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"parlia_getValidators\",\"params\":[\"0x$(printf '%x' "$EPOCH_BOUNDARY")\"],\"id\":1}")
val_count=$(echo "$parlia_resp" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(len(d.get('result',[])))" 2>/dev/null || echo 0)
[[ "$val_count" -eq 3 ]] || \
  fail "parlia_getValidators at block ${EPOCH_BOUNDARY}: expected 3 validators, got ${val_count}"
pass "parlia_getValidators at epoch boundary returned ${val_count} validators"

# 5. Epoch boundary block was produced by a real validator (miner != zero)
epoch_miner=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${EPOCH_BOUNDARY}).miner")
[[ "$epoch_miner" != "0x0000000000000000000000000000000000000000" ]] || \
  fail "epoch boundary block miner is zero address"
pass "epoch boundary block miner: ${epoch_miner}"

# 6. Second epoch boundary block exists
log "Checking second epoch boundary block ${SECOND_EPOCH_BOUNDARY}..."
second_hash=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${SECOND_EPOCH_BOUNDARY}).hash")
[[ "$second_hash" != "null" && -n "$second_hash" ]] || \
  fail "second epoch boundary block ${SECOND_EPOCH_BOUNDARY} missing"
pass "second epoch boundary block ${SECOND_EPOCH_BOUNDARY} exists: ${second_hash:0:14}..."

# 7. All three nodes agree on hash at POST_SECOND_EPOCH
log "Checking all 3 nodes agree at block ${POST_SECOND_EPOCH}..."
assert_same_hash_at "$POST_SECOND_EPOCH" \
  "$GETH" "$(val_ipc 1)" \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"
pass "all 3 nodes agree on block ${POST_SECOND_EPOCH}"

# ── Phase 11: stop ─────────────────────────────────────────────────────────────
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
