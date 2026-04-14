# parliagenesis/default — Local Testing Bytecodes

This directory contains system contract bytecodes compiled with **3 fixed dev validator addresses**
for use by the local transition test suite (`script/transition-test/`).

Chain ID 99988 (the throwaway chain used by transition tests) falls through to `defaultNet` in
`applyParliaGenesisUpgrade`, so these bytecodes are injected at `ParliaGenesisBlock` when running
T-1, T-1.5, T-1.6, and T-2 tests.

## Fixed Dev Validator Addresses

The `INIT_VALIDATORSET_BYTES` in the compiled `ValidatorContract` bytecode contains these addresses:

| Validator | Address |
|-----------|---------|
| validator-1 | see `keystores/validator-1/address.txt` |
| validator-2 | see `keystores/validator-2/address.txt` |
| validator-3 | see `keystores/validator-3/address.txt` |

Keystores are in `keystores/` with password `password`.

## Why Fixed Addresses Are Required

At `ParliaGenesisBlock`, `initContract()` calls `BSCValidatorSet.init()` which reads
`INIT_VALIDATORSET_BYTES` from the bytecode and writes those addresses into contract storage.
At each epoch boundary, `prepareValidators()` reads those addresses back via `getValidators()` and
encodes them into `header.Extra`. The snapshot switches the active signer set accordingly.

If the addresses in the bytecode differ from the actual sealing node addresses, the chain halts
at epoch boundary + 1 with `errUnauthorizedValidator`. The T-2 test (`95-run-epoch-test.sh`)
verifies this path works correctly by using the same fixed addresses for both the keystores and
the compiled bytecodes.

## How to Reproduce / Update the Bytecodes

If you need to change the validator addresses (e.g. to rotate dev keys):

1. Generate new keystores:
   ```bash
   GETH=./build/bin/geth
   for n in 1 2 3; do
     d=$(mktemp -d); printf 'password\n' > "$d/pw.txt"
     addr=$("$GETH" account new --datadir "$d" --password "$d/pw.txt" 2>&1 \
       | grep -oE "0x[0-9a-fA-F]{40}" | head -1)
     mkdir -p keystores/validator-${n}
     echo "$addr" > keystores/validator-${n}/address.txt
     cp "$d/keystore/"* keystores/validator-${n}/
     printf 'password\n' > keystores/validator-${n}/password.txt
   done
   ```

2. Write `../validators.conf` (gitignored) with the new addresses:
   ```
   0xADDR1,0xADDR1,0xADDR1,0x64,0x<96-zero-bytes>
   0xADDR2,0xADDR2,0xADDR2,0x64,0x<96-zero-bytes>
   0xADDR3,0xADDR3,0xADDR3,0x64,0x<96-zero-bytes>
   ```
   (BLS key is unused on the test chain which has no `lubanBlock`; zero value is fine.)

3. Compile bytecodes:
   ```bash
   cd ../   # parliagenesis/
   make pre   # only needed once
   make build
   ```

4. Rebuild geth:
   ```bash
   cd /path/to/abcore-v2
   make geth
   ```

5. Commit the updated `keystores/` and contract bytecode files.

## Chain Parameters (Makefile defaults)

The bytecodes are compiled with `CHAIN_ID=714` and `MAX_ELECTED_VALIDATORS=3`. These are the
default Makefile values and are used for all transition tests regardless of the test chain ID
(99988) — the chain ID in the bytecode does not affect consensus for local testing purposes.
