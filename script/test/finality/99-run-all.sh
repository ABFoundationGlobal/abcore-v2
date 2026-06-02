#!/usr/bin/env bash
# Fast Finality E2E — orchestrator. Runs the full flow and exits non-zero if
# fast finality is not verified. Suitable for CI (devnet-ops/jenkins).
#
#   01-setup     N validators (default 3) + BLS keypairs
#   02-start     start with --vote; breathe effectively OFF (see below)
#   03-register  StakeHub createValidator/delegate; poll until election non-empty
#   <wait>       until the chain passes an epoch boundary (block % epoch == 0),
#                where Parlia re-reads the validator set — including each
#                validator's BLS voteAddress — into the snapshot. THIS is what
#                activates voting (NOT a breathe block).
#   04-verify    assert justify + finalize + attestation
#
# Two things learned the hard way, encoded here:
#  1. A breathe block calls ValidatorContract.updateValidatorSetV2(eVals,...).
#     If it fires while the StakeHub election set is EMPTY, the contract reverts
#     with `invalid opcode: INVALID`, the breathe block can't seal, and the chain
#     STALLS permanently (this is the block-~18 stall). We therefore keep breathe
#     effectively OFF for the whole test — breathe (validator-set rotation) is
#     orthogonal to fast-finality voting and not needed to exercise it.
#  2. voteAddress enters the snapshot at the EPOCH boundary (block % epoch == 0,
#     epoch=200), not at a breathe block. So we just wait until the chain crosses
#     block 200 after registration, then voting begins.
#
# N=3 default: the baked system contracts (post-#117) elect a FIXED 3-validator
# set into BSCValidatorSet at the epoch boundary, so the chain only stays live
# past block 200 with all 3 signers present. 3 is therefore the minimum that
# both crosses the epoch boundary (required to activate voteAddress) AND reaches
# the BLS quorum ceil(2*3/3)=2. Set FINALITY_NUM_VALIDATORS to override (max 3).
#
# Always stops validators and wipes data on exit (unless KEEP_DATA=1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GETH="$REPO_ROOT/build/bin/geth"
LOCAL_DIR="$REPO_ROOT/script/local"
DATA_DIR="$LOCAL_DIR/data"
IPC="$DATA_DIR/validator-1/geth.ipc"

# Breathe effectively OFF (10 years) — no breathe block fires during the test,
# so the empty-election updateValidatorSetV2 stall can never happen.
export BREATHE_INTERVAL=${BREATHE_INTERVAL:-315360000}
# Epoch boundary at which voteAddress activates (matches genesis parlia.epoch).
EPOCH=${EPOCH:-200}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

cleanup() {
    local rc=$?
    echo -e "${YELLOW}==> Stopping validators...${NC}"
    "$LOCAL_DIR/04-stop-validators.sh" 2>/dev/null || true
    if [ "${KEEP_DATA:-0}" != "1" ]; then
        echo -e "${YELLOW}==> Wiping data...${NC}"
        rm -rf "$DATA_DIR" "$LOCAL_DIR/genesis.json"
    else
        echo -e "${YELLOW}==> KEEP_DATA=1 — leaving data in place${NC}"
    fi
    exit "$rc"
}
trap cleanup EXIT

run() { echo -e "\n${GREEN}########## $* ##########${NC}"; "$@"; }
_blk() { "$GETH" attach --exec "eth.blockNumber" "$IPC" 2>/dev/null | tr -d '"\r'; }

run "$SCRIPT_DIR/01-setup.sh"
run "$SCRIPT_DIR/02-start-with-vote.sh"
run "$SCRIPT_DIR/03-register-vote-address.sh"

# Wait until the chain crosses the first epoch boundary AFTER registration, so
# the registered voteAddress is read into the validator snapshot. Poll the tip
# with a hard wall-clock budget AND a stall guard so a broken chain fails fast
# instead of hanging the Jenkins job (the previous version could loop forever).
EPOCH_WAIT_SECS=${EPOCH_WAIT_SECS:-1200}   # ~20 min; an epoch is 200 blocks * 3s = ~10 min
TARGET=0; ELAPSED=0; PREV_BN=-1; STALL=0
echo -e "\n${YELLOW}==> Waiting (≤${EPOCH_WAIT_SECS}s) for the chain to cross an epoch boundary (block % ${EPOCH} == 0) to activate voteAddress...${NC}"
while [ "$ELAPSED" -lt "$EPOCH_WAIT_SECS" ]; do
    BN=$(_blk)
    if [[ "$BN" =~ ^[0-9]+$ ]] && [ "$BN" -gt 0 ]; then
        # first epoch boundary strictly greater than the current tip
        [ "$TARGET" -eq 0 ] && TARGET=$(( (BN / EPOCH + 1) * EPOCH ))
        [ "$BN" -ge "$TARGET" ] && break
        # stall guard: if the tip hasn't moved across several polls, bail out
        if [ "$BN" -eq "$PREV_BN" ]; then
            STALL=$((STALL + 1))
            if [ "$STALL" -ge 6 ]; then
                echo -e "${RED}  FAIL  chain stalled at block ${BN} (no progress ~30s) before reaching epoch boundary ${TARGET}${NC}"
                exit 1
            fi
        else
            STALL=0
        fi
        PREV_BN=$BN
    fi
    sleep 5; ELAPSED=$((ELAPSED + 5))
done
if [ "$TARGET" -eq 0 ] || [ "$(_blk)" -lt "$TARGET" ]; then
    echo -e "${RED}  FAIL  chain did not reach epoch boundary ${TARGET} within ${EPOCH_WAIT_SECS}s${NC}"
    exit 1
fi
echo -e "  ${GREEN}tip=$(_blk) (>= epoch boundary ${TARGET}) — voteAddress should now be active${NC}"

run "$SCRIPT_DIR/04-verify-finality.sh"

echo -e "\n${GREEN}========== FAST FINALITY E2E PASSED ==========${NC}"
