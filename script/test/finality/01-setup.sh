#!/usr/bin/env bash
# Fast Finality E2E — Step 1: set up a 3-validator Parlia devnet and generate a
# BLS keypair (Prysm wallet + proof-of-possession) for each validator.
#
# Reuses script/local/01-setup.sh for genesis/account generation and the
# bls_proof helper from script/test/upgrade-drill for proof-of-possession.
# The local genesis pins lubanBlock=6 / platoBlock=7 / feynmanTime=0, so the
# chain satisfies the fast-finality protocol gate from a low block height.
#
# Per-validator BLS artifacts written under data/validator-N/:
#   bls/wallet/         — Prysm-format BLS wallet (geth's `bls account new`
#                         default; passed verbatim to --blswallet by 02-start)
#   bls-password.txt    — wallet password (--blspassword for 02-start)
#   bls-pubkey.txt      — 48-byte BLS public key (96 hex chars, no 0x)
#   bls-proof.txt       — 96-byte proof-of-possession (0x-prefixed, 194 chars)
set -euo pipefail

# Default to 3 validators. The baked system contracts (post-#117) elect a FIXED
# 3-validator set into BSCValidatorSet at the epoch boundary (block 200), so the
# chain only stays live past block 200 with all 3 signers present — running 1-2
# produces blocks up to ~200 then stalls ("Signed recently, must wait for
# others") because the snapshot expands to 3 but the missing signers never sign.
# Since fast finality needs the chain to cross an epoch boundary (voteAddress is
# read into the snapshot only at block % epoch == 0), 3 is the minimum that both
# crosses the boundary AND reaches the BLS quorum ceil(2*3/3)=2.
# Override with FINALITY_NUM_VALIDATORS (max 3, bounded by the baked keystores).
NUM_VALIDATORS=${FINALITY_NUM_VALIDATORS:-3}
BLS_PW="blspassword"
CHAIN_ID=7140

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GETH="$REPO_ROOT/build/bin/geth"
LOCAL_DIR="$REPO_ROOT/script/local"
DATA_DIR="$LOCAL_DIR/data"
BLS_PROOF_SRC="$REPO_ROOT/script/test/upgrade-drill/bls_proof/main.go"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# ── Pre-flight ───────────────────────────────────────────────────────────────
[ -x "$GETH" ] || { echo -e "${RED}geth not found at $GETH — run 'make geth'${NC}"; exit 1; }
[ -f "$BLS_PROOF_SRC" ] || { echo -e "${RED}bls_proof helper not found at $BLS_PROOF_SRC${NC}"; exit 1; }
command -v python3 >/dev/null || { echo -e "${RED}python3 required${NC}"; exit 1; }
command -v go      >/dev/null || { echo -e "${RED}go toolchain required (BLS key gen)${NC}"; exit 1; }

echo -e "${GREEN}=== Fast Finality setup: ${NUM_VALIDATORS} validators ===${NC}"

# ── Step 1: accounts + genesis via the local devnet setup ────────────────────
echo -e "${YELLOW}==> Running script/local/01-setup.sh ${NUM_VALIDATORS}...${NC}"
"$LOCAL_DIR/01-setup.sh" "$NUM_VALIDATORS"

# ── Step 2: build bls_proof once ─────────────────────────────────────────────
echo -e "${YELLOW}==> Building bls_proof helper...${NC}"
BLS_PROOF_BIN="$DATA_DIR/bls_proof"
(cd "$REPO_ROOT" && go build -o "$BLS_PROOF_BIN" "$BLS_PROOF_SRC")

# ── Step 3: per-validator BLS keypair + proof-of-possession ──────────────────
for i in $(seq 1 "$NUM_VALIDATORS"); do
    VAL_DIR="$DATA_DIR/validator-$i"
    VAL_ADDR=$(cat "$VAL_DIR/address.txt")
    VAL_ADDR_LOWER=$(echo "$VAL_ADDR" | tr '[:upper:]' '[:lower:]')

    echo -e "${YELLOW}==> validator-$i: generating BLS keypair...${NC}"

    # Skip if already present (idempotent re-runs). Require all three artifacts —
    # wallet, pubkey AND proof — so a run interrupted after `bls account new` but
    # before bls-proof.txt is written is regenerated rather than silently skipped
    # (a missing proof would later be passed empty to createValidator and rejected).
    if [ -f "$VAL_DIR/bls-pubkey.txt" ] && [ -f "$VAL_DIR/bls-proof.txt" ] && [ -d "$VAL_DIR/bls/wallet" ]; then
        echo -e "  ${GREEN}BLS keys already exist — skipping${NC}"
        continue
    fi

    printf '%s\n' "$BLS_PW" > "$VAL_DIR/bls-password.txt"

    # `geth bls account new` creates the Prysm wallet under <datadir>/bls/wallet
    # and a keystore under <datadir>/bls/keystore. The node's --blswallet flag
    # defaults to exactly <datadir>/bls/wallet, so 02-start points there directly.
    "$GETH" bls account new \
        --datadir "$VAL_DIR" \
        --blspassword "$VAL_DIR/bls-password.txt" 2>/dev/null

    keystore=$(find "$VAL_DIR/bls/keystore" -name "keystore-*.json" 2>/dev/null | head -1)
    [ -n "$keystore" ] || { echo -e "${RED}validator-$i: no BLS keystore generated${NC}"; exit 1; }

    proof_out=$("$BLS_PROOF_BIN" \
        -keystore "$keystore" \
        -password "$BLS_PW" \
        -operator "$VAL_ADDR_LOWER" \
        -chainid "$CHAIN_ID")

    BLS_PUBKEY=$(echo "$proof_out" | grep '^PUBKEY=' | cut -d= -f2 | tr -d '[:space:]')
    BLS_PROOF_HEX=$(echo "$proof_out" | grep '^PROOF=' | cut -d= -f2 | tr -d '[:space:]')

    [ ${#BLS_PUBKEY} -eq 96 ]   || { echo -e "${RED}validator-$i: bad pubkey len ${#BLS_PUBKEY}${NC}"; exit 1; }
    [ ${#BLS_PROOF_HEX} -eq 194 ] || { echo -e "${RED}validator-$i: bad proof len ${#BLS_PROOF_HEX}${NC}"; exit 1; }

    echo "$BLS_PUBKEY"    > "$VAL_DIR/bls-pubkey.txt"
    echo "$BLS_PROOF_HEX" > "$VAL_DIR/bls-proof.txt"
    echo -e "  ${GREEN}validator-$i: pubkey ${BLS_PUBKEY:0:12}…${NC}"
done

echo ""
echo -e "${GREEN}=== Setup complete ===${NC}"
echo "Next: ./02-start-with-vote.sh"
