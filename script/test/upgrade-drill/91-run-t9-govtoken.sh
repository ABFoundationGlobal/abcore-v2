#!/usr/bin/env bash
#
# 91-run-t9-govtoken.sh — T-9: GovToken voting-power history and transfer restrictions
#
# T-9.a  getPastVotes at a past block: confirm voting-power checkpoints recorded.
# T-9.b  getPastTotalSupply: snapshot total matches recorded value at past block.
# T-9.c  transfer and approve are blocked: all 3 transfer-related calls revert.
# T-9.d  delegates query: each validator self-delegates (set in U-3 Phase 5b).
#
# Prerequisites:
#   - U-3 completed; validators have delegated and hold govAB balance.
#
# Usage:
#   GETH=./build/bin/geth bash script/test/upgrade-drill/91-run-t9-govtoken.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

GETH=${GETH:-geth}

# ── Contract addresses ────────────────────────────────────────────────────────
GOV_TOKEN="0x0000000000000000000000000000000000002005"

VAL1=$(val_addr 1 | tr '[:upper:]' '[:lower:]')
VAL2=$(val_addr 2 | tr '[:upper:]' '[:lower:]')
VAL3=$(val_addr 3 | tr '[:upper:]' '[:lower:]')

IPC1=$(val_ipc 1)
HTTP1="http://127.0.0.1:$(http_port 1)"

PASS=0; FAIL=0
ok()   { log "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { log "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

# ── Helpers ───────────────────────────────────────────────────────────────────

eth_call_raw() {
  local to="$1" data="$2"
  curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"${to}\",\"data\":\"${data}\"},\"latest\"],\"id\":1}" \
    2>/dev/null \
  | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if "error" in resp: print("0x"); sys.exit(0)
print(resp.get("result","0x"))' || echo "0x"
}

# Returns "revert" if the call reverts, "ok:<hex>" if it succeeds.
eth_call_expect_revert() {
  local to="$1" data="$2" from_addr="${3:-}"
  local body resp
  if [[ -n "$from_addr" ]]; then
    body="{\"to\":\"${to}\",\"from\":\"${from_addr}\",\"data\":\"${data}\"}"
  else
    body="{\"to\":\"${to}\",\"data\":\"${data}\"}"
  fi
  resp=$(curl -sS -X POST "$HTTP1" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[${body},\"latest\"],\"id\":1}" \
    2>/dev/null || echo '{}')
  echo "$resp" | python3 -c "
import json, sys
resp = json.load(sys.stdin)
if 'error' in resp:
    print('revert')
elif 'result' in resp:
    r = resp['result']
    # A result of '0x' could be a silent revert; treat '0x' as revert too
    if not r or r == '0x':
        print('revert')
    else:
        print('ok:' + r[:20])
else:
    print('revert')
"
}

selector() { attach_exec "$GETH" "$IPC1" "web3.sha3('${1}').substring(2,10)" 2>/dev/null; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
wait_for_ipc "$GETH" "$IPC1" 10
code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${GOV_TOKEN}','latest')" 2>/dev/null || echo "0x")
[[ $(( (${#code} - 2) / 2 )) -gt 100 ]] || die "GovToken not deployed at ${GOV_TOKEN}. Run U-3 first."

log "T-9  GovToken voting-power history and transfer restrictions"
log "  GovToken: ${GOV_TOKEN}"
log "  VAL1: ${VAL1}  VAL2: ${VAL2}  VAL3: ${VAL3}"

# ── Compute selectors ─────────────────────────────────────────────────────────
log ""
log "Computing selectors..."
SEL_GET_VOTES=$(selector "getVotes(address)")
SEL_GET_PAST_VOTES=$(selector "getPastVotes(address,uint256)")
SEL_TOTAL_SUPPLY=$(selector "totalSupply()")
SEL_GET_PAST_TOTAL=$(selector "getPastTotalSupply(uint256)")
SEL_TRANSFER=$(selector "transfer(address,uint256)")
SEL_APPROVE=$(selector "approve(address,uint256)")
SEL_TRANSFER_FROM=$(selector "transferFrom(address,address,uint256)")
SEL_DELEGATES=$(selector "delegates(address)")

for _s in SEL_GET_VOTES SEL_GET_PAST_VOTES SEL_TOTAL_SUPPLY SEL_GET_PAST_TOTAL \
           SEL_TRANSFER SEL_APPROVE SEL_TRANSFER_FROM SEL_DELEGATES; do
  [[ "${!_s}" =~ ^[0-9a-fA-F]{8}$ ]] \
    || die "${_s}: bad selector '${!_s}' (geth attach failed?)"
done
log "  Selectors ready."

VAL1_PAD=$(printf '%064s' "${VAL1#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
VAL2_PAD=$(printf '%064s' "${VAL2#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
VAL3_PAD=$(printf '%064s' "${VAL3#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')

# ─────────────────────────────────────────────────────────────────────────────
# T-9.a — getPastVotes at a past block
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-9.a: getPastVotes at a past block ──────────────────────────────────────"

# Record current block and votes
current_block=$(attach_exec "$GETH" "$IPC1" "eth.blockNumber" 2>/dev/null || echo "0")
log "  current block: ${current_block}"

raw=$(eth_call_raw "$GOV_TOKEN" "0x${SEL_GET_VOTES}${VAL1_PAD}")
current_votes=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(0); exit()
print(int(raw, 16))
" 2>/dev/null || echo "0")
log "  GovToken.getVotes(val1) at current block: ${current_votes}"

if [[ "$current_votes" -gt 0 ]]; then
  ok "T-9.a pre: getVotes(val1) > 0 (${current_votes})"
else
  fail "T-9.a pre: getVotes(val1) == 0; validator may not have self-delegated"
fi

# Wait 2 blocks so the checkpoint at current_block is in the past
target_block=$(( current_block + 2 ))
log "  waiting for block ${target_block}..."
wait_for_head_at_least "$GETH" "$IPC1" "$target_block" 30

# getPastVotes(val1, current_block) — should equal current_votes recorded earlier
current_block_hex=$(printf '%064x' "$current_block")
raw=$(eth_call_raw "$GOV_TOKEN" "0x${SEL_GET_PAST_VOTES}${VAL1_PAD}${current_block_hex}")
past_votes=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(-1); exit()
print(int(raw, 16))
" 2>/dev/null || echo "-1")
log "  getPastVotes(val1, block=${current_block}) = ${past_votes}"

if [[ "$past_votes" -eq "$current_votes" ]]; then
  ok "T-9.a: getPastVotes(val1, ${current_block}) == ${past_votes} == current votes at snapshot"
else
  fail "T-9.a: getPastVotes(val1, ${current_block}) = ${past_votes}, expected ${current_votes}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-9.b — getPastTotalSupply
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-9.b: getPastTotalSupply ─────────────────────────────────────────────────"

snapshot_block=$(attach_exec "$GETH" "$IPC1" "eth.blockNumber" 2>/dev/null || echo "0")
raw=$(eth_call_raw "$GOV_TOKEN" "0x${SEL_TOTAL_SUPPLY}")
total_now=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(0); exit()
print(int(raw, 16))
" 2>/dev/null || echo "0")
log "  GovToken.totalSupply() at block ${snapshot_block}: ${total_now}"

if [[ "$total_now" -gt 0 ]]; then
  ok "T-9.b pre: totalSupply() > 0 (${total_now})"
else
  fail "T-9.b pre: totalSupply() == 0"
fi

# Wait 1 block
wait_for_head_at_least "$GETH" "$IPC1" "$(( snapshot_block + 1 ))" 15

snapshot_block_hex=$(printf '%064x' "$snapshot_block")
raw=$(eth_call_raw "$GOV_TOKEN" "0x${SEL_GET_PAST_TOTAL}${snapshot_block_hex}")
past_total=$(python3 -c "
raw = '${raw}'
if not raw or raw == '0x': print(-1); exit()
print(int(raw, 16))
" 2>/dev/null || echo "-1")
log "  getPastTotalSupply(block=${snapshot_block}) = ${past_total}"

if [[ "$past_total" -eq "$total_now" ]]; then
  ok "T-9.b: getPastTotalSupply(${snapshot_block}) == ${past_total} == totalSupply at snapshot"
else
  fail "T-9.b: getPastTotalSupply(${snapshot_block}) = ${past_total}, expected ${total_now}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-9.c — transfer and approve are blocked
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-9.c: transfer and approve are blocked ──────────────────────────────────"

ONE_WEI="$(printf '%064x' 1)"

# transfer(val2, 1) — should revert
transfer_data="0x${SEL_TRANSFER}${VAL2_PAD}${ONE_WEI}"
result=$(eth_call_expect_revert "$GOV_TOKEN" "$transfer_data" "$VAL1")
if [[ "$result" == "revert" ]]; then
  ok "T-9.c: transfer(val2, 1) reverted as expected (non-transferable token)"
else
  fail "T-9.c: transfer(val2, 1) did not revert (got: ${result})"
fi

# approve(val2, 1) — should revert
approve_data="0x${SEL_APPROVE}${VAL2_PAD}${ONE_WEI}"
result=$(eth_call_expect_revert "$GOV_TOKEN" "$approve_data" "$VAL1")
if [[ "$result" == "revert" ]]; then
  ok "T-9.c: approve(val2, 1) reverted as expected"
else
  fail "T-9.c: approve(val2, 1) did not revert (got: ${result})"
fi

# transferFrom(val1, val2, 1) — should revert
transfer_from_data="0x${SEL_TRANSFER_FROM}${VAL1_PAD}${VAL2_PAD}${ONE_WEI}"
result=$(eth_call_expect_revert "$GOV_TOKEN" "$transfer_from_data" "$VAL1")
if [[ "$result" == "revert" ]]; then
  ok "T-9.c: transferFrom(val1, val2, 1) reverted as expected"
else
  fail "T-9.c: transferFrom(val1, val2, 1) did not revert (got: ${result})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T-9.d — delegates query
# ─────────────────────────────────────────────────────────────────────────────
log ""
log "── T-9.d: delegates query ───────────────────────────────────────────────────"

for entry in "1:${VAL1}:${VAL1_PAD}" "2:${VAL2}:${VAL2_PAD}" "3:${VAL3}:${VAL3_PAD}"; do
  n="${entry%%:*}"; rest="${entry#*:}"; addr="${rest%%:*}"; pad="${rest##*:}"
  raw=$(eth_call_raw "$GOV_TOKEN" "0x${SEL_DELEGATES}${pad}")
  delegatee="0x${raw: -40}"
  if [[ "${delegatee,,}" == "${addr,,}" ]]; then
    ok "T-9.d: delegates(val${n}) == val${n}_operator (self-delegated)"
  else
    fail "T-9.d: delegates(val${n}) = ${delegatee}, expected ${addr}"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
if [[ "$FAIL" -eq 0 ]]; then
  log "[ PASS ]  T-9 govtoken: ${PASS} checks passed"
else
  log "[ FAIL ]  T-9 govtoken: ${PASS} passed, ${FAIL} failed"
  exit 1
fi
