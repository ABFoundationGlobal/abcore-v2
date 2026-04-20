#!/usr/bin/env bash
# Clique epoch boundary coincides with fork block.
#
# Scenario: CLIQUE_EPOCH == PARLIA_GENESIS_BLOCK == N.
# The fork block is simultaneously a Clique epoch checkpoint, so its extraData
# carries a full signer list.  Parlia snapshot seeding must treat this block as
# both an epoch checkpoint and the fork origin without triggering
# errUnauthorizedValidator or errExtraValidators.
#
# This test covers the code path that 95-run-epoch-test.sh (T-2) explicitly
# excludes with its "PARLIA_GENESIS_BLOCK must be less than EPOCH_LENGTH" guard.
#
# Environment:
#   GETH                  path to geth binary (required)
#   EPOCH_LENGTH          Clique epoch and Parlia epochLength (default: 20)
#   PARLIA_GENESIS_BLOCK  fork block; must be a multiple of EPOCH_LENGTH
#                         (default: EPOCH_LENGTH, i.e. the first epoch boundary)
#   PORT_BASE             base port offset; auto-selected if unset
#   DATADIR_ROOT          test data dir; auto-selected if unset
#   KEEP_RUNNING=1        leave nodes up after PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

if [[ -z "${GETH:-}" ]]; then
  echo "[$(date +'%H:%M:%S')] Building v2 binary (set GETH=... to skip)..."
  (cd "${REPO_ROOT}" && CGO_CFLAGS="-O -D__BLST_PORTABLE__" CGO_CFLAGS_ALLOW="-O -D__BLST_PORTABLE__" make geth)
fi

_PORT_BASE_EXPLICIT=${PORT_BASE+set}
_DATADIR_ROOT_EXPLICIT=${DATADIR_ROOT+set}

EPOCH_LENGTH=${EPOCH_LENGTH:-20}
export CLIQUE_EPOCH="$EPOCH_LENGTH"
export PARLIA_GENESIS_BLOCK="${PARLIA_GENESIS_BLOCK:-$EPOCH_LENGTH}"

source "${SCRIPT_DIR}/lib.sh"

# Invariant: PGB must be a multiple of EPOCH_LENGTH (fork fires on epoch boundary)
if [[ $(( PARLIA_GENESIS_BLOCK % EPOCH_LENGTH )) -ne 0 ]]; then
  die "PARLIA_GENESIS_BLOCK (${PARLIA_GENESIS_BLOCK}) must be a multiple of EPOCH_LENGTH (${EPOCH_LENGTH}) for this test"
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
DEV_KEYSTORES="${REPO_ROOT}/core/systemcontracts/parliagenesis/default/keystores"

# Key block heights
PRE_STOP=$(( PARLIA_GENESIS_BLOCK - 3 ))
if [[ "$PRE_STOP" -lt 3 ]]; then PRE_STOP=3; fi
POST_FORK=$(( PARLIA_GENESIS_BLOCK + 5 ))
FIRST_PARLIA_EPOCH=$(( PARLIA_GENESIS_BLOCK + EPOCH_LENGTH ))
POST_FIRST_PARLIA_EPOCH=$(( FIRST_PARLIA_EPOCH + 3 ))

log "Clique-epoch-fork test"
log "  EPOCH_LENGTH=${EPOCH_LENGTH}, PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK}"
log "  PRE_STOP=${PRE_STOP}, POST_FORK=${POST_FORK}"
log "  FIRST_PARLIA_EPOCH=${FIRST_PARLIA_EPOCH}, POST_FIRST_PARLIA_EPOCH=${POST_FIRST_PARLIA_EPOCH}"

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
# Use fixed dev keystores so validator addresses match INIT_VALIDATORSET_BYTES
# baked into parliagenesis/default/ValidatorContract (same requirement as T-2).
log "Copying fixed dev keystores from ${DEV_KEYSTORES}"
for n in 1 2 3; do
  d=$(val_dir "$n")
  mkdir -p "$d"
  src="${DEV_KEYSTORES}/validator-${n}"
  [[ -d "$src" ]] || die "dev keystore for validator-${n} not found at ${src}"
  if ls "${src}"/UTC--* >/dev/null 2>&1; then
    mkdir -p "${d}/keystore"
    cp "${src}"/UTC--* "${d}/keystore/"
  fi
  cp "${src}/address.txt" "${d}/address.txt"
  cp "${src}/password.txt" "${d}/password.txt" 2>/dev/null || printf 'password\n' > "${d}/password.txt"
  log "validator-${n}: $(cat "${d}/address.txt")"
done

partial_clean
run "${SCRIPT_DIR}/01-setup.sh"

# ── Phase 2: start Clique network ──────────────────────────────────────────────
run "${SCRIPT_DIR}/02-start.sh"

# ── Phase 3: wait for stable Clique history ────────────────────────────────────
# Stop at PGB-3, which is EPOCH_LENGTH-3: the chain has built a few blocks before
# the epoch boundary but has not yet produced the epoch checkpoint itself.
log "Waiting for all 3 nodes to reach block ${PRE_STOP}..."
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

# ── Phase 4: stop all validators ───────────────────────────────────────────────
run "${SCRIPT_DIR}/03-stop.sh"
mkdir "/tmp/transition-test-reserved-${PORT_BASE}" 2>/dev/null || true

# ── Phase 5: write TOML override and restart with deadlock recovery ────────────
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
  log "Restart attempt ${_restart_attempt} with ParliaGenesisBlock=${PARLIA_GENESIS_BLOCK}..."
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
      _alive=true; break
    fi
    sleep 2
  done

  if "$_alive"; then
    log "Chain advancing (head=${_head_now} >= target=${_target}). Restart successful."
    break
  fi

  if [[ "$_restart_attempt" -ge 5 ]]; then
    die "chain did not advance after ${_restart_attempt} restart attempts"
  fi
  log "WARNING: chain stalled (seal-race deadlock). Stopping for retry..."
  "${SCRIPT_DIR}/03-stop.sh"
  mkdir "/tmp/transition-test-reserved-${PORT_BASE}" 2>/dev/null || true
done

# ── Phase 6: wait for convergence and fork crossing ────────────────────────────
post_restart_head=$(head_number "$GETH" "$(val_ipc 1)")
log "Waiting for all nodes to converge post-restart (min-height=${post_restart_head})..."
wait_for_same_head --min-height "$post_restart_head" "$GETH" "$(val_ipc 1)" 120 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"

log "Waiting for all nodes to reach block ${POST_FORK} (post-fork)..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_FORK" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

# ── Phase 7: wait for first Parlia epoch boundary ──────────────────────────────
log "Waiting for all nodes to reach block ${POST_FIRST_PARLIA_EPOCH} (past first Parlia epoch at ${FIRST_PARLIA_EPOCH})..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_FIRST_PARLIA_EPOCH" 300 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
wait_for_same_head --min-height "$POST_FIRST_PARLIA_EPOCH" "$GETH" "$(val_ipc 1)" 60 \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"
log "All nodes past first Parlia epoch boundary."

# ── Phase 8: assertions ────────────────────────────────────────────────────────
IPC1="$(val_ipc 1)"
HTTP1="http://127.0.0.1:$(http_port 1)"

pass() { log "  OK: $*"; }
fail() { die "FAIL: $*"; }

# 1. Fork/epoch block exists
log "Checking fork/epoch block ${PARLIA_GENESIS_BLOCK}..."
fork_hash=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${PARLIA_GENESIS_BLOCK}).hash")
[[ "$fork_hash" != "null" && -n "$fork_hash" ]] || fail "fork/epoch block ${PARLIA_GENESIS_BLOCK} missing"
pass "fork/epoch block ${PARLIA_GENESIS_BLOCK} exists: ${fork_hash:0:14}..."

# 2. Fork/epoch block extraData contains full signer list
# pre-Luban: 32B vanity + 3×20B addrs + 65B seal = 117 bytes = 234 hex chars (+ "0x" = 236 total)
fork_extra=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${PARLIA_GENESIS_BLOCK}).extraData")
fork_hex="${fork_extra#0x}"
[[ "${#fork_hex}" -gt 194 ]] || \
  fail "fork/epoch block extraData too short (${#fork_hex} hex chars); expected > 194 for 3 validators"
pass "fork/epoch block extraData length OK: ${#fork_hex} hex chars (contains signer list)"

# 3. Fork/epoch block miner is non-zero (Parlia is sealing, not Clique)
fork_miner=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${PARLIA_GENESIS_BLOCK}).miner")
[[ "$fork_miner" != "0x0000000000000000000000000000000000000000" ]] || \
  fail "fork/epoch block miner is zero address — Clique may have sealed this block instead of Parlia"
pass "fork/epoch block miner: ${fork_miner}"

# 4. parlia_getValidators at fork block returns 3 validators
log "Checking parlia_getValidators at block ${PARLIA_GENESIS_BLOCK}..."
parlia_resp=$(curl -sS -X POST "$HTTP1" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"parlia_getValidators\",\"params\":[\"0x$(printf '%x' "$PARLIA_GENESIS_BLOCK")\"],\"id\":1}")
val_count=$(echo "$parlia_resp" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(len(d.get('result',[])))" 2>/dev/null || echo 0)
[[ "$val_count" -eq 3 ]] || \
  fail "parlia_getValidators at block ${PARLIA_GENESIS_BLOCK}: expected 3 validators, got ${val_count}"
pass "parlia_getValidators at fork/epoch block returned ${val_count} validators"

# 5. Block PGB+1 exists — the critical assertion.
# errExtraValidators or signer mismatch would stall the chain here.
post_fork_hash=$(attach_exec "$GETH" "$IPC1" "eth.getBlock($((PARLIA_GENESIS_BLOCK+1))).hash")
[[ "$post_fork_hash" != "null" && -n "$post_fork_hash" ]] || \
  fail "post-fork block $((PARLIA_GENESIS_BLOCK+1)) missing — chain stalled at fork/epoch boundary (errExtraValidators or signer mismatch)"
pass "post-fork block $((PARLIA_GENESIS_BLOCK+1)) exists: ${post_fork_hash:0:14}..."

# 6. First Parlia epoch boundary block exists
log "Checking first Parlia epoch boundary block ${FIRST_PARLIA_EPOCH}..."
first_epoch_hash=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${FIRST_PARLIA_EPOCH}).hash")
[[ "$first_epoch_hash" != "null" && -n "$first_epoch_hash" ]] || \
  fail "first Parlia epoch boundary block ${FIRST_PARLIA_EPOCH} missing"
pass "first Parlia epoch boundary block ${FIRST_PARLIA_EPOCH} exists: ${first_epoch_hash:0:14}..."

# 7. All three nodes agree at POST_FIRST_PARLIA_EPOCH
log "Checking all 3 nodes agree at block ${POST_FIRST_PARLIA_EPOCH}..."
assert_same_hash_at "$POST_FIRST_PARLIA_EPOCH" \
  "$GETH" "$(val_ipc 1)" \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"
pass "all 3 nodes agree on block ${POST_FIRST_PARLIA_EPOCH}"

# ── Phase 9: stop ──────────────────────────────────────────────────────────────
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
