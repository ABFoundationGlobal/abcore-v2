# Fast Finality (BEP-126) End-to-End Test

Verifies that ABCore's BLS vote-based fast finality actually works end-to-end:
validators sign votes → broadcast → the proposer aggregates ≥2/3 into a
`VoteAttestation` written to the block header → peers verify it → blocks become
**justified** and then **finalized**.

This is the only test that exercises the full voting path with `--vote`
enabled. Upstream BSC unit tests cover the pure-Parlia data structures but never
start a live network with voting on, and never touch ABCore's `DualConsensus`
wrapper.

## Why this matters

Devnet validators already run with `--vote` (the `devnet-ops` Jenkinsfiles add
`--vote --blswallet --blspassword` to every `val-*` node), so fast finality is
live there. Note that voting is **independent of system rewards**: the deployed
contracts pay nothing for finality (the system-reward ratio is 0), but votes are
still produced and blocks still finalize. The vote gate lives in
`consensus/parlia/parlia.go` (around the `IsActiveValidatorAt` / vote-key check);
the reward distribution is a separate path in the StakeHub/SystemReward system
contracts (`core/systemcontracts/parliagenesis/`), not coupled to it.

This is the only test that drives the full voting path on a live local network
rather than testing the data structures in isolation. A bug in that path is a
consensus-level failure (a bad attestation makes `verifyVoteAttestation` reject
the whole block), so it must be caught here before it can reach testnet/mainnet.
Because it spins up a 3-validator network and crosses an epoch boundary
(~13–15 min wall), it belongs in a **manual-trigger** Jenkins job, not per-PR CI.

## Requirements

- `make geth` (binary at `build/bin/geth`)
- `python3` (ABI calldata encoding, hex math)
- `go` toolchain (builds the `bls_proof` proof-of-possession helper)
- Reuses `script/local` (genesis, accounts, start/stop) and
  `script/test/upgrade-drill/bls_proof` (proof-of-possession).

## Run

```bash
cd script/test/finality
./99-run-all.sh            # full flow; exits 0 only if finality is verified
```

Environment knobs:

| Var | Default | Effect |
|-----|---------|--------|
| `FINALITY_NUM_VALIDATORS` | `3` | validator count (max 3, bounded by the baked keystores). 3 is required: the baked system contracts elect a fixed 3-validator set at the epoch boundary, so fewer than 3 stalls past block 200; 3 also reaches the BLS quorum ⌈2·3/3⌉=2 |
| `BREATHE_INTERVAL` | `315360000` | breathe interval (s). Kept effectively **off** so a breathe block never fires on an empty election (which would stall the chain — see below). Not needed for voting |
| `EPOCH` | `200` | epoch length; voteAddress activates when the chain crosses `block % EPOCH == 0` |
| `FINALITY_TIMEOUT` | `360` | seconds `04` polls for voteAddress activation + justified advancing |
| `KEEP_DATA` | `0` | `1` keeps `script/local/data` after the run for inspection |

## How voting actually activates (important)

1. `--vote` makes each node create a VoteManager and sign BLS votes — but only
   for validators whose BLS **voteAddress** matches one in the snapshot.
2. `createValidator` registers the voteAddress in **StakeHub** (immediately
   reflected in `getValidatorElectionInfo`).
3. The voteAddress is copied into the **Parlia validator snapshot at the next
   epoch boundary** (`block % 200 == 0`) — NOT at a breathe block. Once it's in
   the snapshot, `IsActiveValidatorAt` matches and the validator starts voting.
4. After a ~40-block voting warmup (`blocksNumberSinceMining`), attestations
   appear in headers and blocks become justified → finalized.

A **breathe block** is only for daily validator-set rotation
(`updateValidatorSetV2`) and is irrelevant to voting. Worse, if a breathe block
fires while the StakeHub election set is **empty**, it calls
`updateValidatorSetV2([],[],[])` which reverts `invalid opcode: INVALID`, the
breathe block can't seal, and the chain **stalls permanently** (the historical
"block ~18 stall"). So this harness keeps breathe off for the whole run.

## Scripts

| Script | Does |
|--------|------|
| `01-setup.sh` | `script/local/01-setup.sh N` for genesis/accounts (N=`FINALITY_NUM_VALIDATORS`, default 3), then a BLS keypair + proof-of-possession per validator (wallet at `data/validator-N/bls/wallet`, plus `bls-pubkey.txt`, `bls-proof.txt`, `bls-password.txt`) |
| `02-start-with-vote.sh` | starts each validator with `--vote --blswallet --blspassword --vote-journal-path` (+ `--override.breatheblockinterval` set to the off value); asserts `Create voteManager successfully` in each log. Nodes start **without** `--mine`; only after the full mesh is connected does it call `miner.start()` on all of them at once — starting all signers before they peer makes them fork at low height and stall (`Signed recently, must wait for others`) |
| `03-register-vote-address.sh` | each validator runs StakeHub `createValidator` (with its BLS voteAddress + proof) and `delegate`, then polls `getValidatorElectionInfo` until the election set is non-empty |
| `04-verify-finality.sh` | waits for voteAddress to enter the snapshot (epoch boundary), then asserts `parlia.getJustifiedNumber()`/`getFinalizedNumber()` advance, justified tracks the tip, and a recent header carries an attestation |
| `99-run-all.sh` | orchestrates 01→02→03→(wait for epoch boundary)→04; stops + wipes on exit (preserve with `KEEP_DATA=1`) |

## Expected output

```
validator-1: VoteManager up
...
election set has 1 validator(s) — safe for breathe block
==> Waiting for the chain to cross an epoch boundary (block % 200 == 0) ...
  voteAddress present in snapshot @0s
PASS  justified advanced: <a> -> <b>
PASS  finalized advanced: <c> -> <d>
PASS  justified lag = 1 blocks (<=5)
PASS  attestation found in header #<n> (extraData > 97 bytes)
=== Fast finality VERIFIED (justify + finalize + attestation) ===
========== FAST FINALITY E2E PASSED ==========
```

Note: reaching the first epoch boundary takes ~`EPOCH × block_time` ≈ 200 × 3s ≈
10 minutes, so a full run is ~12–15 min. Voting cannot start before then.

## Self-check (proving the test isn't always-green)

Re-run `02` without `--vote` (so no validator signs) and `04-verify-finality.sh`
must **fail**: `voteAddress` may still appear in the snapshot, but justified/
finalized never advance and no attestation appears.

## Note on the historical "block ~18 stall"

Earlier iterations of this harness used a short `--override.breatheblockinterval`
(e.g. 60s). That made a **breathe block fire before any validator was
registered**, calling `updateValidatorSetV2([],[],[])`, which reverts
`invalid opcode: INVALID` and stalls the chain at ~block 18. Reproduced directly:

```
eth.call ValidatorContract.updateValidatorSetV2([],[],[])  →  invalid opcode: INVALID
```

This is **not** a fast-finality bug and **not** a stale-bytecode bug — it is the
expected contract behaviour for an empty validator array. The fix is simply to
never fire a breathe block on an empty election; this harness keeps breathe off
(`BREATHE_INTERVAL=315360000`) and relies on the **epoch boundary** to activate
voteAddress instead. A clean `script/local` devnet with breathe off runs
indefinitely (verified past block 200+ with finality advancing).

## Scope / not covered

- The 7140 local devnet is **pure Parlia from genesis** (no Clique segment), so
  this does not exercise the `DualConsensus` Clique→Parlia path. Covering voting
  under `DualConsensus` (via `script/test/transition`) is a possible follow-up.
- Does not assert finality **reward** distribution (intentionally — rewards are
  gated separately on `systemRewardBaseRatio > 0`, which is `0` here).
