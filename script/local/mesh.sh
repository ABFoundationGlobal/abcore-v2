#!/bin/sh
# Connect N devnet validators in a full peer mesh via admin_addPeer.
# Reads NUM_VALIDATORS from the environment (set by docker-compose via .env).
# Uses only busybox tools available in the alpine image.
set -e

NUM_VALIDATORS="${NUM_VALIDATORS:-3}"

# Maximum number of 2-second polls before giving up on a validator.
# 150 × 2 s = 5 minutes, enough for a cold image pull + genesis init.
WAIT_MAX_ATTEMPTS=150

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
  attempts=0
  until rpc "$1" "net_version" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$WAIT_MAX_ATTEMPTS" ]; then
      echo ""
      echo "ERROR: timed out waiting for $1 after $((attempts * 2))s" >&2
      echo "" >&2
      echo "Possible causes:" >&2
      echo "  • The container exited or crashed — check: docker compose logs" >&2
      echo "  • Genesis init failed — check: docker compose logs validator-1" >&2
      echo "  • Image not built — run: docker build -t abcore:local ../../" >&2
      echo "" >&2
      echo "To clean up and retry:" >&2
      echo "  docker compose down -v && ./07-docker-up.sh" >&2
      exit 1
    fi
    printf "."
    sleep 2
  done
  echo " ok"
}

get_enode() {
  # Parse enode URI from admin_nodeInfo JSON using sed (no jq in alpine by default).
  # The geth JSON-RPC response format for admin_nodeInfo is stable; this pattern
  # extracts the value of the "enode" key and strips any query-string suffix (?...).
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
