#!/usr/bin/env bash
# Initialises the 3-node network for the upgrade drill.
#
# Uses the fixed dev keystores from core/systemcontracts/parliagenesis/default/
# so that validator addresses match INIT_VALIDATORSET_BYTES baked into the
# defaultNet contract bytecodes.  This is required for U-3 (Feynman / StakeHub)
# and beyond.
#
# Creates:
#   <DATADIR_ROOT>/validator-{1,2,3}/  — keystores, password files, datadirs
#   <DATADIR_ROOT>/genesis.json        — Clique+Parlia genesis; higher forks
#                                        at placeholder heights, overridden by
#                                        each U-N script via reinit_genesis()
#   <DATADIR_ROOT>/config.toml         — base TOML (NetworkId, SyncMode only)
#
# Does NOT start the nodes.  Run 80-run-u1-parlia-switch.sh next.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"

if [[ -d "${DATADIR_ROOT}" ]]; then
  die "DATADIR_ROOT already exists: ${DATADIR_ROOT}
Run '${SCRIPT_DIR}/clean.sh' first, or set DATADIR_ROOT to a new path."
fi

mkdir -p "${DATADIR_ROOT}"
log "GETH:        ${GETH}"
log "DATADIR_ROOT: ${DATADIR_ROOT}"
log "CHAIN_ID:    ${CHAIN_ID}"

# ── Dev keystores ─────────────────────────────────────────────────────────────

use_dev_keystore() {
  local n="$1"
  local dir src
  dir=$(val_dir "$n")
  src="${REPO_ROOT}/core/systemcontracts/parliagenesis/default/keystores/validator-${n}"
  [[ -d "$src" ]] || die "dev keystore for validator-${n} not found at ${src}"
  mkdir -p "${dir}/keystore"
  local -a keystore_files
  shopt -s nullglob; keystore_files=("${src}"/UTC--*); shopt -u nullglob
  [[ ${#keystore_files[@]} -gt 0 ]] || die "no UTC--* files in ${src}"
  cp "${keystore_files[@]}" "${dir}/keystore/"
  cp "${src}/address.txt" "${dir}/address.txt"
  cp "${src}/password.txt" "$(val_pw "$n")" 2>/dev/null || printf "password\n" > "$(val_pw "$n")"
  log "validator-${n}: $(cat "${dir}/address.txt")"
}

for n in 1 2 3; do use_dev_keystore "$n"; done

# ── Genesis ───────────────────────────────────────────────────────────────────
# Fork activation heights / timestamps are set to large placeholder values here.
# Each U-N script calls reinit_genesis() with an updated genesis.json that
# lowers the relevant parameter to the desired local test value.
#
# Exception: ParliaGenesisBlock is left absent; U-1 activates it via the
# OverrideParliaGenesisBlock TOML field (no genesis reinit needed for U-1).

export SCRIPT_DIR DATADIR_ROOT CHAIN_ID CLIQUE_PERIOD CLIQUE_EPOCH GENESIS_JSON

python3 - <<'PY'
import json, os

datadir    = os.environ['DATADIR_ROOT']
genesis_out = os.environ['GENESIS_JSON']
chain_id   = int(os.environ['CHAIN_ID'])
period     = int(os.environ['CLIQUE_PERIOD'])
epoch      = int(os.environ['CLIQUE_EPOCH'])

def read_addr(n):
    p = os.path.join(datadir, f'validator-{n}', 'address.txt')
    with open(p) as f:
        a = f.read().strip().lower()
    if not a.startswith('0x') or len(a) != 42:
        raise SystemExit(f'bad address in {p}: {a}')
    return a[2:]

addrs = [read_addr(1), read_addr(2), read_addr(3)]

vanity = '00' * 32
sig    = '00' * 65
extra  = '0x' + vanity + ''.join(addrs) + sig

alloc = {a: {'balance': '1000000000000000000000000'} for a in addrs}

genesis = {
    'config': {
        'chainId': chain_id,
        'homesteadBlock': 0,
        'eip150Block': 0,
        'eip155Block': 0,
        'eip158Block': 0,
        'byzantiumBlock': 0,
        'constantinopleBlock': 0,
        'petersburgBlock': 0,
        'istanbulBlock': 0,
        'berlinBlock': 0,
        # Higher forks (London, Shanghai, Cancun, …) are intentionally absent
        # (nil) here.  Each U-N script adds the relevant fork fields to
        # genesis.json and calls reinit_genesis() to update the stored
        # chainconfig.  Absent fields are never-activated, which is the correct
        # representation of the initial v0.1 Clique chain state.
        # Both clique and parlia are required so HasCliqueAndParlia() = true,
        # which enables DualConsensus when OverrideParliaGenesisBlock is set.
        'clique':  {'period': period, 'epoch': epoch},
        'parlia':  {'period': period, 'epoch': epoch},
    },
    'difficulty': '1',
    'gasLimit':   '30000000',
    'extradata':  extra,
    'alloc':      alloc,
}

with open(genesis_out, 'w') as f:
    json.dump(genesis, f, indent=2)
    f.write('\n')
print(f'Wrote {genesis_out}')
PY

require_file "${GENESIS_JSON}"

# ── Initialise datadirs ───────────────────────────────────────────────────────

for n in 1 2 3; do
  log "geth init validator-${n}"
  "$GETH" init --datadir "$(val_dir "$n")" "${GENESIS_JSON}" 2>/dev/null
done

# ── Base TOML config ──────────────────────────────────────────────────────────
# Each U-N script appends its own section to this file before restarting nodes.

cat > "${TOML_CONFIG}" <<TOML
[Eth]
NetworkId = ${NETWORK_ID}
SyncMode = "full"

[Eth.Miner]
GasPrice = 1000000000

[Node]
InsecureUnlockAllowed = true
NoUSB = true
TOML
log "Wrote base TOML: ${TOML_CONFIG}"

log "Init complete."
log "Next: run 80-run-u1-parlia-switch.sh"
