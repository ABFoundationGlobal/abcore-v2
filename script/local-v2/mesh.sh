#!/bin/sh
# Connect N devnet validators in a full peer mesh via admin_addPeer.
# Reads NUM_VALIDATORS from the environment (set by docker-compose via .env).
# Uses only busybox tools available in the alpine image.
set -e

NUM_VALIDATORS="${NUM_VALIDATORS:-3}"

# ── helpers ────────────────────────────────────────────────────────────────────

rpc() {
  # rpc <url> <method> [params-json]
  wget -qO- "$1" \
    --post-data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":${3:-[]},\"id\":1}" \
    --header "Content-Type: application/json"
}

url_for() {
  printf 'http://validator-%d:8545' "$1"
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

# ── wait for all validators ────────────────────────────────────────────────────

i=1
while [ "$i" -le "$NUM_VALIDATORS" ]; do
  wait_for "$(url_for "$i")"
  i=$((i + 1))
done

# ── fetch and cache enodes ─────────────────────────────────────────────────────

echo "Fetching enodes..."
i=1
while [ "$i" -le "$NUM_VALIDATORS" ]; do
  enode=$(get_enode "$(url_for "$i")")
  echo "$enode" > "/tmp/enode-$i"
  printf "  V%d: %s\n" "$i" "$enode"
  i=$((i + 1))
done

# ── wire full mesh ─────────────────────────────────────────────────────────────

echo "Connecting full mesh..."
i=1
while [ "$i" -le "$NUM_VALIDATORS" ]; do
  j=1
  while [ "$j" -le "$NUM_VALIDATORS" ]; do
    if [ "$i" -ne "$j" ]; then
      add_peer "$(url_for "$i")" "$(cat "/tmp/enode-$j")"
    fi
    j=$((j + 1))
  done
  i=$((i + 1))
done

echo "Mesh complete – all $NUM_VALIDATORS validators peered."
