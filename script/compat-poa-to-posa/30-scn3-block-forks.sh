#!/usr/bin/env bash
set -euo pipefail

# Scenario 3: Verify block-based fork activation at PARLIA_GENESIS_BLOCK.
# London fork is indicated by a non-null baseFeePerGas field in the block header.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

log "[scn3] Checking block-fork activation at block ${PARLIA_GENESIS_BLOCK}"

# Make sure we have that block available.
wait_for_head_at_least "${ABCORE_V2_GETH}" "$(val_ipc 1)" "$PARLIA_GENESIS_BLOCK" 60

# London fork: baseFeePerGas must be present (non-null) at PARLIA_GENESIS_BLOCK.
base_fee=$(attach_exec "${ABCORE_V2_GETH}" "$(val_ipc 1)" \
  "eth.getBlock(${PARLIA_GENESIS_BLOCK}).baseFeePerGas")
log "[scn3] Block ${PARLIA_GENESIS_BLOCK} baseFeePerGas: ${base_fee}"

if [[ -z "$base_fee" || "$base_fee" == "null" || "$base_fee" == "undefined" ]]; then
  die "baseFeePerGas is absent at block ${PARLIA_GENESIS_BLOCK} — London fork did not activate"
fi

log "[scn3] PASS: London fork active at block ${PARLIA_GENESIS_BLOCK} (baseFeePerGas=${base_fee})"
