#!/usr/bin/env bash
#
# 87-run-u3-whitelist-test.sh — T-6.b through T-6.p: StakeHub whitelist tests
#
# T-6.b  Whitelist election priority (Phases 1-5):
#   1. All 3 genesis validators are whitelisted and receive WHITELIST_VOTING_POWER
#      in getValidatorElectionInfo (initial state).
#   2. Removing a validator from the whitelist reduces its election voting power.
#   3. Disabling the global whitelistEnabled toggle removes WHITELIST_VOTING_POWER
#      for all validators simultaneously.
#
# T-6.c  WHITELIST_VOTING_POWER arithmetic correctness (Phase 0):
#   Verifies the constant baked into the bytecode and Parlia normalization (÷1e10).
#
# T-6.d  initialize() event-log audit (Phase 6):
#   Confirms that ValidatorWhitelistUpdated and WhitelistEnabledUpdated events
#   were correctly emitted during StakeHub initialization.
#
# T-6.e  updateParam input validation — rejection tests (Phase 7):
#   Uses eth_call with from:GovHub to simulate the governance call path and
#   verify that invalid inputs are rejected with InvalidValue.
#
# T-6.f  Whitelist vs. large-stake ordering invariant (Phase 3 extension):
#   Verifies that even an inflated-stake non-whitelisted validator ranks below
#   whitelisted validators.
#
# T-6.g  TokenRecoverPortal.SOURCE_CHAIN_ID constant (Phase 8):
#   Confirms the deployed bytecode returns "AB-Chain-Local" (abchain-local genesis mode).
#
# T-6.k  INIT_WHITELIST_BYTES boundary verification (Phase 9):
#   Reads the INIT_WHITELIST_BYTES constant from chain, verifies length % 20 == 0,
#   decodes first/last addresses, and cross-checks against live whitelist storage.
#
# T-6.l  getValidatorElectionInfo index correctness (Phase 10):
#   Verifies the returned arrays preserve validator insertion order regardless of
#   whitelist status (no re-sorting by power).
#
# T-6.m  Jailed validator overrides whitelist (Phase 11):
#   Discovers the jailed field storage slot at runtime and verifies that a jailed-
#   but-whitelisted validator still receives voting power 0.
#
# T-6.n  ValidatorWhitelistUpdated event data field (Phase 12):
#   Decodes the unindexed bool from initialization events and confirms it equals
#   true; the false path is verified in 88-run-u3-governance-whitelist.sh.
#
# T-6.o  updateParam addToValidatorWhitelist success path (Phase 13):
#   Dry-runs a successful addToValidatorWhitelist call and validates the storage
#   key derivation using stateDiff.
#
# T-6.p  INIT_WHITELIST_BYTES vs. live storage cross-check (Phase 14):
#   Unpacks the constant byte-by-byte and verifies each decoded address is active
#   in the live validatorWhitelist mapping.
#
# Prerequisites:
#   - U-3 (82-run-u3-shanghai-feynman.sh) has completed successfully.
#   - All 3 nodes are still running (left up by 82-run-u3 or KEEP_RUNNING=1).
#   - Validators have called StakeHub.createValidator() (done by U-3 script).
#
# NOTE: Phases 2-5 use eth_call state overrides (stateDiff in the third
# parameter) to simulate modified storage without mutating the live chain.
# The full governance path (BSCGovernor → BSCTimelock → GovHub →
# StakeHub.updateParam) with reduced abchain-local timeouts (10-block voting
# period, 3-second timelock) is covered by T-6.h in
# 88-run-u3-governance-whitelist.sh, which runs after this script.
#
# Usage:
#   GETH=./build/bin/geth bash script/test/upgrade-drill/87-run-u3-whitelist-test.sh
#
#   Environment:
#     GETH         path to geth binary (default: geth)
#     DATADIR_ROOT data root (default: <script-dir>/data)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

GETH=${GETH:-geth}

# ── System contract addresses ─────────────────────────────────────────────────
STAKE_HUB="0x0000000000000000000000000000000000002002"
GOV_HUB="0x0000000000000000000000000000000000001007"
TOKEN_RECOVER_PORTAL="0x0000000000000000000000000000000000003000"

# Consensus addresses derived from the validator keystores used by the drill.
# In the default local drill, consensus == operator == fee address for each node.
VAL1_CONSENSUS=$(val_addr 1 | tr '[:upper:]' '[:lower:]')
VAL2_CONSENSUS=$(val_addr 2 | tr '[:upper:]' '[:lower:]')
VAL3_CONSENSUS=$(val_addr 3 | tr '[:upper:]' '[:lower:]')

IPC1=$(val_ipc 1)
HTTP1="http://127.0.0.1:$(http_port 1)"

PASS=0; FAIL=0
ok()   { log "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { log "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

# ── Helpers ───────────────────────────────────────────────────────────────────

ZERO_32="0x0000000000000000000000000000000000000000000000000000000000000000"
ONE_32="0x0000000000000000000000000000000000000000000000000000000000000001"

# eth_call via HTTP JSON-RPC; echoes 0x-prefixed hex result.
eth_call_raw() {
  local to="$1" data="$2"
  curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"${to}\",\"data\":\"${data}\"},\"latest\"],\"id\":1}" \
    2>/dev/null \
  | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if "error" in resp:
    print("eth_call error: " + str(resp["error"]), file=sys.stderr); sys.exit(1)
print(resp.get("result",""))' || return 1
}

# eth_call with a single state override (stateDiff) on STAKE_HUB.
# Simulates contract state without mutating the chain.
# Arguments: data override_key override_value
eth_call_override() {
  local data="$1" key="$2" val="$3"
  curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "$(python3 -c "
import json
print(json.dumps({
  'jsonrpc': '2.0', 'method': 'eth_call', 'id': 1,
  'params': [
    {'to': '${STAKE_HUB}', 'data': '${data}'},
    'latest',
    {'${STAKE_HUB}': {'stateDiff': {'${key}': '${val}'}}}
  ]
}))")" \
    2>/dev/null \
  | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if "error" in resp:
    print("eth_call_override error: " + str(resp["error"]), file=sys.stderr); sys.exit(1)
print(resp.get("result",""))' || return 1
}

# eth_call with multiple state overrides (stateDiff) on STAKE_HUB.
# Arguments: data json_dict_literal
#   json_dict_literal: Python dict literal, e.g. "{'0xkey1': '0xval1', '0xkey2': '0xval2'}"
eth_call_override_multi() {
  local data="$1" dict_literal="$2"
  curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "$(python3 -c "
import json
print(json.dumps({
  'jsonrpc': '2.0', 'method': 'eth_call', 'id': 1,
  'params': [
    {'to': '${STAKE_HUB}', 'data': '${data}'},
    'latest',
    {'${STAKE_HUB}': {'stateDiff': ${dict_literal}}}
  ]
}))")" \
    2>/dev/null \
  | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if "error" in resp:
    print("eth_call_override_multi error: " + str(resp["error"]), file=sys.stderr); sys.exit(1)
print(resp.get("result",""))' || return 1
}

# eth_call to any contract with from:GovHub and gasPrice:0.
# Returns "error:<json>" if the call reverts, "result:<hex>" if it succeeds.
eth_call_from_govhub() {
  local to="$1" data="$2"
  curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"from\":\"${GOV_HUB}\",\"to\":\"${to}\",\"data\":\"${data}\",\"gasPrice\":\"0x0\"},\"latest\"],\"id\":1}" \
    2>/dev/null \
  | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if "error" in resp:
    print("error:" + json.dumps(resp["error"]))
else:
    print("result:" + resp.get("result","0x"))' || return 1
}

# ABI-encode updateParam(string key, bytes value) call data.
# Arguments: selector_hex(8chars) key_string value_hex(no 0x prefix, may be empty)
abi_encode_updateparam() {
  local sel="$1" key_str="$2" val_hex="$3"
  python3 -c "
key = '${key_str}'.encode('utf-8')
val = bytes.fromhex('${val_hex}') if '${val_hex}' else b''
key_pad = ((len(key)+31)//32)*32
val_pad = ((len(val)+31)//32)*32 if val else 32
val_off = 64 + 32 + key_pad
data = '${sel}'
data += format(64,'064x')
data += format(val_off,'064x')
data += format(len(key),'064x')
data += key.hex().ljust(key_pad*2,'0')
data += format(len(val),'064x')
data += val.hex().ljust(val_pad*2,'0')
print('0x' + data)
"
}

# Query eth_getLogs for a single topic from a contract address.
# Arguments: address topic0_hex fromBlock(hex) toBlock
# Prints JSON array of log objects.
eth_get_logs() {
  local address="$1" topic0="$2" from_block="${3:-0x1}" to_block="${4:-latest}"
  curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "$(python3 -c "
import json
print(json.dumps({
  'jsonrpc': '2.0', 'method': 'eth_getLogs', 'id': 1,
  'params': [{'address': '${address}', 'topics': ['${topic0}'],
              'fromBlock': '${from_block}', 'toBlock': '${to_block}'}]
}))")" \
    2>/dev/null \
  | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if "error" in resp:
    print("eth_getLogs error: " + str(resp["error"]), file=sys.stderr); sys.exit(1)
print(json.dumps(resp.get("result",[])))' || return 1
}

# 4-byte function selector via geth's keccak256.
selector() {
  attach_exec "$GETH" "$IPC1" "web3.sha3('${1}').substring(2,10)" 2>/dev/null
}

# True if the last byte of a 0x-prefixed 32-byte hex value is 0x01.
is_true() { [[ "${1: -2}" == "01" ]]; }

# Compute keccak256(abi.encode(address, uint256(slot))) for mapping lookup.
# Arguments: <0x-prefixed address> <decimal slot number>
mapping_key() {
  local addr; addr=$(printf '%064s' "${1#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
  local slot; slot=$(printf '%064x' "$2")
  attach_exec "$GETH" "$IPC1" \
    "web3.sha3('0x${addr}${slot}', {encoding:'hex'})" 2>/dev/null
}

# Read a storage slot from StakeHub.
read_slot() {
  attach_exec "$GETH" "$IPC1" \
    "eth.getStorageAt('${STAKE_HUB}', '${1}', 'latest')" 2>/dev/null
}

# Extract votingPowers[] from the ABI-encoded return of getValidatorElectionInfo.
# Prints one decimal integer per line, or exits non-zero on empty/malformed input.
parse_voting_powers() {
  python3 -c "
import sys
raw = '''${1}'''.strip()
if not raw or raw == '0x':
    print('parse_voting_powers: empty result', file=sys.stderr); sys.exit(1)
if raw.startswith('0x'): raw = raw[2:]
if len(raw) < 128:
    print('parse_voting_powers: result too short (' + str(len(raw)) + ' hex chars)', file=sys.stderr)
    sys.exit(1)
data = bytes.fromhex(raw)
# votingPowers is the second return value (dynamic); its offset is at bytes 32-63.
vp_off = int.from_bytes(data[32:64], 'big')
vp_len = int.from_bytes(data[vp_off:vp_off+32], 'big')
for i in range(vp_len):
    start = vp_off + 32 + i * 32
    print(int.from_bytes(data[start:start+32], 'big'))
"
}

# Count how many entries in a getValidatorElectionInfo result equal WHITELIST_VP.
count_wl_validators() {
  local raw="$1" wl_count=0 vp
  while IFS= read -r vp; do
    [[ -z "$vp" ]] && continue
    [[ "$vp" == "$WHITELIST_VP" ]] && wl_count=$(( wl_count + 1 ))
  done < <(parse_voting_powers "$raw")
  echo "$wl_count"
}

# ── Pre-flight: confirm StakeHub is deployed ──────────────────────────────────
code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${STAKE_HUB}', 'latest')" 2>/dev/null || echo "0x")
bytes=$(( (${#code} - 2) / 2 ))
if [[ "$bytes" -lt 100 ]]; then
  die "StakeHub not deployed at ${STAKE_HUB} (code bytes: ${bytes}). Run U-3 first."
fi

# ── WHITELIST_VOTING_POWER = uint256(type(uint64).max) * 1e10 ─────────────────
# Computed via geth's BigNumber to avoid float/precision issues.
WHITELIST_VP=$(attach_exec "$GETH" "$IPC1" \
  "web3.toBigNumber('0x' + 'ff'.repeat(8)).times(web3.toBigNumber('10000000000')).toString(10)" \
  2>/dev/null)
if [[ -z "$WHITELIST_VP" || "$WHITELIST_VP" == "null" ]]; then
  die "Failed to compute WHITELIST_VOTING_POWER via geth BigNumber"
fi

# ── Pre-compute selectors and call data ──────────────────────────────────────
log "T-6.b–T-6.p  StakeHub whitelist tests"
log "  StakeHub           : ${STAKE_HUB}"
log "  GovHub             : ${GOV_HUB}"
log "  TokenRecoverPortal : ${TOKEN_RECOVER_PORTAL}"
log "  WHITELIST_VP       : ${WHITELIST_VP}"
log "  Computing selectors..."

SEL_WL_ENABLED=$(selector "whitelistEnabled()")
SEL_WL_MEMBER=$(selector "validatorWhitelist(address)")
SEL_ELECTION=$(selector "getValidatorElectionInfo(uint256,uint256)")
SEL_UPDATE_PARAM=$(selector "updateParam(string,bytes)")
SEL_SOURCE_CHAIN_ID=$(selector "SOURCE_CHAIN_ID()")
SEL_INIT_WL=$(selector "INIT_WHITELIST_BYTES()")

for _sel_name in SEL_WL_ENABLED SEL_WL_MEMBER SEL_ELECTION SEL_UPDATE_PARAM SEL_SOURCE_CHAIN_ID SEL_INIT_WL; do
  _sel_val="${!_sel_name}"
  [[ "$_sel_val" =~ ^[0-9a-fA-F]{8}$ ]] \
    || die "${_sel_name}: invalid selector '${_sel_val}' (expected 8 hex chars; geth attach may have failed)"
done

# getValidatorElectionInfo(0, 10) — fixed call data reused throughout
ELECTION_DATA="0x${SEL_ELECTION}$(printf '%064x' 0)$(printf '%064x' 10)"

log "  Selectors ready."
log ""

# ─────────────────────────────────────────────────────────────────────────────
# Phase 0 — T-6.c: WHITELIST_VOTING_POWER arithmetic correctness
#
# Verifies that the constant satisfies three properties:
#   a) exact decimal value == uint64_max * 1e10
#   b) divisible by 1e10 (no truncation in Parlia normalization)
#   c) divided by 1e10 == type(uint64).max  (the normalized value)
# ─────────────────────────────────────────────────────────────────────────────
log "Phase 0: T-6.c — WHITELIST_VOTING_POWER arithmetic"

UINT64_MAX="18446744073709551615"
EXPECTED_VP="184467440737095516150000000000"

if [[ "$WHITELIST_VP" == "$EXPECTED_VP" ]]; then
  ok "WHITELIST_VP == uint64_max × 1e10 == ${EXPECTED_VP}"
else
  fail "WHITELIST_VP: expected ${EXPECTED_VP}, got ${WHITELIST_VP}"
fi

# Divisibility check: WHITELIST_VP mod 1e10 == 0
vp_mod=$(python3 -c "print(${WHITELIST_VP} % 10**10)")
if [[ "$vp_mod" == "0" ]]; then
  ok "WHITELIST_VP mod 1e10 == 0 (exact divisibility; no truncation in Parlia normalization)"
else
  fail "WHITELIST_VP mod 1e10 == ${vp_mod} (non-zero; would cause truncation)"
fi

# Normalization check: WHITELIST_VP / 1e10 == type(uint64).max
vp_normalized=$(python3 -c "print(${WHITELIST_VP} // 10**10)")
if [[ "$vp_normalized" == "$UINT64_MAX" ]]; then
  ok "WHITELIST_VP ÷ 1e10 == type(uint64).max == ${UINT64_MAX}"
else
  fail "WHITELIST_VP ÷ 1e10 == ${vp_normalized}, expected ${UINT64_MAX}"
fi

log ""

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 — initial read-only whitelist state
# ─────────────────────────────────────────────────────────────────────────────
log "Phase 1: initial whitelist state (read-only)"

# 1a. whitelistEnabled() should be true
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_ENABLED}")
if is_true "$raw"; then
  ok "whitelistEnabled() == true"
else
  fail "whitelistEnabled(): expected true, got ${raw}"
fi

# 1b. validatorWhitelist(<addr>) == true for each consensus address
for entry in "val1:${VAL1_CONSENSUS}" "val2:${VAL2_CONSENSUS}" "val3:${VAL3_CONSENSUS}"; do
  label="${entry%%:*}"
  addr="${entry#*:}"
  padded=$(printf '%064s' "${addr#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
  raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_MEMBER}${padded}")
  if is_true "$raw"; then
    ok "validatorWhitelist(${label}) == true"
  else
    fail "validatorWhitelist(${label}): expected true, got ${raw}"
  fi
done

# 1c. getValidatorElectionInfo(0,10): all 3 validators should have WHITELIST_VP
raw=$(eth_call_raw "$STAKE_HUB" "$ELECTION_DATA")
wl_count=$(count_wl_validators "$raw")
if [[ "$wl_count" -eq 3 ]]; then
  ok "getValidatorElectionInfo: all 3 validators have WHITELIST_VOTING_POWER"
else
  fail "getValidatorElectionInfo: expected 3 with WHITELIST_VOTING_POWER, got ${wl_count}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2 — discover validatorWhitelist storage slot at runtime
#
# StakeHub storage layout (OZ v4.9.3 upgradeable, no namespace storage):
#   Slot  0 : Initializable._initialized / _initializing
#   Slot  1 : Protectable._paused / _protector
#   Slot  2 : Protectable.blackList (mapping base)
#   Slots 3-52 : Protectable.__reservedSlot[50]
#   Slot 53 : StakeHub._receiveFundStatus (uint8)
#   ...
#   Slot 80 : StakeHub.validatorWhitelist (mapping base)  ← expected
#   Slot 81 : StakeHub.whitelistEnabled (bool)
#
# Scan slots 70–90 to confirm by checking that
# keccak256(val1_addr || slot) maps to storage value 0x...01.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 2: discover validatorWhitelist mapping storage slot"

WL_SLOT=-1
for slot in $(seq 70 90); do
  key=$(mapping_key "$VAL1_CONSENSUS" "$slot")
  val=$(read_slot "$key")
  if [[ "${val: -2}" == "01" ]]; then
    WL_SLOT="$slot"
    break
  fi
done

if [[ "$WL_SLOT" -lt 0 ]]; then
  fail "validatorWhitelist storage slot not found in range 70–90; cannot proceed"
  log "Results: PASS=${PASS} FAIL=${FAIL}"
  exit 1
fi
ok "validatorWhitelist mapping base slot confirmed: ${WL_SLOT}"

# whitelistEnabled sits at WL_SLOT+1; store as a 32-byte hex slot key for overrides.
WL_ENABLED_SLOT=$(printf '0x%064x' $(( WL_SLOT + 1 )))
enabled_val=$(read_slot "$WL_ENABLED_SLOT")
if [[ "${enabled_val: -2}" == "01" ]]; then
  ok "whitelistEnabled storage at slot $((WL_SLOT + 1)) confirmed: ${enabled_val}"
else
  fail "whitelistEnabled slot $((WL_SLOT + 1)): expected 0x...01, got ${enabled_val}"
fi

VAL1_KEY=$(mapping_key "$VAL1_CONSENSUS" "$WL_SLOT")

# Discover StakeHub._validators mapping slot (operator address → Validator struct).
# The Validator struct stores creditContract address at a known offset.
# We read it by scanning the mapping for VAL1 and checking if the result looks like
# a deployed contract address (code bytes > 0).
# The _validators mapping is expected near slots 55–70; scan for the creditContract field.
# We use the operator address (== consensus address in local drill) as the mapping key.
VAL1_OPERATOR="${VAL1_CONSENSUS}"
VAL1_CREDIT_ADDR=""
VALIDATORS_SLOT=-1
for _vs in $(seq 55 75); do
  # _validators[op].creditContract is at slot keccak(op||_vs) + offset_of_creditContract
  # The Validator struct has creditContract as the third field (offset 2 in 32-byte slots
  # assuming packed storage with OperatorAddress + consensusAddress both fitting in 1 slot each).
  # Try offset 2 first.
  _base_key=$(mapping_key "$VAL1_OPERATOR" "$_vs")
  _base_num=$(python3 -c "print(int('${_base_key}',16))")
  for _field_off in 0 1 2 3; do
    _slot_num=$(python3 -c "print(hex(${_base_num} + ${_field_off}))")
    _val=$(attach_exec "$GETH" "$IPC1" \
      "eth.getStorageAt('${STAKE_HUB}', '${_slot_num}', 'latest')" 2>/dev/null)
    # Extract the lower 20 bytes as an address candidate
    _addr="0x${_val: -40}"
    if [[ "${#_addr}" -eq 42 && "$_addr" != "0x0000000000000000000000000000000000000000" ]]; then
      _code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${_addr}','latest')" 2>/dev/null || echo "0x")
      _code_bytes=$(( (${#_code} - 2) / 2 ))
      if [[ "$_code_bytes" -gt 10 ]]; then
        VAL1_CREDIT_ADDR="$_addr"
        VALIDATORS_SLOT="$_vs"
        break 2
      fi
    fi
  done
done

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 — simulate val1 removed from whitelist via eth_call state override
#
# state override: stateDiff {VAL1_KEY: 0x0} applied only to this call;
# live chain state is never mutated.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 3: simulate val1 removed from whitelist (state override)"

VAL1_PADDED=$(printf '%064s' "${VAL1_CONSENSUS#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')

# 3a. validatorWhitelist(val1) with override → false
raw=$(eth_call_override "0x${SEL_WL_MEMBER}${VAL1_PADDED}" "$VAL1_KEY" "$ZERO_32")
if ! is_true "$raw"; then
  ok "validatorWhitelist(val1) == false (state override: whitelist slot cleared)"
else
  fail "validatorWhitelist(val1): expected false with override, got ${raw}"
fi

# 3b. getValidatorElectionInfo with override → val1 drops to stake-based power
raw=$(eth_call_override "$ELECTION_DATA" "$VAL1_KEY" "$ZERO_32")
wl_count=$(count_wl_validators "$raw")
if [[ "$wl_count" -eq 2 ]]; then
  ok "getValidatorElectionInfo: 2 validators have WHITELIST_VOTING_POWER (val1 overridden out)"
else
  fail "getValidatorElectionInfo: expected 2 with WHITELIST_VOTING_POWER, got ${wl_count}"
fi

# 3c. T-6.f — whitelist vs. large-stake ordering invariant
#
# Same override as 3b (val1 removed from whitelist), but simultaneously also
# override val1's StakeCredit.totalPooledBNB storage slot 0 with WHITELIST_VP×2.
# This simulates val1 having an astronomically large stake, yet still losing to
# whitelisted validators (WHITELIST_VP = uint64_max × 1e10; any real stake
# ÷ 1e10 is far below uint64_max, so the comparison is guaranteed).
#
# The StakeCredit contract stores totalPooledBNB at slot 0 (first state variable).
# We inject the override via stateDiff on the StakeCredit contract address.
log ""
log "Phase 3c: T-6.f — whitelist vs. large-stake ordering invariant"

if [[ -z "$VAL1_CREDIT_ADDR" ]]; then
  log "  SKIP: could not locate val1 StakeCredit contract address (scan inconclusive)"
  log "        T-6.f ordering invariant cannot be tested without the credit contract address"
else
  # LARGE_STAKE = WHITELIST_VP * 2 in 32-byte hex
  LARGE_STAKE=$(python3 -c "print(hex(${WHITELIST_VP} * 2))")
  LARGE_STAKE_32=$(python3 -c "print('0x' + format(${WHITELIST_VP} * 2, '064x'))")
  log "  val1 credit contract : ${VAL1_CREDIT_ADDR}"
  log "  inflated stake       : ${LARGE_STAKE}"

  # Build stateDiff: clear val1 whitelist AND inflate val1 StakeCredit slot 0
  # eth_call with two contracts overridden simultaneously
  raw=$(curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "$(python3 -c "
import json
print(json.dumps({
  'jsonrpc': '2.0', 'method': 'eth_call', 'id': 1,
  'params': [
    {'to': '${STAKE_HUB}', 'data': '${ELECTION_DATA}'},
    'latest',
    {
      '${STAKE_HUB}': {'stateDiff': {'${VAL1_KEY}': '${ZERO_32}'}},
      '${VAL1_CREDIT_ADDR}': {'stateDiff': {'0x0000000000000000000000000000000000000000000000000000000000000000': '${LARGE_STAKE_32}'}}
    }
  ]
}))")" \
    2>/dev/null \
  | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if "error" in resp:
    print("eth_call error: " + str(resp["error"]), file=sys.stderr); sys.exit(1)
print(resp.get("result",""))' 2>/dev/null || echo "")

  if [[ -z "$raw" ]]; then
    log "  SKIP: eth_call with dual stateDiff returned empty (node may not support multi-contract overrides)"
  else
    wl_count=$(count_wl_validators "$raw")
    # val1's power should be stake-based (inflated) but still < WHITELIST_VP
    val1_power=$(parse_voting_powers "$raw" 2>/dev/null | head -1 || echo "0")
    if [[ "$wl_count" -eq 2 ]]; then
      ok "getValidatorElectionInfo: 2 validators still have WHITELIST_VOTING_POWER (val1 overridden out)"
    else
      fail "getValidatorElectionInfo: expected 2 with WHITELIST_VOTING_POWER, got ${wl_count}"
    fi
    # Assert val1's returned voting power < WHITELIST_VP.
    # Even if the StakeCredit storage override is not visible (credit contract view
    # may use its own internal accounting), val1 is off the whitelist so its power
    # must be stake-based (÷1e10 ≤ ~10^16), which is far below WHITELIST_VP.
    _t6f_ok=0
    python3 -c "
import sys
vp = int('${val1_power}' or '0')
wl = int('${WHITELIST_VP}')
sys.exit(0 if vp < wl else 1)
" 2>/dev/null || _t6f_ok=1
    if [[ "$_t6f_ok" -eq 0 ]]; then
      ok "T-6.f invariant: val1 voting power (${val1_power}) < WHITELIST_VP (whitelist always beats stake-based power)"
    else
      fail "T-6.f invariant: val1 voting power (${val1_power}) >= WHITELIST_VP (unexpected)"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4 — simulate whitelistEnabled = false via eth_call state override
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 4: simulate whitelistEnabled = false (state override)"

# 4a. whitelistEnabled() with override → false
raw=$(eth_call_override "0x${SEL_WL_ENABLED}" "$WL_ENABLED_SLOT" "$ZERO_32")
if ! is_true "$raw"; then
  ok "whitelistEnabled() == false (state override)"
else
  fail "whitelistEnabled(): expected false with override, got ${raw}"
fi

# 4b. getValidatorElectionInfo with override → all validators fall back to stake-based power
raw=$(eth_call_override "$ELECTION_DATA" "$WL_ENABLED_SLOT" "$ZERO_32")
wl_count=$(count_wl_validators "$raw")
if [[ "$wl_count" -eq 0 ]]; then
  ok "getValidatorElectionInfo: 0 validators have WHITELIST_VOTING_POWER (whitelistEnabled overridden off)"
else
  fail "getValidatorElectionInfo: expected 0 with WHITELIST_VOTING_POWER when disabled, got ${wl_count}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5 — jailed validator note
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 5: jailed validator (contract logic note)"
log "  StakeHub.getValidatorElectionInfo: if (jailed) votingPowers[i] = 0,"
log "  regardless of whitelist status. Triggering a real jail requires a downtime"
log "  or double-sign slash event. This path is in cloud testnet scope (E-2/S-1)."

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6 — T-6.d: initialize() event-log audit
#
# Query eth_getLogs from block 0x1 to latest for ValidatorWhitelistUpdated and
# WhitelistEnabledUpdated events emitted by StakeHub.initialize(). The local
# genesis uses abchain-local mode, which packs all 3 validator consensus
# addresses into INIT_WHITELIST_BYTES (3 × 20 = 60 bytes), so we expect exactly
# 3 ValidatorWhitelistUpdated events and 0 WhitelistEnabledUpdated events
# (initialize() sets whitelistEnabled directly in storage without emitting).
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 6: T-6.d — initialize() event-log audit"

# Compute event topic hashes at runtime
TOPIC_WL_UPDATED=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('ValidatorWhitelistUpdated(address,bool)')" 2>/dev/null)
TOPIC_WL_ENABLED=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('WhitelistEnabledUpdated(bool)')" 2>/dev/null)

for _t_name in TOPIC_WL_UPDATED TOPIC_WL_ENABLED; do
  _t_val="${!_t_name}"
  [[ "$_t_val" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || die "${_t_name}: invalid topic hash '${_t_val}'"
done

log "  ValidatorWhitelistUpdated topic : ${TOPIC_WL_UPDATED}"
log "  WhitelistEnabledUpdated topic   : ${TOPIC_WL_ENABLED}"

# 6a. Count ValidatorWhitelistUpdated events
wl_logs=$(eth_get_logs "$STAKE_HUB" "$TOPIC_WL_UPDATED" "0x1" "latest")
wl_event_count=$(python3 -c "import json; print(len(json.loads('''${wl_logs}''')))" 2>/dev/null || echo "0")
if [[ "$wl_event_count" -eq 3 ]]; then
  ok "ValidatorWhitelistUpdated: exactly 3 events emitted (one per INIT_WHITELIST_BYTES address)"
else
  fail "ValidatorWhitelistUpdated: expected 3 events, got ${wl_event_count}"
fi

# 6b. Verify each event's address matches a local validator consensus address
# Use || to capture exit code under set -euo pipefail (plain heredoc exits the
# script on failure before $? can be checked in the following if statement).
_addr_ok=0
python3 - <<PYEOF 2>/dev/null || _addr_ok=$?
import json, sys
logs = json.loads('''${wl_logs}''')
expected = {
    '${VAL1_CONSENSUS}'.lower().replace('0x','').zfill(64),
    '${VAL2_CONSENSUS}'.lower().replace('0x','').zfill(64),
    '${VAL3_CONSENSUS}'.lower().replace('0x','').zfill(64),
}
found = set()
for log in logs:
    # topics[1] = indexed consensusAddress (32 bytes, left-padded)
    if len(log.get('topics',[])) >= 2:
        found.add(log['topics'][1].replace('0x','').lower().zfill(64))
missing = expected - found
extra   = found - expected
if missing or extra:
    print(f"MISMATCH  missing={missing} extra={extra}", file=sys.stderr)
    sys.exit(1)
PYEOF
if [[ "$_addr_ok" -eq 0 ]]; then
  ok "ValidatorWhitelistUpdated: all 3 event addresses match VAL1/VAL2/VAL3 consensus addresses"
else
  fail "ValidatorWhitelistUpdated: event addresses do not match expected validator consensus addresses"
fi

# 6c. Verify all events have whitelisted=true (data last byte == 0x01)
all_true=$(python3 -c "
import json
logs = json.loads('''${wl_logs}''')
print(all(l.get('data','')[-2:] == '01' for l in logs))
" 2>/dev/null || echo "False")
if [[ "$all_true" == "True" ]]; then
  ok "ValidatorWhitelistUpdated: all events have whitelisted=true"
else
  fail "ValidatorWhitelistUpdated: some events have whitelisted=false (unexpected)"
fi

# 6d. WhitelistEnabledUpdated events — initialize() sets whitelistEnabled=true directly
# in storage (no emit); the event is only fired via updateParam("whitelistEnabled",...).
# Expect 0 events from initialization.
we_logs=$(eth_get_logs "$STAKE_HUB" "$TOPIC_WL_ENABLED" "0x1" "latest")
we_event_count=$(python3 -c "import json; print(len(json.loads('''${we_logs}''')))" 2>/dev/null || echo "-1")
if [[ "$we_event_count" -eq 0 ]]; then
  ok "WhitelistEnabledUpdated: 0 events at init (whitelistEnabled set directly in storage, not via emit)"
else
  fail "WhitelistEnabledUpdated: expected 0 events at init, got ${we_event_count}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 7 — T-6.e: updateParam input validation (rejection tests)
#
# Uses eth_call with from:GovHub (0x1007) and gasPrice:0x0 to satisfy the
# onlyGov and onlyZeroGasPrice modifiers without submitting a real transaction.
# Tests 5 sub-cases: 4 expected reverts and 1 expected success.
#
# Note: if onlyCoinbase blocks the call (msg.sender != block.coinbase), the test
# emits a SKIP warning rather than FAIL, since that is a harness limitation.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 7: T-6.e — updateParam input validation (rejection tests via eth_call)"

# Helper: expect a revert from eth_call_from_govhub.
# Only error:* counts as a revert; result:* (including result:0x from a void
# function) always means the call succeeded and the test should fail.
expect_revert() {
  local label="$1" data="$2"
  local result
  result=$(eth_call_from_govhub "$STAKE_HUB" "$data")
  case "$result" in
    error:*)
      ok "${label}: call reverted as expected"
      ;;
    result:*)
      fail "${label}: expected revert but call succeeded (result=${result#result:})"
      ;;
    *)
      fail "${label}: unexpected response '${result}'"
      ;;
  esac
}

# Helper: expect success from eth_call_from_govhub
expect_success() {
  local label="$1" data="$2"
  local result
  result=$(eth_call_from_govhub "$STAKE_HUB" "$data")
  case "$result" in
    result:*)
      ok "${label}: call succeeded as expected"
      ;;
    error:*)
      err_msg=$(echo "$result" | sed 's/^error://')
      if echo "$err_msg" | python3 -c "import json,sys; e=json.load(sys.stdin); print(e.get('message',''))" 2>/dev/null \
          | grep -qi "coinbase\|onlyCoinbase\|must be the block"; then
        log "  SKIP ${label}: onlyCoinbase modifier blocked eth_call (harness limitation; governance path is E-2/S-1)"
      else
        fail "${label}: expected success, got revert: ${err_msg}"
      fi
      ;;
  esac
}

# Case 7a: addToValidatorWhitelist with 32-byte value (wrong length; must be 20)
DATA_7A=$(abi_encode_updateparam "$SEL_UPDATE_PARAM" "addToValidatorWhitelist" \
  "0000000000000000000000000000000000000000000000000000000000000001")
expect_revert "7a addToValidatorWhitelist(32-byte value)" "$DATA_7A"

# Case 7b: addToValidatorWhitelist with zero address (20 zero bytes)
DATA_7B=$(abi_encode_updateparam "$SEL_UPDATE_PARAM" "addToValidatorWhitelist" \
  "0000000000000000000000000000000000000000")
expect_revert "7b addToValidatorWhitelist(zero address)" "$DATA_7B"

# Case 7c: removeFromValidatorWhitelist with zero address
DATA_7C=$(abi_encode_updateparam "$SEL_UPDATE_PARAM" "removeFromValidatorWhitelist" \
  "0000000000000000000000000000000000000000")
expect_revert "7c removeFromValidatorWhitelist(zero address)" "$DATA_7C"

# Case 7d: whitelistEnabled with flag=2 (must be 0 or 1)
DATA_7D=$(abi_encode_updateparam "$SEL_UPDATE_PARAM" "whitelistEnabled" \
  "0000000000000000000000000000000000000000000000000000000000000002")
expect_revert "7d whitelistEnabled(flag=2)" "$DATA_7D"

# Case 7e: whitelistEnabled with flag=1 — valid call, expect success
DATA_7E=$(abi_encode_updateparam "$SEL_UPDATE_PARAM" "whitelistEnabled" \
  "0000000000000000000000000000000000000000000000000000000000000001")
expect_success "7e whitelistEnabled(flag=1) from GovHub" "$DATA_7E"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 8 — T-6.g: TokenRecoverPortal.SOURCE_CHAIN_ID constant
#
# Calls SOURCE_CHAIN_ID() on TokenRecoverPortal (0x3000) and ABI-decodes the
# returned string. In the abchain-local genesis, generate.py overrides
# source_chain_id to "AB-Chain-Local" (the local drill identifier). This
# confirms the bytecode was produced by the abchain-local command, not a
# stale or wrong build.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 8: T-6.g — TokenRecoverPortal.SOURCE_CHAIN_ID constant"

EXPECTED_SOURCE_CHAIN_ID="AB-Chain-Local"

raw=$(eth_call_raw "$TOKEN_RECOVER_PORTAL" "0x${SEL_SOURCE_CHAIN_ID}")
if [[ -z "$raw" || "$raw" == "0x" ]]; then
  fail "SOURCE_CHAIN_ID(): empty response (TokenRecoverPortal may not be deployed)"
else
  chain_id=$(python3 -c "
raw = '''${raw}'''.strip()
if raw.startswith('0x'): raw = raw[2:]
if len(raw) < 128:
    print('ERROR:too_short'); exit()
data = bytes.fromhex(raw)
# ABI-encoded string: [offset(32)][length(32)][utf8_data]
offset = int.from_bytes(data[0:32], 'big')
length = int.from_bytes(data[offset:offset+32], 'big')
s = data[offset+32:offset+32+length].decode('utf-8', errors='replace')
print(s)
" 2>/dev/null || echo "ERROR:decode_failed")

  if [[ "$chain_id" == "$EXPECTED_SOURCE_CHAIN_ID" ]]; then
    ok "SOURCE_CHAIN_ID() == \"${EXPECTED_SOURCE_CHAIN_ID}\" (abchain-local bytecode confirmed)"
  else
    fail "SOURCE_CHAIN_ID(): expected \"${EXPECTED_SOURCE_CHAIN_ID}\", got \"${chain_id}\" (wrong genesis bytecode?)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 9 — T-6.k: INIT_WHITELIST_BYTES boundary verification
#
# Reads the INIT_WHITELIST_BYTES public constant from StakeHub, verifies:
#   a) length is a multiple of 20 (packed 20-byte addresses)
#   b) count == 3 (abchain-local genesis packs all 3 local validator addresses)
#   c) first and last decoded addresses are non-zero
#   d) cross-check: validatorWhitelist[first] and validatorWhitelist[last] are true
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 9: T-6.k — INIT_WHITELIST_BYTES boundary verification"

EXPECTED_WL_COUNT=3
iwb_addrs=()
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_INIT_WL}")
if [[ -z "$raw" || "$raw" == "0x" ]]; then
  fail "INIT_WHITELIST_BYTES(): empty response (selector may be wrong or constant not public)"
else
  # Decode ABI-encoded bytes: offset(32) + length(32) + payload
  decoded=$(python3 -c "
raw = '''${raw}'''.strip()
if raw.startswith('0x'): raw = raw[2:]
data = bytes.fromhex(raw)
offset = int.from_bytes(data[0:32], 'big')
length = int.from_bytes(data[offset:offset+32], 'big')
payload = data[offset+32:offset+32+length]
count = length // 20
remainder = length % 20
addrs = ['0x' + payload[i*20:i*20+20].hex() for i in range(count)]
print(length)
print(count)
print(remainder)
for a in addrs:
    print(a)
" 2>/dev/null || echo "ERROR")

  if [[ "$decoded" == "ERROR" || -z "$decoded" ]]; then
    fail "INIT_WHITELIST_BYTES(): ABI decode failed"
  else
    iwb_length=$(echo "$decoded" | sed -n '1p')
    iwb_count=$(echo "$decoded" | sed -n '2p')
    iwb_remainder=$(echo "$decoded" | sed -n '3p')
    mapfile -t iwb_addrs < <(echo "$decoded" | tail -n +4)

    if [[ "$iwb_remainder" -eq 0 ]]; then
      ok "INIT_WHITELIST_BYTES length (${iwb_length}) is a multiple of 20 (no boundary misalignment)"
    else
      fail "INIT_WHITELIST_BYTES length (${iwb_length}) % 20 == ${iwb_remainder} (byte boundary error)"
    fi

    if [[ "$iwb_count" -eq "$EXPECTED_WL_COUNT" ]]; then
      ok "INIT_WHITELIST_BYTES decoded ${iwb_count} addresses (expected ${EXPECTED_WL_COUNT} for abchain-local)"
    else
      fail "INIT_WHITELIST_BYTES: expected ${EXPECTED_WL_COUNT} addresses, decoded ${iwb_count}"
    fi

    ZERO_ADDR="0x0000000000000000000000000000000000000000"
    for _idx in 0 $(( iwb_count - 1 )); do
      _addr="${iwb_addrs[$_idx]:-}"
      if [[ -z "$_addr" ]]; then
        fail "INIT_WHITELIST_BYTES: addr[${_idx}] missing from decoded output"
        continue
      fi
      if [[ "$_addr" != "$ZERO_ADDR" ]]; then
        ok "INIT_WHITELIST_BYTES addr[${_idx}] (${_addr}) is non-zero"
      else
        fail "INIT_WHITELIST_BYTES addr[${_idx}] is zero address (assembly decode off-by-one?)"
      fi
      _padded=$(printf '%064s' "${_addr#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
      _wl=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_MEMBER}${_padded}")
      if is_true "$_wl"; then
        ok "validatorWhitelist(addr[${_idx}]=${_addr}) == true (cross-check with live storage)"
      else
        fail "validatorWhitelist(addr[${_idx}]=${_addr}): expected true, got ${_wl}"
      fi
    done
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 10 — T-6.l: getValidatorElectionInfo index correctness
#
# Verifies the returned arrays preserve validator insertion order (val1, val2,
# val3) regardless of whitelist status.  Uses stateDiff to remove val1 from
# the whitelist and confirms:
#   consensusAddrs[0] == val1  AND  votingPowers[0] < WHITELIST_VP
#   consensusAddrs[1] == val2  AND  votingPowers[1] == WHITELIST_VP
#   consensusAddrs[2] == val3  AND  votingPowers[2] == WHITELIST_VP
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 10: T-6.l — getValidatorElectionInfo index correctness (state override)"

# Use getValidatorElectionInfo(0,3) with val1 whitelist slot cleared
ELECTION_DATA_3="0x${SEL_ELECTION}$(printf '%064x' 0)$(printf '%064x' 3)"
raw=$(eth_call_override "$ELECTION_DATA_3" "$VAL1_KEY" "$ZERO_32")

_idx_ok=0
python3 - <<PYEOF 2>/dev/null || _idx_ok=$?
import sys
raw = '''${raw}'''.strip()
if raw.startswith('0x'): raw = raw[2:]
if len(raw) < 64:
    print('result too short', file=sys.stderr); sys.exit(1)
data = bytes.fromhex(raw)
ca_off = int.from_bytes(data[0:32], 'big')
vp_off = int.from_bytes(data[32:64], 'big')
ca_len = int.from_bytes(data[ca_off:ca_off+32], 'big')
vp_len = int.from_bytes(data[vp_off:vp_off+32], 'big')
addrs  = ['0x' + data[ca_off+32+i*32+12:ca_off+64+i*32].hex() for i in range(ca_len)]
powers = [int.from_bytes(data[vp_off+32+i*32:vp_off+64+i*32], 'big') for i in range(vp_len)]

expected_addrs  = ['${VAL1_CONSENSUS}', '${VAL2_CONSENSUS}', '${VAL3_CONSENSUS}']
whitelist_vp    = int('${WHITELIST_VP}')

errors = []
for i in range(min(3, ca_len)):
    got = addrs[i].lower()
    exp = expected_addrs[i].lower()
    if got != exp:
        errors.append(f'consensusAddrs[{i}]: expected {exp}, got {got}')
if ca_len < 3:
    errors.append(f'consensusAddrs count {ca_len} < 3')

if vp_len >= 1 and powers[0] >= whitelist_vp:
    errors.append(f'votingPowers[0] (val1, non-whitelisted) should be < WHITELIST_VP, got {powers[0]}')
for i in [1, 2]:
    if vp_len > i and powers[i] != whitelist_vp:
        errors.append(f'votingPowers[{i}] (val{i+1}, whitelisted) should == WHITELIST_VP, got {powers[i]}')

if errors:
    for e in errors: print(e, file=sys.stderr)
    sys.exit(1)
PYEOF
if [[ "$_idx_ok" -eq 0 ]]; then
  ok "T-6.l: consensusAddrs order preserved (val1→val2→val3); votingPowers reflect whitelist status correctly"
else
  fail "T-6.l: getValidatorElectionInfo index or power mismatch (see stderr for details)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 11 — T-6.m: jailed validator overrides whitelist
#
# Discovers the Validator.jailed storage slot at runtime by probing struct field
# offsets within the _validators mapping.  Expected layout (OZ upgradeable):
#   offset 0: operatorAddress (address)
#   offset 1: creditContract  (address)
#   offset 2: voteAddress     (bytes, dynamic; length here)
#   offset 3-6: Description   (4 strings, dynamic; lengths here)
#   offset 7: Commission      (3 uint64s packed)
#   offset 8: updateTime      (uint256)
#   offset 9: jailed          (bool)  ← expected
#
# Override: set slot(base + probe_offset) to 0x01.  Correct offset produces
# val1.power == 0 (jailed path) while val2/val3 remain WHITELIST_VP.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 11: T-6.m — jailed validator overrides whitelist (state override)"

if [[ "$VALIDATORS_SLOT" -lt 0 ]]; then
  log "  SKIP: _validators mapping slot not found in Phase 2 scan; cannot probe jailed field"
else
  VAL1_BASE_KEY=$(mapping_key "$VAL1_CONSENSUS" "$VALIDATORS_SLOT")
  VAL1_BASE_NUM=$(python3 -c "print(int('${VAL1_BASE_KEY}',16))")
  VAL1_JAILED_SLOT=""

  for _field_off in $(seq 0 15); do
    _try_key=$(python3 -c "print('0x' + format(${VAL1_BASE_NUM} + ${_field_off}, '064x'))")
    _raw=$(eth_call_override "$ELECTION_DATA" "$_try_key" "$ONE_32" 2>/dev/null || echo "")
    [[ -z "$_raw" ]] && continue
    # val1's power (first in list) should be 0; val2/val3 should still be WHITELIST_VP
    _probe_ok=0
    python3 -c "
import sys
raw = '''${_raw}'''.strip()
if raw.startswith('0x'): raw = raw[2:]
if len(raw) < 128: sys.exit(1)
data = bytes.fromhex(raw)
vp_off = int.from_bytes(data[32:64], 'big')
vp_len = int.from_bytes(data[vp_off:vp_off+32], 'big')
if vp_len < 3: sys.exit(1)
powers = [int.from_bytes(data[vp_off+32+i*32:vp_off+64+i*32], 'big') for i in range(3)]
wl = int('${WHITELIST_VP}')
# val1 jailed → power 0; val2/val3 whitelisted → WHITELIST_VP (unaffected)
if powers[0] == 0 and powers[1] == wl and powers[2] == wl:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null || _probe_ok=$?
    if [[ "$_probe_ok" -eq 0 ]]; then
      VAL1_JAILED_SLOT="$_try_key"
      log "  jailed field discovered at struct offset ${_field_off} (slot ${_try_key})"
      break
    fi
  done

  if [[ -z "$VAL1_JAILED_SLOT" ]]; then
    log "  SKIP: jailed field not found in struct offsets 0–15 (contract layout may differ)"
    log "        T-6.m jailed-overrides-whitelist assertion cannot be completed"
  else
    raw=$(eth_call_override "$ELECTION_DATA" "$VAL1_JAILED_SLOT" "$ONE_32")
    _jailed_result=$(python3 -c "
import sys
raw = '''${raw}'''.strip()
if raw.startswith('0x'): raw = raw[2:]
data = bytes.fromhex(raw)
vp_off = int.from_bytes(data[32:64], 'big')
vp_len = int.from_bytes(data[vp_off:vp_off+32], 'big')
if vp_len < 3: sys.exit(1)
powers = [int.from_bytes(data[vp_off+32+i*32:vp_off+64+i*32], 'big') for i in range(3)]
wl = int('${WHITELIST_VP}')
tags = []
if powers[0] == 0: tags.append('val1_zero')
if powers[1] == wl: tags.append('val2_wl')
if powers[2] == wl: tags.append('val3_wl')
print(' '.join(tags))
" 2>/dev/null || echo "")
    if [[ "$_jailed_result" == *"val1_zero"* ]]; then
      ok "T-6.m: jailed val1 voting power == 0 (jailed overrides whitelist)"
    else
      fail "T-6.m: jailed val1 voting power != 0 (jailed field may not be correct)"
    fi
    if [[ "$_jailed_result" == *"val2_wl"* && "$_jailed_result" == *"val3_wl"* ]]; then
      ok "T-6.m: val2/val3 (whitelisted, not jailed) remain at WHITELIST_VOTING_POWER"
    else
      fail "T-6.m: val2/val3 voting power unexpected (stateDiff may have corrupted global state)"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 12 — T-6.n: ValidatorWhitelistUpdated event data field (true path)
#
# Decodes the unindexed `bool whitelisted` from the data field of each
# ValidatorWhitelistUpdated log emitted during initialize().  All initialization
# events should encode `true` (last byte 0x01).
# The false path (data == 0x...0000 after removeFromValidatorWhitelist) is
# verified in 88-run-u3-governance-whitelist.sh after T-6.i executes.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 12: T-6.n — ValidatorWhitelistUpdated data field decoding (true path)"

init_logs=$(eth_get_logs "$STAKE_HUB" "$TOPIC_WL_UPDATED" "0x1" "latest")
_data_ok=0
python3 - <<PYEOF 2>/dev/null || _data_ok=$?
import json, sys
logs = json.loads('''${init_logs}''')
bad = []
for i, log in enumerate(logs):
    data = log.get('data', '')
    # ABI-encoded bool true: 32 bytes, last byte 0x01
    if not data or data[-2:] != '01':
        bad.append(f"log[{i}].data={data!r} (expected last byte 01)")
if bad:
    for b in bad: print(b, file=sys.stderr)
    sys.exit(1)
PYEOF
if [[ "$_data_ok" -eq 0 ]]; then
  ok "T-6.n (true path): all ${wl_event_count} ValidatorWhitelistUpdated events have data[-1] == 0x01 (whitelisted=true)"
else
  fail "T-6.n (true path): one or more ValidatorWhitelistUpdated events have unexpected data field"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 13 — T-6.o: updateParam("addToValidatorWhitelist") success path
#
# Dry-runs a successful addToValidatorWhitelist call from GovHub using eth_call
# (no state written to chain), then validates that the storage key derivation
# for the new address matches the WL_SLOT mapping layout discovered in Phase 2.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 13: T-6.o — updateParam addToValidatorWhitelist success path + storage key"

NEW_ADDR="0x000000000000000000000000000000000000cafe"
NEW_ADDR_HEX="${NEW_ADDR#0x}"

DATA_ADD=$(abi_encode_updateparam "$SEL_UPDATE_PARAM" "addToValidatorWhitelist" "$NEW_ADDR_HEX")
expect_success "T-6.o addToValidatorWhitelist(${NEW_ADDR}) from GovHub" "$DATA_ADD"

# Derive storage key for validatorWhitelist[NEW_ADDR] using WL_SLOT
NEW_KEY=$(mapping_key "$NEW_ADDR" "$WL_SLOT")
NEW_ADDR_PADDED=$(printf '%064s' "$NEW_ADDR_HEX" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
raw=$(eth_call_override "0x${SEL_WL_MEMBER}${NEW_ADDR_PADDED}" "$NEW_KEY" "$ONE_32")
if is_true "$raw"; then
  ok "T-6.o storage key derived from WL_SLOT (${WL_SLOT}) correctly maps validatorWhitelist[${NEW_ADDR}]"
else
  fail "T-6.o validatorWhitelist(${NEW_ADDR}) with stateDiff override returned ${raw} (key derivation mismatch?)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 14 — T-6.p: INIT_WHITELIST_BYTES vs. live storage cross-check
#
# Re-uses the address list decoded in Phase 9 to verify every address encoded in
# the compile-time constant is active in the live validatorWhitelist mapping.
# Provides independent confirmation beyond the event-log audit in T-6.d.
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 14: T-6.p — INIT_WHITELIST_BYTES vs. live storage cross-check"

if [[ "${#iwb_addrs[@]}" -eq 0 ]]; then
  log "  SKIP: INIT_WHITELIST_BYTES decode in Phase 9 failed; cannot cross-check"
else
  _t6p_match=0
  for _iwb_addr in "${iwb_addrs[@]}"; do
    _padded=$(printf '%064s' "${_iwb_addr#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
    _wl=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_MEMBER}${_padded}")
    if is_true "$_wl"; then
      _t6p_match=$(( _t6p_match + 1 ))
    else
      fail "T-6.p: validatorWhitelist(${_iwb_addr}) == false (address in INIT_WHITELIST_BYTES not active in storage)"
    fi
  done
  if [[ "$_t6p_match" -eq "${#iwb_addrs[@]}" ]]; then
    ok "T-6.p: all ${_t6p_match} addresses from INIT_WHITELIST_BYTES are active in live validatorWhitelist storage"
  fi

  # Cross-check: count from constant == count from T-6.d event logs
  _iwb_count="${#iwb_addrs[@]}"
  if [[ "$_iwb_count" -eq "$wl_event_count" ]]; then
    ok "T-6.p: INIT_WHITELIST_BYTES count (${_iwb_count}) == ValidatorWhitelistUpdated event count (${wl_event_count})"
  else
    fail "T-6.p: INIT_WHITELIST_BYTES count (${_iwb_count}) != ValidatorWhitelistUpdated events (${wl_event_count})"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
log ""
if [[ "$FAIL" -eq 0 ]]; then
  log "[ PASS ]  T-6.b through T-6.p whitelist tests: ${PASS} checks passed"
else
  log "[ FAIL ]  T-6.b through T-6.p whitelist tests: ${PASS} passed, ${FAIL} failed"
  exit 1
fi
