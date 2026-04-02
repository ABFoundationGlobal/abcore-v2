#!/usr/bin/env bash
set -euo pipefail

# Scenario 1: Verify we are in Clique PoA phase (head < PARLIA_GENESIS_BLOCK).
# Asserts:
#   - head_number < PARLIA_GENESIS_BLOCK on all nodes
#   - clique.getSnapshot(head) succeeds on all nodes
#   - all 3 nodes agree on the same head hash

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

log "[scn1] Checking pre-fork PoA state"

for n in 1 2 3; do
  ipc=$(val_ipc "$n")
  head=$(head_number "${ABCORE_V2_GETH}" "$ipc")
  log "validator-${n}: head=${head}"
  if [[ "$head" -ge "$PARLIA_GENESIS_BLOCK" ]]; then
    die "validator-${n} head=${head} >= PARLIA_GENESIS_BLOCK=${PARLIA_GENESIS_BLOCK}; already past fork"
  fi
done

log "[scn1] Verifying clique.getSnapshot works on all nodes"
for n in 1 2 3; do
  ipc=$(val_ipc "$n")
  head=$(head_number "${ABCORE_V2_GETH}" "$ipc")
  snap=$(attach_exec "${ABCORE_V2_GETH}" "$ipc" \
    "JSON.stringify(clique.getSnapshot(${head}))" 2>/dev/null || true)
  if [[ -z "$snap" || "$snap" == "null" || "$snap" == "{}" ]]; then
    die "validator-${n}: clique.getSnapshot(${head}) returned empty/null — Clique is not active"
  fi
  log "validator-${n}: clique snapshot OK at block ${head}"
done

log "[scn1] Asserting all nodes have the same head"
assert_same_head "${ABCORE_V2_GETH}" "$(val_ipc 1)" \
  "${ABCORE_V2_GETH}" "$(val_ipc 2)" \
  "${ABCORE_V2_GETH}" "$(val_ipc 3)"

log "[scn1] PASS: chain is in Clique PoA phase, all nodes consistent"
