# Pinned Safe v1.5.0 creation bytecode (foundation multisig deploy)

Used by `scripts/deploy-foundation-safe.sh` to deploy the DevNet foundation Safe
with **cast only** — no forge/clone at deploy time, so the resulting address is
identical regardless of the agent's toolchain.

To regenerate / verify these files: `bash regenerate.sh` (rewrite) or
`bash regenerate.sh --check` (verify committed == freshly compiled, no overwrite).

## Provenance (reproducible)

- Source: https://github.com/safe-fndn/safe-smart-account @ tag `v1.5.0`
  (commit `dc437e8fba8b4805d76bcbd1c668c9fd3d1e83be`)
- Compiler: **solc 0.8.35**, **--evm-version london**, optimizer off (Safe default)
- Command: `forge build --use 0.8.35 --evm-version london contracts/Safe.sol contracts/proxies/SafeProxy.sol contracts/proxies/SafeProxyFactory.sol`

## creationCode keccak256 (verify before trusting)

| file | keccak256(creationCode) |
|------|--------------------------|
| SafeProxyFactory.bin | 0xd5649b4de7cda86b579a5be88b8af45e4bb4fe2a54348d38e65814aae0aa5916 |
| Safe.bin             | 0xf3d17710639f6b10d8df16f89db7e38a5cebb6045e165de47c098ac76ff6e3c2 |
| SafeProxy.bin        | 0x4ab6f99ef271eaf7d01acb871455935e404a5beb819b72f6c9dfd9ffa5cc0701 |

## Why london

v1 (geth 1.13.15) supports up to cancun; london avoids any opcode the v1 EVM
can't execute. Verified end-to-end on a local v1 chain: deploy + foundation
payout via call{gas:30000} + 2/3 owner execTransaction all succeed.

## Why pinned solc

Safe's pragma is `>=0.7.0 <0.9.0` and forge auto-detects solc, so different
machines pick different solc patch versions (0.8.17 vs 0.8.35) → different
metadata → different bytecode → different CREATE2 address. Pinning solc+evm
makes the bytecode (and thus FOUNDATION_ADDR) reproducible.
