#!/usr/bin/env bash
# Creates 3 validator accounts and a Clique genesis, then initializes datadirs.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"
mkdir -p "${DATADIR_ROOT}"

log "GETH: ${GETH}"
log "DATADIR_ROOT: ${DATADIR_ROOT}"
log "CHAIN_ID: ${CHAIN_ID}"

# ── Create accounts ──────────────────────────────────────────────────────────
create_account() {
  local n="$1"
  local dir pw out addr
  dir=$(val_dir "$n")
  pw=$(val_pw "$n")
  mkdir -p "$dir"
  [[ -f "$pw" ]] || printf "password\n" > "$pw"
  if [[ -f "${dir}/address.txt" ]]; then
    log "validator-${n}: address already exists ($(cat "${dir}/address.txt"))"
    return 0
  fi
  out=$("$GETH" account new --datadir "$dir" --password "$pw")
  addr=$(echo "$out" | grep -oE "0x[0-9a-fA-F]{40}" | head -n1 || true)
  [[ -n "$addr" ]] || die "failed to parse address for validator-${n}: ${out}"
  echo "$addr" > "${dir}/address.txt"
  log "validator-${n}: ${addr}"
}

# use_dev_keystore copies the fixed dev keystore for validator N so its address
# matches INIT_VALIDATORSET_BYTES baked into the defaultNet bytecode.  Without
# this, the first Parlia epoch boundary triggers getValidators() which returns
# the dev-keystore addresses; if the actual validators differ, the chain stalls.
use_dev_keystore() {
  local n="$1"
  local dir src
  dir=$(val_dir "$n")
  src="${REPO_ROOT}/core/systemcontracts/parliagenesis/default/keystores/validator-${n}"
  [[ -d "$src" ]] || die "dev keystore for validator-${n} not found at ${src}"
  mkdir -p "${dir}/keystore"
  cp "${src}"/UTC--* "${dir}/keystore/" 2>/dev/null || true
  cp "${src}/address.txt" "${dir}/address.txt"
  cp "${src}/password.txt" "$(val_pw "$n")" 2>/dev/null || printf "password\n" > "$(val_pw "$n")"
  log "validator-${n}: $(cat "${dir}/address.txt")"
}

for n in 1 2 3; do use_dev_keystore "$n"; done

# ── Write genesis.json ───────────────────────────────────────────────────────
export SCRIPT_DIR DATADIR_ROOT CHAIN_ID CLIQUE_PERIOD CLIQUE_EPOCH GENESIS_JSON

python3 - <<'PY'
import json, os

script_dir = os.environ['SCRIPT_DIR']
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

alloc = {a: {"balance": "1000000000000000000000000"} for a in addrs}

genesis = {
    "config": {
        "chainId": chain_id,
        "homesteadBlock": 0,
        "eip150Block": 0,
        "eip155Block": 0,
        "eip158Block": 0,
        "byzantiumBlock": 0,
        "constantinopleBlock": 0,
        "petersburgBlock": 0,
        "istanbulBlock": 0,
        "berlinBlock": 0,
        # Both clique and parlia configs are required so that HasCliqueAndParlia() = true,
        # which causes CreateConsensusEngine to use DualConsensus when ParliaGenesisBlock is set.
        "clique": {"period": period, "epoch": epoch},
        "parlia": {"period": period, "epoch": epoch},
    },
    "difficulty": "1",
    "gasLimit": "30000000",
    "extradata": extra,
    "alloc": alloc,
}

with open(genesis_out, 'w') as f:
    json.dump(genesis, f, indent=2)
    f.write('\n')
print(f'Wrote {genesis_out}')
PY

require_file "${GENESIS_JSON}"

# ── Initialize datadirs ──────────────────────────────────────────────────────
for n in 1 2 3; do
  log "geth init validator-${n}"
  "$GETH" init --datadir "$(val_dir "$n")" "${GENESIS_JSON}" 2>/dev/null
done

log "Setup complete. Run ./02-start.sh next."
