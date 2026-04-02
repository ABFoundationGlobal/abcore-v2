#!/usr/bin/env bash
set -euo pipefail

# Scenario 4: Wait for TIME_FORK_TIME and verify Shanghai (and later) time-fork activation.
# Shanghai fork is indicated by the presence of a 'withdrawals' field in the block.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries
require_file "${SCRIPT_DIR}/fork-times.env"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/fork-times.env"

log "[scn4] Waiting for timestamp >= TIME_FORK_TIME=${TIME_FORK_TIME}"

TIMEOUT_SEC=300
deadline=$(( $(date +%s) + TIMEOUT_SEC ))

while [[ $(date +%s) -lt $deadline ]]; do
  ts=$(attach_exec "${ABCORE_V2_GETH}" "$(val_ipc 1)" \
    "eth.getBlock('latest').timestamp" 2>/dev/null || echo 0)
  bn=$(head_number "${ABCORE_V2_GETH}" "$(val_ipc 1)" 2>/dev/null || echo 0)
  now=$(date +%s)
  log "[scn4] block=${bn} timestamp=${ts} target=${TIME_FORK_TIME} wall=${now}"
  if [[ "$ts" -ge "$TIME_FORK_TIME" ]]; then
    log "[scn4] Block ${bn} has timestamp ${ts} >= ${TIME_FORK_TIME}"
    break
  fi
  sleep 3
done

if [[ $(date +%s) -ge $deadline ]]; then
  die "timed out waiting for block timestamp >= ${TIME_FORK_TIME}"
fi

# Verify the Shanghai fork: latest block should have 'withdrawals' field.
withdrawals=$(attach_exec "${ABCORE_V2_GETH}" "$(val_ipc 1)" \
  "JSON.stringify(eth.getBlock('latest').withdrawals)" 2>/dev/null || true)
log "[scn4] latest block withdrawals field: ${withdrawals}"

if [[ -z "$withdrawals" || "$withdrawals" == "null" || "$withdrawals" == "undefined" ]]; then
  die "withdrawals field absent in latest block — Shanghai fork did not activate"
fi

log "[scn4] PASS: time-based forks active (Shanghai+ detected via withdrawals field)"
