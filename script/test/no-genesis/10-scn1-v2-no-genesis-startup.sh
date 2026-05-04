#!/usr/bin/env bash
set -euo pipefail

# Scenario 1: v2 starts without geth init using --abcore.testnet only.
#
# Setup:
#   v1 node  — initialized from testnet genesis (chain ID 26888), no mining
#   v2 node  — empty datadir, started with --abcore.testnet (no init)
#
# Assertions:
#   1. v2 IPC becomes ready (node started without init)
#   2. Both nodes agree on the genesis block hash (0x739b6207...)
#   3. No "unknown genesis" or parlia-related errors in v2 log

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TESTNET_GENESIS="$(testnet_genesis_json)"

resolve_binaries
require_file "${TESTNET_GENESIS}"

log "=== Scenario 1: v2 no-genesis startup (--abcore.testnet) ==="

# ---- Start v1 sync node ----
log "Starting v1 sync node (chain ID ${ABCORE_CHAIN_ID}, no mining)"
"$ABCORE_V1_GETH" \
  --datadir "$(scn1_v1_datadir)" \
  --networkid "${ABCORE_NETWORK_ID}" \
  --port "$(scn1_v1_p2p_port)" \
  --nodiscover \
  --nat none \
  --verbosity 3 \
  >>"$(scn1_v1_log)" 2>&1 &
echo $! > "$(scn1_v1_pid)"
log "v1 started (pid $(cat "$(scn1_v1_pid)"))"

# ---- Start v2 node WITHOUT init — this is the test ----
log "Starting v2 with --abcore.testnet only (empty datadir, no init)"
"$ABCORE_V2_GETH" \
  --abcore.testnet \
  --datadir "$(scn1_v2_datadir)" \
  --port "$(scn1_v2_p2p_port)" \
  --nodiscover \
  --nat none \
  --verbosity 3 \
  >>"$(scn1_v2_log)" 2>&1 &
echo $! > "$(scn1_v2_pid)"
log "v2 started (pid $(cat "$(scn1_v2_pid)"))"

# ---- Wait for IPC sockets ----
log "Waiting for v1 IPC..."
wait_for_ipc "$ABCORE_V1_GETH" "$(scn1_v1_ipc)" 60
log "Waiting for v2 IPC..."
wait_for_ipc "$ABCORE_V2_GETH" "$(scn1_v2_ipc)" 60
log "Both nodes ready"

# ---- Peer v2 → v1 ----
log "Peering v2 to v1"
V1_ENODE=$(get_enode "$ABCORE_V1_GETH" "$(scn1_v1_ipc)")
add_peer "$ABCORE_V2_GETH" "$(scn1_v2_ipc)" "$V1_ENODE"
wait_for_min_peers "$ABCORE_V2_GETH" "$(scn1_v2_ipc)" 1 30
log "v2 is connected to v1"

# ---- Assert genesis block hash matches ----
log "Asserting genesis block (height 0) hash matches between v1 and v2"
assert_same_hash_at 0 \
  "$ABCORE_V1_GETH" "$(scn1_v1_ipc)" \
  "$ABCORE_V2_GETH" "$(scn1_v2_ipc)"

# ---- Check v2 log for error conditions ----
log "Checking v2 log for error conditions"
V2_LOG="$(scn1_v2_log)"
if grep -qi "unknown genesis\|incompatible genesis\|genesis block mismatch" "$V2_LOG" 2>/dev/null; then
  die "v2 log contains genesis error — check ${V2_LOG}"
fi
# Parlia must not fire during pure Clique phase (ParliaGenesisBlock=nil)
if grep -qi "parlia.*error\|parlia.*panic\|parlia.*fatal" "$V2_LOG" 2>/dev/null; then
  die "v2 log contains parlia error — check ${V2_LOG}"
fi

log "=== Scenario 1 PASSED ==="
log "  v2 started without geth init using --abcore.testnet"
log "  genesis hash matches v1 at block 0"

# ---- Stop scenario 1 nodes ----
stop_pidfile "$(scn1_v1_pid)"
stop_pidfile "$(scn1_v2_pid)"
log "Scenario 1 nodes stopped"
