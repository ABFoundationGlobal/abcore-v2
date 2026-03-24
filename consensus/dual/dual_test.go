package dual

import (
	"math/big"
	"testing"

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
