#!/usr/bin/env bash
# One-time: generate BLS keypairs for the 3 dev validators and store them
# alongside the existing secp256k1 keystores.
#
# Run this script ONCE after building geth, then commit the output files.
# The output is deterministic per-validator because it depends only on the
# fixed operator address, the generated BLS private key, and CHAIN_ID=99988.
#
# Output per validator (in core/systemcontracts/parliagenesis/default/keystores/validator-N/):
#   bls-password.txt  — wallet+account password (plain text: "blspassword")
#   bls-pubkey.txt    — 48-byte BLS public key (96 hex chars, no 0x prefix)
#   bls-proof.txt     — 96-byte proof-of-possession for chain-id 99988 (0x-prefixed, 194 chars)
#   bls-wallet/       — Prysm-format BLS wallet (for Fast Finality node operation)
#
# Usage:
#   make geth
#   bash script/upgrade-drill/09-gen-bls-keys.sh
#   git add core/systemcontracts/parliagenesis/default/keystores
#   git commit -m "chore: pre-generate BLS keys for dev validators"
#
# To regenerate (rotate keys), delete the bls-* files and bls-wallet/ dirs, then re-run.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

require_exe "$GETH"

KEYSTORE_BASE="${REPO_ROOT}/core/systemcontracts/parliagenesis/default/keystores"
BLS_PW="blspassword"

log "Generating BLS keys for dev validators (chain-id=${CHAIN_ID})..."

for n in 1 2 3; do
  dest="${KEYSTORE_BASE}/validator-${n}"
  [[ -d "$dest" ]] || die "keystore dir not found: $dest"

  addr=$(cat "${dest}/address.txt" | tr -d '[:space:]')
  addr_lower=$(echo "$addr" | tr '[:upper:]' '[:lower:]')

  if [[ -f "${dest}/bls-pubkey.txt" && -f "${dest}/bls-proof.txt" ]]; then
    log "validator-${n}: BLS keys already exist — skipping (delete bls-* files and bls-wallet/ to regenerate)"
    continue
  fi

  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  pwfile="${tmpdir}/bls-pw.txt"
  printf '%s\n' "$BLS_PW" > "$pwfile"

  log "validator-${n}: creating BLS wallet and generating keypair..."
  "$GETH" bls account new \
    --datadir "$tmpdir" \
    --blspassword "$pwfile" \
    2>/dev/null

  # Locate the generated keystore JSON.
  keystore=$(find "${tmpdir}/bls/keystore" -name "keystore-*.json" 2>/dev/null | head -1)
  [[ -n "$keystore" ]] || die "no keystore file found in ${tmpdir}/bls/keystore/"

  # Compute BLS pubkey and proof-of-possession using the bls_proof helper.
  # The helper decrypts the keystore, derives the BLS private key, and computes:
  #   proof = Sign(privKey, keccak256(operatorAddr || pubKey || paddedChainId))
  log "validator-${n}: computing pubkey and proof-of-possession..."
  proof_output=$(go run "${SCRIPT_DIR}/bls_proof/main.go" \
    -keystore "$keystore" \
    -password "$BLS_PW" \
    -operator "$addr_lower" \
    -chainid "$CHAIN_ID")
  pubkey=$(echo "$proof_output" | grep "^PUBKEY=" | cut -d= -f2 | tr -d '[:space:]')
  proof=$(echo "$proof_output"  | grep "^PROOF="  | cut -d= -f2 | tr -d '[:space:]')

  [[ ${#pubkey} -eq 96  ]] || die "validator-${n}: unexpected pubkey length ${#pubkey}: '${pubkey}'"
  [[ ${#proof}  -eq 194 ]] || die "validator-${n}: unexpected proof length ${#proof}: '${proof}'"

  log "validator-${n}: pubkey=${pubkey:0:12}...${pubkey: -8}"
  log "validator-${n}: proof=${proof:0:14}...${proof: -8}"

  # Persist results.
  printf '%s\n' "$BLS_PW"  > "${dest}/bls-password.txt"
  printf '%s\n' "$pubkey"  > "${dest}/bls-pubkey.txt"
  printf '%s\n' "$proof"   > "${dest}/bls-proof.txt"

  # Copy Prysm wallet for Fast Finality node operation.
  rm -rf "${dest}/bls-wallet"
  cp -r "${tmpdir}/bls/wallet" "${dest}/bls-wallet"

  trap - EXIT
  rm -rf "$tmpdir"
  log "validator-${n}: BLS keys written to ${dest}"
done

echo
log "Done."
log "Next steps:"
log "  1. git add core/systemcontracts/parliagenesis/default/keystores"
log "  2. git commit -m 'chore: pre-generate BLS keys for dev validators'"
