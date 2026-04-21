#!/usr/bin/env bash
# T-3: User transaction submitted while the Clique chain is stalled crosses
# the fork boundary and is mined in a post-fork Parlia block.
#
# Scenario:
#   1. Run the standard T-1 setup: 3 validators, Clique genesis, reach PRE_STOP.
#   2. Stop all validators at PRE_STOP (chain frozen).
#   3. Restart val-1 in sync-only mode (no --mine, no peers live) so the chain
#      stays frozen at PRE_STOP.
#   4. Submit a user transaction via val-1's IPC; it enters the txpool but
#      cannot be mined (val-1 is not mining and has no live peers).
#   5. Stop val-1 (graceful SIGTERM → geth flushes the txpool journal to disk
#      at <datadir>/geth/transactions.rlp).
#   6. Write TOML override and restart all 3 validators with ParliaGenesisBlock.
#      Val-1 reloads the txpool journal on startup and re-broadcasts the pending
#      transaction to peers once the mesh is wired.
#   7. The chain crosses ParliaGenesisBlock and enters Parlia mode.
#   8. Assert: transaction is mined at blockNumber >= ParliaGenesisBlock,
#      receipt status is 0x1, and the recipient balance reflects the transfer.
#
# Environment:
#   GETH                  path to geth binary (required)
#   PARLIA_GENESIS_BLOCK  fork block (default: 20)
#   PORT_BASE             base port offset; auto-selected if unset
#   DATADIR_ROOT          test data dir; auto-selected if unset
#   KEEP_RUNNING=1        leave nodes up after PASS
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

if [[ -z "${GETH:-}" ]]; then
  echo "[$(date +'%H:%M:%S')] Building v2 binary (set GETH=... to skip)..."
  (cd "${_REPO_ROOT}" && CGO_CFLAGS="-O -D__BLST_PORTABLE__" CGO_CFLAGS_ALLOW="-O -D__BLST_PORTABLE__" make geth)
fi

_PORT_BASE_EXPLICIT=${PORT_BASE+set}
_DATADIR_ROOT_EXPLICIT=${DATADIR_ROOT+set}

source "${SCRIPT_DIR}/lib.sh"

# Create a shared venv for test dependencies so pip installs are isolated from
# the system Python (works on Debian PEP-668 environments and any other distro).
# The venv is stored alongside the scripts and reused across runs.
_VENV="${SCRIPT_DIR}/.venv"
[[ -d "$_VENV" ]] || python3 -m venv "$_VENV"
# shellcheck source=/dev/null
source "${_VENV}/bin/activate"

ensure_python_deps eth-account

if [[ "${_PORT_BASE_EXPLICIT}" != "set" ]]; then
  PORT_BASE=$(find_free_port_base)
  log "Auto-selected PORT_BASE=${PORT_BASE}"
fi
export PORT_BASE

if [[ "${_DATADIR_ROOT_EXPLICIT:-}" != "set" ]]; then
  export DATADIR_ROOT="${SCRIPT_DIR}/data-${PORT_BASE}"
fi

TOML_CONFIG="${DATADIR_ROOT}/override.toml"
TRANSFER_WEI="1000000000000000000"  # 1 ETH in wei

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

# Start a single validator without --mine so it accepts RPC but does not seal.
# Used to inject a transaction into the txpool while the chain is frozen.
start_sync_validator() {
  local n="$1"
  local dir addr pw p2p http logfile pidfile
  dir=$(val_dir "$n")
  addr=$(val_addr "$n")
  pw=$(val_pw "$n")
  p2p=$(p2p_port "$n")
  http=$(http_port "$n")
  logfile=$(val_log "$n")
  pidfile=$(val_pid "$n")

  stop_pidfile "$pidfile"

  log "Starting validator-${n} in sync-only mode (no mining)"
  (
    nohup "$GETH" \
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
      --http.api "eth,net,web3,admin,miner" \
      --syncmode full \
      --unlock "$addr" \
      --password "$pw" \
      --allow-insecure-unlock \
      --nousb \
      >>"$logfile" 2>&1 &
    echo $! > "$pidfile"
  )
  wait_for_ipc "$GETH" "$(val_ipc "$n")" 60
}

# ── Phase 1: setup ────────────────────────────────────────────────────────────
run "${SCRIPT_DIR}/04-clean.sh"
run "${SCRIPT_DIR}/01-setup.sh"

# ── Phase 2: start Clique network ────────────────────────────────────────────
run "${SCRIPT_DIR}/02-start.sh"

# ── Phase 2.5: create a non-validator user account and fund it ────────────────
# A validator address CANNOT be used as the tx sender: Parlia increments the
# coinbase nonce via system transactions in every block that validator mines.
# After the fork the journal tx (nonce=0) becomes stale and is dropped by the
# TxTracker before it is ever added to the txpool.  A dedicated non-validator
# account is unaffected by system-transaction nonce increments.
log "Generating ephemeral non-validator user account (Python eth_account)..."
read -r USER_ADDR USER_KEY < <(python3 -c "
from eth_account import Account
acct = Account.create()
print(acct.address, acct.key.hex())
")
[[ "$USER_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "failed to generate user account"
log "User account: ${USER_ADDR}"

_fund_http="http://127.0.0.1:$(http_port 1)"
_v1_early=$(val_addr 1)
_fund_tx=$(attach_exec "$GETH" "$(val_ipc 1)" \
  "eth.sendTransaction({from:'${_v1_early}',to:'${USER_ADDR}',value:web3.toWei('2','ether'),gas:21000,gasPrice:1000000000})")
[[ "$_fund_tx" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "failed to fund user account: ${_fund_tx}"
_fund_deadline=$(( $(date +%s) + 30 ))
while [[ $(date +%s) -lt $_fund_deadline ]]; do
  _fund_blk=$(curl -sS -X POST "$_fund_http" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"${_fund_tx}\"],\"id\":1}" \
    2>/dev/null | python3 -c \
    "import json,sys; d=json.load(sys.stdin); r=d.get('result'); print(r.get('blockNumber','') if r else '')" \
    2>/dev/null || true)
  [[ -n "$_fund_blk" ]] && break
  sleep 1
done
[[ -n "$_fund_blk" ]] || die "funding tx ${_fund_tx} not mined within 30s"
log "User account funded with 2 ETH (mined at block ${_fund_blk})."

# ── Phase 3: wait for stable Clique history ──────────────────────────────────
# Stop 5 blocks before the fork so there is room for the chain to race ahead
# without crossing ParliaGenesisBlock before 03-stop.sh fires.  Val-1 runs
# sync-only (no mining) after the stop, so no Clique blocks will be produced
# between tx submission and the full Parlia restart regardless of the gap.
PRE_STOP=$(( PARLIA_GENESIS_BLOCK - 5 ))
if [[ "$PRE_STOP" -lt 3 ]]; then PRE_STOP=3; fi
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

_current=$(head_number "$GETH" "$(val_ipc 1)")
log "All nodes converged at block ${_current}. Stopping all validators."

# ── Phase 4: stop all validators (chain frozen at PRE_STOP) ──────────────────
run "${SCRIPT_DIR}/03-stop.sh"
mkdir "/tmp/transition-test-reserved-${PORT_BASE}" 2>/dev/null || true

# ── Phase 5: restart val-1 in sync-only mode (no peers, no mining) ───────────
# Val-2 and val-3 are offline.  Val-1 has no peers and is not mining, so the
# chain stays frozen at PRE_STOP.  Any transaction submitted here enters the
# txpool but cannot be mined.
start_sync_validator 1

# Read the exact frozen head now that the chain is completely still (val-1 has
# no peers and is not mining; vals 2/3 are stopped).  Set ParliaGenesisBlock to
# frozen_head + 1: the very next block produced after the full restart will be
# the first Parlia block, leaving zero Clique blocks that could mine the pending tx.
_frozen_head=$(head_number "$GETH" "$(val_ipc 1)")
_ORIG_PARLIA_GENESIS_BLOCK="$PARLIA_GENESIS_BLOCK"
PARLIA_GENESIS_BLOCK=$(( _frozen_head + 1 ))
log "Frozen head: ${_frozen_head}. ParliaGenesisBlock adjusted to ${PARLIA_GENESIS_BLOCK}"

V1_ADDR=$(val_addr 1)
V2_ADDR=$(val_addr 2)
# Use HTTP JSON-RPC to get exact hex balance; avoid geth console scientific notation
# (e.g. "1e+24") which causes int() precision loss in Python3.
HTTP1="http://127.0.0.1:$(http_port 1)"
V2_BALANCE_BEFORE=$(curl -sS -X POST "$HTTP1" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"${V2_ADDR}\",\"latest\"],\"id\":1}" \
  | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))")
log "val-2 balance before transfer: ${V2_BALANCE_BEFORE} wei"

# ── Phase 6: sign and submit user transaction (enters txpool, cannot be mined) ─
# Sign locally with eth_account; submit via eth_sendRawTransaction over HTTP.
# No geth account unlock needed — the private key never touches the keystore.
log "Signing transaction locally: ${USER_ADDR} → ${V2_ADDR} (1 ETH)"
USER_NONCE=$(curl -sS -X POST "$HTTP1" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionCount\",\"params\":[\"${USER_ADDR}\",\"latest\"],\"id\":1}" \
  | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))")
RAW_TX=$(python3 -c "
from eth_account import Account
signed = Account.from_key('${USER_KEY}').sign_transaction({
    'nonce': ${USER_NONCE},
    'to': '${V2_ADDR}',
    'value': 10**18,
    'gas': 21000,
    'gasPrice': 10**9,
    'chainId': ${CHAIN_ID},
})
raw = getattr(signed, 'raw_transaction', None) or getattr(signed, 'rawTransaction', None)
print('0x' + raw.hex())
")
TX_HASH=$(curl -sS -X POST "$HTTP1" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"${RAW_TX}\"],\"id\":1}" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result') or d.get('error',{}).get('message',''))")
[[ "$TX_HASH" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "failed to submit transaction: ${TX_HASH}"
log "Transaction submitted: ${TX_HASH}"

# Confirm the tx is pending (blockNumber should be null since no block can be produced)
sleep 1
pending_block=$(attach_exec "$GETH" "$(val_ipc 1)" \
  "(function(){ var t=eth.getTransaction('${TX_HASH}'); return t?String(t.blockNumber):'null'; })()")
if [[ "$pending_block" != "null" && -n "$pending_block" ]]; then
  die "transaction unexpectedly mined at block ${pending_block} (chain should be stalled)"
fi
log "Transaction is pending in val-1 txpool (blockNumber=null, as expected)"

# ── Phase 7: stop val-1 (SIGTERM flushes txpool journal to disk) ─────────────
# Must be strictly-graceful: SIGKILL prevents geth from flushing the txpool
# journal, which is the exact artifact this test is verifying.
log "Stopping val-1 (txpool journal written on graceful shutdown)..."
_val1_pid=""
[[ -f "$(val_pid 1)" ]] && _val1_pid=$(cat "$(val_pid 1)" 2>/dev/null || true)
if [[ -n "$_val1_pid" ]] && kill -0 "$_val1_pid" 2>/dev/null; then
  kill "$_val1_pid"
  _stop_deadline=$(( $(date +%s) + 30 ))
  while kill -0 "$_val1_pid" 2>/dev/null && [[ $(date +%s) -lt $_stop_deadline ]]; do
    sleep 0.5
  done
  kill -0 "$_val1_pid" 2>/dev/null && \
    die "val-1 (pid=${_val1_pid}) did not exit within 30s after SIGTERM — txpool journal may be incomplete"
fi
rm -f "$(val_pid 1)"
mkdir "/tmp/transition-test-reserved-${PORT_BASE}" 2>/dev/null || true

JOURNAL_PATH="$(val_dir 1)/geth/transactions.rlp"
_journal_deadline=$(( $(date +%s) + 5 ))
while [[ ! -f "$JOURNAL_PATH" ]] && [[ $(date +%s) -lt $_journal_deadline ]]; do
  sleep 0.5
done
[[ -f "$JOURNAL_PATH" ]] || \
  die "txpool journal not found at ${JOURNAL_PATH} after graceful shutdown — geth did not flush it"
log "Txpool journal written: ${JOURNAL_PATH}"

# ── Phase 8: write TOML override and restart all with ParliaGenesisBlock ──────
# Val-1 reloads the txpool journal on startup; the pending transaction will be
# re-broadcast to val-2 and val-3 once the peer mesh is wired by 02-start.sh.
log "Writing TOML override: ${TOML_CONFIG}"
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
    log "Chain advancing (head=${_head_now} >= target=${_target})."
    break
  fi

  if [[ "$_restart_attempt" -ge 5 ]]; then
    die "chain did not advance after ${_restart_attempt} restart attempts"
  fi
  log "WARNING: chain stalled. Stopping for retry..."
  "${SCRIPT_DIR}/03-stop.sh"
  mkdir "/tmp/transition-test-reserved-${PORT_BASE}" 2>/dev/null || true
done

# ── Phase 9: verify transaction is in val-1's txpool after restart ────────────
# The journal (transactions.rlp) must be reloaded by geth on startup.  Verifying
# this immediately gives a clear error instead of a misleading receipt timeout.
log "Verifying transaction ${TX_HASH} is pending in val-1 txpool after restart..."
HTTP1="http://127.0.0.1:$(http_port 1)"
_txpool_deadline=$(( $(date +%s) + 30 ))
_tx_in_pool=false
while [[ $(date +%s) -lt $_txpool_deadline ]]; do
  _tx_result=$(curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionByHash\",\"params\":[\"${TX_HASH}\"],\"id\":1}" \
    2>/dev/null || true)
  _tx_status=$(echo "$_tx_result" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); r=d.get('result'); print('pending' if r and r.get('blockNumber') is None else 'found' if r else 'missing')" \
    2>/dev/null || echo missing)
  if [[ "$_tx_status" != "missing" ]]; then
    log "Transaction ${_tx_status} in val-1 after restart (txpool journal reloaded)."
    _tx_in_pool=true
    break
  fi
  sleep 1
done
"$_tx_in_pool" || \
  die "transaction ${TX_HASH} not found in val-1 30s after restart — txpool journal did not reload (journal: ${JOURNAL_PATH})"

# ── Phase 10: wait for all nodes to cross the fork ───────────────────────────
POST_FORK=$(( PARLIA_GENESIS_BLOCK + 5 ))
log "Waiting for all nodes to reach block ${POST_FORK}..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_FORK" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

# ── Phase 11: wait for the pending transaction to be mined ───────────────────
log "Waiting for transaction ${TX_HASH} to be mined in a Parlia block..."
TX_RECEIPT=""
TX_BLOCK_HEX=""
deadline=$(( $(date +%s) + 120 ))
while [[ $(date +%s) -lt $deadline ]]; do
  TX_RECEIPT=$(curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"${TX_HASH}\"],\"id\":1}" \
    2>/dev/null || true)
  TX_BLOCK_HEX=$(echo "$TX_RECEIPT" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); r=d.get('result') or {}; print(r.get('blockNumber',''))" \
    2>/dev/null || true)
  [[ -n "$TX_BLOCK_HEX" ]] && break
  sleep 2
done
[[ -n "$TX_BLOCK_HEX" ]] || \
  die "transaction ${TX_HASH} not mined within timeout (tx was in txpool but not included — check FinalizeAndAssemble / IsSystemTransaction)"

TX_BLOCK_DEC=$(( TX_BLOCK_HEX ))
log "Transaction mined at block ${TX_BLOCK_DEC}"

# ── Phase 12: verification ────────────────────────────────────────────────────
PASS=0; FAIL=0
ok()   { log "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { log "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

# 1. Mined in a post-fork Parlia block
if [[ "$TX_BLOCK_DEC" -ge "$PARLIA_GENESIS_BLOCK" ]]; then
  ok "Transaction mined at Parlia block ${TX_BLOCK_DEC} (>= ParliaGenesisBlock ${PARLIA_GENESIS_BLOCK})"
else
  fail "Transaction mined at Clique block ${TX_BLOCK_DEC} (expected >= ${PARLIA_GENESIS_BLOCK})"
fi

# 2. Receipt status = success
TX_STATUS=$(echo "$TX_RECEIPT" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); r=d.get('result') or {}; print(r.get('status',''))" \
  2>/dev/null || true)
if [[ "$TX_STATUS" == "0x1" ]]; then
  ok "Transaction status: 0x1 (success)"
else
  fail "Transaction status unexpected: ${TX_STATUS:-empty}"
fi

# 3. Recipient balance increased by at least TRANSFER_WEI
# Using >= to tolerate any Parlia block rewards val-2 may have earned.
V2_BALANCE_AFTER=$(curl -sS -X POST "$HTTP1" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"${V2_ADDR}\",\"latest\"],\"id\":1}" \
  | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))")
balance_ok=$(python3 -c \
  "print('ok' if int('${V2_BALANCE_AFTER}') >= int('${V2_BALANCE_BEFORE}') + int('${TRANSFER_WEI}') else 'fail')" \
  2>/dev/null || echo fail)
if [[ "$balance_ok" == "ok" ]]; then
  ok "val-2 balance: ${V2_BALANCE_BEFORE} → ${V2_BALANCE_AFTER} (increased by >= ${TRANSFER_WEI} wei)"
else
  fail "val-2 balance did not increase by ${TRANSFER_WEI}: before=${V2_BALANCE_BEFORE}, after=${V2_BALANCE_AFTER}"
fi

# 4. Standard fork transition checks (snapshot, contract deployment, miner field)
run "${SCRIPT_DIR}/05-verify.sh"
PARLIA_GENESIS_BLOCK="$_ORIG_PARLIA_GENESIS_BLOCK"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "===================================="
echo "  T-3 tx-across-fork results"
echo "  PASS: ${PASS}   FAIL: ${FAIL}"
echo "===================================="
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED" >&2
  exit 1
fi

if [[ "${KEEP_RUNNING:-0}" -eq 1 ]]; then
  echo "PASS. KEEP_RUNNING=1 — nodes remain running."
  exit 0
fi

echo
echo "==> Stopping nodes"
"${SCRIPT_DIR}/03-stop.sh"
echo
echo "PASS"
