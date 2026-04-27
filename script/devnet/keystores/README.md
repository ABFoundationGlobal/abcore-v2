# DevNet Validator Keystores

Pre-generated validator accounts for the ABCore DevNet (Chain ID 17140).
These addresses are used as the initial Parlia validator set and must match
the `INIT_VALIDATORSET_BYTES` in the system contracts genesis bytecode.

## Addresses

| Node  | Address                                    |
|-------|--------------------------------------------|
| val-0 | 0x4f2Bb6ABFed42114aD4a62024F3972E0bea0458e |
| val-1 | 0x7ad0778245D0F165AeFDFaDb518095E393Fd02a5 |
| val-2 | 0xA12D1C6Cc89b272dAD860469445415f718E81eaf |
| val-3 | 0x590dafcF7E9ce522b0C867AE45D2A051A8412d27 |
| val-4 | 0xb29CDF1d829543A1076EF13913bfa7f1C2E15414 |

## How These Were Generated

```bash
GETH=/data/kai/workspace/ab/abcore-v2/build/bin/geth   # or any abcore-v1/v2 binary
KS_DIR=script/devnet/keystores

for i in 0 1 2 3 4; do
    TMPDIR=$(mktemp -d)
    echo "" > "$TMPDIR/pw.txt"          # empty password
    $GETH account new --datadir "$TMPDIR" --password "$TMPDIR/pw.txt"
    cp "$TMPDIR/keystore/UTC--"* "$KS_DIR/val-$i.json"
    rm -rf "$TMPDIR"
done
```

Password: empty string (DevNet only — never reuse on Testnet/Mainnet).

## What Is Committed / What Is Not

| File            | Committed | Contents                        |
|-----------------|-----------|---------------------------------|
| `val-N.address` | ✅ yes    | Plain-text address (public)     |
| `val-N.json`    | ❌ no     | Keystore file (contains private key, gitignored) |

The keystore files (`val-N.json`) must be present locally before running
`01-start.sh`. Copy them onto each server before starting the devnet.
They are excluded from git via `.gitignore`.

## Deployment

Before running `./01-start.sh`, ensure the keystore files exist:

```bash
ls script/devnet/keystores/val-{0,1,2,3,4}.json
```

If missing, either regenerate using the commands above (produces different
private keys and different addresses — requires updating system contracts),
or restore from your secure backup.
