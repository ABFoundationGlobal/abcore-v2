#!/usr/bin/env bash
set -euo pipefail

# Downloads the pinned v1.13.x geth binary from the ABFoundationGlobal/abcore
# GitHub release and places it at script/test/compat/bin/geth-v1.
# Called automatically by resolve_binaries() in lib.sh when the binary is absent.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

RELEASE_TAG="v1.13.15-abcore-1.1"
ASSET_NAME="geth-v1.13.15-abcore-1.1"
REPO="ABFoundationGlobal/abcore"
DEST="${SCRIPT_DIR}/bin/geth-v1"

if [[ -x "$DEST" ]]; then
  echo "[00-get-v1-geth] already present: $DEST"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"

echo "[00-get-v1-geth] downloading ${REPO}@${RELEASE_TAG} ..."
gh release download "$RELEASE_TAG" \
  --repo "$REPO" \
  --pattern "$ASSET_NAME" \
  --output "$DEST"

chmod +x "$DEST"
echo "[00-get-v1-geth] saved to $DEST"
