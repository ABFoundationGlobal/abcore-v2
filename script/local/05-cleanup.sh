#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

echo -e "${YELLOW}=== Cleanup Warning ===${NC}"
echo "This will:"
echo "  - Stop all running validators"
echo "  - Delete all blockchain data"
echo "  - Delete all validator keys"
echo "  - Delete genesis.json"
echo ""
read -p "Are you sure? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cleanup cancelled"
    exit 0
fi

# Stop validators first
echo ""
echo -e "${YELLOW}Stopping validators...${NC}"
./04-stop-validators.sh

# Remove data directory
if [ -d "$DATA_DIR" ]; then
    echo -e "${YELLOW}Removing data directory...${NC}"
    rm -rf "$DATA_DIR"
    echo -e "${GREEN}Data directory removed${NC}"
fi

# Remove genesis.json
if [ -f "$SCRIPT_DIR/genesis.json" ]; then
    echo -e "${YELLOW}Removing genesis.json...${NC}"
    rm -f "$SCRIPT_DIR/genesis.json"
    echo -e "${GREEN}Genesis file removed${NC}"
fi

echo ""
echo -e "${GREEN}=== Cleanup complete ===${NC}"
echo "Run ./01-setup.sh to start fresh"
