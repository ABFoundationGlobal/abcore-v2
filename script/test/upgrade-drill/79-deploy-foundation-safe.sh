#!/usr/bin/env bash
# Pre-U-1: deploy Safe v1.5.0 foundation multisig (Clique phase).
#
# Deploys a 2-of-3 Safe at the baked FOUNDATION_ADDR
# 0x0B53A578F024580563Ef1349b1F2c289115f6bE8 before the Parlia switch.
# Uses pinned Safe v1.5.0 creationCode from vendor/safe-bytecode/ —
# no forge/clone needed; the address is deterministic across chain resets.
#
# Network calls use geth IPC (geth attach --exec), not HTTP, to avoid
# interference from macOS system proxies.
# Local computations (ABI encoding, keccak, address derivation) use cast.
#
# To send transactions from the deployer (anvil[4]), the key is pre-imported
# into validator-1's keystore via `geth account import` and unlocked at startup
# by overriding launch_validator to add it to --unlock with an empty password.
#
# Prerequisites:
#   - 00-init.sh has been run
#   - geth built with Safe address as DefaultValidatorContract FOUNDATION_ADDR
#     (core/systemcontracts/parliagenesis/Makefile `build` target + make geth)
#   - cast (foundry) installed (local ABI encoding only — no network calls)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

BYTECODE_DIR="${SCRIPT_DIR}/vendor/safe-bytecode"

EXPECTED_SAFE="0x0B53A578F024580563Ef1349b1F2c289115f6bE8"

# anvil[4] — dedicated Safe deployer (mnemonic: "test test … junk", index 4)
DEPLOYER_PK_HEX="47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
DEPLOYER_PK="0x${DEPLOYER_PK_HEX}"
# owners: anvil[1], anvil[2], anvil[3]
OWNER_1="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
OWNER_2="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
OWNER_3="0x90F79bf6EB2c4f870365E785982E1f101E93b906"
THRESHOLD="2"
SALT_NONCE="0"
ZERO="0x0000000000000000000000000000000000000000"

EXPECT_HASH_FACTORY="0xd5649b4de7cda86b579a5be88b8af45e4bb4fe2a54348d38e65814aae0aa5916"
EXPECT_HASH_SINGLETON="0xf3d17710639f6b10d8df16f89db7e38a5cebb6045e165de47c098ac76ff6e3c2"
EXPECT_HASH_PROXY="0x4ab6f99ef271eaf7d01acb871455935e404a5beb819b72f6c9dfd9ffa5cc0701"

require_exe "$GETH"
[[ -d "${DATADIR_ROOT}" ]] || die "DATADIR_ROOT not found: ${DATADIR_ROOT} — run 00-init.sh first"
require_file "${TOML_CONFIG}"
command -v cast >/dev/null 2>&1 || die "'cast' (foundry) not found — install via: curl -L https://foundry.paradigm.xyz | bash"

for n in 1 2 3; do
  pidfile=$(val_pid "$n")
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    die "validator-${n} is already running — stop nodes first or run via 99-run-all.sh"
  fi
done

pass() { log "  OK: $*"; PASS=$(( PASS + 1 )); }
fail() { log "  FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
PASS=0
FAIL=0

cleanup_on_exit() {
  local code=$?
  [[ "$code" -eq 0 ]] && return
  echo "FAILED (exit=${code}). Stopping nodes (logs: ${DATADIR_ROOT})." >&2
  stop_all || true
  rm -f /tmp/val1-deployer.pw /tmp/deployer.key
  exit "$code"
}
trap cleanup_on_exit EXIT

lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

load_bytecode() {
  local file="$1" want="$2" path="${BYTECODE_DIR}/$1" code got
  [[ -f "$path" ]] || die "bytecode file not found: $path"
  code="0x$(tr -d '[:space:]' < "$path" | sed 's/^0x//')"
  got=$(cast keccak "$code")
  [[ "$(lc "$got")" == "$(lc "$want")" ]] \
    || die "$file keccak mismatch: got $got, expected $want (vendor bytecode tampered)"
  echo "$code"
}

wait_for_tx() {
  local ipc="$1" tx="$2" timeout="${3:-90}" label="${4:-tx}"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    sleep 1
    local status
    status=$(attach_exec "$GETH" "$ipc" \
      "(function(){var r=eth.getTransactionReceipt('${tx}');return r?r.status:'p';})()" \
      2>/dev/null || echo "p")
    if [[ "$status" == "0x1" || "$status" == "1" ]]; then
      log "  ${label}: mined (status=1)"
      return 0
    fi
    if [[ "$status" == "0x0" || "$status" == "0" ]]; then
      die "${label}: tx ${tx} reverted (status=0)"
    fi
  done
  die "${label}: tx ${tx} not mined within ${timeout}s"
}

get_contract_addr() {
  local ipc="$1" tx="$2"
  attach_exec "$GETH" "$ipc" \
    "(function(){var r=eth.getTransactionReceipt('${tx}');return r?r.contractAddress:'null';})()" \
    2>/dev/null || echo "null"
}

# ── Phase 1: import deployer key and start network ────────────────────────────

log "79 pre-U-1: deploying foundation Safe"

# Derive deployer address from private key (local cast, no network)
DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_PK")
log "Deployer: ${DEPLOYER_ADDR}"

# Import deployer key into validator-1's keystore before starting geth
# so geth can unlock it at startup via --unlock.
log "Importing deployer key into validator-1 keystore..."
echo "$DEPLOYER_PK_HEX" > /tmp/deployer.key
"$GETH" --datadir "$(val_dir 1)" account import \
  --password /dev/null \
  /tmp/deployer.key \
  >/dev/null 2>&1 || true   # "already exists" is fine
rm -f /tmp/deployer.key

# Create a 2-line password file for val1: validator password + empty deployer password
# geth reads --password file line-by-line, one line per address in --unlock order.
VAL1_PW_FILE=$(val_pw 1)
printf '%s\n\n' "$(cat "$VAL1_PW_FILE")" > /tmp/val1-deployer.pw

# Override launch_validator so validator-1 also unlocks the deployer account.
# val2 and val3 start normally via the lib.sh version.
launch_validator() {
  local n="$1"
  local dir addr pw p2p http logfile pidfile
  dir=$(val_dir "$n")
  addr=$(val_addr "$n")
  pw=$(val_pw "$n")
  p2p=$(p2p_port "$n")
  http=$(http_port "$n")
  logfile=$(val_log "$n")
  pidfile=$(val_pid "$n")

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    log "validator-${n} already running (pid=$(cat "$pidfile"))"
    return 0
  fi

  local extra_args=()
  if [[ -n "${TOML_CONFIG:-}" && -f "${TOML_CONFIG}" ]]; then
    extra_args+=(--config "${TOML_CONFIG}")
  fi
  extra_args+=(--override.breatheblockinterval "$BREATHE_BLOCK_INTERVAL")
  extra_args+=(--verbosity "$GETH_VERBOSITY")
  if [[ -n "${GETH_VMODULE:-}" ]]; then
    extra_args+=(--vmodule "$GETH_VMODULE")
  fi

  local unlock_addrs="$addr"
  local pw_file="$pw"
  if [[ "$n" -eq 1 ]]; then
    unlock_addrs="${addr},${DEPLOYER_ADDR}"
    pw_file="/tmp/val1-deployer.pw"
  fi

  log "Starting validator-${n} (p2p=${p2p}, http=${http})"
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
      --unlock "$unlock_addrs" \
      --password "$pw_file" \
      --allow-insecure-unlock \
      --nousb \
      >>"$logfile" 2>&1 &
    echo $! > "$pidfile"
  )
}

log "Starting 3-validator Clique network (val1 also unlocks deployer)..."
for n in 1 2 3; do launch_validator "$n"; done

_pids=()
for n in 1 2 3; do
  wait_for_ipc "$GETH" "$(val_ipc "$n")" 60 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

wire_mesh

_pids=()
for n in 1 2 3; do
  wait_for_min_peers "$GETH" "$(val_ipc "$n")" 2 30 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done

wait_for_head_at_least "$GETH" "$(val_ipc 1)" 1 60
log "Clique network up. Head=$(head_number "$GETH" "$(val_ipc 1)")"

IPC1=$(val_ipc 1)

# Verify deployer is unlocked
_deployer_lc=$(lc "$DEPLOYER_ADDR")
_deployer_known=$(attach_exec "$GETH" "$IPC1" \
  "(function(){var accs=eth.accounts;for(var i=0;i<accs.length;i++){if(accs[i].toLowerCase()==='${_deployer_lc}')return true;}return false;})()" \
  2>/dev/null || echo "false")
[[ "$_deployer_known" == "true" ]] \
  || die "deployer ${DEPLOYER_ADDR} not found in unlocked accounts — key import may have failed"
log "Deployer account unlocked ✓"

# ── Idempotent short-circuit ──────────────────────────────────────────────────

EXISTING_CODE=$(attach_exec "$GETH" "$IPC1" \
  "eth.getCode('${EXPECTED_SAFE}', 'latest')" 2>/dev/null || echo "0x")
if [[ "$EXISTING_CODE" != "0x" && "${#EXISTING_CODE}" -gt 4 ]]; then
  log "Foundation Safe already deployed at ${EXPECTED_SAFE} — skipping"
  pass "Foundation Safe pre-deployed at ${EXPECTED_SAFE}"
  stop_all
  rm -f /tmp/val1-deployer.pw
  echo
  echo "================================="
  echo "  Pre-U-1 results: PASS=${PASS} FAIL=${FAIL}"
  echo "================================="
  echo "PASS (pre-U-1). Foundation Safe at ${EXPECTED_SAFE}."
  exit 0
fi

# ── Phase 2: load and verify pinned bytecodes (local cast, no network) ────────

log "Loading Safe v1.5.0 pinned bytecodes (keccak verified)..."
FACTORY_BIN=$(load_bytecode SafeProxyFactory.bin "$EXPECT_HASH_FACTORY")
SINGLETON_BIN=$(load_bytecode Safe.bin "$EXPECT_HASH_SINGLETON")
PROXY_CC=$(load_bytecode SafeProxy.bin "$EXPECT_HASH_PROXY")
log "Bytecodes loaded: factory=$(( (${#FACTORY_BIN}-2)/2 ))B singleton=$(( (${#SINGLETON_BIN}-2)/2 ))B proxy=$(( (${#PROXY_CC}-2)/2 ))B"

# ── Phase 3: pre-compute and verify Safe address (local cast, no network) ─────

FACTORY_PRED=$(cast compute-address "$DEPLOYER_ADDR" --nonce 0 | awk '{print $NF}')
SINGLETON_PRED=$(cast compute-address "$DEPLOYER_ADDR" --nonce 1 | awk '{print $NF}')

INIT=$(cast calldata \
  "setup(address[],uint256,address,bytes,address,address,uint256,address)" \
  "[$OWNER_1,$OWNER_2,$OWNER_3]" "$THRESHOLD" "$ZERO" "0x" "$ZERO" "$ZERO" 0 "$ZERO")

INIT_HASH=$(cast keccak "$INIT")
SALT=$(cast keccak "$(cast concat-hex "$INIT_HASH" "$(cast to-uint256 "$SALT_NONCE")")")
INITCODE_HASH=$(cast keccak "$(cast concat-hex "$PROXY_CC" "$(cast to-uint256 "$SINGLETON_PRED")")")

FACTORY_PRED_HEX=$(lc "$FACTORY_PRED" | sed 's/^0x//')
SALT_HEX=$(echo "$SALT" | sed 's/^0x//')
INITCODE_HEX=$(echo "$INITCODE_HASH" | sed 's/^0x//')
CREATE2_HASH=$(cast keccak "0xff${FACTORY_PRED_HEX}${SALT_HEX}${INITCODE_HEX}")
SAFE_PRED="0x${CREATE2_HASH:26}"

log "Predicted: factory=${FACTORY_PRED} singleton=${SINGLETON_PRED} Safe=${SAFE_PRED}"
[[ "$(lc "$SAFE_PRED")" == "$(lc "$EXPECTED_SAFE")" ]] \
  || die "predicted Safe ${SAFE_PRED} != expected ${EXPECTED_SAFE} — bytecode/params drifted"

# ── Phase 4: verify deployer nonce is 0 ──────────────────────────────────────

DEPLOYER_NONCE=$(attach_exec "$GETH" "$IPC1" \
  "eth.getTransactionCount('${DEPLOYER_ADDR}', 'pending')" 2>/dev/null || echo 999)
[[ "${DEPLOYER_NONCE:-999}" == "0" ]] \
  || die "deployer ${DEPLOYER_ADDR} nonce=${DEPLOYER_NONCE} (expected 0 — chain not fresh)"

# ── Phase 5: fund deployer from validator-1 ───────────────────────────────────

VAL1_ADDR=$(val_addr 1)
log "Funding deployer from validator-1 (${VAL1_ADDR})..."
FUND_TX=$(attach_exec "$GETH" "$IPC1" \
  "eth.sendTransaction({from:'${VAL1_ADDR}',to:'${DEPLOYER_ADDR}',value:web3.toWei(10,'ether'),gas:21000})")
[[ -n "$FUND_TX" && "$FUND_TX" != "null" ]] || die "funding tx send failed"
wait_for_tx "$IPC1" "$FUND_TX" 60 "fund-deployer"

# ── Phase 6: deploy SafeProxyFactory (deployer nonce 0) ───────────────────────

log "Deploying SafeProxyFactory (deployer nonce 0)..."
FACTORY_TX=$(attach_exec "$GETH" "$IPC1" \
  "eth.sendTransaction({from:'${DEPLOYER_ADDR}',data:'${FACTORY_BIN}',gas:3000000})")
[[ -n "$FACTORY_TX" && "$FACTORY_TX" != "null" ]] || die "SafeProxyFactory deploy tx send failed"
wait_for_tx "$IPC1" "$FACTORY_TX" 60 "SafeProxyFactory"
FACTORY=$(get_contract_addr "$IPC1" "$FACTORY_TX")
[[ "$(lc "$FACTORY")" == "$(lc "$FACTORY_PRED")" ]] \
  || die "factory at ${FACTORY} != predicted ${FACTORY_PRED}"
log "  factory=${FACTORY} ✓"

# ── Phase 7: deploy Safe singleton (deployer nonce 1) ─────────────────────────

log "Deploying Safe singleton (deployer nonce 1)..."
SINGLETON_TX=$(attach_exec "$GETH" "$IPC1" \
  "eth.sendTransaction({from:'${DEPLOYER_ADDR}',data:'${SINGLETON_BIN}',gas:6000000})")
[[ -n "$SINGLETON_TX" && "$SINGLETON_TX" != "null" ]] || die "Safe singleton deploy tx send failed"
wait_for_tx "$IPC1" "$SINGLETON_TX" 120 "Safe-singleton"
SINGLETON=$(get_contract_addr "$IPC1" "$SINGLETON_TX")
[[ "$(lc "$SINGLETON")" == "$(lc "$SINGLETON_PRED")" ]] \
  || die "singleton at ${SINGLETON} != predicted ${SINGLETON_PRED}"
log "  singleton=${SINGLETON} ✓"

# ── Phase 8: create Safe proxy via factory.createProxyWithNonce ───────────────

log "Creating foundation Safe proxy via factory.createProxyWithNonce..."
PROXY_CALLDATA=$(cast calldata \
  "createProxyWithNonce(address,bytes,uint256)" \
  "$SINGLETON" "$INIT" "$SALT_NONCE")
PROXY_TX=$(attach_exec "$GETH" "$IPC1" \
  "eth.sendTransaction({from:'${DEPLOYER_ADDR}',to:'${FACTORY}',data:'${PROXY_CALLDATA}',gas:400000})")
[[ -n "$PROXY_TX" && "$PROXY_TX" != "null" ]] || die "createProxyWithNonce tx send failed"
wait_for_tx "$IPC1" "$PROXY_TX" 60 "createProxyWithNonce"

# ── Phase 9: verify deployment ────────────────────────────────────────────────

CODE=$(attach_exec "$GETH" "$IPC1" \
  "eth.getCode('${EXPECTED_SAFE}','latest')" 2>/dev/null || echo "0x")
if [[ "$CODE" != "0x" && "${#CODE}" -gt 4 ]]; then
  pass "Foundation Safe deployed at ${EXPECTED_SAFE}"
else
  fail "no code at expected Safe address ${EXPECTED_SAFE} after deployment"
fi

THRESHOLD_SEL=$(attach_exec "$GETH" "$IPC1" "web3.sha3('getThreshold()').slice(2,10)")
THRESHOLD_RAW=$(attach_exec "$GETH" "$IPC1" \
  "eth.call({to:'${EXPECTED_SAFE}',data:'0x${THRESHOLD_SEL}'},'latest')" 2>/dev/null || echo "0x0")
THRESHOLD_ACTUAL=$(python3 -c "print(int('${THRESHOLD_RAW}' or '0x0', 16))" 2>/dev/null || echo 0)
if [[ "$THRESHOLD_ACTUAL" == "$THRESHOLD" ]]; then
  pass "Safe threshold=${THRESHOLD_ACTUAL}"
else
  fail "Safe threshold=${THRESHOLD_ACTUAL} (expected ${THRESHOLD})"
fi

OWNERS_SEL=$(attach_exec "$GETH" "$IPC1" "web3.sha3('getOwners()').slice(2,10)")
OWNERS_RAW=$(attach_exec "$GETH" "$IPC1" \
  "eth.call({to:'${EXPECTED_SAFE}',data:'0x${OWNERS_SEL}'},'latest')" 2>/dev/null || echo "0x")
OWNERS_CHECK=$(python3 - "$OWNERS_RAW" "$OWNER_1" "$OWNER_2" "$OWNER_3" <<'PY'
import sys
raw = sys.argv[1].strip()
expected = sorted(a.lower() for a in sys.argv[2:])
if not raw or raw == '0x' or len(raw) < 130:
    print("error:short-response")
    sys.exit(0)
data = bytes.fromhex(raw[2:])
if len(data) < 64:
    print("error:too-short")
    sys.exit(0)
offset = int.from_bytes(data[0:32], 'big')
if offset + 32 > len(data):
    print("error:bad-offset")
    sys.exit(0)
length = int.from_bytes(data[offset:offset+32], 'big')
addrs = []
for i in range(length):
    start = offset + 32 + i * 32
    if start + 32 > len(data):
        break
    addr = '0x' + data[start+12:start+32].hex().lower()
    addrs.append(addr)
got = sorted(addrs)
print("match" if got == expected else f"mismatch:{got}")
PY
)
if [[ "$OWNERS_CHECK" == "match" ]]; then
  pass "Safe owners match anvil[1,2,3]"
else
  fail "Safe owners check: ${OWNERS_CHECK}"
fi

# ── Phase 10: wait for convergence, then stop ─────────────────────────────────
# Wait for all 3 nodes to agree on the same head before stopping.  Without this,
# Clique's "signed recently" state can leave all validators unable to produce the
# next block when U-1 restarts the network (deadlock).

log "Waiting for all nodes to converge before stopping..."
_cur_head=$(head_number "$GETH" "$IPC1" 2>/dev/null || echo 0)
_target=$(( _cur_head + 3 ))
wait_for_head_at_least "$GETH" "$IPC1" "$_target" 30

_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$_target" 30 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p" || true; done

log "Stopping network. U-1 will restart from this state (Safe persists in chain data)."
stop_all
rm -f /tmp/val1-deployer.pw

echo
echo "================================="
echo "  Pre-U-1 results: PASS=${PASS} FAIL=${FAIL}"
echo "================================="

if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED" >&2
  exit 1
fi

echo "PASS (pre-U-1). Foundation Safe deployed at ${EXPECTED_SAFE}."
echo "Next: bash 80-run-u1-parlia-switch.sh"
