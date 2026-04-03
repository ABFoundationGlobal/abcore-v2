#!/usr/bin/env bash
set -euo pipefail

# Generates genesis-clique.json + genesis-posa.json + node toml configs,
# and initializes validator datadirs with the Clique genesis.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries

require_file "${SCRIPT_DIR}/validator-addrs.env"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/validator-addrs.env"

log "Using geth: ${ABCORE_V2_GETH}"
log "DATADIR_ROOT: ${DATADIR_ROOT}"
log "ChainID: ${CHAIN_ID}"
log "ParliaGenesisBlock: ${PARLIA_GENESIS_BLOCK}"

ADDR1="$VAL1_ADDR"
ADDR2="$VAL2_ADDR"
ADDR3="$VAL3_ADDR"

log "Validator addresses: ${ADDR1} ${ADDR2} ${ADDR3}"

mkdir -p "${DATADIR_ROOT}"

# ---- Step 1: Compute TIME_FORK_TIME ----
TIME_FORK_TIME=$(( $(date +%s) + TIME_FORK_DELTA ))
cat >"${SCRIPT_DIR}/fork-times.env" <<EOF
TIME_FORK_TIME=${TIME_FORK_TIME}
EOF
log "TIME_FORK_TIME=${TIME_FORK_TIME} (now + ${TIME_FORK_DELTA}s)"

# ---- Step 2: Generate genesis-clique.json and genesis-posa.json ----
TESTNET_GENESIS="${REPO_ROOT}/script/release/configs/testnet/genesis.json"
require_file "${TESTNET_GENESIS}"

export SCRIPT_DIR CHAIN_ID PARLIA_GENESIS_BLOCK TIME_FORK_TIME
export ADDR1 ADDR2 ADDR3
export GENESIS_CLIQUE_JSON GENESIS_POSA_JSON
export TESTNET_GENESIS

python3 - <<'PY'
import json, os

script_dir          = os.environ['SCRIPT_DIR']
chain_id            = int(os.environ['CHAIN_ID'])
parlia_genesis_block = int(os.environ['PARLIA_GENESIS_BLOCK'])
time_fork_time      = int(os.environ['TIME_FORK_TIME'])
addr1               = os.environ['ADDR1'].lower()[2:]
addr2               = os.environ['ADDR2'].lower()[2:]
addr3               = os.environ['ADDR3'].lower()[2:]
testnet_genesis     = os.environ['TESTNET_GENESIS']
out_clique          = os.environ['GENESIS_CLIQUE_JSON']
out_posa            = os.environ['GENESIS_POSA_JSON']

with open(testnet_genesis) as f:
    base = json.load(f)

# Clique extradata: 32 bytes vanity + addr1+addr2+addr3 + 65 bytes sig
vanity = '00' * 32
sig    = '00' * 65
extradata = '0x' + vanity + addr1 + addr2 + addr3 + sig

# --- genesis-clique.json: only change chainId + extradata ---
clique = json.loads(json.dumps(base))   # deep copy
clique['config']['chainId'] = chain_id
clique['extradata'] = extradata

with open(out_clique, 'w') as f:
    json.dump(clique, f, indent=2)
    f.write('\n')
print(f'Wrote {out_clique}')

# --- genesis-posa.json: same header fields + all upgrade configs in config ---
posa = json.loads(json.dumps(clique))   # deep copy of clique genesis
cfg  = posa['config']

# Block-based forks — all activate at parliaGenesisBlock
for key in [
    'londonBlock', 'arrowGlacierBlock', 'grayGlacierBlock',
    'ramanujanBlock', 'nielsBlock', 'mirrorSyncBlock',
    'brunoBlock', 'eulerBlock', 'gibbsBlock', 'nanoBlock', 'moranBlock',
    'planckBlock', 'lubanBlock', 'platoBlock',
    'hertzBlock', 'hertzfixBlock', 'parliaGenesisBlock',
]:
    cfg[key] = parlia_genesis_block

# Time-based forks — all activate at time_fork_time
for key in [
    'shanghaiTime', 'keplerTime', 'feynmanTime', 'feynmanFixTime',
    'cancunTime', 'haberTime', 'haberFixTime', 'bohrTime',
    'pascalTime', 'pragueTime', 'lorentzTime', 'maxwellTime',
    'fermiTime', 'osakaTime', 'mendelTime',
    'bpo1Time', 'bpo2Time', 'bpo3Time', 'bpo4Time', 'bpo5Time',
    'amsterdamTime', 'pasteurTime',
]:
    cfg[key] = time_fork_time

# blobSchedule: required for each time fork that introduces blobs
_bc = {'cancun':{'target':3,'max':6,'baseFeeUpdateFraction':3338477},'prague':{'target':3,'max':6,'baseFeeUpdateFraction':3338477},'osaka':{'target':3,'max':6,'baseFeeUpdateFraction':3338477},'bpo1':{'target':10,'max':15,'baseFeeUpdateFraction':8346193},'bpo2':{'target':14,'max':21,'baseFeeUpdateFraction':11684671},'bpo3':{'target':21,'max':32,'baseFeeUpdateFraction':20609697},'bpo4':{'target':14,'max':21,'baseFeeUpdateFraction':13739630}}
_bc['bpo5']=_bc['bpo4']
_bc['amsterdam']=_bc['bpo4']
cfg['blobSchedule']=_bc
# Enable Parlia (empty config struct)
cfg['parlia'] = {}

with open(out_posa, 'w') as f:
    json.dump(posa, f, indent=2)
    f.write('\n')
print(f'Wrote {out_posa}')
PY

require_file "${GENESIS_CLIQUE_JSON}"
require_file "${GENESIS_POSA_JSON}"

# ---- Step 3: Render node toml configs from templates ----
render_toml() {
  local tpl="$1"
  local out="$2"
  local n="$3"
  local datadir
  datadir=$(val_dir "$n")
  local p2p
  p2p=$(p2p_port "$n")
  local auth
  auth=$(authrpc_port "$n")

  sed \
    -e "s|{{CHAIN_ID}}|${CHAIN_ID}|g" \
    -e "s|{{DATADIR}}|${datadir}|g" \
    -e "s|{{P2P_PORT}}|${p2p}|g" \
    -e "s|{{AUTH_PORT}}|${auth}|g" \
    -e "s|{{CLIQUE_PERIOD}}|${CLIQUE_PERIOD}|g" \
    -e "s|{{CLIQUE_EPOCH}}|${CLIQUE_EPOCH}|g" \
    -e "s|{{PARLIA_GENESIS_BLOCK}}|${PARLIA_GENESIS_BLOCK}|g" \
    -e "s|{{TIME_FORK_TIME}}|${TIME_FORK_TIME}|g" \
    "$tpl" >"$out"
}

for n in 1 2 3; do
  render_toml \
    "${SCRIPT_DIR}/config/node.toml.tpl" \
    "${SCRIPT_DIR}/config/node-${n}.toml" \
    "$n"
  log "Rendered config/node-${n}.toml"
done

log "Setup complete. Next: ./02-start-validators.sh"

# ---- Step 4: Initialize datadirs with Clique genesis ----
for n in 1 2 3; do
  dir=$(val_dir "$n")
  mkdir -p "$dir"

  # Copy keystore from stable keystore dir into runtime datadir.
  ksdir=$(val_keystore_dir "$n")
  require_file "${ksdir}/address.txt"
  mkdir -p "${dir}/keystore"
  cp -r "${ksdir}/keystore/." "${dir}/keystore/"

  log "geth init validator-${n} (Clique genesis)"
  "$ABCORE_V2_GETH" init --datadir "$dir" "${GENESIS_CLIQUE_JSON}" 2>&1 | tail -3
done
