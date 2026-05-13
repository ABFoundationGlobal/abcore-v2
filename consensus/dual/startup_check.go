// Copyright 2026 The ABCore Authors
//
// This file is part of the go-ethereum library (ABCore fork).
//
// Licensed under the GNU Lesser General Public License, see LICENSE.

package dual

import (
	"fmt"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/params"
)

// Constants mirror the Parlia / Clique extraData layout. They are duplicated
// from consensus/parlia and consensus/clique to avoid importing those packages
// just for two ints (and to keep this check legible without engine internals).
const (
	extraVanity = 32 // header.Extra prefix reserved for signer vanity
	extraSeal   = 65 // header.Extra suffix reserved for signer seal/signature
)

// VerifyForkBlockOnDisk asserts that, if the on-disk chain has reached the
// ParliaGenesisBlock fork point, the stored block at the fork height is a
// Parlia-form block (i.e. its extraData is longer than a pure Clique block's).
//
// This catches the "stop-window race" failure mode: an operator running
// pre-fork validators with PGB=nil, then attempting a stop-all/restart-all
// cutover to PGB=N, can race a Clique-form block at height N onto disk
// before the SIGTERM lands. After restart with PGB=N, that same block is
// reinterpreted under Parlia rules and fails errInvalidSpanValidators —
// the chain deadlocks at height N forever.
//
// See:
//   - docs/ops/fork-cutover-runbook.md (production SOP and prevention)
//   - docs/ops/consensus-switch-rollback-runbook.md (recovery via setHead)
//   - .claude/research/fork-block-seal-deadlock.md (root-cause analysis)
//
// The function is a defense-in-depth guard: even if the operational SOP is
// not followed, the engine refuses to start with a corrupted on-disk fork
// block instead of silently coming up with a broken Parlia snapshot cache
// that will never produce a sealable header.
//
// It is a no-op for chains that are not in the ABCore Clique→Parlia
// dual-consensus configuration, or that have not yet reached the fork
// height. It must be called after the blockchain has loaded its head and
// before any sealing or peer-to-peer activity begins.
//
// chainConfig is the chain config in effect (already with any
// OverrideParliaGenesisBlock applied). headerByNumber is typically
// blockchain.GetHeaderByNumber, but the dependency is decoupled to keep
// this package free of core imports.
func VerifyForkBlockOnDisk(
	chainConfig *params.ChainConfig,
	currentHead *types.Header,
	headerByNumber func(uint64) *types.Header,
) error {
	// Only applies to the Clique+Parlia dual chain (ABCore mainnet/testnet
	// and the local devnet). Pure Clique or pure BSC chains are unaffected.
	if chainConfig == nil || !chainConfig.HasCliqueAndParlia() {
		return nil
	}
	pgb := chainConfig.ParliaGenesisBlock
	if pgb == nil {
		// Phase 1 deployment: PGB has not been scheduled yet, the chain is
		// pure Clique. No fork-block invariant to check.
		return nil
	}
	if currentHead == nil {
		// Genesis-only chain or fresh init; nothing on disk yet beyond
		// genesis itself. The genesis block is always height 0 and never
		// the fork block in any current ABCore configuration.
		return nil
	}
	pgbU := pgb.Uint64()
	if currentHead.Number.Uint64() < pgbU {
		// Chain has not reached the fork yet. Even if the head block
		// shape were wrong (it can't be — head < PGB means it's a
		// pre-fork Clique block, which is correct), the failure mode
		// this function targets has not been triggered.
		return nil
	}

	forkBlock := headerByNumber(pgbU)
	if forkBlock == nil {
		// Should not happen — head ≥ PGB implies the database has a
		// header at PGB. Surface this as a clear startup error rather
		// than continuing with an inconsistent chain view.
		return fmt.Errorf("dual-consensus startup check: head is at #%d (≥ ParliaGenesisBlock=%d) but the database has no header at #%d; chaindb is inconsistent",
			currentHead.Number.Uint64(), pgbU, pgbU)
	}

	// Distinguish Clique-form from Parlia-form at the fork height.
	//
	// Parlia fork-block extraData (pre-Luban): vanity(32) + validators(N×20) + seal(65).
	// Coinbase = the recovered signer address (a real validator, non-zero).
	//
	// Clique extraData has two valid shapes:
	//   (a) Normal Clique block:                     vanity(32) + seal(65) = 97 bytes
	//   (b) Clique epoch/checkpoint block (block#%Epoch==0):
	//                                                vanity(32) + signers(N×20) + seal(65),
	//                                                AND Coinbase MUST be zero
	//                                                (consensus/clique/clique.go:261-263).
	//
	// Therefore "Clique-form" iff EITHER:
	//   - len(Extra) == 97 (case a), OR
	//   - len(Extra) > 97 AND Coinbase == zero address (case b).
	// Otherwise (len > 97, Coinbase != zero) → Parlia-form, pass.
	//
	// Without the Coinbase check, a Clique epoch boundary that happens to
	// coincide with the fork height (or that lands at the fork height by
	// the same stop-window race) would be silently accepted because its
	// Extra length matches Parlia's layout, and the engine would then
	// boot into a broken Parlia snapshot. See T-4 (PR #70,
	// 93-run-clique-epoch-fork-test.sh) for the exact scenario.
	cliqueForm := false
	cliqueReason := ""
	switch {
	case len(forkBlock.Extra) == extraVanity+extraSeal:
		cliqueForm = true
		cliqueReason = fmt.Sprintf("Clique-form extraData (length=%d bytes, no validator list)", len(forkBlock.Extra))
	case forkBlock.Coinbase == (common.Address{}):
		cliqueForm = true
		cliqueReason = fmt.Sprintf("Clique-form epoch checkpoint (length=%d bytes, Coinbase=zero)", len(forkBlock.Extra))
	}
	if cliqueForm {
		// Build the recovery hint. PGB=0 is not currently used by any chain
		// config (mainnet/testnet/devnet all have PGB > 0 or PGB=nil), but a
		// misconfigured override could set it; in that case there is no
		// "previous Clique block" to roll back to, so omit the suggested
		// height instead of printing pgbU-1 (which would underflow to a huge
		// number and obscure the real problem).
		recoveryLine := "  Recovery: roll back the chain to height N-1 (PGB=0 has no pre-fork block).\n"
		if pgbU > 0 {
			recoveryLine = fmt.Sprintf("  Recovery: roll back the chain to height %d and restart\n", pgbU-1)
		}
		return fmt.Errorf(
			"dual-consensus startup check: refusing to start.\n"+
				"  block #%d (hash=%s) is %s,\n"+
				"  but the chain config requires Parlia-form at this height\n"+
				"  (ParliaGenesisBlock=%d).\n"+
				"\n"+
				"  This indicates a stop-window race during fork cutover:\n"+
				"  Clique sealed one extra block at the fork height in the\n"+
				"  millisecond window between the cutover SIGTERM and process\n"+
				"  exit, before the new chain config took effect. The block\n"+
				"  was valid under the old config (PGB=nil) but is invalid\n"+
				"  under the new one (PGB=%d).\n"+
				"\n"+
				"%s"+
				"  with the new config. See:\n"+
				"    - docs/ops/consensus-switch-rollback-runbook.md\n"+
				"    - script/test/transition/96-run-rollback-drill.sh (T-1.6)\n"+
				"\n"+
				"  Prevention (next time): use the rolling-cutover SOP in\n"+
				"  docs/ops/fork-cutover-runbook.md. Do NOT stop-all-then-\n"+
				"  restart-all near the fork height.",
			pgbU, forkBlock.Hash().Hex(), cliqueReason, pgbU, pgbU, recoveryLine)
	}

	return nil
}
