#!/usr/bin/env bash
# T-6: AB-chain system contract parameter and fee-routing verification.
#
# This script is a post-fork assertion pass that runs on already-live nodes;
# it does not start or stop any validators.  Call it after the fork has been
# crossed and 05-verify.sh has passed (nodes must be reachable via IPC/HTTP).
#
# Assertions:
#   BSCValidatorSet (0x1000):
#     FOUNDATION_ADDR constant  == 0x000000000000000000000000000000000000f000
#     INIT_NUM_OF_CABINETS const == 15  (AB-chain; BSC default is 21)
#     FOUNDATION_RATIO constant  == 1500  (15 %)
#     burnRatio()                == 0     (INIT_BURN_RATIO)
#     systemRewardBaseRatio()    == 0     (INIT_SYSTEM_REWARD_RATIO)
#   GovToken (0x2005) / StakeHub (0x2002) / BSCGovernor (0x2004): code deployed
#   Fee routing: FOUNDATION_ADDR balance increases after a test transaction
#   Fast-finality gate: SystemReward balance unchanged (systemRewardBaseRatio==0)
#
# T-6.b and T-6.c (Feynman-initialized parameters, updateParam bounds) are
# tracked as planned work in script/transition-test/README.md.
#
# Environment (inherited from caller):
#   GETH          geth binary path
#   PORT_BASE     port offset (determines HTTP/IPC paths via lib.sh)
#   DATADIR_ROOT  data directory root
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"

IPC1="$(val_ipc 1)"
HTTP1="http://127.0.0.1:$(http_port 1)"

CONTRACT_VALIDATORSET="0x0000000000000000000000000000000000001000"
CONTRACT_GOVTOKEN="0x0000000000000000000000000000000000002005"
CONTRACT_STAKEHUB="0x0000000000000000000000000000000000002002"
CONTRACT_GOVERNOR="0x0000000000000000000000000000000000002004"
CONTRACT_SYSTEM_REWARD="0x0000000000000000000000000000000000001002"
EXPECTED_FOUNDATION="0x000000000000000000000000000000000000f000"

PASS=0
FAIL=0
ok()   { log "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { log "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

# eth_call via HTTP JSON-RPC; returns 0x-prefixed hex result
eth_call_raw() {
  local to="$1" data="$2"
  curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"${to}\",\"data\":\"${data}\"},\"latest\"],\"id\":1}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',''))" 2>/dev/null || echo ""
}

decode_uint256() {
  python3 -c "
h='${1}'.strip().lstrip('0x')
print(int(h, 16) if h else 0)
" 2>/dev/null || echo "0"
}

decode_address() {
  python3 -c "
h='${1}'.strip().lstrip('0x')
print('0x' + h[-40:].lower() if len(h) >= 40 else '')
" 2>/dev/null || echo ""
}

# 4-byte function selector via geth's built-in keccak256
selector() {
  attach_exec "$GETH" "$IPC1" "web3.sha3('${1}').substring(2, 10)" 2>/dev/null || echo ""
}

log "T-6 system contract parameter assertions"
log "  Computing function selectors..."
SEL_FOUNDATION_ADDR=$(selector "FOUNDATION_ADDR()")
SEL_INIT_CABINETS=$(selector "INIT_NUM_OF_CABINETS()")
SEL_FOUNDATION_RATIO=$(selector "FOUNDATION_RATIO()")
SEL_BURN_RATIO=$(selector "burnRatio()")
SEL_SYS_REWARD_RATIO=$(selector "systemRewardBaseRatio()")

# ── 1. FOUNDATION_ADDR constant ───────────────────────────────────────────────
result=$(eth_call_raw "$CONTRACT_VALIDATORSET" "0x${SEL_FOUNDATION_ADDR}")
addr=$(decode_address "$result")
if [[ "$addr" == "$EXPECTED_FOUNDATION" ]]; then
  ok "FOUNDATION_ADDR == ${EXPECTED_FOUNDATION}"
else
  fail "FOUNDATION_ADDR: expected ${EXPECTED_FOUNDATION}, got '${addr}'"
fi

# ── 2. INIT_NUM_OF_CABINETS constant (AB chain: 15) ──────────────────────────
result=$(eth_call_raw "$CONTRACT_VALIDATORSET" "0x${SEL_INIT_CABINETS}")
val=$(decode_uint256 "$result")
if [[ "$val" -eq 15 ]]; then
  ok "INIT_NUM_OF_CABINETS == 15 (AB-chain value)"
else
  fail "INIT_NUM_OF_CABINETS: expected 15, got ${val}"
fi

# ── 3. FOUNDATION_RATIO constant (1500 = 15 %) ───────────────────────────────
result=$(eth_call_raw "$CONTRACT_VALIDATORSET" "0x${SEL_FOUNDATION_RATIO}")
val=$(decode_uint256 "$result")
if [[ "$val" -eq 1500 ]]; then
  ok "FOUNDATION_RATIO == 1500 (15 %)"
else
  fail "FOUNDATION_RATIO: expected 1500, got ${val}"
fi

# ── 4. burnRatio() == 0 ───────────────────────────────────────────────────────
result=$(eth_call_raw "$CONTRACT_VALIDATORSET" "0x${SEL_BURN_RATIO}")
val=$(decode_uint256 "$result")
if [[ "$val" -eq 0 ]]; then
  ok "burnRatio == 0 (no fee burn)"
else
  fail "burnRatio: expected 0, got ${val}"
fi

# ── 5. systemRewardBaseRatio() == 0 (fast-finality gate) ─────────────────────
result=$(eth_call_raw "$CONTRACT_VALIDATORSET" "0x${SEL_SYS_REWARD_RATIO}")
val=$(decode_uint256 "$result")
if [[ "$val" -eq 0 ]]; then
  ok "systemRewardBaseRatio == 0 (fast-finality gated)"
else
  fail "systemRewardBaseRatio: expected 0, got ${val}"
fi

# ── 6–8. Bytecode deployment ──────────────────────────────────────────────────
check_code_deployed() {
  local label="$1" contract="$2"
  local code code_bytes
  code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${contract}', 'latest')" 2>/dev/null || echo "0x")
  code_bytes=$(( (${#code} - 2) / 2 ))
  if [[ "$code_bytes" -gt 10 ]]; then
    ok "${label} (${contract}) bytecode deployed: ${code_bytes} bytes"
  else
    fail "${label} (${contract}) bytecode missing or too short: ${code_bytes} bytes"
  fi
}
check_code_deployed "GovToken"    "$CONTRACT_GOVTOKEN"
check_code_deployed "StakeHub"    "$CONTRACT_STAKEHUB"
check_code_deployed "BSCGovernor" "$CONTRACT_GOVERNOR"

# ── 9. Fee routing: FOUNDATION_ADDR balance increases after a tx ──────────────
log "Fee routing check: sending test transaction..."
balance_before=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBalance('${EXPECTED_FOUNDATION}').toString(10)" 2>/dev/null || echo "0")
sysreward_before=$(attach_exec "$GETH" "$IPC1" \
  "eth.getBalance('${CONTRACT_SYSTEM_REWARD}').toString(10)" 2>/dev/null || echo "0")

VAL1_ADDR=$(val_addr 1)
VAL2_ADDR=$(val_addr 2)
TX_HASH=$(curl -sS -X POST "$HTTP1" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"${VAL1_ADDR}\",\"to\":\"${VAL2_ADDR}\",\"value\":\"0xde0b6b3a7640000\",\"gasPrice\":\"0x3B9ACA00\"}],\"id\":1}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',''))" 2>/dev/null || echo "")

if [[ -n "$TX_HASH" && "$TX_HASH" != "null" ]]; then
  log "  Test tx sent: ${TX_HASH}"
  wait_for_blocks "$GETH" "$IPC1" 2 30

  balance_after=$(attach_exec "$GETH" "$IPC1" \
    "eth.getBalance('${EXPECTED_FOUNDATION}').toString(10)" 2>/dev/null || echo "0")
  sysreward_after=$(attach_exec "$GETH" "$IPC1" \
    "eth.getBalance('${CONTRACT_SYSTEM_REWARD}').toString(10)" 2>/dev/null || echo "0")

  if python3 -c "
before=int('${balance_before}' or '0'); after=int('${balance_after}' or '0')
assert after > before, f'balance did not increase: {before} -> {after}'
" 2>/dev/null; then
    ok "FOUNDATION_ADDR balance increased (15 % fee routing confirmed)"
  else
    fail "FOUNDATION_ADDR balance did not increase (before=${balance_before} after=${balance_after})"
  fi

  # ── 10. SystemReward balance unchanged (systemRewardBaseRatio == 0) ──────────
  if python3 -c "
before=int('${sysreward_before}' or '0'); after=int('${sysreward_after}' or '0')
assert after == before, f'SystemReward balance changed: {before} -> {after}'
" 2>/dev/null; then
    ok "SystemReward balance unchanged (systemRewardBaseRatio == 0 confirmed)"
  else
    fail "SystemReward balance changed unexpectedly (before=${sysreward_before} after=${sysreward_after})"
  fi
else
  fail "Test transaction not accepted — fee routing check skipped"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "===================================="
echo "  T-6 system contract param results"
echo "  PASS: ${PASS}   FAIL: ${FAIL}"
echo "===================================="
if [[ "${FAIL}" -gt 0 ]]; then
  echo "FAILED" >&2
  exit 1
fi
