#!/usr/bin/env bash
set -euo pipefail

# Scenario 9: JSON-RPC response parity between v1 and v2.
#
# Precondition: Scenario 7 has run — all 3 validators are v2, and the v2 RPC node
# (rpc-v2-1) started in Scenario 2 is still running with its HTTP endpoint.
#
# This scenario starts a dedicated non-mining v1 HTTP node (rpc-v1-1), peers it to
# the v2 network, waits for it to sync, then queries both the v1 node and the v2 RPC
# node with the same JSON-RPC calls and asserts that the canonicalised responses are
# identical. It catches any JSON encoding or field-ordering regressions that would not
# be visible from block hash convergence alone.
#
# Methods compared:
#   eth_getBlockByNumber  — block header fields and transaction list (hashes only)
#   eth_getLogs           — log array for a single block range
#   clique_getSnapshot    — Clique signer snapshot at a stable block height
#
# The comparison normalises each response by sorting JSON keys recursively via Python's
# json.dumps(sort_keys=True) before diffing. This tolerates map-iteration ordering
# differences between Go versions while still catching genuine field-value regressions.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

command -v curl   >/dev/null 2>&1 || die "curl is required but not found in PATH"
command -v python3 >/dev/null 2>&1 || die "python3 is required but not found in PATH"

# ── Node configuration ────────────────────────────────────────────────────────

V1_RPC_DIR="${DATADIR_ROOT}/rpc-v1-1"
V1_RPC_IPC="${V1_RPC_DIR}/geth.ipc"
V1_RPC_PID="${V1_RPC_DIR}/geth.pid"
V1_RPC_LOG="${V1_RPC_DIR}/geth.log"
V1_HTTP_PORT=$(rpc_v1_http_port)
V1_HTTP_URL="http://127.0.0.1:${V1_HTTP_PORT}"

V2_RPC_IPC="${DATADIR_ROOT}/rpc-v2-1/geth.ipc"
V2_HTTP_PORT=$(rpc_http_port)
V2_HTTP_URL="http://127.0.0.1:${V2_HTTP_PORT}"

# ── Precondition checks ───────────────────────────────────────────────────────

log "Scenario 9: JSON-RPC response parity"

"$ABCORE_V2_GETH" attach --exec "web3.clientVersion" "$(val_ipc 1)" >/dev/null 2>&1 \
  || die "validator-1 not responding on IPC (run scenarios 1–7 first)"
"$ABCORE_V2_GETH" attach --exec "web3.clientVersion" "$V2_RPC_IPC" >/dev/null 2>&1 \
  || die "v2 RPC node (rpc-v2-1) not responding — run scenario 2 first"

# Verify the v2 RPC node was started with the clique API enabled. Scenario 2
# used to start rpc-v2-1 with --http.api eth,net,web3 (no clique); if this
# node is still running from an old run, clique_getSnapshot will return null.
V2_RPC_PID_FILE="${DATADIR_ROOT}/rpc-v2-1/geth.pid"
_clique_probe=$(curl -sf --max-time 5 -X POST "$V2_HTTP_URL" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"clique_getSnapshot","params":["latest"],"id":1}' 2>/dev/null || true)
_clique_err=$(echo "$_clique_probe" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message',''))" 2>/dev/null || true)
if echo "$_clique_err" | grep -qi "method not found\|no handler"; then
  log "rpc-v2-1 does not expose the clique API — restarting with --http.api eth,net,web3,clique"
  V2_RPC_DIR="${DATADIR_ROOT}/rpc-v2-1"
  V2_RPC_LOG="${V2_RPC_DIR}/geth.log"
  stop_pidfile "$V2_RPC_PID_FILE"
  (
    cd "$REPO_ROOT"
    nohup "$ABCORE_V2_GETH" \
      --datadir "$V2_RPC_DIR" \
      --networkid "$CLIQUE_NETWORK_ID" \
      --port "$(rpc_p2p_port)" \
      --nat none \
      --nodiscover \
      --bootnodes "" \
      --ipcpath geth.ipc \
      --syncmode full \
      --http --http.addr 127.0.0.1 --http.port "$(rpc_http_port)" \
      --http.api eth,net,web3,clique \
      --nousb \
      >>"$V2_RPC_LOG" 2>&1 &
    echo $! >"$V2_RPC_PID_FILE"
  )
  wait_for_ipc "$ABCORE_V2_GETH" "$V2_RPC_IPC" 60
  # Re-peer to validators so the node catches up after the restart.
  for n in 1 2 3; do
    _en=$(get_enode "$ABCORE_V2_GETH" "$(val_ipc "$n")")
    add_peer "$ABCORE_V2_GETH" "$V2_RPC_IPC" "$_en" >/dev/null || true
  done
  wait_for_min_peers "$ABCORE_V2_GETH" "$V2_RPC_IPC" 1 30
fi

# ── Start the v1 HTTP node ────────────────────────────────────────────────────

mkdir -p "$V1_RPC_DIR"

if [[ ! -d "${V1_RPC_DIR}/geth" ]]; then
  log "Initialising rpc-v1-1 datadir"
  "$ABCORE_V1_GETH" init --datadir "$V1_RPC_DIR" "${GENESIS_JSON}"
fi

if [[ -f "$V1_RPC_PID" ]] && kill -0 "$(cat "$V1_RPC_PID")" >/dev/null 2>&1; then
  log "rpc-v1-1 already running (pid=$(cat "$V1_RPC_PID"))"
else
  log "Starting rpc-v1-1 (v1, HTTP on port ${V1_HTTP_PORT})"
  (
    cd "$REPO_ROOT"
    nohup "$ABCORE_V1_GETH" \
      --datadir "$V1_RPC_DIR" \
      --networkid "$CLIQUE_NETWORK_ID" \
      --port "$(rpc_v1_p2p_port)" \
      --nat none \
      --nodiscover \
      --bootnodes "" \
      --ipcpath geth.ipc \
      --authrpc.addr 127.0.0.1 \
      --authrpc.port "$(rpc_v1_auth_port)" \
      --syncmode full \
      --http --http.addr 127.0.0.1 --http.port "$V1_HTTP_PORT" \
      --http.api eth,net,web3,clique \
      --nousb \
      >>"$V1_RPC_LOG" 2>&1 &
    echo $! >"$V1_RPC_PID"
  )
fi

wait_for_ipc "$ABCORE_V1_GETH" "$V1_RPC_IPC" 60

# Peer to all three validators (all v2 after scn4, but the IPC protocol is compatible).
log "Peering rpc-v1-1 to validators"
for n in 1 2 3; do
  enode=$(get_enode "$ABCORE_V2_GETH" "$(val_ipc "$n")")
  add_peer "$ABCORE_V1_GETH" "$V1_RPC_IPC" "$enode" >/dev/null || true
done

wait_for_min_peers "$ABCORE_V1_GETH" "$V1_RPC_IPC" 1 60

log "Waiting for rpc-v1-1 to sync"
ref_head=$(head_number "$ABCORE_V2_GETH" "$(val_ipc 1)")
wait_for_head_at_least "$ABCORE_V1_GETH" "$V1_RPC_IPC" "$ref_head" 120

# ── Choose a stable comparison block ─────────────────────────────────────────

# Use a block a few behind the current head so both nodes have certainly stored
# it and the chain tip is not racing ahead between our two curl calls.
cur_head=$(head_number "$ABCORE_V1_GETH" "$V1_RPC_IPC")
stable_block=$(( cur_head > 4 ? cur_head - 4 : 1 ))
stable_block_hex=$(printf '0x%x' "$stable_block")

log "Comparing responses at block ${stable_block} (${stable_block_hex})"

# ── Comparison helper ─────────────────────────────────────────────────────────

# V2_ADDITIVE_KEYS: top-level keys present in v2 responses that v1 does not
# return. These are intentional v2 additions, not regressions. Strip them from
# both sides before comparing so the assertion focuses on shared fields.
#
#   milliTimestamp — BSC extension added in rpcMarshalBlock/rpcMarshalHeader
#                    (internal/ethapi/api.go). Derived from header.MilliTimestamp().
#                    Not part of the standard eth_getBlockByNumber ABI.
V2_ADDITIVE_KEYS='["milliTimestamp"]'

# compare_rpc <method> <params-json>
# Queries both v1 and v2 HTTP endpoints, extracts .result, strips known v2-only
# additive fields, sorts JSON keys recursively, and asserts equality.
compare_rpc() {
  local method="$1"
  local params="$2"
  local payload
  payload="{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}"

  local v1_raw v2_raw
  v1_raw=$(curl -sf --max-time 10 -X POST "$V1_HTTP_URL" \
    -H 'Content-Type: application/json' -d "$payload" || true)
  v2_raw=$(curl -sf --max-time 10 -X POST "$V2_HTTP_URL" \
    -H 'Content-Type: application/json' -d "$payload" || true)

  [[ -n "$v1_raw" ]] || die "empty response from v1 HTTP node for ${method}"
  [[ -n "$v2_raw" ]] || die "empty response from v2 HTTP node for ${method}"

  # Strip known v2-only additive keys from both sides, then sort and serialise.
  local strip_py
  strip_py="
import json, sys
additive = set(${V2_ADDITIVE_KEYS})
def strip(obj):
    if isinstance(obj, dict):
        return {k: strip(v) for k, v in obj.items() if k not in additive}
    if isinstance(obj, list):
        return [strip(i) for i in obj]
    return obj
d = json.load(sys.stdin)
print(json.dumps(strip(d.get('result')), sort_keys=True))
"

  local v1_norm v2_norm
  v1_norm=$(echo "$v1_raw" | python3 -c "$strip_py" 2>/dev/null || true)
  v2_norm=$(echo "$v2_raw" | python3 -c "$strip_py" 2>/dev/null || true)

  [[ -n "$v1_norm" ]] || die "could not parse v1 response for ${method}: ${v1_raw}"
  [[ -n "$v2_norm" ]] || die "could not parse v2 response for ${method}: ${v2_raw}"

  if [[ "$v1_norm" != "$v2_norm" ]]; then
    echo "MISMATCH for ${method} at block ${stable_block}:"
    echo "  v1: ${v1_norm}"
    echo "  v2: ${v2_norm}"
    die "JSON-RPC response mismatch: ${method}"
  fi

  log "  ${method}: OK"
}

# ── Run comparisons ───────────────────────────────────────────────────────────

compare_rpc "eth_getBlockByNumber" \
  "[\"${stable_block_hex}\", false]"

compare_rpc "eth_getLogs" \
  "[{\"fromBlock\":\"${stable_block_hex}\",\"toBlock\":\"${stable_block_hex}\"}]"

compare_rpc "clique_getSnapshot" \
  "[\"${stable_block_hex}\"]"

log "All RPC responses match"

# ── Tear down rpc-v1-1 ───────────────────────────────────────────────────────

log "Stopping rpc-v1-1"
stop_pidfile "$V1_RPC_PID"

log "Scenario 9 OK"
