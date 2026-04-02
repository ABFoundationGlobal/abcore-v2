package parlia

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/lru"
	"github.com/ethereum/go-ethereum/core/rawdb"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/params"
)

type transitionSnapshotChain struct {
	parliaStubChainReader
	cfg             *params.ChainConfig
	headersByNumber map[uint64]*types.Header
	headersByHash   map[common.Hash]*types.Header
}

func (s *transitionSnapshotChain) Config() *params.ChainConfig {
	return s.cfg
}

func (s *transitionSnapshotChain) GetHeader(hash common.Hash, number uint64) *types.Header {
	header := s.headersByHash[hash]
	if header != nil && header.Number.Uint64() == number {
		return header
	}
	return nil
}

func (s *transitionSnapshotChain) GetHeaderByNumber(number uint64) *types.Header {
	return s.headersByNumber[number]
}

func (s *transitionSnapshotChain) GetHeaderByHash(hash common.Hash) *types.Header {
	return s.headersByHash[hash]
}

func (s *transitionSnapshotChain) GenesisHeader() *types.Header {
	return s.headersByNumber[0]
}

func buildTransitionSnapshotChain(cfg *params.ChainConfig, forkBlock, checkpointNumber uint64, genesisValidators, checkpointValidators []common.Address) (*transitionSnapshotChain, *types.Header) {
	headersByNumber := make(map[uint64]*types.Header, forkBlock)
	headersByHash := make(map[common.Hash]*types.Header, forkBlock)
	var parentHash common.Hash
	for number := uint64(0); number < forkBlock; number++ {
		header := &types.Header{
			Number:     new(big.Int).SetUint64(number),
			ParentHash: parentHash,
			Time:       number,
			Extra:      make([]byte, extraVanity+extraSeal),
		}
		switch number {
		case 0:
			header.Extra = cliqueEpochExtra(genesisValidators)
		case checkpointNumber:
			header.Extra = cliqueEpochExtra(checkpointValidators)
		}
		hash := header.Hash()
		headersByNumber[number] = header
		headersByHash[hash] = header
		parentHash = hash
	}
	chain := &transitionSnapshotChain{
		cfg:             cfg,
		headersByNumber: headersByNumber,
		headersByHash:   headersByHash,
	}
	return chain, headersByNumber[forkBlock-1]
}

func assertValidatorSet(t *testing.T, validatorSet map[common.Address]*ValidatorInfo, expected []common.Address) {
	t.Helper()
	if len(validatorSet) != len(expected) {
		t.Fatalf("validator set size: got %d, want %d", len(validatorSet), len(expected))
	}
	for _, validator := range expected {
		if _, ok := validatorSet[validator]; !ok {
			t.Fatalf("validator %s missing from set", validator)
		}
	}
}

func TestSnapshotSeedsForkParentFromCliqueCheckpoint(t *testing.T) {
	const (
		forkBlock   = uint64(101)
		cliqueEpoch = uint64(100)
	)
	genesisValidators := []common.Address{
		common.HexToAddress("0x1000000000000000000000000000000000000001"),
		common.HexToAddress("0x2000000000000000000000000000000000000002"),
	}
	checkpointValidators := []common.Address{
		common.HexToAddress("0x3000000000000000000000000000000000000003"),
		common.HexToAddress("0x4000000000000000000000000000000000000004"),
	}

	cfg := migrationChainConfig(forkBlock, cliqueEpoch)
	sigCache := lru.NewCache[common.Hash, common.Address](inMemorySignatures)
	p := &Parlia{
		chainConfig: cfg,
		config:      cfg.Parlia,
		recentSnaps: lru.NewCache[common.Hash, *Snapshot](inMemorySnapshots),
		signatures:  sigCache,
	}
	chain, forkParent := buildTransitionSnapshotChain(cfg, forkBlock, cliqueEpoch, genesisValidators, checkpointValidators)
	genesisHash := chain.headersByNumber[0].Hash()
	p.recentSnaps.Add(genesisHash, newSnapshot(cfg.Parlia, sigCache, 0, genesisHash, genesisValidators, nil, nil))

	snap, err := p.snapshot(chain, forkParent.Number.Uint64(), forkParent.Hash(), nil)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	if snap.Number != forkParent.Number.Uint64() {
		t.Fatalf("snapshot number: got %d, want %d", snap.Number, forkParent.Number.Uint64())
	}
	if snap.Hash != forkParent.Hash() {
		t.Fatalf("snapshot hash: got %s, want %s", snap.Hash, forkParent.Hash())
	}
	assertValidatorSet(t, snap.Validators, checkpointValidators)

	seed, ok := p.recentSnaps.Get(genesisHash)
	if !ok {
		t.Fatal("missing cached genesis snapshot")
	}
	if seed.Number != 0 {
		t.Fatalf("cached genesis snapshot number mutated: got %d, want 0", seed.Number)
	}
	if seed.Hash != genesisHash {
		t.Fatalf("cached genesis snapshot hash mutated: got %s, want %s", seed.Hash, genesisHash)
	}
	assertValidatorSet(t, seed.Validators, genesisValidators)
}

func TestSnapshotGenesisPathUsesCliqueCheckpointAndEpoch(t *testing.T) {
	const (
		forkBlock   = uint64(35)
		cliqueEpoch = uint64(10)
	)
	genesisValidators := []common.Address{
		common.HexToAddress("0x1000000000000000000000000000000000000001"),
		common.HexToAddress("0x2000000000000000000000000000000000000002"),
		common.HexToAddress("0x3000000000000000000000000000000000000003"),
	}
	checkpointValidators := []common.Address{
		common.HexToAddress("0x1000000000000000000000000000000000000001"),
		common.HexToAddress("0x2000000000000000000000000000000000000002"),
		common.HexToAddress("0x3000000000000000000000000000000000000003"),
		common.HexToAddress("0x4000000000000000000000000000000000000004"),
	}

	cfg := migrationChainConfig(forkBlock, cliqueEpoch)
	cfg.Clique.Period = 1
	db := rawdb.NewMemoryDatabase()
	sigCache := lru.NewCache[common.Hash, common.Address](inMemorySignatures)
	p := &Parlia{
		chainConfig: cfg,
		config:      cfg.Parlia,
		db:          db,
		recentSnaps: lru.NewCache[common.Hash, *Snapshot](inMemorySnapshots),
		signatures:  sigCache,
	}
	chain, forkParent := buildTransitionSnapshotChain(cfg, forkBlock, 30, genesisValidators, checkpointValidators)

	snap, err := p.snapshot(chain, forkParent.Number.Uint64(), forkParent.Hash(), nil)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	if snap.Number != forkParent.Number.Uint64() {
		t.Fatalf("snapshot number: got %d, want %d", snap.Number, forkParent.Number.Uint64())
	}
	if snap.Hash != forkParent.Hash() {
		t.Fatalf("snapshot hash: got %s, want %s", snap.Hash, forkParent.Hash())
	}
	assertValidatorSet(t, snap.Validators, checkpointValidators)
	if snap.EpochLength != cliqueEpoch {
		t.Fatalf("snapshot epoch length: got %d, want %d", snap.EpochLength, cliqueEpoch)
	}
	if snap.BlockInterval != 1000 {
		t.Fatalf("snapshot block interval: got %d, want %d", snap.BlockInterval, 1000)
	}
}
