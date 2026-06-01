#!/usr/bin/env bash
# Fast Finality E2E — Step 3: register every validator in StakeHub with its
# BLS voteAddress + proof-of-possession (createValidator + delegate).
#
# Why this is required: IsActiveValidatorAt (consensus/parlia/parlia.go:1768)
# checks the validator's voteAddress in the snapshot via checkVoteKeyFn. Until
# the BLS pubkey is registered on-chain via StakeHub.createValidator and the
# next breathe block runs updateValidatorSetV2, the node's voteKey won't match
# any active validator and it will NOT sign votes.
#
# The createValidator ABI encoding is reused verbatim from
# script/local/08-test-breathe-block.sh.
set -euo pipefail

STAKEHUB="0x0000000000000000000000000000000000002002"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GETH="$REPO_ROOT/build/bin/geth"
DATA_DIR="$REPO_ROOT/script/local/data"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

[ -d "$DATA_DIR/validator-1" ] || { echo -e "${RED}Setup not done. Run ./01-setup.sh first${NC}"; exit 1; }
NUM_VALIDATORS=$(ls -d "$DATA_DIR"/validator-* 2>/dev/null | wc -l)

# ── helpers (per-validator IPC) ──────────────────────────────────────────────
_attach() {  # _attach <validator-num> <js>
    "$GETH" attach --exec "$2" "$DATA_DIR/validator-$1/geth.ipc" 2>/dev/null | tr -d '"' | tr -d '\r'
}

_wait_mined() {  # _wait_mined <validator-num> <txhash> <label>
    local num="$1" tx="$2" label="$3"
    for _ in $(seq 1 20); do
        sleep 3
        local st
        st=$(_attach "$num" "(function(){var r=eth.getTransactionReceipt('${tx}');return r?r.status:'pending';})()")
        case "$st" in
            0x1|1) echo -e "${GREEN}  PASS  $label (tx=${tx:0:14}…)${NC}"; return 0 ;;
            0x0|0) echo -e "${RED}  FAIL  $label reverted (tx=${tx:0:14}…)${NC}"; return 1 ;;
        esac
    done
    echo -e "${RED}  FAIL  $label not mined after 60s${NC}"; return 1
}

# ── Wait for StakeHub init on validator-1 (minSelfDelegationBNB > 0) ──────────
echo -e "${YELLOW}==> Waiting for StakeHub initialization...${NC}"
MIN_SEL=$(_attach 1 "web3.sha3('minSelfDelegationBNB()').slice(2,10)")
LOCK_SEL=$(_attach 1 "web3.sha3('LOCK_AMOUNT()').slice(2,10)")
CREATE_SEL=$(_attach 1 "web3.sha3('createValidator(address,bytes,bytes,(uint64,uint64,uint64),(string,string,string,string))').slice(2,10)")
DEL_SEL=$(_attach 1 "web3.sha3('delegate(address,bool)').slice(2,10)")
[ ${#CREATE_SEL} -eq 8 ] || { echo -e "${RED}IPC/selector not ready${NC}"; exit 1; }

MIN_WEI=0
for i in $(seq 1 60); do
    MIN_RAW=$(_attach 1 "eth.call({to:'${STAKEHUB}',data:'0x${MIN_SEL}'})")
    MIN_WEI=$(python3 -c "print(int('${MIN_RAW}'.replace('0x','') or '0',16))" 2>/dev/null || echo 0)
    [ "${MIN_WEI:-0}" != "0" ] && break
    [ $i -eq 60 ] && { echo -e "${RED}StakeHub not initialized after 60s${NC}"; exit 1; }
    sleep 1
done
LOCK_RAW=$(_attach 1 "eth.call({to:'${STAKEHUB}',data:'0x${LOCK_SEL}'})")
LOCK_WEI=$(python3 -c "print(int('${LOCK_RAW}'.replace('0x','') or '0',16))" 2>/dev/null || echo 0)
TX_VALUE_HEX=$(python3 -c "print(hex(${MIN_WEI}+${LOCK_WEI}))")
echo -e "  ${GREEN}StakeHub ready — LOCK=${LOCK_WEI} minSelfDel=${MIN_WEI} wei${NC}"

# ── Register each validator from its own node ────────────────────────────────
declare -a CREATE_TXS DEL_TXS
for i in $(seq 1 "$NUM_VALIDATORS"); do
    VAL_DIR="$DATA_DIR/validator-$i"
    VAL_ADDR_LOWER=$(tr '[:upper:]' '[:lower:]' < "$VAL_DIR/address.txt")
    BLS_PUBKEY=$(cat "$VAL_DIR/bls-pubkey.txt")
    BLS_PROOF_HEX=$(cat "$VAL_DIR/bls-proof.txt")

    echo -e "${YELLOW}==> validator-$i: createValidator + delegate...${NC}"

    CALLBODY=$(VAL_ADDR_LOWER="$VAL_ADDR_LOWER" BLS_PUBKEY="$BLS_PUBKEY" BLS_PROOF_HEX="$BLS_PROOF_HEX" \
               VAL_LABEL="Val$i" python3 - <<'PY'
import os
def to32(n): return n.to_bytes(32,'big').hex()
def enc_bytes(h):
    d=bytes.fromhex(h); sz=len(d); pad=(32-sz%32)%32
    return to32(sz)+h+'00'*pad
def enc_str(s): return enc_bytes(s.encode().hex())

addr_hex=os.environ['VAL_ADDR_LOWER'].replace('0x','')
pubkey_hex=os.environ['BLS_PUBKEY']
proof_hex=os.environ['BLS_PROOF_HEX'].replace('0x','')

p_addr='00'*12+addr_hex
vote_enc=enc_bytes(pubkey_hex)
bls_enc=enc_bytes(proof_hex)
commission_enc=to32(10)+to32(100)+to32(5)
mon_enc=enc_str(os.environ['VAL_LABEL'])
id_enc=enc_str(''); ws_enc=enc_str(''); det_enc=enc_str('')
inner_head=4*32
mon_off=inner_head
id_off=mon_off+len(mon_enc)//2
ws_off=id_off+len(id_enc)//2
det_off=ws_off+len(ws_enc)//2
desc_enc=(to32(mon_off)+to32(id_off)+to32(ws_off)+to32(det_off)
          +mon_enc+id_enc+ws_enc+det_enc)
HEAD=32+32+32+96+32
vote_off=HEAD
bls_off=vote_off+len(vote_enc)//2
desc_off=bls_off+len(bls_enc)//2
head=(p_addr+to32(vote_off)+to32(bls_off)+commission_enc+to32(desc_off))
print(head+vote_enc+bls_enc+desc_enc)
PY
)

    PADDED_ADDR=$(printf '%064s' "${VAL_ADDR_LOWER#0x}" | tr ' ' '0')

    CREATE_TX=$(_attach "$i" "eth.sendTransaction({from:'${VAL_ADDR_LOWER}',to:'${STAKEHUB}',value:'${TX_VALUE_HEX}',gas:2000000,data:'0x${CREATE_SEL}${CALLBODY}'})")
    [[ "$CREATE_TX" =~ ^0x[0-9a-fA-F]{64}$ ]] || { echo -e "${RED}validator-$i: createValidator rejected (got '${CREATE_TX}')${NC}"; exit 1; }
    CREATE_TXS[$i]="$CREATE_TX"

    DEL_TX=$(_attach "$i" "eth.sendTransaction({from:'${VAL_ADDR_LOWER}',to:'${STAKEHUB}',value:'0xde0b6b3a7640000',gas:300000,data:'0x${DEL_SEL}${PADDED_ADDR}$(printf '%064x' 1)'})")
    [[ "$DEL_TX" =~ ^0x[0-9a-fA-F]{64}$ ]] || { echo -e "${RED}validator-$i: delegate rejected (got '${DEL_TX}')${NC}"; exit 1; }
    DEL_TXS[$i]="$DEL_TX"
done

# ── Wait for all registration txs to be mined ────────────────────────────────
for i in $(seq 1 "$NUM_VALIDATORS"); do
    _wait_mined "$i" "${CREATE_TXS[$i]}" "validator-$i createValidator"
    _wait_mined "$i" "${DEL_TXS[$i]}"   "validator-$i delegate"
done

# ── CRITICAL: confirm the StakeHub election set is non-empty ─────────────────
# A breathe block runs ValidatorContract.updateValidatorSetV2(eValidators,...).
# If getValidatorElectionInfo returns an EMPTY set, the contract reverts with
# `invalid opcode: INVALID`, the breathe block can't be sealed, and the chain
# STALLS permanently. So registration MUST be reflected in the election before
# any breathe block fires. Poll getValidatorElectionInfo until totalLength > 0.
echo -e "${YELLOW}==> Confirming StakeHub election set is non-empty (prevents breathe-block stall)...${NC}"
ELECT_SEL=$(_attach 1 "web3.sha3('getValidatorElectionInfo(uint256,uint256)').slice(2,10)")
ELECT_DATA="0x${ELECT_SEL}$(printf '%064x' 0)$(printf '%064x' 0)"
ELECTED=0
for _ in $(seq 1 30); do
    RAW=$(_attach 1 "eth.call({to:'${STAKEHUB}',data:'${ELECT_DATA}'})")
    # ABI return: (address[] off, uint256[] off, bytes[] off, uint256 totalLength).
    # The three dynamic args are returned as head offsets, so `totalLength` is the
    # 4th static head word (byte offset 0x60 = chars 2+3*64 .. 2+4*64), NOT the
    # trailing word. Non-zero means at least one validator is in _validatorSet.
    if [[ "$RAW" =~ ^0x[0-9a-fA-F]+$ ]] && [ ${#RAW} -ge $((2 + 4*64)) ]; then
        TOTAL_HEX=${RAW:$((2 + 3*64)):64}
        TOTAL=$(python3 -c "print(int('${TOTAL_HEX}',16))" 2>/dev/null || echo 0)
        [ "${TOTAL:-0}" -gt 0 ] && { ELECTED=$TOTAL; break; }
    fi
    sleep 2
done
if [ "$ELECTED" -lt 1 ]; then
    echo -e "${RED}  FAIL  election set still empty after registration — a breathe block WILL stall the chain.${NC}"
    exit 1
fi
echo -e "  ${GREEN}election set has ${ELECTED} validator(s) — safe for breathe block${NC}"

echo ""
echo -e "${GREEN}=== All ${NUM_VALIDATORS} validators registered; election non-empty ===${NC}"
echo "voteAddress takes effect at the next breathe block (updateValidatorSetV2)."
echo "Next: ./04-verify-finality.sh"
