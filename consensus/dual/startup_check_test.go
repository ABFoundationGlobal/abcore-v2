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
// Coinbase defaults to zero. For Parlia-form fork-block headers, callers must
// set a non-zero Coinbase via headerWithCoinbase or by writing the field
// directly, because the startup check distinguishes Clique epoch checkpoints
// (Coinbase=zero) from Parlia blocks (Coinbase=signer) when len(Extra) > 97.
func header(number uint64, extraLen int) *types.Header {
	return &types.Header{
		Number: new(big.Int).SetUint64(number),
		Extra:  make([]byte, extraLen),
	}
}

// parliaForkHeader builds a Parlia-form fork-block header: extraData layout is
// vanity(32) + N×20-byte validators + seal(65), and Coinbase is a non-zero
// address (the recovered signer). This matches what a healthy Parlia fork
// block looks like on disk.
func parliaForkHeader(number uint64, validatorCount int) *types.Header {
	h := header(number, extraVanity+validatorCount*common.AddressLength+extraSeal)
	h.Coinbase = common.HexToAddress("0x1111111111111111111111111111111111111111")
	return h
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
	head := parliaForkHeader(16, 3) // 3 validators × 20 bytes, Coinbase non-zero
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

	head := parliaForkHeader(20, 3) // post-fork is Parlia-form

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

func TestVerifyForkBlockOnDisk_HeadPastForkCliqueEpochCheckpoint(t *testing.T) {
	// Stronger failure mode: the on-disk block at PGB has Extra > 97 (looks
	// Parlia-shaped) but Coinbase == zero, the unique invariant of a Clique
	// epoch checkpoint. This is what Copilot review #3222179622 flagged —
	// without the Coinbase check, this scenario would silently pass and the
	// engine would boot into a broken Parlia snapshot.
	cfg := dualConfig()
	cfg.ParliaGenesisBlock = big.NewInt(16)

	head := parliaForkHeader(20, 3)
	// Looks Parlia-shaped (Extra > 97) but Coinbase=zero → Clique checkpoint.
	bad := header(16, extraVanity+3*common.AddressLength+extraSeal)
	// Coinbase already zero by default.

	err := VerifyForkBlockOnDisk(cfg, head, func(n uint64) *types.Header {
		if n == 16 {
			return bad
		}
		return nil
	})
	if err == nil {
		t.Fatalf("expected refuse-to-start error for Clique epoch checkpoint at fork height")
	}
	msg := err.Error()
	for _, want := range []string{
		"refusing to start",
		"epoch checkpoint",
		"Coinbase=zero",
		"ParliaGenesisBlock=16",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("error message missing %q\nfull message:\n%s", want, msg)
		}
	}
}

func TestVerifyForkBlockOnDisk_PgbZeroNoUnderflow(t *testing.T) {
	// Copilot review #3222179654: if PGB=0 (only via misconfigured override),
	// the recovery hint must not say "roll back to height 18446744073709551615"
	// because of uint underflow. The error must still mention "refusing to
	// start" and must NOT contain the giant underflow number.
	cfg := dualConfig()
	cfg.ParliaGenesisBlock = big.NewInt(0)

	head := parliaForkHeader(5, 3)
	bad := header(0, extraVanity+extraSeal) // Clique-form at "fork" height 0

	err := VerifyForkBlockOnDisk(cfg, head, func(n uint64) *types.Header {
		if n == 0 {
			return bad
		}
		return nil
	})
	if err == nil {
		t.Fatalf("expected refuse-to-start error when fork-block at PGB=0 is Clique-form")
	}
	msg := err.Error()
	if !strings.Contains(msg, "refusing to start") {
		t.Errorf("error message missing refusal phrase; got: %s", msg)
	}
	// pgbU-1 with pgbU=0 underflows to 18446744073709551615; that must not appear.
	if strings.Contains(msg, "18446744073709551615") {
		t.Errorf("error message contains uint underflow value (pgbU-1 with PGB=0); got:\n%s", msg)
	}
	// The PGB=0 branch prints a textual "N-1" instead of a number; check we
	// took that branch.
	if !strings.Contains(msg, "PGB=0 has no pre-fork block") {
		t.Errorf("expected PGB=0 branch's explanatory text; got:\n%s", msg)
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
