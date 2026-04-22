#!/usr/bin/env bash
# Verifies the Clique→Parlia transition at PARLIA_GENESIS_BLOCK.
#
# Checks:
#   1. All 3 nodes are alive and on the same chain past the fork
#   2. Block 0 (genesis epoch) has Clique extraData with signer list (>97 bytes)
#   3. Block at PARLIA_GENESIS_BLOCK is produced by DualConsensus (via parlia.getValidators)
#   4. Parlia validator set at fork block contains the same addresses as the last
#      pre-fork Clique checkpoint signer set
#   5. System contract ValidatorSet (0x1000) has non-empty code at PARLIA_GENESIS_BLOCK
#   6. ValidatorSet code was absent before the fork
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"

FORK_BLOCK="$PARLIA_GENESIS_BLOCK"
POST_FORK_CHECK=$(( FORK_BLOCK + 3 ))

VALIDATOR_CONTRACT="0x0000000000000000000000000000000000001000"
PRE_FORK=$(( FORK_BLOCK - 1 ))

PASS=0
FAIL=0

ok()   { log "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { log "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

IPC1=$(val_ipc 1)

# ── 1. Nodes alive and past POST_FORK_CHECK ──────────────────────────────────
log "Waiting for all nodes to reach block ${POST_FORK_CHECK}..."
_pids=()
for n in 1 2 3; do
  wait_for_head_at_least "$GETH" "$(val_ipc "$n")" "$POST_FORK_CHECK" 120 &
  _pids+=($!)
done
for p in "${_pids[@]}"; do wait "$p"; done
ok "All nodes reached block ${POST_FORK_CHECK}"

# ── 2. Chain agreement ───────────────────────────────────────────────────────
assert_same_hash_at "$POST_FORK_CHECK" \
  "$GETH" "$IPC1" \
  "$GETH" "$(val_ipc 2)" \
  "$GETH" "$(val_ipc 3)"
ok "All nodes agree on hash at block ${POST_FORK_CHECK}"

# ── 3. Genesis epoch block has Clique signer list in extraData ───────────────
genesis_ed=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(0).extraData")
genesis_hex="${genesis_ed#0x}"
# Clique epoch: 64 vanity hex + N*40 signer hex + 130 sig hex; for N=3: 64+120+130=314 hex
genesis_len="${#genesis_hex}"
if [[ "$genesis_len" -gt 194 ]]; then
  signer_hex_len=$(( genesis_len - 64 - 130 ))
  signer_count=$(( signer_hex_len / 40 ))
  ok "Genesis has Clique epoch extraData with ${signer_count} signer(s) (len=${genesis_len} hex)"
else
  fail "Genesis extraData too short for Clique epoch (len=${genesis_len}, expected >194)"
fi

# ── 4. Pre-fork block exists (sanity) ────────────────────────────────────────
pre_hash=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${PRE_FORK}).hash")
if [[ -n "$pre_hash" && "$pre_hash" != "null" ]]; then
  ok "Block ${PRE_FORK} exists (pre-fork Clique: ${pre_hash})"
else
  fail "Block ${PRE_FORK} not found"
fi

# ── 5. parlia.getValidators() at fork block returns the last Clique signer set ─
CHECKPOINT_BLOCK=$(( PRE_FORK - (PRE_FORK % CLIQUE_EPOCH) ))
checkpoint_ed=$(attach_exec "$GETH" "$IPC1" "eth.getBlock(${CHECKPOINT_BLOCK}).extraData")
checkpoint_hex="${checkpoint_ed#0x}"
if [[ -z "$checkpoint_hex" || "$checkpoint_hex" == "$checkpoint_ed" ]]; then
  fail "Could not read extraData for Clique checkpoint block ${CHECKPOINT_BLOCK}"
  checkpoint_hex=""
fi

# Extract Clique signers from the last pre-fork checkpoint extraData
inner_hex=""
if [[ ${#checkpoint_hex} -gt 194 ]]; then
  inner_hex="${checkpoint_hex:64:$(( ${#checkpoint_hex} - 64 - 130 ))}"
fi
clique_signers=()
while [[ ${#inner_hex} -ge 40 ]]; do
  addr="0x${inner_hex:0:40}"
  clique_signers+=("$(echo "$addr" | tr '[:upper:]' '[:lower:]')")
  inner_hex="${inner_hex:40}"
done
log "Clique signers (from checkpoint ${CHECKPOINT_BLOCK}): ${clique_signers[*]}"
if [[ ${#clique_signers[@]} -eq 0 ]]; then
  fail "No Clique signers parsed from checkpoint ${CHECKPOINT_BLOCK}"
fi

# parlia.getValidators uses HTTP port since IPC only exposes the parlia namespace
# if the API is registered. Use the HTTP endpoint instead.
HTTP1="http://127.0.0.1:$(http_port 1)"
parlia_vals_raw=$(curl -sS -X POST "$HTTP1" \
  -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"parlia_getValidators\",\"params\":[\"0x$(printf '%x' "$FORK_BLOCK")\"],\"id\":1}" \
  2>/dev/null)

if echo "$parlia_vals_raw" | grep -q '"result"'; then
  parlia_vals=$(echo "$parlia_vals_raw" | python3 -c "
import json, sys
data = json.load(sys.stdin)
result = data.get('result') or []
for v in result:
    print(v.lower())
" 2>/dev/null || true)

  if [[ -z "$parlia_vals" ]]; then
    fail "parlia_getValidators(${FORK_BLOCK}) returned empty"
  else
    log "Parlia validators: ${parlia_vals}"
    ok "parlia_getValidators(${FORK_BLOCK}) returned validators"
    # Verify each Clique signer appears in the Parlia validator set
    for csig in "${clique_signers[@]}"; do
      if echo "$parlia_vals" | grep -qi "^${csig}$"; then
        ok "Clique signer ${csig} is in Parlia validator set"
      else
        fail "Clique signer ${csig} NOT in Parlia validator set"
      fi
    done
  fi
else
  # API not registered — might mean DualConsensus isn't active.
  # This is a soft failure: log the raw response for diagnosis.
  log "  WARN: parlia_getValidators returned unexpected: ${parlia_vals_raw}"
  fail "parlia_getValidators HTTP call failed (engine may not be DualConsensus)"
fi

# ── 6. System contract ValidatorSet deployed at fork block ───────────────────
code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${VALIDATOR_CONTRACT}', ${FORK_BLOCK})")
code_len=$(( (${#code} - 2) / 2 ))
if [[ "$code_len" -gt 100 ]]; then
  ok "ValidatorSet (${VALIDATOR_CONTRACT}) deployed at block ${FORK_BLOCK}: ${code_len} bytes"
else
  fail "ValidatorSet code at block ${FORK_BLOCK} is too short or empty: code=${code}"
fi

# Confirm absent before the fork
pre_code=$(attach_exec "$GETH" "$IPC1" "eth.getCode('${VALIDATOR_CONTRACT}', ${PRE_FORK})")
if [[ "$pre_code" == "0x" ]]; then
  ok "ValidatorSet absent at block ${PRE_FORK} (before fork)"
else
  fail "ValidatorSet unexpectedly present at block ${PRE_FORK}: ${pre_code}"
fi

# ── 7. Post-fork blocks are being produced (engine is live) ─────────────────
post_hash1=$(block_hash_at "$GETH" "$IPC1" "$(( FORK_BLOCK + 1 ))")
post_hash2=$(block_hash_at "$GETH" "$IPC1" "$POST_FORK_CHECK")
if [[ -n "$post_hash1" && "$post_hash1" != "null" ]] && \
   [[ -n "$post_hash2" && "$post_hash2" != "null" ]]; then
  ok "Post-fork blocks produced (block $(( FORK_BLOCK + 1 ))=${post_hash1:0:12}…, ${POST_FORK_CHECK}=${post_hash2:0:12}…)"
else
  fail "Post-fork block production failed (block $(( FORK_BLOCK + 1 ))=${post_hash1:-null})"
fi

# ── 8. Post-fork block has non-zero miner (proves Parlia sealed it) ─────────
# Clique sets header.Coinbase=0x0 on non-epoch, non-vote blocks; Parlia always
# sets header.Coinbase=p.val (the sealer's address).  A non-zero miner on the
# first post-fork block is definitive proof that DualConsensus routed to Parlia.
post_miner=$(attach_exec "$GETH" "$IPC1" "eth.getBlock($(( FORK_BLOCK + 1 ))).miner" 2>/dev/null || true)
post_miner_lower=$(echo "$post_miner" | tr '[:upper:]' '[:lower:]')
if [[ "$post_miner_lower" == "0x0000000000000000000000000000000000000000" || \
      -z "$post_miner_lower" || "$post_miner_lower" == "null" ]]; then
  fail "Block $(( FORK_BLOCK + 1 )) has zero/null miner — block was NOT sealed by Parlia"
else
  ok "Block $(( FORK_BLOCK + 1 )) miner=${post_miner} (non-zero proves Parlia sealing)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "===================================="
echo "  Transition test results"
echo "  PASS: ${PASS}   FAIL: ${FAIL}"
echo "===================================="
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED" >&2
  exit 1
fi

# ── T-6: system contract parameter and fee-routing assertions ────────────────
"${SCRIPT_DIR}/06-verify-contracts.sh"

echo "PASSED"
