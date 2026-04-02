#!/usr/bin/env bash
set -euo pipefail

# Compiles system contracts and rebuilds the geth binary with custom genesis bytecode.
# Run once before 01-setup.sh. Safe to re-run (skips steps that are already complete).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PARLIAGENESIS_DIR="${REPO_ROOT}/core/systemcontracts/parliagenesis"

# Ensure poetry and foundry (installed by 'make pre' / foundryup) are on PATH.
export PATH="${HOME}/.local/bin:${HOME}/.foundry/bin:${PATH}"

# ---- Pre-flight checks ----

# Python dev headers (required to build lru-dict C extension)
_py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")
_python_h=$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))' 2>/dev/null || echo "")
if [[ -z "$_python_h" ]] || [[ ! -f "${_python_h}/Python.h" ]]; then
  log "Python.h not found — installing python3-dev"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y "python${_py_ver}-dev" 2>/dev/null || sudo apt-get install -y python3-dev
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y "python${_py_ver}-devel" 2>/dev/null || sudo yum install -y python3-devel
  else
    die "Python.h not found. Install python3-dev (Debian/Ubuntu) or python3-devel (RHEL/CentOS) and retry."
  fi
fi

# Forge (required by 'make build' to compile Solidity contracts)
if ! command -v forge >/dev/null 2>&1; then
  log "forge not found — installing Foundry via foundryup"
  curl -sSL https://foundry.paradigm.xyz | bash
  # foundryup installs into ~/.foundry/bin; it should already be on PATH above.
  foundryup
  command -v forge >/dev/null 2>&1 || die "forge still not found after foundryup; check Foundry installation"
  log "forge installed: $(forge --version)"
else
  log "forge already available: $(forge --version)"
fi

# ---- Step 1: Ensure genesis contract deps are available ----
# Run 'make pre' if node_modules is missing OR if poetry is not yet available.
if [[ ! -d "${PARLIAGENESIS_DIR}/abcore-v2-genesis-contract/node_modules" ]] || \
   ! command -v poetry >/dev/null 2>&1; then
  log "Running: make pre (cloning + installing genesis contract deps)"
  make -C "${PARLIAGENESIS_DIR}" pre
else
  log "Genesis contract dependencies already present, skipping 'make pre'"
fi

# ---- Step 2: Create 3 test accounts (stable keystore dirs) ----
BLS_PLACEHOLDER="0x$(printf 'ab%.0s' {1..96})"  # 96 bytes of 0xab...

for n in 1 2 3; do
  ksdir=$(val_keystore_dir "$n")
  mkdir -p "$ksdir"

  pwfile=$(val_pw "$n")
  if [[ ! -f "$pwfile" ]]; then
    printf "password\n" >"$pwfile"
  fi

  if [[ -f "${ksdir}/address.txt" ]]; then
    log "keystore-${n}: address already exists ($(cat "${ksdir}/address.txt"))"
    continue
  fi

  # Pick any available geth binary to create accounts.
  _geth="${ABCORE_V2_GETH:-}"
  if [[ -z "$_geth" ]]; then
    if [[ -x "${SCRIPT_DIR}/bin/geth-custom" ]]; then
      _geth="${SCRIPT_DIR}/bin/geth-custom"
    elif [[ -x "${REPO_ROOT}/build/bin/geth" ]]; then
      _geth="${REPO_ROOT}/build/bin/geth"
    else
      # Build a minimal geth first so we can create accounts, then rebuild later.
      log "No geth binary found; building ${REPO_ROOT}/build/bin/geth first"
      (cd "${REPO_ROOT}" && go build -o build/bin/geth ./cmd/geth)
      _geth="${REPO_ROOT}/build/bin/geth"
    fi
  fi

  log "Creating account keystore-${n}"
  out=$("$_geth" account new --datadir "$ksdir" --password "$pwfile" 2>&1)
  addr=$(echo "$out" | grep -oE "0x[0-9a-fA-F]{40}" | head -n1 || true)
  [[ -n "$addr" ]] || die "failed to parse account address for keystore-${n}: ${out}"
  echo "$addr" >"${ksdir}/address.txt"
  log "keystore-${n}: address ${addr}"
done

# ---- Step 3: Write validator-addrs.env ----
ADDR1=$(cat "$(val_keystore_dir 1)/address.txt")
ADDR2=$(cat "$(val_keystore_dir 2)/address.txt")
ADDR3=$(cat "$(val_keystore_dir 3)/address.txt")

cat >"${SCRIPT_DIR}/validator-addrs.env" <<EOF
VAL1_ADDR=${ADDR1}
VAL2_ADDR=${ADDR2}
VAL3_ADDR=${ADDR3}
EOF
log "Written validator-addrs.env"

# ---- Step 4: Generate validators.conf for parliagenesis ----
log "Writing ${PARLIAGENESIS_DIR}/validators.conf"
cat >"${PARLIAGENESIS_DIR}/validators.conf" <<EOF
consensusAddr,feeAddr,bscFeeAddr,votingPower,bLSPublicKey
${ADDR1},${ADDR1},${ADDR1},0x64,${BLS_PLACEHOLDER}
${ADDR2},${ADDR2},${ADDR2},0x64,${BLS_PLACEHOLDER}
${ADDR3},${ADDR3},${ADDR3},0x64,${BLS_PLACEHOLDER}
EOF

# ---- Step 5: Build system contract bytecode ----
log "Building system contracts (CHAIN_ID=${CHAIN_ID}, MAX_ELECTED_VALIDATORS=3, BLOCK_INTERVAL=${CLIQUE_PERIOD} seconds)"
make -C "${PARLIAGENESIS_DIR}" build \
  CHAIN_ID="${CHAIN_ID}" \
  MAX_ELECTED_VALIDATORS=3 \
  "BLOCK_INTERVAL=${CLIQUE_PERIOD} seconds"

log "System contracts built into ${PARLIAGENESIS_DIR}/default/"

# ---- Step 6: Build geth binary ----
mkdir -p "${SCRIPT_DIR}/bin"
log "Building geth binary → ${SCRIPT_DIR}/bin/geth-custom"
(cd "${REPO_ROOT}" && go build -o "${SCRIPT_DIR}/bin/geth-custom" ./cmd/geth)
log "geth-custom built: $("${SCRIPT_DIR}/bin/geth-custom" version 2>&1 | head -1)"

log "Build complete. Next: ./01-setup.sh"
