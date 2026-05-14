#!/usr/bin/env bash
#
# 88-run-u3-governance-whitelist.sh — T-6.h: full governance path whitelist update
#
# Exercises the complete on-chain governance path:
#   BSCGovernor.propose → castVote × 3 → queue → (timelock) → execute
#   → StakeHub.validatorWhitelist(newAddr) == true
#
# Uses the reduced timeouts baked into the abchain-local genesis by generate.py:
#   init_voting_period          = 10 blocks  (≈ 30 s at 3 s/block)
#   init_voting_delay           = 0 blocks   (Active immediately)
#   init_min_period_after_quorum = 0 blocks
#   init_minimal_delay          = 3 seconds  (BSCTimelock; 1 block at 3 s/block)
#   propose_start_threshold     = 0 ether    (no total-supply gate)
#
# Prerequisites:
#   - U-3 (82-run-u3-shanghai-feynman.sh) completed; all 3 nodes running
#   - Validators registered via StakeHub.createValidator() (done by U-3 script)
#
# Usage:
#   GETH=./build/bin/geth bash script/test/upgrade-drill/88-run-u3-governance-whitelist.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

GETH=${GETH:-geth}

# ── Contract addresses ────────────────────────────────────────────────────────
GOVERNOR="0x0000000000000000000000000000000000002004"
GOV_HUB="0x0000000000000000000000000000000000001007"
STAKE_HUB="0x0000000000000000000000000000000000002002"
NEW_WL_ADDR="0x000000000000000000000000000000000000beef"

VAL1=$(val_addr 1 | tr '[:upper:]' '[:lower:]')
VAL2=$(val_addr 2 | tr '[:upper:]' '[:lower:]')
VAL3=$(val_addr 3 | tr '[:upper:]' '[:lower:]')

IPC1=$(val_ipc 1)
IPC2=$(val_ipc 2)
IPC3=$(val_ipc 3)
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

selector() { attach_exec "$GETH" "$IPC1" "web3.sha3('${1}').substring(2,10)" 2>/dev/null; }

# Send tx via ipc; wait up to 60 s for receipt; echo tx hash to stdout or print
# error to stderr and return 1.  Stderr is used so callers like TX=$(send_tx_wait ...)
# still see the error message even though stdout is captured.
send_tx_wait() {
  local ipc="$1" from_addr="$2" to_addr="$3" value_hex="$4" gas="$5" data="$6" label="$7"
  local tx
  tx=$(attach_exec "$GETH" "$ipc" \
    "eth.sendTransaction({from:'${from_addr}',to:'${to_addr}',value:'${value_hex}',gas:${gas},data:'${data}'})" \
    2>/dev/null || echo "")
  if [[ ! "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    log "  FAIL: ${label}: sendTransaction rejected (got: '${tx}')" >&2; return 1
  fi
  log "  ${label}: tx=${tx:0:20}…" >&2
  local i status
  for i in $(seq 1 60); do
    sleep 1
    status=$(attach_exec "$GETH" "$IPC1" \
      "(function(){var r=eth.getTransactionReceipt('${tx}');return r?r.status:'p';})()" \
      2>/dev/null || echo "p")
    if [[ "$status" == "0x1" || "$status" == "1" ]]; then echo "$tx"; return 0; fi
    if [[ "$status" == "0x0" || "$status" == "0" ]]; then
      log "  FAIL: ${label}: tx reverted (tx=${tx})" >&2; return 1
    fi
  done
  log "  FAIL: ${label}: tx not mined in 60 s (tx=${tx})" >&2; return 1
}

# Query BSCGovernor.state(proposalId); returns decimal integer
governor_state() {
  local id_hex="$1" sel raw
  sel=$(selector "state(uint256)")
  raw=$(eth_call_raw "$GOVERNOR" "0x${sel}${id_hex}")
  python3 -c "print(int('${raw}' if '${raw}'.startswith('0x') else '0x0', 16))" 2>/dev/null || echo "-1"
}

# Poll until state == expected or timeout
wait_for_governor_state() {
  local id_hex="$1" expected="$2" timeout_s="$3" label="$4"
  local start cur elapsed
  start=$(date +%s)
  while true; do
    cur=$(governor_state "$id_hex")
    if [[ "$cur" -eq "$expected" ]]; then log "  state=${cur} (${label})"; return 0; fi
    elapsed=$(( $(date +%s) - start ))
    if [[ "$elapsed" -ge "$timeout_s" ]]; then
      fail "Proposal state timeout: expected=${expected} got=${cur} after ${elapsed}s"; return 1
    fi
    sleep 2
  done
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
wait_for_ipc "$GETH" "$IPC1" 10
code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${GOVERNOR}','latest')" 2>/dev/null || echo "0x")
[[ $(( (${#code} - 2) / 2 )) -gt 100 ]] || die "BSCGovernor not deployed at ${GOVERNOR}. Run U-3 first."

log "T-6.h  Full governance whitelist test"
log "  Governor : ${GOVERNOR}  GovHub: ${GOV_HUB}"
log "  StakeHub : ${STAKE_HUB}  NewAddr: ${NEW_WL_ADDR}"
log "  Proposer : ${VAL1}"

# ── Compute selectors ─────────────────────────────────────────────────────────
log ""
log "Computing selectors..."
SEL_PROPOSE=$(selector "propose(address[],uint256[],bytes[],string)")
SEL_CAST_VOTE=$(selector "castVote(uint256,uint8)")
SEL_QUEUE=$(selector "queue(address[],uint256[],bytes[],bytes32)")
SEL_EXECUTE=$(selector "execute(address[],uint256[],bytes[],bytes32)")
SEL_WL_MEMBER=$(selector "validatorWhitelist(address)")
SEL_GOV_UPDATE=$(selector "updateParam(string,bytes,address)")
for _s in SEL_PROPOSE SEL_CAST_VOTE SEL_QUEUE SEL_EXECUTE SEL_WL_MEMBER SEL_GOV_UPDATE; do
  [[ "${!_s}" =~ ^[0-9a-fA-F]{8}$ ]] \
    || die "${_s}: bad selector '${!_s}' (geth attach failed?)"
done
log "  Selectors ready."

# ── Phase 1: build GovHub.updateParam(string,bytes,address) calldata ──────────
log ""
log "Phase 1: encoding GovHub.updateParam calldata"

# updateParam(string key, bytes value, address target)
# key = "addToValidatorWhitelist" (23 bytes), value = NEW_WL_ADDR as 20 bytes, target = StakeHub
GOVHUB_CALLDATA=$(python3 -c "
sel = '${SEL_GOV_UPDATE}'
key = b'addToValidatorWhitelist'          # 23 bytes
val = bytes.fromhex('${NEW_WL_ADDR}'.replace('0x','').zfill(40))   # 20 bytes
target = '${STAKE_HUB}'.replace('0x','').lower().zfill(64)

def p32(n): return format(n, '064x')
def enc_dyn(b):
    pad = ((len(b) + 31) // 32) * 32
    return p32(len(b)) + b.hex().ljust(pad * 2, '0')

# ABI (string, bytes, address): head = [off_key, off_val, addr_static]
off_key = 3 * 32           # 96
off_val = off_key + 32 + ((len(key) + 31) // 32) * 32  # 96 + 32 + 32 = 160
head = p32(off_key) + p32(off_val) + target
body = enc_dyn(key) + enc_dyn(val)
print('0x' + sel + head + body)
")
log "  GovHub calldata: $((( ${#GOVHUB_CALLDATA} - 2 ) / 2)) bytes"

# ── Phase 2: propose ──────────────────────────────────────────────────────────
log ""
log "Phase 2: submitting governance proposal (val1 = proposer)"

DESCRIPTION="T-6.h: addToValidatorWhitelist ${NEW_WL_ADDR}"

PROPOSE_DATA=$(python3 -c "
sel = '${SEL_PROPOSE}'
gov_hub  = '${GOV_HUB}'.replace('0x','').lower()
inner    = bytes.fromhex('${GOVHUB_CALLDATA}'.replace('0x',''))
desc     = '${DESCRIPTION}'.encode()

def p32(n): return format(n,'064x')
def enc_dyn(b):
    pad = ((len(b)+31)//32)*32
    return p32(len(b)) + b.hex().ljust(pad*2,'0')

# propose(address[], uint256[], bytes[], string)  — all four are dynamic
targets_enc   = p32(1) + gov_hub.zfill(64)
values_enc    = p32(1) + p32(0)
calldatas_enc = p32(1) + p32(32) + enc_dyn(inner)   # 1 element, offset=32 to its encoding
desc_enc      = enc_dyn(desc)

off0 = 4 * 32
off1 = off0 + len(targets_enc)//2
off2 = off1 + len(values_enc)//2
off3 = off2 + len(calldatas_enc)//2
head = p32(off0) + p32(off1) + p32(off2) + p32(off3)
print('0x' + sel + head + targets_enc + values_enc + calldatas_enc + desc_enc)
")

PROPOSE_TX=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$PROPOSE_DATA" "propose()") || exit 1

# Parse proposalId from log[0].data first 32 bytes (proposalId is first non-indexed param)
PROPOSAL_ID_HEX=$(attach_exec "$GETH" "$IPC1" \
  "(function(){var r=eth.getTransactionReceipt('${PROPOSE_TX}');
    if(!r||!r.logs||!r.logs.length) return 'null';
    var d=r.logs[0].data;
    return d&&d.length>=66?d.slice(2,66):'null';})()" 2>/dev/null || echo "null")
[[ "${#PROPOSAL_ID_HEX}" -eq 64 ]] \
  || die "Could not parse proposalId from propose() receipt (got: '${PROPOSAL_ID_HEX}')"

ok "propose() mined; proposalId=0x${PROPOSAL_ID_HEX:0:8}…"

# ── Phase 3: cast votes ────────────────────────────────────────────────────────
# votingDelay=0: proposal is Active in the next block; wait 3 s (≈ 3 blocks) to be safe.
log ""
log "Phase 3: casting votes (FOR) from all 3 validators"
sleep 3

CAST_DATA="0x${SEL_CAST_VOTE}${PROPOSAL_ID_HEX}$(printf '%064x' 1)"
for entry in "1:${VAL1}:${IPC1}" "2:${VAL2}:${IPC2}" "3:${VAL3}:${IPC3}"; do
  n="${entry%%:*}"; rest="${entry#*:}"; addr="${rest%%:*}"; ipc="${rest##*:}"
  tx=$(send_tx_wait "$ipc" "$addr" "$GOVERNOR" "0x0" 200000 "$CAST_DATA" "castVote(val${n})") || exit 1
  ok "val${n} castVote(FOR) mined (tx=${tx:0:14}…)"
done

# ── Phase 4: wait for Succeeded (state=4) ─────────────────────────────────────
log ""
log "Phase 4: waiting for voting period to end (10 blocks × 3 s ≈ 30 s, timeout 90 s)"
wait_for_governor_state "$PROPOSAL_ID_HEX" 4 90 "Succeeded" \
  || { fail "Proposal did not reach Succeeded within 90 s"; exit 1; }
ok "Proposal state == Succeeded (quorum reached, majority FOR)"

# ── Phase 5: queue ────────────────────────────────────────────────────────────
log ""
log "Phase 5: queuing proposal into BSCTimelock"

# keccak256(description) for descriptionHash
DESC_HASH=$(attach_exec "$GETH" "$IPC1" \
  "web3.sha3('${DESCRIPTION}').slice(2)" 2>/dev/null)
[[ "${#DESC_HASH}" -eq 64 ]] || die "Failed to compute descriptionHash (got: '${DESC_HASH}')"

QUEUE_EXECUTE_DATA=$(python3 -c "
import sys

def build(sel):
    gov_hub  = '${GOV_HUB}'.replace('0x','').lower()
    inner    = bytes.fromhex('${GOVHUB_CALLDATA}'.replace('0x',''))
    desc_hash = '${DESC_HASH}'

    def p32(n): return format(n,'064x')
    def enc_dyn(b):
        pad = ((len(b)+31)//32)*32
        return p32(len(b)) + b.hex().ljust(pad*2,'0')

    # queue/execute(address[], uint256[], bytes[], bytes32)
    # first three dynamic, last (bytes32) static in head
    targets_enc   = p32(1) + gov_hub.zfill(64)
    values_enc    = p32(1) + p32(0)
    calldatas_enc = p32(1) + p32(32) + enc_dyn(inner)

    off0 = 4 * 32
    off1 = off0 + len(targets_enc)//2
    off2 = off1 + len(values_enc)//2
    head = p32(off0) + p32(off1) + p32(off2) + desc_hash
    return '0x' + sel + head + targets_enc + values_enc + calldatas_enc

# Print queue calldata then execute calldata, one per line
print(build('${SEL_QUEUE}'))
print(build('${SEL_EXECUTE}'))
")

QUEUE_DATA=$(echo "$QUEUE_EXECUTE_DATA" | head -1)
EXECUTE_DATA=$(echo "$QUEUE_EXECUTE_DATA" | tail -1)

QUEUE_TX=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 500000 "$QUEUE_DATA" "queue()") || exit 1
ok "queue() mined"

cur=$(governor_state "$PROPOSAL_ID_HEX")
if [[ "$cur" -eq 5 ]]; then
  ok "Proposal state == Queued (BSCTimelock delay started)"
else
  fail "Proposal state expected 5 (Queued), got ${cur}"
fi

# ── Phase 6: wait for timelock delay (60 s) ───────────────────────────────────
log ""
log "Phase 6: waiting for BSCTimelock delay (3 s = 1 block)..."
sleep 10
log "  Timelock delay elapsed."

# ── Phase 7: execute ──────────────────────────────────────────────────────────
log ""
log "Phase 7: executing proposal"

EXECUTE_TX=$(send_tx_wait "$IPC1" "$VAL1" "$GOVERNOR" "0x0" 1000000 "$EXECUTE_DATA" "execute()") || exit 1
ok "execute() mined"

cur=$(governor_state "$PROPOSAL_ID_HEX")
if [[ "$cur" -eq 7 ]]; then
  ok "Proposal state == Executed"
else
  fail "Proposal state expected 7 (Executed), got ${cur}"
fi

# ── Phase 8: verify whitelist entry on-chain ──────────────────────────────────
log ""
log "Phase 8: verifying StakeHub.validatorWhitelist(${NEW_WL_ADDR})"

padded=$(printf '%064s' "${NEW_WL_ADDR#0x}" | tr '[:upper:]' '[:lower:]' | tr ' ' '0')
raw=$(eth_call_raw "$STAKE_HUB" "0x${SEL_WL_MEMBER}${padded}")
if [[ "${raw: -2}" == "01" ]]; then
  ok "StakeHub.validatorWhitelist(${NEW_WL_ADDR}) == true (end-to-end governance verified)"
else
  fail "StakeHub.validatorWhitelist(${NEW_WL_ADDR}): expected true, got ${raw}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
if [[ "$FAIL" -eq 0 ]]; then
  log "[ PASS ]  T-6.h governance whitelist test: ${PASS} checks passed"
else
  log "[ FAIL ]  T-6.h governance whitelist test: ${PASS} passed, ${FAIL} failed"
  exit 1
fi
