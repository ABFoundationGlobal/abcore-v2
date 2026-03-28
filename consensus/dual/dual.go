// Package dual implements a consensus engine wrapper that routes calls between
// Clique (PoA) and Parlia (PoSA) based on the ParliaGenesisBlock fork point.
//
// Before ParliaGenesisBlock: all engine calls are handled by Clique.
// At and after ParliaGenesisBlock: all engine calls are handled by Parlia.
//
// This pattern mirrors consensus/beacon/consensus.go (Ethereum's PoW→PoS wrapper).
// The key difference is that snapshot seeding and initContract are handled entirely
// inside Parlia's own Finalize (PR #49), so DualConsensus has no special fork-block logic.
package dual

import (
	"errors"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/consensus"
	"github.com/ethereum/go-ethereum/consensus/clique"
	"github.com/ethereum/go-ethereum/consensus/parlia"
	"github.com/ethereum/go-ethereum/core/state"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/ethdb"
	"github.com/ethereum/go-ethereum/internal/ethapi"
	"github.com/ethereum/go-ethereum/params"
	"github.com/ethereum/go-ethereum/rpc"
)

// DualConsensus is a consensus engine wrapper for ABCore's Clique→Parlia transition.
// It routes every consensus.Engine call to the appropriate inner engine depending on
// whether the target block is before or at/after ParliaGenesisBlock.
type DualConsensus struct {
	config *params.ChainConfig
	clique *clique.Clique
	parlia *parlia.Parlia
}

// New creates a DualConsensus engine. ParliaGenesisBlock must be set in config.
func New(
	config *params.ChainConfig,
	db ethdb.Database,
	ethAPI *ethapi.BlockChainAPI,
	genesisHash common.Hash,
) (*DualConsensus, error) {
	if config.ParliaGenesisBlock == nil {
		return nil, errors.New("DualConsensus requires ParliaGenesisBlock to be set in chain config")
	}
	if config.Clique == nil {
		return nil, errors.New("DualConsensus requires Clique config to be set")
	}
	if config.Parlia == nil {
		return nil, errors.New("DualConsensus requires Parlia config to be set")
	}
	return &DualConsensus{
		config: config,
		clique: clique.New(config.Clique, db),
		parlia: parlia.New(config, db, ethAPI, genesisHash),
	}, nil
}

// isParlia returns true if the given block number should be handled by Parlia.
// At ParliaGenesisBlock and beyond, Parlia is active.
func (d *DualConsensus) isParlia(number *big.Int) bool {
	return d.config.IsParliaActive(number)
}

// Clique returns the inner Clique engine. Used by eth/backend.go to call Authorize.
func (d *DualConsensus) Clique() *clique.Clique {
	return d.clique
}

// Parlia returns the inner Parlia engine. Used by eth/backend.go to call Authorize.
func (d *DualConsensus) Parlia() *parlia.Parlia {
	return d.parlia
}

// Author implements consensus.Engine.
func (d *DualConsensus) Author(header *types.Header) (common.Address, error) {
	if d.isParlia(header.Number) {
		return d.parlia.Author(header)
	}
	return d.clique.Author(header)
}

// VerifyHeader implements consensus.Engine.
func (d *DualConsensus) VerifyHeader(chain consensus.ChainHeaderReader, header *types.Header) error {
	if d.isParlia(header.Number) {
		return d.parlia.VerifyHeader(chain, header)
	}
	return d.clique.VerifyHeader(chain, header)
}

// splitHeaders splits a contiguous header slice into [pre-fork, post-fork] halves.
// Headers with Number < ParliaGenesisBlock go to pre; >= go to post.
// Both slices may be empty (the caller checks this).
func (d *DualConsensus) splitHeaders(headers []*types.Header) ([]*types.Header, []*types.Header) {
	forkNum := d.config.ParliaGenesisBlock
	for i, h := range headers {
		if h.Number.Cmp(forkNum) >= 0 {
			return headers[:i], headers[i:]
		}
	}
	return headers, nil
}

// VerifyHeaders implements consensus.Engine.
// Batches are split at ParliaGenesisBlock; Clique and Parlia verify their halves
// concurrently, and results are merged in original order.
func (d *DualConsensus) VerifyHeaders(chain consensus.ChainHeaderReader, headers []*types.Header) (chan<- struct{}, <-chan error) {
	if len(headers) == 0 {
		abort := make(chan struct{})
		results := make(chan error)
		close(results)
		return abort, results
	}

	preHeaders, postHeaders := d.splitHeaders(headers)

	if len(postHeaders) == 0 {
		// All pre-fork: delegate entirely to Clique.
		return d.clique.VerifyHeaders(chain, headers)
	}
	if len(preHeaders) == 0 {
		// All post-fork: delegate entirely to Parlia.
		return d.parlia.VerifyHeaders(chain, headers)
	}

	// Transition point is within the batch: run both engines concurrently.
	var (
		abort   = make(chan struct{})
		results = make(chan error, len(headers))
	)
	go func() {
		// No recover: a panic here crashes the process immediately.
		// This is the correct fail-fast behaviour for consensus code — a panic
		// indicates a programming error that must not be silently swallowed.
		// Matches the pattern used in consensus/beacon/consensus.go.
		var (
			old, new_, out            = 0, len(preHeaders), 0
			errs                      = make([]error, len(headers))
			done                      = make([]bool, len(headers))
			cliqueAbort, cliqueResult = d.clique.VerifyHeaders(chain, preHeaders)
			parliaAbort, parliaResult = d.parlia.VerifyHeaders(chain, postHeaders)
		)
		defer func() {
			close(cliqueAbort)
			close(parliaAbort)
		}()
		for {
			for ; done[out]; out++ {
				results <- errs[out]
				if out == len(headers)-1 {
					return
				}
			}
			select {
			case err := <-cliqueResult:
				// Defensive guard: Clique's VerifyHeaders contract guarantees exactly
				// one result per input header, so done[old] should never be true here.
				// The check prevents index corruption if that contract is ever violated.
				if !done[old] {
					errs[old], done[old] = err, true
				}
				old++
			case err := <-parliaResult:
				errs[new_], done[new_] = err, true
				new_++
			case <-abort:
				return
			}
		}
	}()
	return abort, results
}

// VerifyUncles implements consensus.Engine.
func (d *DualConsensus) VerifyUncles(chain consensus.ChainReader, block *types.Block) error {
	if d.isParlia(block.Number()) {
		return d.parlia.VerifyUncles(chain, block)
	}
	return d.clique.VerifyUncles(chain, block)
}

// VerifyRequests implements consensus.Engine.
func (d *DualConsensus) VerifyRequests(header *types.Header, requests [][]byte) error {
	if d.isParlia(header.Number) {
		return d.parlia.VerifyRequests(header, requests)
	}
	return d.clique.VerifyRequests(header, requests)
}

// NextInTurnValidator implements consensus.Engine.
func (d *DualConsensus) NextInTurnValidator(chain consensus.ChainHeaderReader, header *types.Header) (common.Address, error) {
	if d.isParlia(header.Number) {
		return d.parlia.NextInTurnValidator(chain, header)
	}
	return d.clique.NextInTurnValidator(chain, header)
}

// Prepare implements consensus.Engine.
func (d *DualConsensus) Prepare(chain consensus.ChainHeaderReader, header *types.Header) error {
	if d.isParlia(header.Number) {
		return d.parlia.Prepare(chain, header)
	}
	return d.clique.Prepare(chain, header)
}

// Finalize implements consensus.Engine.
func (d *DualConsensus) Finalize(
	chain consensus.ChainHeaderReader,
	header *types.Header,
	state vm.StateDB,
	txs *[]*types.Transaction,
	uncles []*types.Header,
	withdrawals []*types.Withdrawal,
	receipts *[]*types.Receipt,
	systemTxs *[]*types.Transaction,
	usedGas *uint64,
	tracer *tracing.Hooks,
) error {
	if d.isParlia(header.Number) {
		return d.parlia.Finalize(chain, header, state, txs, uncles, withdrawals, receipts, systemTxs, usedGas, tracer)
	}
	return d.clique.Finalize(chain, header, state, txs, uncles, withdrawals, receipts, systemTxs, usedGas, tracer)
}

// FinalizeAndAssemble implements consensus.Engine.
func (d *DualConsensus) FinalizeAndAssemble(
	chain consensus.ChainHeaderReader,
	header *types.Header,
	state *state.StateDB,
	body *types.Body,
	receipts []*types.Receipt,
	tracer *tracing.Hooks,
) (*types.Block, []*types.Receipt, error) {
	if d.isParlia(header.Number) {
		return d.parlia.FinalizeAndAssemble(chain, header, state, body, receipts, tracer)
	}
	return d.clique.FinalizeAndAssemble(chain, header, state, body, receipts, tracer)
}

// Seal implements consensus.Engine.
func (d *DualConsensus) Seal(chain consensus.ChainHeaderReader, block *types.Block, results chan<- *types.Block, stop <-chan struct{}) error {
	if d.isParlia(block.Number()) {
		return d.parlia.Seal(chain, block, results, stop)
	}
	return d.clique.Seal(chain, block, results, stop)
}

// SealHash implements consensus.Engine.
func (d *DualConsensus) SealHash(header *types.Header) common.Hash {
	if d.isParlia(header.Number) {
		return d.parlia.SealHash(header)
	}
	return d.clique.SealHash(header)
}

// SignBAL implements consensus.Engine.
func (d *DualConsensus) SignBAL(bal *types.BlockAccessListEncode) error {
	// BAL is a BSC/Parlia feature. DualConsensus always delegates BAL signing to Parlia,
	// even for pre-fork (Clique-era) blocks, because BAL headers are only produced and
	// verified in the Parlia phase.
	return d.parlia.SignBAL(bal)
}

// VerifyBAL implements consensus.Engine.
func (d *DualConsensus) VerifyBAL(block *types.Block, bal *types.BlockAccessListEncode) error {
	if d.isParlia(block.Number()) {
		return d.parlia.VerifyBAL(block, bal)
	}
	return d.clique.VerifyBAL(block, bal)
}

// CalcDifficulty implements consensus.Engine.
func (d *DualConsensus) CalcDifficulty(chain consensus.ChainHeaderReader, t uint64, parent *types.Header) *big.Int {
	// The next block is parent.Number + 1.
	next := new(big.Int).Add(parent.Number, common.Big1)
	if d.isParlia(next) {
		return d.parlia.CalcDifficulty(chain, t, parent)
	}
	return d.clique.CalcDifficulty(chain, t, parent)
}

// Delay implements consensus.Engine.
func (d *DualConsensus) Delay(chain consensus.ChainReader, header *types.Header, leftOver *time.Duration) *time.Duration {
	if d.isParlia(header.Number) {
		return d.parlia.Delay(chain, header, leftOver)
	}
	return d.clique.Delay(chain, header, leftOver)
}

// APIs implements consensus.Engine. Returns APIs from both inner engines.
func (d *DualConsensus) APIs(chain consensus.ChainHeaderReader) []rpc.API {
	return append(d.clique.APIs(chain), d.parlia.APIs(chain)...)
}

// Close implements consensus.Engine.
func (d *DualConsensus) Close() error {
	return errors.Join(d.clique.Close(), d.parlia.Close())
}

// compile-time check: DualConsensus must satisfy consensus.PoSA so that
// eth/backend.go's votePool initialization and state_processor.go's system
// transaction classification can use DualConsensus through the PoSA interface.
var _ consensus.PoSA = (*DualConsensus)(nil)

// IsSystemTransaction implements consensus.PoSA.
// Pre-fork Clique has no system transactions; post-fork delegates to Parlia.
func (d *DualConsensus) IsSystemTransaction(tx *types.Transaction, header *types.Header) (bool, error) {
	if d.isParlia(header.Number) {
		return d.parlia.IsSystemTransaction(tx, header)
	}
	return false, nil
}

// IsSystemContract implements consensus.PoSA.
// System contract addresses are a static set determined by Parlia; the same set
// applies regardless of phase, so always delegate to Parlia.
func (d *DualConsensus) IsSystemContract(to *common.Address) bool {
	return d.parlia.IsSystemContract(to)
}

// EnoughDistance implements consensus.PoSA.
// Clique has no distance concept; return true (permissive) to allow block production.
func (d *DualConsensus) EnoughDistance(chain consensus.ChainReader, header *types.Header) bool {
	if d.isParlia(header.Number) {
		return d.parlia.EnoughDistance(chain, header)
	}
	return true
}

// IsLocalBlock implements consensus.PoSA.
// Parlia.val is set by Parlia.Authorize, which DualConsensus always calls with the
// same etherbase as Clique. Delegating to Parlia is correct for both phases.
func (d *DualConsensus) IsLocalBlock(header *types.Header) bool {
	return d.parlia.IsLocalBlock(header)
}

// GetJustifiedNumberAndHash implements consensus.PoSA.
// Clique has no fast-finality voting; return genesis as the justified checkpoint.
func (d *DualConsensus) GetJustifiedNumberAndHash(chain consensus.ChainHeaderReader, headers []*types.Header) (uint64, common.Hash, error) {
	if len(headers) > 0 && d.isParlia(headers[len(headers)-1].Number) {
		return d.parlia.GetJustifiedNumberAndHash(chain, headers)
	}
	if chain == nil {
		return 0, common.Hash{}, errors.New("GetJustifiedNumberAndHash: nil chain")
	}
	genesis := chain.GetHeaderByNumber(0)
	if genesis == nil {
		return 0, common.Hash{}, errors.New("GetJustifiedNumberAndHash: genesis header not found")
	}
	return 0, genesis.Hash(), nil
}

// GetFinalizedHeader implements consensus.PoSA.
// Clique has no finality; return the genesis header as the finalized anchor.
func (d *DualConsensus) GetFinalizedHeader(chain consensus.ChainHeaderReader, header *types.Header) *types.Header {
	if header != nil && d.isParlia(header.Number) {
		return d.parlia.GetFinalizedHeader(chain, header)
	}
	if chain == nil {
		return nil
	}
	return chain.GetHeaderByNumber(0)
}

// CheckFinalityAndNotify implements consensus.PoSA.
// No-op during Clique phase; delegates to Parlia once the fork is active.
func (d *DualConsensus) CheckFinalityAndNotify(chain consensus.ChainHeaderReader, targetBlockHash common.Hash, notifyFn func(*types.Header)) {
	head := chain.CurrentHeader()
	if head != nil && d.isParlia(head.Number) {
		d.parlia.CheckFinalityAndNotify(chain, targetBlockHash, notifyFn)
	}
}

// VerifyVote implements consensus.PoSA.
// Votes are only valid in the Parlia phase. During the Clique phase, reject
// immediately rather than triggering Parlia snapshot validation on Clique-era
// headers (unnecessary work and a potential DoS vector).
func (d *DualConsensus) VerifyVote(chain consensus.ChainHeaderReader, vote *types.VoteEnvelope) error {
	if vote == nil || vote.Data == nil {
		return errors.New("invalid vote")
	}
	if !d.isParlia(new(big.Int).SetUint64(vote.Data.TargetNumber)) {
		return errors.New("VerifyVote not supported in Clique phase")
	}
	return d.parlia.VerifyVote(chain, vote)
}

// IsActiveValidatorAt implements consensus.PoSA.
// Clique has no Parlia-style active validator set; return false pre-fork.
func (d *DualConsensus) IsActiveValidatorAt(chain consensus.ChainHeaderReader, header *types.Header, checkVoteKeyFn func(*types.BLSPublicKey) bool) bool {
	if d.isParlia(header.Number) {
		return d.parlia.IsActiveValidatorAt(chain, header, checkVoteKeyFn)
	}
	return false
}

// NextProposalBlock implements consensus.PoSA.
// Proposal blocks are a Parlia concept; return an error during Clique phase.
func (d *DualConsensus) NextProposalBlock(chain consensus.ChainHeaderReader, header *types.Header, proposer common.Address) (uint64, uint64, error) {
	if d.isParlia(header.Number) {
		return d.parlia.NextProposalBlock(chain, header, proposer)
	}
	return 0, 0, errors.New("NextProposalBlock not supported in Clique phase")
}
