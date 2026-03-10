#!/usr/bin/env bash
set -euo pipefail

# Scenario 6: Transaction propagation parity across the v1/v2 boundary.
#
# Precondition: Scenario 3 has run — 3 active validators (1 v2, 2 v1) plus the
# v2 RPC node started in Scenario 2. Validator accounts are funded (genesis alloc)
# and their addresses are unlocked at node startup.
#
# Part 1 — v2 HTTP → network → confirmed on v1 node:
#   Sign a transfer on the v2 validator's IPC (account already unlocked) and
#   submit the raw transaction via the v2 RPC node's HTTP endpoint. Wait for the
#   tx receipt to appear on a v1 validator node. Confirms that a transaction
#   entering the network through a v2 HTTP endpoint is gossiped across the version
#   boundary and accepted by v1 nodes as part of the canonical chain.
#   (Clique is round-robin; the assertion is that v1 receives and validates the tx,
#   not that a v1 node specifically seals the block containing it.)
#
# Part 2 — v1 IPC → network → confirmed on v2 node:
#   Submit a transfer directly from a v1 validator's IPC and wait for the receipt
#   to appear on the v2 validator's IPC. Confirms the reverse path: a transaction
#   originating on a v1 node propagates to v2 and is accepted as part of the
#   canonical chain.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

command -v curl >/dev/null 2>&1 || die "curl is required but not found in PATH"

N=${UPGRADE_VALIDATOR_N:-2}
[[ "$N" -ge 1 && "$N" -le 3 ]] || die "UPGRADE_VALIDATOR_N must be 1..3"

# Select a v1 peer that is not the upgraded validator.
V1_PEER=1
[[ "$V1_PEER" -eq "$N" ]] && V1_PEER=2
[[ "$V1_PEER" -eq "$N" ]] && V1_PEER=3

V2_IPC=$(val_ipc "$N")
V1_IPC=$(val_ipc "$V1_PEER")
V2_ADDR=$(val_addr "$N")
V1_ADDR=$(val_addr "$V1_PEER")

RPC_HTTP_PORT=$(rpc_http_port)
RPC_URL="http://127.0.0.1:${RPC_HTTP_PORT}"
# Used only to verify the RPC node process is still alive before submitting via HTTP.
RPC_IPC="${DATADIR_ROOT}/rpc-v2-1/geth.ipc"

log "Scenario 6: tx propagation — v2 validator=val-${N} (${V2_ADDR}), v1 peer=val-${V1_PEER} (${V1_ADDR})"

# Verify preconditions — use active IPC handshake, not just file existence,
# because stale socket files can linger after a crash.
"$ABCORE_V2_GETH" attach --exec "web3.clientVersion" "$V2_IPC" >/dev/null 2>&1 \
  || die "v2 validator not responding on ${V2_IPC} (run scenarios 1–3 first)"
"$ABCORE_V1_GETH" attach --exec "web3.clientVersion" "$V1_IPC" >/dev/null 2>&1 \
  || die "v1 validator not responding on ${V1_IPC}"
"$ABCORE_V2_GETH" attach --exec "web3.clientVersion" "$RPC_IPC" >/dev/null 2>&1 \
  || die "v2 RPC node not responding on ${RPC_IPC} (run scenario 2 first)"

# ── Helper ────────────────────────────────────────────────────────────────────

# Poll eth.getTransactionReceipt until status is '0x1' (success) or fail.
wait_for_receipt() {
  local geth_bin="$1"
  local ipc_path="$2"
  local txhash="$3"
  local timeout_sec=${4:-90}
  local deadline=$(( $(date +%s) + timeout_sec ))

  while [[ $(date +%s) -lt $deadline ]]; do
    local status
    status=$(attach_exec "$geth_bin" "$ipc_path" \
      "(function(){var r=eth.getTransactionReceipt('${txhash}');return r?r.status:'null';})()" \
      2>/dev/null || echo "null")
    if [[ "$status" == "0x1" ]]; then
      return 0
    fi
    if [[ "$status" == "0x0" ]]; then
      die "tx ${txhash} reverted (status=0x0) on ${ipc_path}"
    fi
    sleep 1
  done
  die "tx ${txhash} not mined within timeout on ${ipc_path}"
}

# ── Part 1: v2 → v1 propagation (via HTTP entry point) ───────────────────────

log "Part 1: sign on v2 IPC, submit via HTTP, verify receipt on v1 node (val-${V1_PEER})"

# Get current nonce for the v2 validator address.
NONCE=$(attach_exec "$ABCORE_V2_GETH" "$V2_IPC" \
  "eth.getTransactionCount('${V2_ADDR}')" 2>/dev/null)
[[ "$NONCE" =~ ^[0-9]+$ ]] || die "could not read nonce for ${V2_ADDR}: ${NONCE}"

# Sign a transfer on the v2 validator's IPC. The account is unlocked at startup
# (--unlock flag), so eth.signTransaction succeeds without prompting.
SIGNED_TX=$(attach_exec "$ABCORE_V2_GETH" "$V2_IPC" \
  "eth.signTransaction({from:'${V2_ADDR}',to:'${V1_ADDR}',value:web3.toWei(1,'ether'),gas:21000,gasPrice:eth.gasPrice,nonce:${NONCE}}).raw" \
  2>/dev/null || true)
[[ "$SIGNED_TX" =~ ^0x ]] \
  || die "eth.signTransaction failed on v2 validator: ${SIGNED_TX}"

log "Raw tx signed (len=${#SIGNED_TX}), submitting via HTTP to ${RPC_URL}"

CURL_ERR_FILE=$(mktemp "${DATADIR_ROOT}/curl-scn6.XXXXXX")
trap 'rm -f "$CURL_ERR_FILE"' EXIT
HTTP_RESP=$(curl -f --silent --show-error -X POST "$RPC_URL" \
  -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\":[\"${SIGNED_TX}\"],\"id\":1}" \
  2>"$CURL_ERR_FILE" || true)
[[ -n "$HTTP_RESP" ]] || die "HTTP request to ${RPC_URL} failed: $(cat "$CURL_ERR_FILE")"

TXHASH1=$(echo "$HTTP_RESP" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); r=d.get('result',''); print(r)" 2>/dev/null || true)
[[ -n "$TXHASH1" && "$TXHASH1" =~ ^0x[0-9a-fA-F]{64}$ ]] \
  || die "eth_sendRawTransaction via HTTP failed: ${HTTP_RESP}"

log "tx submitted via HTTP (hash=${TXHASH1})"
log "Waiting for receipt on v1 validator (val-${V1_PEER})"
wait_for_receipt "$ABCORE_V1_GETH" "$V1_IPC" "$TXHASH1" 90

log "Part 1 OK — tx ${TXHASH1} mined and confirmed on v1 node"

# ── Part 2: v1 → v2 propagation ───────────────────────────────────────────────

log "Part 2: submit tx from v1 IPC, verify receipt on v2 node"

TXHASH2=$(attach_exec "$ABCORE_V1_GETH" "$V1_IPC" \
  "eth.sendTransaction({from:'${V1_ADDR}',to:'${V2_ADDR}',value:web3.toWei(1,'ether'),gas:21000,gasPrice:eth.gasPrice})" \
  2>/dev/null || true)
[[ -n "$TXHASH2" && "$TXHASH2" =~ ^0x[0-9a-fA-F]{64}$ ]] \
  || die "eth.sendTransaction on v1 node failed: ${TXHASH2}"

log "tx submitted from v1 IPC (hash=${TXHASH2})"
log "Waiting for receipt on v2 validator (val-${N})"
wait_for_receipt "$ABCORE_V2_GETH" "$V2_IPC" "$TXHASH2" 90

log "Part 2 OK — tx ${TXHASH2} mined and confirmed on v2 node"

# ── Final convergence ─────────────────────────────────────────────────────────

# Determine the third validator (not V1_PEER, not N).
V1_OTHER=1
[[ "$V1_OTHER" -eq "$N" || "$V1_OTHER" -eq "$V1_PEER" ]] && V1_OTHER=2
[[ "$V1_OTHER" -eq "$N" || "$V1_OTHER" -eq "$V1_PEER" ]] && V1_OTHER=3

log "Verifying all 3 validators agree on the same canonical head"
wait_for_same_head "$ABCORE_V1_GETH" "$V1_IPC" 30 \
  "$ABCORE_V2_GETH" "$V2_IPC" \
  "$ABCORE_V1_GETH" "$(val_ipc "$V1_OTHER")"

log "Scenario 6 OK"
