#!/bin/sh
# Connect the three devnet validators in a full peer mesh via admin_addPeer.
# Runs once after all validators report healthy (Docker depends_on condition).
# Uses only busybox tools available in the alpine image.
set -e

V1="http://validator-1:8545"
V2="http://validator-2:8545"
V3="http://validator-3:8545"

# ── helpers ────────────────────────────────────────────────────────────────────

rpc() {
  # rpc <url> <method> [params-json]
  wget -qO- "$1" \
    --post-data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":${3:-[]},\"id\":1}" \
    --header "Content-Type: application/json"
}

wait_for() {
  printf "Waiting for %s ..." "$1"
  until rpc "$1" "net_version" >/dev/null 2>&1; do
    printf "."
    sleep 2
  done
  echo " ok"
}

get_enode() {
  enode=$(rpc "$1" "admin_nodeInfo" \
    | sed 's/.*"enode":"\([^"]*\)".*/\1/' \
    | sed 's/?[^"]*$//')
  if [ -z "$enode" ]; then
    echo "ERROR: failed to get enode from $1" >&2
    exit 1
  fi
  printf '%s\n' "$enode"
}

add_peer() {
  response=$(rpc "$1" "admin_addPeer" "[\"$2\"]")
  if echo "$response" | grep -q '"error"'; then
    echo "ERROR: admin_addPeer failed ($1 -> $2): $response" >&2
    exit 1
  fi
  if ! echo "$response" | grep -q '"result":true'; then
    echo "ERROR: admin_addPeer did not return true ($1 -> $2): $response" >&2
    exit 1
  fi
}

# ── wait for all three validators ─────────────────────────────────────────────

wait_for "$V1"
wait_for "$V2"
wait_for "$V3"

# ── fetch enodes ───────────────────────────────────────────────────────────────

E1=$(get_enode "$V1")
E2=$(get_enode "$V2")
E3=$(get_enode "$V3")

printf "Enodes:\n  V1: %s\n  V2: %s\n  V3: %s\n" "$E1" "$E2" "$E3"

# ── wire full mesh ─────────────────────────────────────────────────────────────

echo "Connecting full mesh..."

add_peer "$V1" "$E2"; add_peer "$V1" "$E3"
add_peer "$V2" "$E1"; add_peer "$V2" "$E3"
add_peer "$V3" "$E1"; add_peer "$V3" "$E2"

echo "Mesh complete – all three validators peered."
