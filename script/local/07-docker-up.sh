#!/usr/bin/env bash
# Start the local Parlia devnet in Docker.
#
# Usage:
#   ./07-docker-up.sh
#
# Prerequisite: run ./01-setup.sh [1-5] first.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Use an array so the path is passed as a single argument even if it contains spaces.
COMPOSE=(docker compose -f "$SCRIPT_DIR/docker-compose.yml")

# ── prerequisite checks ────────────────────────────────────────────────────────

if [ ! -f "$SCRIPT_DIR/genesis.json" ]; then
    echo -e "${RED}Error: genesis.json not found. Run ./01-setup.sh first.${NC}"
    exit 1
fi

if [ ! -d "$SCRIPT_DIR/data/validator-1" ]; then
    echo -e "${RED}Error: validator data not found. Run ./01-setup.sh first.${NC}"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/config/config.toml" ]; then
    echo -e "${RED}Error: config/config.toml not found.${NC}"
    exit 1
fi

# ── count validators set up on disk ───────────────────────────────────────────

NUM_VALIDATORS=$(ls -d "$SCRIPT_DIR/data"/validator-* 2>/dev/null | wc -l | tr -d ' ')
echo -e "${GREEN}Found ${NUM_VALIDATORS} validator(s) on disk${NC}"

if [ "$NUM_VALIDATORS" -lt 1 ] || [ "$NUM_VALIDATORS" -gt 5 ]; then
    echo -e "${RED}Error: validator count must be 1–5, got ${NUM_VALIDATORS}.${NC}"
    exit 1
fi

# ── build image only when not already present ─────────────────────────────────
# To force a rebuild: docker build -t abcore:local <repo-root>

if ! docker image inspect abcore:local >/dev/null 2>&1; then
    echo -e "${YELLOW}Image abcore:local not found – building...${NC}"
    docker build -t abcore:local "$REPO_ROOT"
else
    echo -e "${GREEN}Using existing image abcore:local${NC}"
fi

# ── populate shared config dir ────────────────────────────────────────────────
# genesis.json and password.txt live here alongside the pre-written config.toml.

cp "$SCRIPT_DIR/genesis.json"                  "$SCRIPT_DIR/config/genesis.json"
cp "$SCRIPT_DIR/data/validator-1/password.txt" "$SCRIPT_DIR/config/password.txt"

# ── generate .env with validator addresses and active profiles ────────────────
# Docker Compose reads COMPOSE_PROFILES from .env automatically, so subsequent
# plain `docker compose logs / down` commands see all profiled services too.

ENV_FILE="$SCRIPT_DIR/.env"
: > "$ENV_FILE"

echo -e "${YELLOW}Validator addresses:${NC}"
for i in $(seq 1 "$NUM_VALIDATORS"); do
    ADDR=$(cat "$SCRIPT_DIR/data/validator-$i/address.txt")
    echo "VALIDATOR_${i}_ADDR=${ADDR}" >> "$ENV_FILE"
    echo -e "  Validator $i: ${GREEN}${ADDR}${NC}"
done

# NUM_VALIDATORS is read by the mesh container via docker-compose environment.
echo "NUM_VALIDATORS=${NUM_VALIDATORS}" >> "$ENV_FILE"

# Map validator count to the matching Compose profile (v2..v5).
# Profile vN activates validators 2..N and the mesh sidecar.
# Validator-1 has no profile and always starts.
if [ "$NUM_VALIDATORS" -ge 2 ]; then
    echo "COMPOSE_PROFILES=v${NUM_VALIDATORS}" >> "$ENV_FILE"
fi

# ── launch ─────────────────────────────────────────────────────────────────────

echo ""
"${COMPOSE[@]}" up -d

# ── print endpoints ───────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}=== Devnet started! ===${NC}"
echo ""
echo "Endpoints:"
for i in $(seq 1 "$NUM_VALIDATORS"); do
    RPC_PORT=$((8544 + i))
    WS_PORT=$((9544 + i))
    echo "  Validator $i  RPC : http://localhost:${RPC_PORT}"
    echo "             WS  : ws://localhost:${WS_PORT}"
done
echo ""
echo "Commands (run from any directory):"
echo "  Logs (all)  : ${COMPOSE[*]} logs -f"
echo "  Logs (one)  : ${COMPOSE[*]} logs -f validator-1"
echo "  Stop        : ${COMPOSE[*]} down"
echo "  Shell       : docker exec -it abcore-v1 /bin/bash"
echo "  Rebuild img : docker build -t abcore:local $REPO_ROOT"
