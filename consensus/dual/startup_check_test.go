// Copyright 2026 The ABCore Authors

package dual

import (
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/params"
)

// dualConfig returns a chain config that satisfies HasCliqueAndParlia(): both
// Clique and Parlia engine fields are populated. ParliaGenesisBlock is left
// for the caller to set.
func dualConfig() *params.ChainConfig {
	return &params.ChainConfig{
		ChainID: big.NewInt(99988),
		Clique:  &params.CliqueConfig{Period: 1, Epoch: 30000},
		Parlia:  &params.ParliaConfig{},
	}
}

// header builds a header at the given height with extraData of the given length.
func header(number uint64, extraLen int) *types.Header {
	return &types.Header{
		Number: new(big.Int).SetUint64(number),
		Extra:  make([]byte, extraLen),
	}
}

func TestVerifyForkBlockOnDisk_NonDualChainNoOp(t *testing.T) {
	// Pure Clique config: HasCliqueAndParlia() == false (no Parlia engine).
	cfg := &params.ChainConfig{
		ChainID: big.NewInt(99988),
		Clique:  &params.CliqueConfig{Period: 1, Epoch: 30000},
	}
	cfg.ParliaGenesisBlock = big.NewInt(16)
	head := header(20, extraVanity+extraSeal) // would fail if check ran

	err := VerifyForkBlockOnDisk(cfg, head, func(uint64) *types.Header {
		t.Fatalf("headerByNumber should not be called on a non-dual chain")
		return nil
	})
	if err != nil {
		t.Fatalf("expected nil on non-dual chain, got: %v", err)
	}
}

func TestVerifyForkBlockOnDisk_PgbNilNoOp(t *testing.T) {
	cfg := dualConfig() // ParliaGenesisBlock = nil
	head := header(20, extraVanity+extraSeal)

	err := VerifyForkBlockOnDisk(cfg, head, func(uint64) *types.Header {
		t.Fatalf("headerByNumber should not be called when PGB=nil")
		return nil
	})
	if err != nil {
		t.Fatalf("expected nil when PGB=nil, got: %v", err)
	}
}

func TestVerifyForkBlockOnDisk_HeadBeforeForkNoOp(t *testing.T) {
	cfg := dualConfig()
	cfg.ParliaGenesisBlock = big.NewInt(20)
	head := header(15, extraVanity+extraSeal) // Clique-form is fine pre-fork

	err := VerifyForkBlockOnDisk(cfg, head, func(uint64) *types.Header {
		t.Fatalf("headerByNumber should not be called when head < PGB")
		return nil
	})
	if err != nil {
		t.Fatalf("expected nil when head < PGB, got: %v", err)
	}
}

func TestVerifyForkBlockOnDisk_NilHeadNoOp(t *testing.T) {
	cfg := dualConfig()
	cfg.ParliaGenesisBlock = big.NewInt(20)

	err := VerifyForkBlockOnDisk(cfg, nil, func(uint64) *types.Header {
		t.Fatalf("headerByNumber should not be called when head is nil")
		return nil
	})
	if err != nil {
		t.Fatalf("expected nil on nil head, got: %v", err)
	}
}

func TestVerifyForkBlockOnDisk_HeadAtForkParliaForm(t *testing.T) {
	cfg := dualConfig()
	cfg.ParliaGenesisBlock = big.NewInt(16)
	head := header(16, extraVanity+3*common.AddressLength+extraSeal) // 3 validators × 20 bytes
	called := false
	getHeader := func(n uint64) *types.Header {
		called = true
		if n != 16 {
			t.Errorf("expected lookup at PGB=16, got %d", n)
		}
		return head
	}

	err := VerifyForkBlockOnDisk(cfg, head, getHeader)
	if err != nil {
		t.Fatalf("Parlia-form fork block should pass; got: %v", err)
	}
	if !called {
		t.Fatalf("headerByNumber should have been called for PGB lookup")
	}
}

func TestVerifyForkBlockOnDisk_HeadPastForkCliqueForm(t *testing.T) {
	// The exact failure mode the runbook describes: chain head is past PGB
	// but the on-disk block at PGB has Clique-form extraData (length =
	// 32 + 65 = 97 bytes). Engine must refuse to start.
	cfg := dualConfig()
	cfg.ParliaGenesisBlock = big.NewInt(16)

	head := header(20, extraVanity+3*common.AddressLength+extraSeal) // post-fork is Parlia-form

	// The block at PGB itself is Clique-form — this is the corruption.
	bad := header(16, extraVanity+extraSeal)

	getHeader := func(n uint64) *types.Header {
		if n == 16 {
			return bad
		}
		return nil
	}

	err := VerifyForkBlockOnDisk(cfg, head, getHeader)
	if err == nil {
		t.Fatalf("expected refuse-to-start error when fork block is Clique-form")
	}
	// Surface check: the error message should mention rollback and the
	// runbook so an operator hitting this in production knows what to do.
	msg := err.Error()
	for _, want := range []string{
		"refusing to start",
		"Clique-form",
		"ParliaGenesisBlock=16",
		"consensus-switch-rollback-runbook.md",
		"fork-cutover-runbook.md",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("error message missing %q\nfull message:\n%s", want, msg)
		}
	}
}

func TestVerifyForkBlockOnDisk_HeadPastForkButForkBlockMissing(t *testing.T) {
	// Defensive: if the database somehow has head > PGB but no header
	// stored at PGB, surface a clear error rather than silently returning
	// nil. This shouldn't happen, but if it does we want to know.
	cfg := dualConfig()
	cfg.ParliaGenesisBlock = big.NewInt(16)
	head := header(20, extraVanity+3*common.AddressLength+extraSeal)

	err := VerifyForkBlockOnDisk(cfg, head, func(uint64) *types.Header {
		return nil // simulate missing block at PGB
	})
	if err == nil {
		t.Fatalf("expected error when fork-block header is missing from db")
	}
	if !strings.Contains(err.Error(), "inconsistent") {
		t.Errorf("error message should mention chaindb inconsistency; got: %v", err)
	}
}
