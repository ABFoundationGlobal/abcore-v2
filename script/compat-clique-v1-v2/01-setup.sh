#!/usr/bin/env bash
set -euo pipefail

# Generates 3 v1 validator accounts + Clique genesis.json and initializes datadirs.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

resolve_binaries
mkdir -p "${DATADIR_ROOT}"

NUM_VALIDATORS=${NUM_VALIDATORS:-3}
[[ "$NUM_VALIDATORS" -eq 3 ]] || die "this suite currently expects exactly 3 initial validators (NUM_VALIDATORS=3)"

log "Using v1 geth: ${ABCORE_V1_GETH}"
log "Using v2 geth: ${ABCORE_V2_GETH}"
log "DATADIR_ROOT: ${DATADIR_ROOT}"
log "ChainID/NetworkID: ${CLIQUE_CHAIN_ID}/${CLIQUE_NETWORK_ID}"

create_account() {
  local n="$1"
  local dir
  dir=$(val_dir "$n")
  mkdir -p "$dir"

  local pw
  pw=$(val_pw "$n")
  if [[ ! -f "$pw" ]]; then
    printf "password\n" >"$pw"
  fi

  if [[ -f "$dir/address.txt" ]]; then
    log "validator-${n}: address already exists ($(cat "$dir/address.txt"))"
    return 0
  fi

  local out addr
  out=$("$ABCORE_V1_GETH" account new --datadir "$dir" --password "$pw")
  addr=$(echo "$out" | grep -oE "0x[0-9a-fA-F]{40}" | head -n1 || true)
  [[ -n "$addr" ]] || die "failed to parse account address for validator-${n}: ${out}"
  echo "$addr" >"$dir/address.txt"
  log "validator-${n}: address ${addr}"
}

for n in 1 2 3; do
  create_account "$n"
done

export DATADIR_ROOT
export CLIQUE_CHAIN_ID
export CLIQUE_PERIOD
export SCRIPT_DIR
export GENESIS_JSON

python3 - <<'PY'
import json
import os

script_dir = os.environ.get('SCRIPT_DIR')
if not script_dir:
  raise SystemExit('SCRIPT_DIR env var is required')

datadir = os.environ.get('DATADIR_ROOT')
if not datadir:
    datadir = os.path.join(script_dir, 'data')

def read_addr(n: int) -> str:
    p = os.path.join(datadir, f'validator-{n}', 'address.txt')
    with open(p, 'r') as f:
        a = f.read().strip().lower()
    if not a.startswith('0x') or len(a) != 42:
        raise SystemExit(f'bad address in {p}: {a}')
    return a[2:]

addrs = [read_addr(1), read_addr(2), read_addr(3)]

# Clique extraData = 32 bytes vanity + 20*signers + 65 bytes signature
vanity = '00' * 32
sig = '00' * 65
extra = '0x' + vanity + ''.join(addrs) + sig

chain_id = int(os.environ.get('CLIQUE_CHAIN_ID', '7141'))
period = int(os.environ.get('CLIQUE_PERIOD', '3'))

alloc = {a: {"balance": "1000000000000000000000000"} for a in addrs}

# Base this off cmd/geth/testdata/clique.json
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
    # Required by abcore-v2: set a high value so the network stays pre-merge
    # (Clique) during these compatibility tests.
    "terminalTotalDifficulty": 1000000000000,
    "clique": {"period": period, "epoch": 30000},
  },
  "difficulty": "1",
  "gasLimit": "8000000",
  "extradata": extra,
  "alloc": alloc,
}

out = os.environ.get('GENESIS_JSON') or os.path.join(script_dir, 'genesis.json')
with open(out, 'w') as f:
    json.dump(genesis, f, indent=2)
    f.write('\n')

print(f'Wrote {out}')
PY

require_file "${GENESIS_JSON}"

for n in 1 2 3; do
  dir=$(val_dir "$n")
  log "geth init validator-${n}"
  "$ABCORE_V1_GETH" init --datadir "$dir" "${GENESIS_JSON}"
done

log "Setup complete. Next: ./02-start-v1-validators.sh"