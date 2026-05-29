# Contract Scenario Test Plan — upgrade-drill

This document lists planned contract-level scenario tests beyond what the
U-series upgrade scripts already exercise.  Each section maps to a new or
extended shell script in this directory.  Tests are designed to run against
the 3-node network left running after U-3 (`82-run-u3-shanghai-feynman.sh`),
so all Feynman-era system contracts (`StakeHub`, `BSCGovernor`, `GovToken`,
etc.) are already deployed and initialised.

For what each script currently tests, see [`README.md`](README.md).

---

## Already covered (existing scripts)

| Contract | Covered scenarios |
|---|---|
| `BSCValidatorSet` | `getValidators`, `init`, `parlia_getValidators`, breathe-block validator-set correctness |
| `StakeHub` | `createValidator`, `delegate` (voting-power activation), `getValidatorElectionInfo`, whitelist series, `validatorWhitelist` after governance execution |
| `BSCGovernor` | `propose`, `castVote` (×3), `queue`, `execute`, state machine Pending→Executed, `proposalThreshold` |
| `BSCTimelock` | `queue`/`execute` delay, 3-second `minDelay` in local drill |
| `GovHub` | `updateParam` rejection tests, full governance pipeline integration |
| `GovToken` | `sync` (via `createValidator`), `delegateVote` (via `StakeHub.delegate`), `getVotes` |
| `TokenRecoverPortal` | `SOURCE_CHAIN_ID()` constant |

**T-6 whitelist coverage detail** (scripts `87-run-u3-whitelist-test.sh` and `88-run-u3-governance-whitelist.sh`):

| Sub-test | What is verified |
|---|---|
| T-6.b | Initial whitelist state read; `getValidatorElectionInfo` returns `WHITELIST_VOTING_POWER` for all 3 |
| T-6.c | `WHITELIST_VOTING_POWER` arithmetic: `== uint64.max × 1e10`, exact divisibility, Parlia normalization |
| T-6.d | `eth_getLogs` audit: 3 `ValidatorWhitelistUpdated(addr, true)` events from `initialize()`; 0 `WhitelistEnabledUpdated` |
| T-6.e | `updateParam` rejection tests (5 cases): wrong-length address, zero address, flag > 1; success with `flag=1` |
| T-6.f | Whitelist-vs-large-stake ordering invariant via dual `stateDiff` override |
| T-6.g | `TokenRecoverPortal.SOURCE_CHAIN_ID()` returns `"AB-Chain-Local"` (abchain-local bytecode) |
| T-6.h | Full governance path: `propose → castVote×3 → queue → execute → validatorWhitelist(newAddr)==true` |

---

## T-6 extensions — StakeHub whitelist deep coverage (PR #4)

The changes introduced by PR #4 (`abcore-v2-genesis-contract`) add new contract
logic paths that are only partially exercised by T-6.b–T-6.h.  The sub-tests
below extend coverage of the same whitelist mechanism without duplicating what is
already tested.

**Scripts:** extend `87-run-u3-whitelist-test.sh` (stateDiff / read-only phases)
and `88-run-u3-governance-whitelist.sh` (full governance phases).  
**Prerequisite:** U-3 complete; T-6.b–T-6.h pass.

### T-6.i — governance `removeFromValidatorWhitelist` (full on-chain path)

T-6.h only exercises `addToValidatorWhitelist`.  This sub-test covers the
symmetric removal path through the real governance pipeline.

```
Phase 1: encode GovHub.updateParam("removeFromValidatorWhitelist",
                 val1_consensus_20bytes, StakeHub)
Phase 2: BSCGovernor.propose → castVote(FOR)×3 → queue → execute
Phase 3: verify StakeHub.validatorWhitelist(val1_consensus) == false
Phase 4: verify getValidatorElectionInfo: val1 power < WHITELIST_VOTING_POWER
          (reverts to stake-based power)
Phase 5: verify ValidatorWhitelistUpdated(val1_consensus, false) event emitted
```

**Verify:** Removal is permanent until re-added; val1 is not jailed (still produces blocks).

### T-6.j — governance `whitelistEnabled` toggle (off → on)

T-6.e only dry-runs `flag=0x01`; this sub-test confirms the full on-chain toggle
cycle with real governance transactions and verifies both directions.

```
# Part A: disable
Phase 1: encode GovHub.updateParam("whitelistEnabled", 0x00..00, StakeHub)
Phase 2: propose → vote → queue → execute
Phase 3: verify StakeHub.whitelistEnabled() == false
Phase 4: verify getValidatorElectionInfo: ALL validators revert to stake-based power
          (no WHITELIST_VOTING_POWER returned)
Phase 5: verify WhitelistEnabledUpdated(false) event

# Part B: re-enable
Phase 6: encode GovHub.updateParam("whitelistEnabled", 0x00..01, StakeHub)
Phase 7: propose → vote → queue → execute
Phase 8: verify StakeHub.whitelistEnabled() == true
Phase 9: verify getValidatorElectionInfo: whitelisted validators return WHITELIST_VOTING_POWER again
Phase 10: verify WhitelistEnabledUpdated(true) event
```

### T-6.k — `INIT_WHITELIST_BYTES` on-chain decode boundary verification

Verify the assembly loop in `initialize()` decodes the packed bytes correctly
at both the first and last address boundaries, and that the length is a multiple
of 20.

```
Phase 1: eth_call StakeHub.INIT_WHITELIST_BYTES() — ABI-decode the raw bytes constant
Phase 2: assert len(INIT_WHITELIST_BYTES) % 20 == 0
Phase 3: assert len(INIT_WHITELIST_BYTES) / 20 == expected_addr_count
Phase 4: for i in [0, count-1] (first and last):
           decode addr[i] = INIT_WHITELIST_BYTES[i*20 : i*20+20]
           assert addr[i] != 0x0
Phase 5: cross-check: eth_call StakeHub.validatorWhitelist(addr[i]) == true for each decoded addr
```

**Verify:** byte-boundary decode matches the `shr(96, mload(...))` assembly logic;
no off-by-one on the last address.

### T-6.l — `getValidatorElectionInfo` mixed-state index correctness

Phase 3 of `87` only counts "how many have WHITELIST_VP"; it does not verify
*which index* maps to which validator.  This sub-test confirms that the returned
arrays preserve the same order as `_validatorSet` enumeration regardless of
whitelist status.

```
stateDiff: val1 whitelist slot → false; val2/val3 unchanged
eth_call getValidatorElectionInfo(0, 3)
          → (consensusAddrs[3], votingPowers[3], voteAddrs[3])
verify: consensusAddrs[0] == val1_consensus  AND  votingPowers[0] < WHITELIST_VP
verify: consensusAddrs[1] == val2_consensus  AND  votingPowers[1] == WHITELIST_VP
verify: consensusAddrs[2] == val3_consensus  AND  votingPowers[2] == WHITELIST_VP
```

**Verify:** The contract does not re-sort by power; order is stable and predictable.

### T-6.m — jailed validator overrides whitelist (priority check)

The PR #4 logic is `if (jailed) → 0` **before** the whitelist check.  Verify
that a jailed-but-whitelisted validator still gets voting power 0.

```
stateDiff: val1.jailed = true  (set Validator.jailed storage slot)
           val1 remains in whitelist (no whitelist slot override)
eth_call getValidatorElectionInfo(0, 3)
verify: votingPowers[index_of_val1] == 0
verify: val2/val3 (whitelisted, not jailed) still == WHITELIST_VP
```

**Verify:** Jailed status takes precedence over whitelist; whitelist does not
resurrect a jailed validator's election weight.

### T-6.n — `ValidatorWhitelistUpdated` event `data` field decoding

T-6.d verifies event *count* and *topics[1]* (indexed address).  This sub-test
additionally decodes the unindexed `bool whitelisted` from `data`.

```
# From initialization logs (already fetched in T-6.d):
for each ValidatorWhitelistUpdated log from block 1:
    verify log.data == 0x0000...0001  (whitelisted = true)

# After T-6.i (removeFromValidatorWhitelist governance execution):
eth_getLogs ValidatorWhitelistUpdated from T-6.i execute block
verify log.topics[1] == val1_consensus (padded)
verify log.data == 0x0000...0000  (whitelisted = false)
```

**Verify:** `data` encodes the boolean correctly for both `true` (add) and
`false` (remove) paths.

### T-6.o — `updateParam("addToValidatorWhitelist")` success path with storage read-back

T-6.e Phase 7 tests rejection paths and one `whitelistEnabled` success path,
but does not verify that a successful `addToValidatorWhitelist` actually writes
to storage.  Use `eth_call` with `stateDiff` (no real governance round) to
verify the write path.

```
# Dry-run: apply the updateParam calldata via eth_call with from=GovHub
eth_call [from: GovHub(0x1007), to: StakeHub]
         updateParam("addToValidatorWhitelist", newAddr_20bytes, StakeHub)
         → result: 0x  (success)

# Verify storage was written (stateDiff approach):
compute keccak256(newAddr . slot_80) → storage key for validatorWhitelist[newAddr]
eth_call [stateDiff: key → 0x1]
         StakeHub.validatorWhitelist(newAddr)  → true
```

**Verify:** The calldata encoding is accepted; the storage key derivation for a
new address matches the mapping layout confirmed in Phase 2 of `87`.

### T-6.p — `INIT_WHITELIST_BYTES` constant vs. live `validatorWhitelist` storage cross-check

T-6.d audits via event logs (reverse direction).  This sub-test reads the
constant directly from chain, unpacks it in Python, and verifies each decoded
address against live storage — providing independent confirmation that no address
was silently dropped or corrupted during initialization.

```
Phase 1: eth_call StakeHub.INIT_WHITELIST_BYTES()  → raw bytes (ABI: bytes)
Phase 2: python: unpack every 20-byte slice → [addr_0, addr_1, ...]
Phase 3: for each addr:
           eth_call StakeHub.validatorWhitelist(addr)  → must be true
Phase 4: assert count(decoded) == count(ValidatorWhitelistUpdated events from T-6.d)
```

**Verify:** Every address encoded in `INIT_WHITELIST_BYTES` at compile time is
present and active in the live `validatorWhitelist` mapping; constant and storage
are in sync.

---

## T-7 — StakeHub: validator lifecycle edits

**Script:** `89-run-t7-stakehub-lifecycle.sh`  
**Prerequisite:** U-3 complete; all 3 validators registered.

### T-7.a — `editCommissionRate`

Change val1's commission rate and confirm the on-chain `Validator.commission`
struct is updated.

```
eth_call  StakeHub.getValidatorCommission(val1_operator)  → record initial rate
sendTx    val1: StakeHub.editCommissionRate(newRate=300)  (3%)
eth_call  StakeHub.getValidatorCommission(val1_operator)  → rate == 300
```

**Verify:** `CommissionRateEdited` event emitted; rate field updated.

### T-7.b — `editDescription`

Change val1's on-chain description and read it back.

```
sendTx    val1: StakeHub.editDescription(newDescription{moniker:"val1-v2",...})
eth_call  StakeHub.getValidatorDescription(val1_operator)  → moniker == "val1-v2"
```

**Verify:** `DescriptionEdited` event emitted; moniker field updated.

### T-7.c — `editConsensusAddress` (eth_call dry-run)

Verify that `editConsensusAddress` accepts the call once the `BREATHE_BLOCK_INTERVAL`
cooldown has cleared.  A real `sendTx` is intentionally omitted: the parlia engine
keeps signing with the original key, so a real consensus-address change would cause
val1 to stop producing blocks until the next breathe-block validator-set refresh.

```
# After sleep 7 s (cooldown cleared by T-7.b's updateTime)
eth_call  [from: val1, to: StakeHub]
          editConsensusAddress(TEST_ADDR)  → SUCCESS (no revert)
eth_call  StakeHub.consensusToOperator(TEST_ADDR)  → 0x0  (real state unchanged)
```

**Verify:** Dry-run succeeds once cooldown window has elapsed; real storage is
untouched since no tx was sent.

### T-7.d — validator info query suite

Confirm read-only queries return consistent data for all three validators.

```
eth_call  StakeHub.getValidatorBasicInfo(operator)   → consensusAddress, creditContract, jailed, inJail
eth_call  StakeHub.getValidatorDescription(operator) → moniker, identity, website, details
eth_call  StakeHub.getValidatorCommission(operator)  → rate, maxRate, maxChangeRate
eth_call  StakeHub.getValidators(0, 10)              → [val1_op, val2_op, val3_op]
eth_call  StakeHub.getValidatorCreditContract(operator)
eth_call  StakeHub.getValidatorConsensusAddress(operator)
eth_call  StakeHub.getValidatorVoteAddress(operator)
```

**Verify:** All returned fields match the values supplied to `createValidator`.

### T-7.e — Node ID management (`addNodeIDs` / `removeNodeIDs` / `getNodeIDs`)

Register a P2P node ID for val1 and confirm removal works.

```
sendTx    val1: StakeHub.addNodeIDs([nodeId_hex])
eth_call  StakeHub.getNodeIDs(val1_operator)  → [nodeId_hex]
sendTx    val1: StakeHub.removeNodeIDs([nodeId_hex])
eth_call  StakeHub.getNodeIDs(val1_operator)  → []
```

**Verify:** `NodeIDAdded` / `NodeIDRemoved` events emitted.

### T-7.f — `UpdateTooFrequently` cooldown enforcement

Verify that a second edit within the same `BREATHE_BLOCK_INTERVAL` window reverts
with the expected custom error.  Run immediately after T-7.b (no sleep between them).

```
# T-7.b already set updateTime = block.timestamp
eth_call  [from: val1, to: StakeHub]
          editCommissionRate(newRate)  → REVERT UpdateTooFrequently()
verify: error data[0:4] == keccak256("UpdateTooFrequently()")[0:4]
```

**Verify:** Custom error selector matches `UpdateTooFrequently()`; confirms the shared
`updateTime` guard fires for all `edit*` functions within the same cooldown window.

---

## T-8 — StakeHub + StakeCredit: delegation lifecycle

**Script:** `90-run-t8-delegation-lifecycle.sh`  
**Prerequisite:** U-3 complete; validators registered and self-delegated.

### T-8.a — additional `delegate` (no vote-power activation)

Delegate an additional 1 BNB from val1 to val2's pool without activating vote
power (`delegateVotePower = false`).  Confirm share balance increases.

```
eth_call  StakeCredit(val2).getPooledBNB(val1_operator)  → initial
sendTx    val1: StakeHub.delegate(val2_operator, false)  --value 1 BNB
eth_call  StakeCredit(val2).getPooledBNB(val1_operator)  → initial + 1 BNB
```

**Verify:** `Delegated` event; share price unchanged (pool grows proportionally).

### T-8.b — `undelegate`

Initiate unbonding from val2's pool and confirm an unbond request is queued.

```
eth_call  StakeCredit(val2).balanceOf(val1_operator)  → shares
sendTx    val1: StakeHub.undelegate(val2_operator, shares/2)
eth_call  StakeCredit(val2).pendingUnbondRequest(val1_operator)
                             → [{shares, bnbAmount, lockTime}]
```

**Verify:** `Undelegated` event; pending request count = 1.

### T-8.c — `redelegate`

Move val1's remaining delegation in val2's pool to val3's pool.

```
eth_call  StakeCredit(val2).balanceOf(val1_operator)  → remaining_shares
sendTx    val1: StakeHub.redelegate(val2_operator, val3_operator, remaining_shares, false)
eth_call  StakeCredit(val2).balanceOf(val1_operator)  → 0 (or dust)
eth_call  StakeCredit(val3).getPooledBNB(val1_operator)  → > 0
```

**Verify:** `Redelegated` event; val2 balance zero, val3 balance increased.

### T-8.d — `claim` after unbond period (state-override)

Use `eth_call` with a `stateDiff` override to simulate the `lockTime` having
elapsed, then call `StakeHub.claimBatch` dry-run.

Note: in a real run the unbond period (default 7 days) must elapse; the local
drill uses storage override to skip waiting.

```
eth_call  StakeCredit(val2).claimableUnbondRequest(val1_operator)  → 0 (not claimable yet)
eth_call  [stateDiff override lockTime to past]
          StakeHub.claimBatch([val2_operator], [1])  → success
```

**Verify:** `Claimed` event in dry-run; `claimableUnbondRequest` returns 1 with override.

### T-8.e — StakeCredit read queries

```
eth_call  StakeCredit(val1).getSharesByPooledBNB(1 ether)  → shares
eth_call  StakeCredit(val1).getPooledBNBByShares(shares)   → ~1 ether
eth_call  StakeCredit(val1).lockedBNBs(0, 10)             → locked amounts per epoch
eth_call  StakeCredit(val1).unbondSequence()               → current sequence
eth_call  StakeCredit(val1).totalPooledBNB()               → total staked BNB
```

**Verify:** `getSharesByPooledBNB` and `getPooledBNBByShares` are inverse operations.

### T-8.f — real `claimBatch` after `unbondPeriod` elapses

Complements T-8.d (which uses a stateDiff override) with a real end-to-end claim.
Requires `unbondPeriod ≤ 15 s` (set via `generate.py abchain_local`).

```
# T-8.b already queued an unbond request; poll until claimable:
poll  StakeCredit(val2).claimableUnbondRequest(val1)  → 1  (timeout 40 s)
record  val1 BNB balance before claim
sendTx  val1: StakeHub.claimBatch([val2_operator], [1])
verify  val1 BNB balance increased
verify  Claimed(val2_operator, val1, amount) event emitted
verify  pendingUnbondRequest(val1) count decreased
```

**Verify:** Real BNB transfer occurs; unbond queue is drained; complements the
stateDiff simulation in T-8.d with a real on-chain flow.

---

## T-9 — GovToken: voting-power history and transfer restrictions

**Script:** `91-run-t9-govtoken.sh`  
**Prerequisite:** U-3 complete; validators have delegated and have govAB balance.

### T-9.a — `getPastVotes` at a past block

Confirm voting-power checkpoints are recorded correctly.

```
current_block = eth.blockNumber
eth_call  GovToken.getVotes(val1_operator)         → current_votes
wait 2 blocks
eth_call  GovToken.getPastVotes(val1_operator, current_block)  → same as current_votes
```

**Verify:** Past votes match the votes recorded at `current_block`.

### T-9.b — `getPastTotalSupply`

```
snapshot_block = eth.blockNumber
eth_call  GovToken.totalSupply()               → total_now
wait 1 block
eth_call  GovToken.getPastTotalSupply(snapshot_block)  → total_now
```

**Verify:** Snapshot total matches the value recorded at `snapshot_block`.

### T-9.c — `transfer` and `approve` are blocked

The contract overrides ERC-20 transfer and approval to always revert
(govAB is non-transferable).

```
eth_call  GovToken.transfer(val2_operator, 1)  → REVERT
eth_call  GovToken.approve(val2_operator, 1)   → REVERT
eth_call  GovToken.transferFrom(val1_operator, val2_operator, 1)  → REVERT
```

**Verify:** All three calls revert.

### T-9.d — `delegates` query

Confirm each validator's delegatee is their own operator address (self-delegate
set in U-3 Phase 5b).

```
eth_call  GovToken.delegates(val1_operator)  → val1_operator
eth_call  GovToken.delegates(val2_operator)  → val2_operator
eth_call  GovToken.delegates(val3_operator)  → val3_operator
```

---

## T-10 — BSCGovernor: extended governance scenarios

**Script:** `92-run-t10-governor-extended.sh`  
**Prerequisite:** U-3 complete; validators have govAB voting power.

### T-10.a — `castVoteWithReason`

Submit a vote with an on-chain reason string and confirm it is accepted.

```
sendTx propose(...)  → proposalId
sendTx val1: castVoteWithReason(proposalId, FOR=1, "supporting whitelist update")
eth_call  hasVoted(proposalId, val1_operator)  → true
```

**Verify:** `VoteCast` event includes the reason string.

### T-10.b — proposal `cancel`

Proposer cancels the proposal before votes start (or while still Active).

```
sendTx val1: propose(...)  → proposalId
sendTx val1: cancel(targets, values, calldatas, descHash)
eth_call  state(proposalId)  → Canceled (2)
```

**Verify:** `ProposalCanceled` event; subsequent `castVote` reverts.

### T-10.c — `Defeated` (majority Against)

All three validators vote Against.  Confirm the proposal ends in Defeated.

```
sendTx val1: propose(...)
sendTx val1/val2/val3: castVote(proposalId, AGAINST=0)
wait voting period
eth_call  state(proposalId)  → Defeated (3)
```

**Verify:** `queue` on a Defeated proposal reverts with `ProposalNotSuccessful`.

### T-10.d — Governor `updateParam` via governance (change `votingPeriod`)

Full governance round that targets `BSCGovernor` itself via `GovHub.updateParam`,
changing `votingPeriod` to a new value and confirming the change on-chain.

```
encode  GovHub.updateParam("votingPeriod", newValue, GOVERNOR_ADDR)
propose → vote → queue → execute
eth_call  BSCGovernor.votingPeriod()  → newValue
```

**Verify:** `ParamChange` event in GovHub; Governor returns updated value.

---

## T-11 — BSCValidatorSet: state queries

**Script:** `93-run-t11-validatorset-queries.sh`  
**Prerequisite:** U-3 complete; all 3 validators active.

### T-11.a — `getLivingValidators`

```
eth_call  BSCValidatorSet.getLivingValidators()
          → ([consensus_addr_1, ...], [voteAddr_1, ...])
```

**Verify:** Returns all 3 validator consensus addresses; no jailed entries.

### T-11.b — `getMiningValidators`

```
eth_call  BSCValidatorSet.getMiningValidators()  → [consensus_addr_1, ...]
```

**Verify:** All 3 validators eligible for block production.

### T-11.c — `isWorkingValidator`

```
eth_call  BSCValidatorSet.isWorkingValidator(val1_consensus)  → true
eth_call  BSCValidatorSet.isWorkingValidator(0x000...dead)    → false
```

### T-11.d — `getWorkingValidatorCount`

```
eth_call  BSCValidatorSet.getWorkingValidatorCount()  → 3
```

### T-11.e — `getIncoming`

Query the accumulated incoming BNB (block rewards) for val1.

```
eth_call  BSCValidatorSet.getIncoming(val1_consensus)  → incoming_wei
```

**Verify:** Non-zero after several blocks have been produced.

### T-11.f — `getCurrentValidatorIndex`

```
eth_call  BSCValidatorSet.getCurrentValidatorIndex(val1_consensus)  → 0 (or 1, 2)
```

**Verify:** Index is within [0, 2]; distinct for each validator.

### T-11.g — `BSCValidatorSet.updateParam` via governance (change `maxNumOfWorkingCandidates`)

Full governance round targeting `BSCValidatorSet` through `GovHub.updateParam`.

```
encode  GovHub.updateParam("maxNumOfWorkingCandidates", newValue, VALIDATOR_CONTRACT_ADDR)
propose → vote → queue → execute
eth_call  BSCValidatorSet.<param getter>()  → newValue
```

---

## T-12 — SlashIndicator: read-path and threshold queries

**Script:** `94-run-t12-slash-indicator.sh`  
**Prerequisite:** U-3 complete.

Note: tests that require actual validator misbehavior (double-sign, downtime)
are in cloud-testnet scope (E-2 / S-1).  This script covers read-only paths
and state-override simulations only.

### T-12.a — `getSlashThresholds`

```
eth_call  SlashIndicator.getSlashThresholds()
          → (felonyThreshold, misdemeanorThreshold)
```

**Verify:** Both thresholds are non-zero.

### T-12.b — `getSlashIndicator`

```
eth_call  SlashIndicator.getSlashIndicator(val1_consensus)
          → (height, count)
```

**Verify:** count == 0 for a validator with no misbehavior.

### T-12.c — slash counter via `stateDiff` (simulate misdemeanor threshold reached)

Use `eth_call` with `stateDiff` to override val1's slash count to
`misdemeanorThreshold - 1` and confirm the read path is correct.

```
compute  slashIndicator storage slot for val1_consensus
eth_call [stateDiff: slot → misdemeanorThreshold-1]
         SlashIndicator.getSlashIndicator(val1_consensus)  → count == threshold-1
```

### T-12.d — `SlashIndicator.updateParam` via governance

Full governance round to change a slash threshold parameter.

```
encode  GovHub.updateParam("felonyThreshold", newValue, SLASH_CONTRACT_ADDR)
propose → vote → queue → execute
eth_call  SlashIndicator.getSlashThresholds()  → felonyThreshold == newValue
```

---

## T-13 — BSCGovernor + GovHub: governance `updateParam` matrix

**Script:** `95-run-t13-governance-param-matrix.sh`  
**Prerequisite:** U-3 complete; validators have govAB voting power.

Exercises the full `BSCGovernor → BSCTimelock → GovHub → target.updateParam`
pipeline for multiple system-contract targets in sequence.  Each sub-case is
an independent proposal.

| Sub-case | Target contract | GovHub key | Expected effect |
|---|---|---|---|
| T-13.a | `StakeHub` | `removeFromValidatorWhitelist` | `validatorWhitelist(addr) == false` |
| T-13.b | `StakeHub` | `whitelistEnabled` (→ false) | `whitelistEnabled() == false` |
| T-13.c | `StakeHub` | `whitelistEnabled` (→ true) | `whitelistEnabled() == true` |
| T-13.d | `BSCValidatorSet` | `maxNumOfWorkingCandidates` | getter returns new value |
| T-13.e | `SlashIndicator` | `felonyThreshold` | `getSlashThresholds()` returns new value |
| T-13.f | `BSCGovernor` | `votingPeriod` | `BSCGovernor.votingPeriod()` returns new value |

Each sub-case follows the same pattern:

```
Phase 1: encode GovHub.updateParam(key, value, targetContract)
Phase 2: BSCGovernor.propose([GovHub], [0], [calldata], description)
Phase 3: castVote(FOR) × 3 validators
Phase 4: wait Succeeded (10 blocks)
Phase 5: queue
Phase 6: wait timelock (3 s)
Phase 7: execute
Phase 8: verify on-chain state matches expected value
```

---

## Implementation notes

- All scripts source `lib.sh` for shared helpers (`attach_exec`, `wait_for_ipc`, etc.).
- `eth_call` with `stateDiff` (state override) is used wherever a real on-chain
  action is impractical in a short-lived local drill (e.g., waiting 7-day unbond
  periods, triggering real slash events).
- Governance proposals in T-10/T-13 use the same reduced timeouts baked into the
  `abchain-local` genesis: `votingPeriod = 10 blocks`, `minDelay = 3 seconds`.
- Scripts that modify chain state (T-7.a commission edit, T-8.b undelegate, etc.)
  must be run **in order** within a session, as each may affect state that later
  scripts read.
- Slash-triggering scenarios (double-sign evidence, downtime evidence, finality
  violation evidence) require real misbehavior and are deferred to cloud testnet
  scope (E-2 / S-1).
- **`generate.py` abchain-local defaults changed** to enable T-7.a/b/c/f and T-8.f:
  - `breathe_block_interval`: `"1 days"` → `"5 seconds"` — clears the
    `BREATHE_BLOCK_INTERVAL` cooldown in `editCommissionRate` / `editDescription` /
    `editConsensusAddress` within a normal script run.
  - `unbond_period`: `"7 days"` → `"15 seconds"` — allows T-8.f to wait for a real
    unbond to mature rather than relying on stateDiff simulation.
  - `editConsensusAddress` is still tested as an `eth_call` dry-run only (T-7.c),
    because sending a real tx would break parlia block signing until the next
    breathe-block validator-set update, during which geth still signs with the
    original key.
