#!/usr/bin/env bash
set -euo pipefail

FIXTURE_VERSION=${EVM_FIXTURES_VERSION:-v5.1.0}
FIXTURE_ARCHIVE=fixtures_develop.tar.gz
FIXTURE_URL="https://github.com/ethereum/execution-spec-tests/releases/download/${FIXTURE_VERSION}/${FIXTURE_ARCHIVE}"
FIXTURE_SENTINEL="spec-tests/.fixture-version-${FIXTURE_VERSION}"

cd ..
git submodule update --init --depth 1 --recursive
git apply tests/0001-diff-go-ethereum.patch
git apply tests/0002-diff-go-ethereum.patch
cd tests
mkdir -p spec-tests
if [ ! -f "$FIXTURE_SENTINEL" ]; then
    rm -rf spec-tests/*
    cd spec-tests
    wget "$FIXTURE_URL"
    tar xzf "$FIXTURE_ARCHIVE"
    rm -f "$FIXTURE_ARCHIVE"
    touch ".fixture-version-${FIXTURE_VERSION}"
    cd ..
fi
go test -run . -v -short >test.log
PASS=$(grep -c "PASS:" test.log || true)
grep "FAIL" test.log > fail.log || true
FAIL=$(grep -c "FAIL:" fail.log || true)
echo "PASS",$PASS,"FAIL",$FAIL
if [ "$FAIL" -ne 0 ]
then
    cat fail.log
    exit 1
fi
