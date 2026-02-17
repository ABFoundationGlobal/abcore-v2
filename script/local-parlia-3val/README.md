# Local 3-Validator Parlia Network

This directory contains scripts to launch a local Parlia network with 3 validators for testing ABCore v2.0.

## Quick Start

```bash
# 1. Generate validator keys and genesis
./01-setup.sh

# 2. Start all 3 validators
./02-start-validators.sh

# 3. Check status
./03-check-status.sh

# 4. Stop all validators
./04-stop-validators.sh

# 5. Clean up everything
./05-cleanup.sh
```

## Network Configuration

- **Chain ID**: 7140 (custom for local testing)
- **Validators**: 3 (validator-1, validator-2, validator-3)
- **Block time**: 3 seconds
- **Epoch**: 200 blocks
- **Ports**:
  - Validator 1: RPC 8545, P2P 30303
  - Validator 2: RPC 8546, P2P 30304
  - Validator 3: RPC 8547, P2P 30305

## Directory Structure

```
data/
├── validator-1/
│   ├── geth/
│   └── keystore/
├── validator-2/
│   ├── geth/
│   └── keystore/
└── validator-3/
    ├── geth/
    └── keystore/
```

## Validator Addresses

After running `01-setup.sh`, validator addresses will be stored in:
- `data/validator-1/address.txt`
- `data/validator-2/address.txt`
- `data/validator-3/address.txt`

## Genesis File

The genesis file is generated at `genesis.json` with all 3 validators encoded in the `extraData` field.

## Testing

After starting the network:

```bash
# Attach to validator 1
../build/bin/geth attach data/validator-1/geth.ipc

# Check validators
> admin.peers
> eth.blockNumber
> parlia.getValidators()
```

## Notes

- All validators use empty password for testing
- Data is stored in `data/` directory
- Logs are in `data/validator-*/geth.log`
- Network uses discovery disabled (private network)
