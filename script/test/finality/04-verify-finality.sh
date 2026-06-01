#!/usr/bin/env bash
# Fast Finality E2E — Step 4: assert that the chain is actually justifying and
# finalizing blocks via BLS vote attestations.
#
# Checks (against validator-1's RPC, IPC console for parlia namespace):
#   a) justified number advances over time and tracks the chain tip closely
#   b) finalized number advances over time
#   c) at least one recent block header carries a vote attestation (extraData
#      longer than the base 32B vanity + 65B seal envelope)
#
# Exits non-zero if finality is not progressing — this is what makes the test
# fail when --vote is absent or voteAddress was never registered.
set -euo pipefail

# Tunables.
# Poll for up to FINALITY_TIMEOUT seconds for justified/finalized to start
# advancing. This must comfortably exceed: time-to-next-epoch-boundary (block %
# epoch == 0, which admits voteAddress into the snapshot — NOT a breathe block) +
# the 40-block voting warmup in core/vote/vote_manager.go + a few rounds for
# justify→finalize to accumulate. When run via 99-run-all.sh the epoch boundary
# is already crossed before this script starts, so the default is ample.
FINALITY_TIMEOUT=${FINALITY_TIMEOUT:-360}
POLL_INTERVAL=${POLL_INTERVAL:-5}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GETH="$REPO_ROOT/build/bin/geth"
DATA_DIR="$REPO_ROOT/script/local/data"
IPC="$DATA_DIR/validator-1/geth.ipc"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

[ -S "$IPC" ] || { echo -e "${RED}validator-1 IPC not found at $IPC — is the network running?${NC}"; exit 1; }

_attach() { "$GETH" attach --exec "$1" "$IPC" 2>/dev/null | tr -d '"' | tr -d '\r'; }

# parlia.getJustifiedNumber()/getFinalizedNumber() take an optional block arg;
# with none they use latest. Return 0 on any error so arithmetic stays safe.
_justified() { local v; v=$(_attach "parlia.getJustifiedNumber()" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }
_finalized() { local v; v=$(_attach "parlia.getFinalizedNumber()" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }
_tip()       { local v; v=$(_attach "eth.blockNumber" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }

# Returns 1 if the latest Parlia snapshot contains any validator with a non-zero
# BLS vote_address, else 0 (regardless of how it got there). The snapshot picks
# up the registered voteAddress at the epoch boundary. This is the precondition
# for any voting to happen at all.
_voteaddr_present() {
    local js
    js=$(_attach 'var s=parlia.getSnapshot();var ok=0;for(var v in s.validators){var a=s.validators[v].vote_address;if(a){for(var i=0;i<a.length;i++){if(a[i]!==0){ok=1;break;}}}if(ok)break;}ok' 2>/dev/null)
    [[ "$js" == "1" ]] && echo 1 || echo 0
}

echo -e "${GREEN}=== Verifying fast finality ===${NC}"

FAIL=0

# ── (0) precondition: voteAddress admitted into the snapshot ─────────────────
# Voting cannot begin until the validator's registered BLS voteAddress is read
# into the snapshot. This happens at an EPOCH boundary (block % epoch == 0),
# when Parlia re-reads the validator set from the contract — NOT at a breathe
# block. Poll for it so we can distinguish "voteAddress never activated" from
# "voting itself is broken".
echo -e "${YELLOW}==> Waiting for voteAddress to enter the snapshot (epoch boundary)...${NC}"
VA=0 ELAPSED=0
while [ "$ELAPSED" -lt "$FINALITY_TIMEOUT" ]; do
    VA=$(_voteaddr_present)
    [ "$VA" -eq 1 ] && { echo -e "  ${GREEN}voteAddress present in snapshot @${ELAPSED}s${NC}"; break; }
    sleep "$POLL_INTERVAL"; ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
if [ "$VA" -ne 1 ]; then
    echo -e "${RED}  FAIL  voteAddress never entered the snapshot within ${FINALITY_TIMEOUT}s${NC}"
    echo -e "${RED}        → the registered BLS voteAddress was not read into the snapshot.${NC}"
    echo -e "${YELLOW}        Check: did the chain cross an epoch boundary (block % epoch == 0) after registration?${NC}"
    exit 1
fi

# ── (a) wait until justified starts advancing (poll, with timeout) ───────────
# justified=0 forever means no attestations are being produced. We require it
# to become >0 AND then increase on a later poll.
echo -e "${YELLOW}==> Polling up to ${FINALITY_TIMEOUT}s for justified to advance...${NC}"
J_FIRST=0 J_NOW=0 F_FIRST=0 F_NOW=0 ELAPSED=0
while [ "$ELAPSED" -lt "$FINALITY_TIMEOUT" ]; do
    J_NOW=$(_justified); F_NOW=$(_finalized); T_NOW=$(_tip)
    if [ "$J_NOW" -gt 0 ]; then
        [ "$J_FIRST" -eq 0 ] && { J_FIRST=$J_NOW; F_FIRST=$F_NOW; echo "  justified became non-zero: J=$J_NOW F=$F_NOW tip=$T_NOW @${ELAPSED}s"; }
        # Once non-zero, require a strict increase to prove ongoing progress.
        if [ "$J_NOW" -gt "$J_FIRST" ]; then
            echo "  justified advancing: J=$J_NOW F=$F_NOW tip=$T_NOW @${ELAPSED}s"
            break
        fi
    fi
    sleep "$POLL_INTERVAL"; ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ "$J_NOW" -gt "$J_FIRST" ] && [ "$J_FIRST" -gt 0 ]; then
    echo -e "${GREEN}  PASS  justified advanced: $J_FIRST -> $J_NOW${NC}"
else
    echo -e "${RED}  FAIL  justified did not advance within ${FINALITY_TIMEOUT}s (stuck at $J_NOW) — no attestations${NC}"
    FAIL=1
fi

# ── (b) finalized advances too ───────────────────────────────────────────────
if [ "$F_NOW" -gt "$F_FIRST" ] && [ "$F_FIRST" -gt 0 ]; then
    echo -e "${GREEN}  PASS  finalized advanced: $F_FIRST -> $F_NOW${NC}"
elif [ "$F_NOW" -gt 0 ]; then
    # finalized lags justified by ~1 round; one more short poll to confirm motion.
    sleep "$((POLL_INTERVAL * 3))"; F2=$(_finalized)
    if [ "$F2" -gt "$F_NOW" ]; then
        echo -e "${GREEN}  PASS  finalized advanced: $F_NOW -> $F2${NC}"
    else
        echo -e "${RED}  FAIL  finalized stalled at $F_NOW${NC}"; FAIL=1
    fi
else
    echo -e "${RED}  FAIL  finalized never became non-zero — chain not reaching finality${NC}"; FAIL=1
fi

# Justified should track the tip closely (healthy network: ~1-2 blocks behind).
T_NOW=$(_tip)
if [ "$J_NOW" -gt 0 ]; then
    LAG=$(( T_NOW - J_NOW ))
    if [ "$LAG" -le 5 ]; then
        echo -e "${GREEN}  PASS  justified lag = ${LAG} blocks (<=5)${NC}"
    else
        echo -e "${YELLOW}  WARN  justified lag = ${LAG} blocks (>5) — finality lagging but progressing${NC}"
    fi
fi

# ── (c) a recent NON-EPOCH header carries a vote attestation ─────────────────
# extraData = 32B vanity + [attestation RLP] + 65B seal. With no attestation the
# length is exactly 97 bytes (194 hex + 0x). Anything materially longer indicates
# an embedded attestation — EXCEPT on an epoch block (block % epoch == 0), whose
# header also carries the validator set in extraData and is >97 bytes regardless
# of any attestation. We therefore skip epoch blocks to avoid a false positive.
echo -e "${YELLOW}==> Checking recent non-epoch headers for embedded vote attestation...${NC}"
ATT_FOUND=$(_attach 'var n=eth.blockNumber,ep=parlia.getSnapshot().epoch_length||200,found=0;for(var i=n;i>n-20&&i>1;i--){if(i%ep===0)continue;var b=eth.getBlock(i);if(b&&b.extraData&&(b.extraData.length-2)/2>97){found=i;break;}}found' 2>/dev/null)
if [[ "$ATT_FOUND" =~ ^[0-9]+$ ]] && [ "$ATT_FOUND" -gt 0 ]; then
    echo -e "${GREEN}  PASS  attestation found in non-epoch header #${ATT_FOUND} (extraData > 97 bytes)${NC}"
else
    echo -e "${RED}  FAIL  no vote attestation in last 20 non-epoch headers${NC}"
    FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}=== Fast finality VERIFIED (justify + finalize + attestation) ===${NC}"
    exit 0
else
    echo -e "${RED}=== Fast finality verification FAILED ===${NC}"
    echo "  Inspect logs: tail -f $DATA_DIR/validator-1/geth.log"
    exit 1
fi
