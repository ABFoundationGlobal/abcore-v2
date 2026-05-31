# Local Parlia Network (v2)

Scripts to spin up a local Parlia (PoSA) test network using the ABCore v2 binary.

## Prerequisites

- Built geth binary: run `make geth` from the repo root
- Python 3 (for genesis generation)

> **Validator set is fixed.** `01-setup.sh` installs a baked set of up to 3
> validators from `core/systemcontracts/parliagenesis/default/keystores/`. These
> exact addresses are compiled into the genesis system contracts
> (`ValidatorContract` init set + `StakeHub` whitelist), so the consensus signer
> stays aligned with the on-chain validator set across the epoch boundary
> (block 200). **Run 3 validators** to keep producing blocks past block 200;
> running 1–2 stalls there (the snapshot expands to all 3 but the missing
> signers never sign). Earlier versions generated random keys, which silently
> stalled at the first epoch boundary.

## Quick Start

```bash
# 1. Install validator keys (from the repo's baked keystores) and generate genesis
#    (default: 3 validators, max: 3 — see note below)
./01-setup.sh [num_validators]

# 2. Start validators
./02-start-validators.sh

# 3. Check status / stop
./03-check-status.sh
./04-stop-validators.sh

# 4. Full reset
./05-cleanup.sh
```

## Running with Docker

An alternative to the bare-metal workflow above. No Go toolchain required — the image is built from the repo's root `Dockerfile`.

### Prerequisites

- Docker 24+
- Docker Compose v2 (`docker compose`)
- Python 3 (still needed by `01-setup.sh` for genesis generation)

### Quick Start

```bash
# 1. Install validator keys and genesis (same as bare metal)
./01-setup.sh [num_validators]   # 1–3 validators (use 3 to cross block 200)

# 2. Build image (first time only) and start
./07-docker-up.sh
```

`07-docker-up.sh` handles the rest: builds the image if not present, copies shared config files, writes `.env` with validator addresses and the active Compose profile, then starts all containers.

### Endpoints

Validator-1 always starts. Additional validators start based on the count passed to `01-setup.sh` (1–3).

| Node | HTTP RPC | WebSocket | P2P |
|------|----------|-----------|-----|
| validator-1 | `http://localhost:8545` | `ws://localhost:9545` | `30303` |
| validator-2 | `http://localhost:8546` | `ws://localhost:9546` | `30304` |
| validator-3 | `http://localhost:8547` | `ws://localhost:9547` | `30305` |

All ports are bound to `127.0.0.1` (localhost only). Only the ports for the validators that were set up will be active.

### Common operations

```bash
# View logs for all containers
docker compose -f docker-compose.yml logs -f

# View logs for a single validator
docker compose -f docker-compose.yml logs -f validator-2

# Stop all containers
docker compose -f docker-compose.yml down

# Open a geth console on validator-1
docker exec -it abcore-v1 geth attach /data/geth.ipc

# Open a shell
docker exec -it abcore-v1 /bin/bash

# Force rebuild the image (e.g. after source changes)
docker build -t abcore:local ../..
```

### Reset

```bash
docker compose -f docker-compose.yml down
./05-cleanup.sh          # removes data/ and genesis.json
./01-setup.sh 3          # re-generate keys and genesis
./07-docker-up.sh        # restart (image already cached)
```

---

## Network Configuration

| Parameter  | Value                    |
|------------|--------------------------|
| Chain ID   | 7140                     |
| Consensus  | Parlia (PoSA)            |
| Block time | 3 seconds                |
| Epoch      | 200 blocks               |

Port allocation per validator N: RPC `8544+N`, P2P `30302+N`, WebSocket `9544+N`.

## Fork Schedule

The genesis uses the same staggered fork schedule as `genesis-dev.json` from upstream BSC so that the pre-Luban extraData format (plain 20-byte addresses, no BLS keys) is valid at block 0:

| Block | Fork(s) activated |
|-------|-------------------|
| 0     | Homestead → Istanbul, Ramanujan, Niels |
| 1     | MirrorSync, Bruno |
| 2     | Euler |
| 3     | Nano, Moran |
| 4     | Gibbs |
| 5     | Planck |
| 6     | **Luban** (post-Luban extraData + validator count byte from here) |
| 7     | Plato |
| 8     | Berlin, London, Hertz, Hertzfix |
| 0s    | Shanghai, Kepler, Feynman, FeynmanFix, Cancun, Haber, HaberFix, Bohr, Pascal, Prague, Lorentz (time-based, all at genesis timestamp) |

Luban must not be block 0 because the genesis extraData uses the pre-Luban format. From block 6 onward the engine writes post-Luban epoch headers automatically.

## System Contracts

`genesis-contracts-dev.json` is a snapshot of [`genesis-dev.json`](https://github.com/bnb-chain/bsc-genesis-contract/blob/master/genesis-dev.json) from the [`bnb-chain/bsc-genesis-contract`](https://github.com/bnb-chain/bsc-genesis-contract) repository. It provides the compiled bytecode for all 18 BSC system contracts that Parlia requires (ValidatorContract at `0x1000`, SlashContract at `0x1001`, etc.).

When updating to a newer version of BSC system contracts, replace `genesis-contracts-dev.json` with the updated `genesis-dev.json` from that repo.

## Generated Files (git-ignored)

- `data/` — validator keystores, chain data, logs, PID files
- `genesis.json` — assembled genesis (regenerated by `01-setup.sh`)

Validator address for node N is in `data/validator-N/address.txt` after setup.

## Test: Breathe Block / `updateValidatorSetV2` Timing

Parlia calls `updateValidatorSetV2` on the ValidatorContract (`0x1000`) at each **breathe block** — the first block whose timestamp crosses a multiple of `BreatheBlockInterval` (default: 86400 s, once per UTC day). The `--override.breatheblockinterval` flag shrinks this to any value for local testing.

`08-test-breathe-block.sh` automates the full cycle: setup → start → wait → verify → cleanup.

### Run

```bash
./08-test-breathe-block.sh
```

The script is self-contained. If `data/validator-1` does not yet exist it calls `./01-setup.sh 1` automatically.

### Configuration

Edit `BREATHE_INTERVAL` at the top of the script (default: `60`):

```bash
# Breathe block interval in seconds (override; default production value: 86400).
BREATHE_INTERVAL=60
```

With 3 s block time, 60 s → one breathe block every ~20 blocks. The script waits `BREATHE_INTERVAL + 10 s` before scanning.

### How it verifies

The script scans the 50 most recent blocks via `geth attach --exec` and looks for transactions to ValidatorContract (`0x1000`) whose 4-byte input selector matches `keccak256("updateValidatorSetV2(address[],uint64[],bytes[])").slice(0,4)`. Exact selector matching avoids false positives from other system calls to `0x1000`.

### Expected output

```
==> Running 01-setup.sh (1 validator)...
==> Starting validator-1 (breatheBlockInterval=60s)...
==> Waiting for RPC on http://127.0.0.1:8545...
==> Precomputing function selectors...
==> Waiting for StakeHub initialization (minSelfDelegationBNB > 0)...
  StakeHub ready — LOCK=1000000000000000000 wei  minSelfDel=2000000000000000000000 wei
==> Registering validator-1 in StakeHub (createValidator + delegate)...
  PASS  createValidator  (tx=0x…)
  PASS  delegate  (tx=0x…)
==> Waiting 70s for breathe block (interval=60s, expect ~every 20 blocks)...
==> Scanning last 50 blocks for updateValidatorSetV2 system calls...

PASS  updateValidatorSetV2 breathe blocks found: #30@ts=…, #10@ts=…
```

## Test: `updateValidatorSetV2` Fails Without Registration

`10-test-breathe-no-registration.sh` is the negative counterpart of test 08.
It starts the chain **without** registering any validator in StakeHub and verifies that `updateValidatorSetV2` never executes successfully.

**Why it should fail**: `updateValidatorSetV2` passes the StakeHub election set (empty arrays) to `BSCValidatorSet._forceMaintainingValidatorsExit()`. With no validators, `numOfFelony (0) >= _validatorSet.length (0)` is true, causing an out-of-bounds array access — INVALID opcode in Solidity < 0.8.0. `Finalize()` propagates the error; the block sealing attempt is abandoned with no on-chain trace.

### Run

```bash
./10-test-breathe-no-registration.sh
```

### How it verifies

After waiting two full breathe periods, the test scans the last 50 blocks for the exact `updateValidatorSetV2` 4-byte selector in transactions to ValidatorContract (`0x1000`). Because failed breathe-block attempts leave no on-chain trace, the selector should be absent.

- **PASS** — selector not found: all breathe attempts failed as expected.
- **FAIL** — selector found: a breathe block unexpectedly succeeded.

### Expected output

```
==> Waiting 75s (≥ 2 breathe periods) for attempts to accumulate...
  Current block: 15
  Block 15 ≥ 9 — Feynman contracts initialized, breathe periods have elapsed.
==> Scanning last 50 blocks for updateValidatorSetV2 (selector-specific)...

PASS  No updateValidatorSetV2 execution found in last 50 blocks.
      Every breathe-block attempt failed (empty candidate set → INVALID opcode)
      and was abandoned by the miner, leaving no on-chain trace.
```

---

## Test: StakeHub Partial Registration

Verifies that the network stays live when validators register with StakeHub in two stages, and that `updateValidatorSetV2` reflects the correct election set after each stage.

**Phase 1** — validator-1 registers (`createValidator` + `delegate`); validators 2 and 3 do not. A breathe block fires and `updateValidatorSetV2` is called with only validator-1's election data. Consensus continues because the Parlia epoch headers still carry the original 3-node signing set.

**Phase 2** — validators 2 and 3 also register. The next breathe block calls `updateValidatorSetV2` with all three validators; the StakeHub election set grows to 3.

### Run

```bash
./09-test-stakehub-partial-register.sh
```

The script is self-contained: setup, BLS key generation, start, register, verify, cleanup — no manual steps.

### Configuration

Edit `BREATHE_INTERVAL` at the top of the script (default: `30` s):

```bash
BREATHE_INTERVAL=30
```

### Prerequisites

In addition to the normal `make geth` requirement, Go toolchain must be available in `PATH` (the script compiles the `bls_proof` helper into a temporary directory on each run and removes it on exit).

### What it checks

| Phase | Check |
|-------|-------|
| 1 | Block height advances after validator-1 registers alone |
| 1 | Breathe block fires (`updateValidatorSetV2` system tx detected) |
| 1 | StakeHub election set = 1 validator |
| 2 | Block height advances after validators 2 and 3 register |
| 2 | Breathe block fires again |
| 2 | StakeHub election set = 3 validators |

### Expected output

```
══════════════════════════════════════════════════════
  PHASE 1 — validator-1 registers; 2 and 3 do not
══════════════════════════════════════════════════════

  PASS  validator-1 createValidator  (tx=0x3a1b2c…)
  PASS  validator-1 delegate  (tx=0x7d4e5f…)
  PASS  Network live after partial registration: #8 → #21
  PASS  Breathe block fired (updateValidatorSetV2 called)
  PASS  StakeHub election set = 1 validator (validator-1 only)

══════════════════════════════════════════════════════
  PHASE 2 — validators 2 and 3 also register
══════════════════════════════════════════════════════

  PASS  validator-2 createValidator  (tx=0xa1b2c3…)
  PASS  validator-2 delegate  (tx=0xd4e5f6…)
  PASS  validator-3 createValidator  (tx=0xe7f8a9…)
  PASS  validator-3 delegate  (tx=0x1b2c3d…)
  PASS  Network live after full registration: #21 → #35
  PASS  Breathe block fired (updateValidatorSetV2 called with all validators)
  PASS  StakeHub election set = 3 validators

ALL TESTS PASSED
```

---

## Relation to the Real Upgrade

This local network is for **testing only** (Chain ID 7140). The production ABCore chain (Chain ID 36888) cannot change its genesis — the Parlia migration there is a hard fork at a future block number, with system contracts deployed via a system transaction at the switch block, not in genesis.
