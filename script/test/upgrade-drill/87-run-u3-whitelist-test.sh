#!/usr/bin/env bash
#
# 87-run-u3-whitelist-test.sh — T-6.b: StakeHub whitelist election-priority test
#
# Verifies that the StakeHub validator whitelist mechanism introduced by Feynman
# works correctly:
#   1. All 3 genesis validators are whitelisted and receive WHITELIST_VOTING_POWER
#      in getValidatorElectionInfo (initial state).
#   2. Removing a validator from the whitelist reduces its election voting power.
#   3. Restoring a validator to the whitelist restores WHITELIST_VOTING_POWER.
#   4. Disabling the global whitelistEnabled toggle removes WHITELIST_VOTING_POWER
#      for all validators simultaneously.
#   5. Re-enabling whitelistEnabled restores WHITELIST_VOTING_POWER for all.
#
# Prerequisites:
#   - U-3 (82-run-u3-shanghai-feynman.sh) has completed successfully.
#   - All 3 nodes are still running (left up by 82-run-u3 or KEEP_RUNNING=1).
#   - Validators have called StakeHub.createValidator() (done by U-3 script).
#
# NOTE: The full governance path (BSCGovernor → BSCTimelock → GovHub →
# StakeHub.updateParam) requires a 7-day voting period and a 24-hour timelock —
# not feasible for a local drill. This script exercises the whitelist contract
# LOGIC directly via geth's debug.setStorageAt (available on IPC endpoints of
# test nodes running with InsecureUnlockAllowed). The governance path is tested
# in cloud testnet scope (E-2/S-1).
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

# Consensus addresses from parliagenesis/default/validators.conf.
# In the default local drill, consensus == operator == fee address for each node.
VAL1_CONSENSUS="0xc3edefb989fa00ca0e36ce30a810c4be7c4a201f"
VAL2_CONSENSUS="0x6c5e5fc2e9710803d661de6b1a4a8fbedb9674e7"
VAL3_CONSENSUS="0x6bde80699ea85293811e91a4fea2434df3461d66"

IPC1=$(val_ipc 1)
HTTP1="http://127.0.0.1:$(http_port 1)"

PASS=0; FAIL=0
ok()   { log "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { log "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

# ── Helpers ───────────────────────────────────────────────────────────────────

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

# Read a storage slot (hex key or decimal) from StakeHub.
read_slot() {
  attach_exec "$GETH" "$IPC1" \
    "eth.getStorageAt('${STAKE_HUB}', '${1}', 'latest')" 2>/dev/null
}

# Write a storage slot via the debug namespace.
# debug.setStorageAt returns null on success; geth attach exits non-zero for null
# output, so we force return 0. Correctness of the write is verified by the
# subsequent eth_call assertions rather than by the return value here.
write_slot() {
  attach_exec "$GETH" "$IPC1" \
    "debug.setStorageAt('${STAKE_HUB}', '${1}', '${2}')" 2>/dev/null
  return 0
}

ZERO_32="0x0000000000000000000000000000000000000000000000000000000000000000"
ONE_32="0x0000000000000000000000000000000000000000000000000000000000000001"

# Extract votingPowers[] from the ABI-encoded return of getValidatorElectionInfo.
# Prints one decimal integer per line, or exits non-zero on empty/malformed input.
parse_voting_powers() {
  python3 -c "
import sys
raw = '''${1}'''.strip()
if not raw or raw == '0x':
    print('parse_voting_powers: empty result', file=sys.stderr)
    sys.exit(1)
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

# Count how many validators in the current getValidatorElectionInfo result have
# voting power equal to WHITELIST_VP.  Dies if the RPC result is empty/malformed.
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
# Computed via geth's BigNumber to avoid any float/precision issues.
WHITELIST_VP=$(attach_exec "$GETH" "$IPC1" \
  "web3.toBigNumber('0x' + 'ff'.repeat(8)).times(web3.toBigNumber('10000000000')).toString(10)" \
  2>/dev/null)
if [[ -z "$WHITELIST_VP" || "$WHITELIST_VP" == "null" ]]; then
  die "Failed to compute WHITELIST_VOTING_POWER via geth BigNumber"
fi

# ── Pre-compute selectors and call data ──────────────────────────────────────
log "T-6.b  whitelist election-priority test"
log "  StakeHub           : ${STAKE_HUB}"
log "  WHITELIST_VP       : ${WHITELIST_VP}"
log "  Computing selectors..."

SEL_WL_ENABLED=$(selector "whitelistEnabled()")
SEL_WL_MEMBER=$(selector "validatorWhitelist(address)")
SEL_ELECTION=$(selector "getValidatorElectionInfo(uint256,uint256)")

# getValidatorElectionInfo(0, 10) — fixed call data reused throughout
ELECTION_DATA="0x${SEL_ELECTION}$(printf '%064x' 0)$(printf '%064x' 10)"

log "  Selectors ready."
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

# 1c. getValidatorElectionInfo(0,10): all 3 active validators should have WHITELIST_VP
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
#   Slot 81 : StakeHub.validatorWhitelist (mapping base)  ← expected
#   Slot 82 : StakeHub.whitelistEnabled (bool)
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

# Also confirm whitelistEnabled at slot WL_SLOT+1 is currently 0x01
WL_ENABLED_SLOT=$(printf '0x%064x' $(( WL_SLOT + 1 )))
enabled_val=$(read_slot "$WL_ENABLED_SLOT")
if [[ "${enabled_val: -2}" == "01" ]]; then
  ok "whitelistEnabled storage at slot $((WL_SLOT + 1)) confirmed: ${enabled_val}"
else
  fail "whitelistEnabled slot $((WL_SLOT + 1)): expected 0x...01, got ${enabled_val}"
fi

# ── Restore state on any exit after this point ────────────────────────────────
# Ensures Phase 3/4 storage writes are always reversed even if a later assertion
# fails and the script exits early, so U-4 inherits a clean StakeHub state.
VAL1_KEY=$(mapping_key "$VAL1_CONSENSUS" "$WL_SLOT")
_restore_state() {
  write_slot "$VAL1_KEY"        "$ONE_32" 2>/dev/null || true
  write_slot "$WL_ENABLED_SLOT" "$ONE_32" 2>/dev/null || true
}
trap _restore_state EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 — remove val1 from whitelist, verify reduced power, restore
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 3: remove / restore val1 from whitelist"

# 3a. Remove val1
write_slot "$VAL1_KEY" "$ZERO_32"
padded=$(printf '%064s' "${VAL1_CONSENSUS#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_MEMBER}${padded}")
if ! is_true "$raw"; then
  ok "validatorWhitelist(val1) == false after removal"
else
  fail "validatorWhitelist(val1): still true after removal via debug.setStorageAt"
fi

raw=$(eth_call_raw "$STAKE_HUB" "$ELECTION_DATA")
wl_count=$(count_wl_validators "$raw")
if [[ "$wl_count" -eq 2 ]]; then
  ok "getValidatorElectionInfo: 2 validators have WHITELIST_VOTING_POWER (val1 removed)"
else
  fail "getValidatorElectionInfo: expected 2 with WHITELIST_VOTING_POWER, got ${wl_count}"
fi

# 3b. Restore val1
write_slot "$VAL1_KEY" "$ONE_32"
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_MEMBER}${padded}")
if is_true "$raw"; then
  ok "validatorWhitelist(val1) == true after restore"
else
  fail "validatorWhitelist(val1): still false after restore"
fi

raw=$(eth_call_raw "$STAKE_HUB" "$ELECTION_DATA")
wl_count=$(count_wl_validators "$raw")
if [[ "$wl_count" -eq 3 ]]; then
  ok "getValidatorElectionInfo: all 3 have WHITELIST_VOTING_POWER after restore"
else
  fail "getValidatorElectionInfo: expected 3 after restore, got ${wl_count}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4 — disable whitelistEnabled, verify no WHITELIST_VP, re-enable
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "Phase 4: toggle whitelistEnabled"

# 4a. Disable
write_slot "$WL_ENABLED_SLOT" "$ZERO_32"
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_ENABLED}")
if ! is_true "$raw"; then
  ok "whitelistEnabled() == false after toggle"
else
  fail "whitelistEnabled(): still true after toggling to false"
fi

raw=$(eth_call_raw "$STAKE_HUB" "$ELECTION_DATA")
wl_count=$(count_wl_validators "$raw")
if [[ "$wl_count" -eq 0 ]]; then
  ok "getValidatorElectionInfo: 0 validators have WHITELIST_VOTING_POWER (whitelistEnabled=false)"
else
  fail "getValidatorElectionInfo: expected 0 with WHITELIST_VOTING_POWER when disabled, got ${wl_count}"
fi

# 4b. Re-enable
write_slot "$WL_ENABLED_SLOT" "$ONE_32"
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_ENABLED}")
if is_true "$raw"; then
  ok "whitelistEnabled() == true after re-enable"
else
  fail "whitelistEnabled(): still false after re-enable"
fi

raw=$(eth_call_raw "$STAKE_HUB" "$ELECTION_DATA")
wl_count=$(count_wl_validators "$raw")
if [[ "$wl_count" -eq 3 ]]; then
  ok "getValidatorElectionInfo: all 3 have WHITELIST_VOTING_POWER after re-enable"
else
  fail "getValidatorElectionInfo: expected 3 after re-enable, got ${wl_count}"
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
# Summary
# ─────────────────────────────────────────────────────────────────────────────
log ""
if [[ "$FAIL" -eq 0 ]]; then
  log "[ PASS ]  T-6.b whitelist election-priority: ${PASS} checks passed"
else
  log "[ FAIL ]  T-6.b whitelist election-priority: ${PASS} passed, ${FAIL} failed"
  exit 1
fi
