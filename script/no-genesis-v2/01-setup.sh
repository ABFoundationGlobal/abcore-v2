#!/usr/bin/env bash
set -euo pipefail

# Generates genesis files and initializes datadirs for both scenarios.
#
# Scn1: Uses the exact ABCore testnet genesis (chain ID 26888) produced by
#       `geth dumpgenesis --abcore.testnet`. v1 is init'd from this genesis;
#       v2 starts from an empty datadir using --abcore.testnet (no init).
#
# Scn2: Uses a custom genesis with the same config as ABCoreTestChainConfig
#       but fresh validator accounts in extraData. Both v1 and v2 are init'd
#       from this genesis (v2 uses --networkid 26888, not --abcore.testnet).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Resolve paths now that DATADIR_ROOT is final.
TESTNET_GENESIS="$(testnet_genesis_json)"
CUSTOM_GENESIS="$(custom_genesis_json)"
VALIDATOR_PW="$(scn2_validator_pw_file)"
VALIDATOR_ADDR_F="$(scn2_validator_addr_file)"

resolve_binaries
mkdir -p "${DATADIR_ROOT}"

log "Using v1 geth: ${ABCORE_V1_GETH}"
log "Using v2 geth: ${ABCORE_V2_GETH}"
log "DATADIR_ROOT:  ${DATADIR_ROOT}"

# ---- Scn1: testnet genesis via dumpgenesis ----
log "Scn1: generating testnet genesis via dumpgenesis --abcore.testnet"
"$ABCORE_V2_GETH" dumpgenesis --abcore.testnet > "${TESTNET_GENESIS}"
require_file "${TESTNET_GENESIS}"
log "Scn1: testnet genesis written to ${TESTNET_GENESIS}"

mkdir -p "$(scn1_v1_datadir)" "$(scn1_v2_datadir)"

log "Scn1: init v1 datadir with testnet genesis"
"$ABCORE_V1_GETH" init --datadir "$(scn1_v1_datadir)" "${TESTNET_GENESIS}"

# v2 scn1 datadir intentionally left empty — no init, that is the test.
log "Scn1: v2 datadir left empty (no init) at $(scn1_v2_datadir)"

# ---- Scn2: custom genesis with fresh validator accounts ----
log "Scn2: generating fresh validator account"

mkdir -p "${DATADIR_ROOT}/scn2-validator"
if [[ ! -f "${VALIDATOR_PW}" ]]; then
  printf "password\n" > "${VALIDATOR_PW}"
fi

if [[ ! -f "${VALIDATOR_ADDR_F}" ]]; then
  out=$("$ABCORE_V1_GETH" account new \
    --datadir "${DATADIR_ROOT}/scn2-validator" \
    --password "${VALIDATOR_PW}")
  addr=$(echo "$out" | grep -oE "0x[0-9a-fA-F]{40}" | head -n1 || true)
  [[ -n "$addr" ]] || die "failed to parse validator address: ${out}"
  echo "$addr" > "${VALIDATOR_ADDR_F}"
fi

VALIDATOR_ADDR=$(cat "${VALIDATOR_ADDR_F}")
log "Scn2: validator address: ${VALIDATOR_ADDR}"

export DATADIR_ROOT ABCORE_CHAIN_ID ABCORE_PERIOD ABCORE_EPOCH VALIDATOR_ADDR
export CUSTOM_GENESIS

python3 - <<'PY'
import json, os

chain_id     = int(os.environ['ABCORE_CHAIN_ID'])
period       = int(os.environ['ABCORE_PERIOD'])
epoch        = int(os.environ['ABCORE_EPOCH'])
validator    = os.environ['VALIDATOR_ADDR'].lower()
out_path     = os.environ['CUSTOM_GENESIS']

if validator.startswith('0x'):
    validator = validator[2:]

if len(validator) != 40:
    raise SystemExit(f'bad validator address: {validator}')

# Clique extraData: 32-byte vanity + 20-byte addr + 65-byte seal
vanity = '00' * 32
seal   = '00' * 65
extra  = '0x' + vanity + validator + seal

# Config mirrors ABCoreTestChainConfig (same fork schedule as production
# testnet, chain ID 26888, period 1, epoch 30000).
genesis = {
    "config": {
        "chainId":             chain_id,
        "homesteadBlock":      0,
        "eip150Block":         0,
        "eip155Block":         0,
        "eip158Block":         0,
        "byzantiumBlock":      0,
        "constantinopleBlock": 0,
        "petersburgBlock":     0,
        "istanbulBlock":       0,
        "muirGlacierBlock":    0,
        "berlinBlock":         0,
        # terminalTotalDifficulty keeps this network in Clique (pre-merge)
        # for the duration of the test.
        "terminalTotalDifficulty": 1000000000000,
        "clique": {"period": period, "epoch": epoch},
        # parlia: {} must be present so HasCliqueAndParlia() returns true, which
        # routes CreateConsensusEngine() through the ABCore dual-consensus branch
        # (currently Clique-only since ParliaGenesisBlock is nil).  Without this
        # field the loaded ChainConfig has Parlia==nil and the test degenerates
        # into plain Clique — identical to what compat-clique-v1-v2 already covers.
        "parlia": {},
    },
    "timestamp":  "0x67cab05a",   # same as production testnet genesis
    "difficulty": "1",
    "gasLimit":   "0x1406f40",    # 21000000
    "extradata":  extra,
    "alloc": {
        validator: {"balance": "1000000000000000000000000"},
    },
}

with open(out_path, 'w') as f:
    json.dump(genesis, f, indent=2)
    f.write('\n')

print(f'Wrote {out_path}')
PY

require_file "${CUSTOM_GENESIS}"

mkdir -p "$(scn2_v1_datadir)" "$(scn2_v2_datadir)"

# Copy keystore from scn2-validator into both scn2 datadirs so the nodes can
# find the account.
cp -r "${DATADIR_ROOT}/scn2-validator/keystore" "$(scn2_v1_datadir)/keystore" 2>/dev/null || true
cp -r "${DATADIR_ROOT}/scn2-validator/keystore" "$(scn2_v2_datadir)/keystore" 2>/dev/null || true

log "Scn2: init v1 datadir"
"$ABCORE_V1_GETH" init --datadir "$(scn2_v1_datadir)" "${CUSTOM_GENESIS}"

log "Scn2: init v2 datadir"
"$ABCORE_V2_GETH" init --datadir "$(scn2_v2_datadir)" "${CUSTOM_GENESIS}"

log "Setup complete."
log "  Scn1 testnet genesis: ${TESTNET_GENESIS}"
log "  Scn2 custom genesis:  ${CUSTOM_GENESIS}"
log "  Scn2 validator:       ${VALIDATOR_ADDR}"
log "Next: ./10-scn1-v2-no-genesis-startup.sh"
