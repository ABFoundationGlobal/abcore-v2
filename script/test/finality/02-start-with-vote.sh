#!/usr/bin/env bash
# Fast Finality E2E — Step 2: start all validators with fast-finality voting on.
#
# Identical to script/local/02-start-validators.sh except every validator gets:
#   --vote                         enable the VoteManager (BLS vote signing)
#   --blswallet  <bls-wallet>      Prysm wallet dir created by 01-setup.sh
#   --blspassword <bls-password>   wallet password
#   --vote-journal-path <dir>      WAL for produced votes
#   --override.breatheblockinterval  set from BREATHE_INTERVAL. The orchestrator
#                                    keeps this effectively OFF (very large): a
#                                    breathe block firing while the StakeHub
#                                    election is empty calls
#                                    updateValidatorSetV2([],[],[]) which reverts
#                                    `invalid opcode: INVALID` and STALLS the
#                                    chain. voteAddress activation does NOT need
#                                    a breathe — it happens at the epoch boundary.
#
# Without --vote a node never creates a VoteManager (eth/backend.go:536) and
# never signs BLS votes, so no attestation is ever assembled.
set -euo pipefail

# Breathe block interval (seconds). The orchestrator (99-run-all.sh) overrides
# this to a very large value to keep breathe blocks effectively OFF for the whole
# run: a breathe block firing on an empty StakeHub election calls
# updateValidatorSetV2([],[],[]) which reverts `invalid opcode: INVALID` and
# stalls the chain. Breathe (validator-set rotation) is orthogonal to fast
# finality — voteAddress activates at the epoch boundary, not at a breathe block,
# so 03/04 never depend on a breathe firing. Do NOT lower this for the E2E run.
BREATHE_INTERVAL=${BREATHE_INTERVAL:-315360000}

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GETH="$REPO_ROOT/build/bin/geth"
DATA_DIR="$REPO_ROOT/script/local/data"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

[ -d "$DATA_DIR/validator-1" ] || { echo -e "${RED}Setup not done. Run ./01-setup.sh first${NC}"; exit 1; }
NUM_VALIDATORS=$(ls -d "$DATA_DIR"/validator-* 2>/dev/null | wc -l)
# Needs the 3 baked validators: the system contracts elect a fixed 3-validator
# set at the epoch boundary, so fewer than 3 stalls past block 200 (the chain
# must cross that boundary to activate voteAddress). 3 also reaches the BLS
# quorum ceil(2*3/3)=2. See 01-setup.sh / README for the full rationale.
[ "$NUM_VALIDATORS" -ge 1 ] || { echo -e "${RED}No validators found — run ./01-setup.sh${NC}"; exit 1; }

echo -e "${GREEN}=== Starting ${NUM_VALIDATORS} validators with --vote (breathe=${BREATHE_INTERVAL}s) ===${NC}"

# Use a high, unlikely-to-collide port base instead of script/local's 8545+.
# Shared hosts often already run a node on 8545/8546 (e.g. the real devnet),
# and binding there would kill our validators with "address already in use".
# Override with FINALITY_RPC_BASE / FINALITY_P2P_BASE if even these clash.
RPC_BASE=${FINALITY_RPC_BASE:-18640}
P2P_BASE=${FINALITY_P2P_BASE:-31340}

# Shared vote flags for a given validator dir, emitted as an array via stdout.
start_validator() {
    local NUM=$1
    local PORT=$((RPC_BASE + NUM))
    local P2P_PORT=$((P2P_BASE + NUM))
    local VAL_DIR="$DATA_DIR/validator-$NUM"
    local VAL_ADDR; VAL_ADDR=$(cat "$VAL_DIR/address.txt")
    local BOOTNODE_FLAG=$2

    [ -d "$VAL_DIR/bls/wallet" ] || { echo -e "${RED}validator-$NUM: bls/wallet missing — re-run 01-setup.sh${NC}"; exit 1; }

    echo -e "${YELLOW}Starting validator-$NUM (vote on)...${NC}  RPC :$PORT  P2P :$P2P_PORT"

    # shellcheck disable=SC2086  # BOOTNODE_FLAG is intentionally word-split
    nohup "$GETH" \
        --datadir "$VAL_DIR" \
        --networkid 7140 \
        --port $P2P_PORT \
        --http \
        --http.addr "127.0.0.1" \
        --http.port $PORT \
        --http.api "eth,net,web3,debug,parlia,admin,personal" \
        --http.corsdomain "*" \
        --ws \
        --ws.addr "127.0.0.1" \
        --ws.port $((PORT + 1000)) \
        --ws.api "eth,net,web3,debug,parlia,admin,personal" \
        --nat extip:127.0.0.1 \
        $BOOTNODE_FLAG \
        --maxpeers 25 \
        --unlock "$VAL_ADDR" \
        --password "$VAL_DIR/password.txt" \
        --miner.etherbase "$VAL_ADDR" \
        --allow-insecure-unlock \
        --syncmode "full" \
        --gcmode "archive" \
        --verbosity 3 \
        --vote \
        --blswallet "$VAL_DIR/bls/wallet" \
        --blspassword "$VAL_DIR/bls-password.txt" \
        --vote-journal-path "$VAL_DIR/voteJournal" \
        --override.breatheblockinterval "$BREATHE_INTERVAL" \
        > "$VAL_DIR/geth.log" 2>&1 &

    echo $! > "$VAL_DIR/geth.pid"
    echo -e "  ${GREEN}PID $(cat "$VAL_DIR/geth.pid")${NC}"
    sleep 2
}

# Validator 1 is the bootnode.
start_validator 1 ""

echo -e "${YELLOW}Waiting for validator-1 enode...${NC}"
ENODE=""
for i in {1..10}; do
    if [ -S "$DATA_DIR/validator-1/geth.ipc" ]; then
        ENODE=$("$GETH" attach --exec "admin.nodeInfo.enode" "$DATA_DIR/validator-1/geth.ipc" 2>/dev/null | tr -d '"' | sed 's/?.*$//' || echo "")
        [ -n "$ENODE" ] && break
    fi
    sleep 2
done
[ -n "$ENODE" ] && BOOTNODE_FLAG="--bootnodes $ENODE" || BOOTNODE_FLAG=""

for NUM in $(seq 2 "$NUM_VALIDATORS"); do
    start_validator "$NUM" "$BOOTNODE_FLAG"
done

# Full mesh.
echo -e "${YELLOW}Connecting validators (full mesh)...${NC}"
ENODES=()
for NUM in $(seq 1 "$NUM_VALIDATORS"); do
    ENODES+=("$("$GETH" attach --exec "admin.nodeInfo.enode" "$DATA_DIR/validator-$NUM/geth.ipc" 2>/dev/null | tr -d '"' | sed 's/?.*$//')")
done
for i in $(seq 1 "$NUM_VALIDATORS"); do
    for j in $(seq 1 "$NUM_VALIDATORS"); do
        [ "$i" -eq "$j" ] && continue
        "$GETH" attach --exec "admin.addPeer(\"${ENODES[$((j-1))]}\") + ''" \
            "$DATA_DIR/validator-$i/geth.ipc" 2>/dev/null >/dev/null
    done
done

# Confirm each node actually started its VoteManager.
echo -e "${YELLOW}Verifying VoteManager started on each validator...${NC}"
sleep 3
ALL_OK=1
for i in $(seq 1 "$NUM_VALIDATORS"); do
    if grep -q "Create voteManager successfully" "$DATA_DIR/validator-$i/geth.log" 2>/dev/null; then
        echo -e "  ${GREEN}validator-$i: VoteManager up${NC}"
    else
        echo -e "  ${RED}validator-$i: VoteManager NOT found in log${NC}"
        ALL_OK=0
    fi
done

echo ""
if [ "$ALL_OK" -ne 1 ]; then
    echo -e "${RED}=== One or more validators did not start VoteManager — check logs ===${NC}"
    exit 1
fi

# ── Start mining only AFTER the full mesh is connected ────────────────────────
# Validators are launched WITHOUT --mine on purpose. If all 3 begin sealing
# before they are peered, each produces conflicting blocks at the same low
# height and the chain forks/stalls ("Signed recently, must wait for others")
# — a startup race unrelated to finality. Waiting for peers to settle, then
# calling miner_start on every node in one pass, makes all signers begin from
# the same genesis and round-robin cleanly across the epoch boundary.
echo -e "${YELLOW}Confirming peers before starting miners...${NC}"
for i in $(seq 1 "$NUM_VALIDATORS"); do
    pc=$("$GETH" attach --exec "admin.peers.length" "$DATA_DIR/validator-$i/geth.ipc" 2>/dev/null)
    echo "  validator-$i peers=$pc"
done

echo -e "${YELLOW}Starting miners on all validators...${NC}"
for i in $(seq 1 "$NUM_VALIDATORS"); do
    "$GETH" attach --exec "miner.start()" "$DATA_DIR/validator-$i/geth.ipc" >/dev/null 2>&1
    echo -e "  ${GREEN}validator-$i: mining started${NC}"
done

echo ""
echo -e "${GREEN}=== All validators started with voting enabled and mining ===${NC}"
echo "Next: ./03-register-vote-address.sh"
