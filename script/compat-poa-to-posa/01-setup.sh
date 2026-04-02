#!/usr/bin/env bash
set -euo pipefail

# Generates genesis.json + node toml configs and initializes validator datadirs.

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

# ---- Step 1: Generate genesis.json from testnet/genesis.json ----
TESTNET_GENESIS="${REPO_ROOT}/script/release/configs/testnet/genesis.json"
require_file "${TESTNET_GENESIS}"

export SCRIPT_DIR
export GENESIS_JSON
export CHAIN_ID
export ADDR1 ADDR2 ADDR3

python3 - <<'PY'
import json, os

script_dir = os.environ['SCRIPT_DIR']
chain_id   = int(os.environ['CHAIN_ID'])
addr1      = os.environ['ADDR1'].lower().lstrip('0x')
addr2      = os.environ['ADDR2'].lower().lstrip('0x')
addr3      = os.environ['ADDR3'].lower().lstrip('0x')

testnet_genesis = os.path.join(
    script_dir, '..', '..', 'script', 'release', 'configs', 'testnet', 'genesis.json')
testnet_genesis = os.path.normpath(testnet_genesis)

with open(testnet_genesis) as f:
    genesis = json.load(f)

# Only modify chainId and extradata; keep everything else (timestamp, difficulty,
# gasLimit, config forks, alloc) identical to testnet.
genesis['config']['chainId'] = chain_id

# Clique extradata: 32 bytes vanity + addr1 + addr2 + addr3 + 65 bytes signature
vanity = '00' * 32
sig    = '00' * 65
genesis['extradata'] = '0x' + vanity + addr1 + addr2 + addr3 + sig

out = os.environ.get('GENESIS_JSON') or os.path.join(script_dir, 'genesis.json')
with open(out, 'w') as f:
    json.dump(genesis, f, indent=2)
    f.write('\n')

print(f'Wrote {out}')
PY

require_file "${GENESIS_JSON}"

# ---- Step 2: Calculate TIME_FORK_TIME and write fork-times.env ----
TIME_FORK_TIME=$(( $(date +%s) + TIME_FORK_DELTA ))
cat >"${SCRIPT_DIR}/fork-times.env" <<EOF
TIME_FORK_TIME=${TIME_FORK_TIME}
EOF
log "TIME_FORK_TIME=${TIME_FORK_TIME} (now + ${TIME_FORK_DELTA}s)"

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
    "${SCRIPT_DIR}/config/node-clique.toml.tpl" \
    "${SCRIPT_DIR}/config/node-clique-${n}.toml" \
    "$n"
  log "Rendered config/node-clique-${n}.toml"

  render_toml \
    "${SCRIPT_DIR}/config/node-posa.toml.tpl" \
    "${SCRIPT_DIR}/config/node-posa-${n}.toml" \
    "$n"
  log "Rendered config/node-posa-${n}.toml"
done

# ---- Step 4: Initialize datadirs ----
for n in 1 2 3; do
  dir=$(val_dir "$n")
  mkdir -p "$dir"

  # Copy keystore from stable keystore dir into runtime datadir.
  ksdir=$(val_keystore_dir "$n")
  require_file "${ksdir}/address.txt"
  mkdir -p "${dir}/keystore"
  cp -r "${ksdir}/keystore/." "${dir}/keystore/"

  log "geth init validator-${n}"
  "$ABCORE_V2_GETH" init --datadir "$dir" "${GENESIS_JSON}" 2>&1 | tail -3
done

log "Setup complete. Next: ./02-start-validators.sh"
