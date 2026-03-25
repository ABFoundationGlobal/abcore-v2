package dual

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/consensus"
	"github.com/ethereum/go-ethereum/core/rawdb"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/params"
)

// testConfig returns a ChainConfig with Clique+Parlia and ParliaGenesisBlock set.
func testConfig(forkBlock int64) *params.ChainConfig {
	cfg := *params.ABCoreTestChainConfig // shallow copy
	cfg.ParliaGenesisBlock = big.NewInt(forkBlock)
	return &cfg
}

func TestNewRequiresParliaGenesisBlock(t *testing.T) {
	cfg := *params.ABCoreTestChainConfig
	cfg.ParliaGenesisBlock = nil
	_, err := New(&cfg, rawdb.NewMemoryDatabase(), nil, [32]byte{})
	if err == nil {
		t.Fatal("expected error when ParliaGenesisBlock is nil")
	}
}

func TestNewRequiresCliqueConfig(t *testing.T) {
	cfg := testConfig(100)
	cfg.Clique = nil
	_, err := New(cfg, rawdb.NewMemoryDatabase(), nil, [32]byte{})
	if err == nil {
		t.Fatal("expected error when Clique config is nil")
	}
}

func TestNewSucceeds(t *testing.T) {
	dc, err := New(testConfig(100), rawdb.NewMemoryDatabase(), nil, [32]byte{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if dc.Clique() == nil {
		t.Fatal("inner Clique is nil")
	}
	if dc.Parlia() == nil {
		t.Fatal("inner Parlia is nil")
	}
}

func TestIsParlia(t *testing.T) {
	const fork = int64(100)
	dc, err := New(testConfig(fork), rawdb.NewMemoryDatabase(), nil, [32]byte{})
	if err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		num        int64
		wantParlia bool
	}{
		{0, false},
		{fork - 1, false},
		{fork, true},
		{fork + 1, true},
		{fork + 9999, true},
	}
	for _, c := range cases {
		got := dc.isParlia(big.NewInt(c.num))
		if got != c.wantParlia {
			t.Errorf("isParlia(%d) = %v, want %v", c.num, got, c.wantParlia)
		}
	}
}

// TestPoSAInterfaceSatisfied verifies that DualConsensus satisfies consensus.PoSA
// at compile time and via a runtime type assertion.
func TestPoSAInterfaceSatisfied(t *testing.T) {
	dc, err := New(testConfig(100), rawdb.NewMemoryDatabase(), nil, [32]byte{})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := any(dc).(consensus.PoSA); !ok {
		t.Fatal("DualConsensus does not satisfy consensus.PoSA")
	}
}

// TestPoSAPreForkStubs verifies that PoSA methods return safe zero values for pre-fork blocks.
func TestPoSAPreForkStubs(t *testing.T) {
	const fork = int64(100)
	dc, err := New(testConfig(fork), rawdb.NewMemoryDatabase(), nil, [32]byte{})
	if err != nil {
		t.Fatal(err)
	}

	preForkHeader := makeHeader(fork - 1)

	t.Run("IsSystemTransaction_preFork", func(t *testing.T) {
		tx := types.NewTx(&types.LegacyTx{})
		got, err := dc.IsSystemTransaction(tx, preForkHeader)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got {
			t.Fatal("expected false for pre-fork system tx check")
		}
	})

	t.Run("IsSystemContract_delegatesToParlia", func(t *testing.T) {
		// A random non-system address should return false.
		addr := common.HexToAddress("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
		if dc.IsSystemContract(&addr) {
			t.Fatal("random address should not be a system contract")
		}
		// nil should return false.
		if dc.IsSystemContract(nil) {
			t.Fatal("nil should not be a system contract")
		}
	})

	t.Run("EnoughDistance_preFork_returnsTrue", func(t *testing.T) {
		if !dc.EnoughDistance(nil, preForkHeader) {
			t.Fatal("expected true for pre-fork EnoughDistance")
		}
	})

	t.Run("IsActiveValidatorAt_preFork_returnsFalse", func(t *testing.T) {
		got := dc.IsActiveValidatorAt(nil, preForkHeader, nil)
		if got {
			t.Fatal("expected false for pre-fork IsActiveValidatorAt")
		}
	})

	t.Run("NextProposalBlock_preFork_returnsError", func(t *testing.T) {
		_, _, err := dc.NextProposalBlock(nil, preForkHeader, common.Address{})
		if err == nil {
			t.Fatal("expected error for pre-fork NextProposalBlock")
		}
	})

	t.Run("GetJustifiedNumberAndHash_preFork_returnsGenesisNumber", func(t *testing.T) {
		chain := &stubGenesisChain{}
		num, hash, err := dc.GetJustifiedNumberAndHash(chain, []*types.Header{preForkHeader})
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if num != 0 {
			t.Errorf("expected justified number 0, got %d", num)
		}
		if hash == (common.Hash{}) {
			// The hash is the RLP hash of an empty genesis header; just verify it is non-zero.
			t.Error("expected non-zero hash for genesis")
		}
	})

	t.Run("GetFinalizedHeader_preFork_returnsGenesisNumber", func(t *testing.T) {
		chain := &stubGenesisChain{}
		h := dc.GetFinalizedHeader(chain, preForkHeader)
		if h == nil {
			t.Fatal("expected non-nil genesis header")
		}
		if h.Number.Cmp(common.Big0) != 0 {
			t.Errorf("expected genesis header (number 0), got number %s", h.Number)
		}
	})
}

// stubGenesisChain implements a minimal consensus.ChainHeaderReader that only
// serves block 0 so the pre-fork PoSA stubs can return the genesis header.
type stubGenesisChain struct {
	consensus.ChainHeaderReader
}

func (s *stubGenesisChain) GetHeaderByNumber(n uint64) *types.Header {
	if n == 0 {
		return &types.Header{Number: big.NewInt(0)}
	}
	return nil
}

func (s *stubGenesisChain) CurrentHeader() *types.Header { return nil }

// makeHeader creates a minimal types.Header with only Number set.
func makeHeader(num int64) *types.Header {
	return &types.Header{Number: big.NewInt(num)}
}

func makeHeaders(nums ...int64) []*types.Header {
	out := make([]*types.Header, len(nums))
	for i, n := range nums {
		out[i] = makeHeader(n)
	}
	return out
}

func TestSplitHeaders(t *testing.T) {
	const fork = int64(50)
	dc, err := New(testConfig(fork), rawdb.NewMemoryDatabase(), nil, [32]byte{})
	if err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		desc              string
		nums              []int64
		wantPre, wantPost int
	}{
		{"all pre-fork", []int64{10, 20, 30}, 3, 0},
		{"all post-fork", []int64{50, 60, 70}, 0, 3},
		{"fork block is first", []int64{50, 51, 52}, 0, 3},
		{"fork block is last", []int64{47, 48, 49, 50}, 3, 1},
		{"split in middle", []int64{48, 49, 50, 51}, 2, 2},
		{"single pre-fork", []int64{10}, 1, 0},
		{"single fork block", []int64{50}, 0, 1},
		{"single post-fork", []int64{51}, 0, 1},
	}

	for _, c := range cases {
		t.Run(c.desc, func(t *testing.T) {
			pre, post := dc.splitHeaders(makeHeaders(c.nums...))
			if len(pre) != c.wantPre {
				t.Errorf("pre: got %d, want %d", len(pre), c.wantPre)
			}
			if len(post) != c.wantPost {
				t.Errorf("post: got %d, want %d", len(post), c.wantPost)
			}
			// Verify pre+post reconstructs the original slice in order.
			all := append(pre, post...)
			for i, h := range all {
				if h.Number.Int64() != c.nums[i] {
					t.Errorf("slot %d: got number %d, want %d", i, h.Number.Int64(), c.nums[i])
				}
			}
		})
	}
}
