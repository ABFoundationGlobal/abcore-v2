#!/usr/bin/env bash
set -euo pipefail

# Scenario 2: v2 seals Clique blocks via the HasCliqueAndParlia() engine path.
#
# Setup:
#   custom genesis (chain ID 26888, fresh validator accounts, terminalTotalDifficulty
#   set high so the network stays in Clique / pre-merge mode)
#
#   v1 node — initialized from custom genesis, no mining (sync-only)
#   v2 node — initialized from custom genesis, --mine, validator key unlocked
#              Started with --networkid 26888 (NOT --abcore.testnet, because the
#              custom genesis has a different hash from the production testnet).
#
# What this exercises:
#   HasCliqueAndParlia() returns true (both Clique and Parlia configs present).
#   ParliaGenesisBlock = nil → IsParliaActive(num) = false at all heights.
#   CreateConsensusEngine() must select the Clique path and seal blocks normally.
#
# Assertions:
#   1. v2 seals at least 3 blocks
#   2. v1 (sync-only) follows v2's chain — same head hash
#   3. No parlia-related errors in v2 log

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CUSTOM_GENESIS="$(custom_genesis_json)"
VALIDATOR_ADDR_F="$(scn2_validator_addr_file)"
VALIDATOR_PW="$(scn2_validator_pw_file)"

resolve_binaries
require_file "${CUSTOM_GENESIS}"
require_file "${VALIDATOR_ADDR_F}"
require_file "${VALIDATOR_PW}"

VALIDATOR_ADDR=$(cat "${VALIDATOR_ADDR_F}")

log "=== Scenario 2: v2 Clique sealing via HasCliqueAndParlia() path ==="
log "Validator: ${VALIDATOR_ADDR}"

# ---- Start v1 sync node ----
log "Starting v1 sync node (custom genesis, no mining)"
"$ABCORE_V1_GETH" \
  --datadir "$(scn2_v1_datadir)" \
  --networkid "${ABCORE_NETWORK_ID}" \
  --port "$(scn2_v1_p2p_port)" \
  --nodiscover \
  --nat none \
  --verbosity 3 \
  >>"$(scn2_v1_log)" 2>&1 &
echo $! > "$(scn2_v1_pid)"
log "v1 started (pid $(cat "$(scn2_v1_pid)"))"

# ---- Start v2 validator node ----
# Use --override.genesis to load the custom genesis explicitly.  We cannot
# use --networkid 26888 alone because that triggers DefaultABCoreTestGenesisBlock()
# (the built-in testnet genesis) which conflicts with the custom genesis in the DB.
log "Starting v2 validator (custom genesis via --override.genesis, --mine)"
"$ABCORE_V2_GETH" \
  --datadir "$(scn2_v2_datadir)" \
  --override.genesis "${CUSTOM_GENESIS}" \
  --port "$(scn2_v2_p2p_port)" \
  --nodiscover \
  --nat none \
  --mine \
  --miner.etherbase "${VALIDATOR_ADDR}" \
  --unlock "${VALIDATOR_ADDR}" \
  --password "${VALIDATOR_PW}" \
  --allow-insecure-unlock \
  --verbosity 3 \
  >>"$(scn2_v2_log)" 2>&1 &
echo $! > "$(scn2_v2_pid)"
log "v2 started (pid $(cat "$(scn2_v2_pid)"))"

# ---- Wait for IPC sockets ----
log "Waiting for v1 IPC..."
wait_for_ipc "$ABCORE_V1_GETH" "$(scn2_v1_ipc)" 60
log "Waiting for v2 IPC..."
wait_for_ipc "$ABCORE_V2_GETH" "$(scn2_v2_ipc)" 60
log "Both nodes ready"

# ---- Peer v1 → v2 ----
log "Peering v1 to v2"
V2_ENODE=$(get_enode "$ABCORE_V2_GETH" "$(scn2_v2_ipc)")
add_peer "$ABCORE_V1_GETH" "$(scn2_v1_ipc)" "$V2_ENODE"
wait_for_min_peers "$ABCORE_V1_GETH" "$(scn2_v1_ipc)" 1 30
log "v1 is connected to v2"

# ---- Start mining on v2 ----
log "Starting miner on v2"
miner_start "$ABCORE_V2_GETH" "$(scn2_v2_ipc)"

# ---- Wait for v2 to seal at least 3 blocks ----
log "Waiting for v2 to produce at least 3 blocks..."
wait_for_head_at_least "$ABCORE_V2_GETH" "$(scn2_v2_ipc)" 3 120
V2_HEAD=$(head_number "$ABCORE_V2_GETH" "$(scn2_v2_ipc)")
log "v2 head: block ${V2_HEAD}"

# ---- Wait for v1 to sync ----
log "Waiting for v1 to sync to v2 head..."
wait_for_same_head "$ABCORE_V2_GETH" "$(scn2_v2_ipc)" 60 \
  "$ABCORE_V1_GETH" "$(scn2_v1_ipc)"
log "v1 and v2 agree on head"

# ---- Verify blocks were sealed by v2 validator ----
log "Verifying v2 validator sealed blocks"
wait_for_block_miner "$ABCORE_V2_GETH" "$(scn2_v2_ipc)" "${VALIDATOR_ADDR}" 6 30

# ---- Check v2 log for parlia-related errors ----
log "Checking v2 log for unexpected parlia activity"
V2_LOG="$(scn2_v2_log)"
if grep -qi "parlia.*error\|parlia.*panic\|parlia.*fatal\|parlia.*active" "$V2_LOG" 2>/dev/null; then
  die "v2 log contains unexpected parlia activity — check ${V2_LOG}"
fi

log "=== Scenario 2 PASSED ==="
log "  v2 sealed blocks via HasCliqueAndParlia() Clique engine"
log "  ParliaGenesisBlock=nil: Parlia did not activate at any height"
log "  v1 (sync-only) followed v2's chain"

# ---- Stop scenario 2 nodes ----
stop_pidfile "$(scn2_v2_pid)"
stop_pidfile "$(scn2_v1_pid)"
log "Scenario 2 nodes stopped"
