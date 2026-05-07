// Copyright 2026 The ABCore Authors
//
// This file is part of the go-ethereum library (ABCore fork).
//
// Licensed under the GNU Lesser General Public License, see LICENSE.

package dual

import (
	"fmt"

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

	// Parlia fork-block extraData layout (pre-Luban): vanity(32) +
	// validators(N×20 bytes) + seal(65). With at least one validator,
	// length > extraVanity + extraSeal = 97. A pure Clique block's
	// extraData is exactly extraVanity + extraSeal = 97 (no validator
	// list). Therefore len(Extra) == 97 at the fork height is sufficient
	// proof that the block was sealed under Clique rules and persisted
	// before the chain config switched to PGB=N.
	if len(forkBlock.Extra) == extraVanity+extraSeal {
		return fmt.Errorf(
			"dual-consensus startup check: refusing to start.\n"+
				"  block #%d (hash=%s) has Clique-form extraData (length=%d bytes),\n"+
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
				"  Recovery: roll back the chain to height %d and restart\n"+
				"  with the new config. See:\n"+
				"    - docs/ops/consensus-switch-rollback-runbook.md\n"+
				"    - script/test/transition/96-run-rollback-drill.sh (T-1.6)\n"+
				"\n"+
				"  Prevention (next time): use the rolling-cutover SOP in\n"+
				"  docs/ops/fork-cutover-runbook.md. Do NOT stop-all-then-\n"+
				"  restart-all near the fork height.",
			pgbU, forkBlock.Hash().Hex(), len(forkBlock.Extra), pgbU, pgbU, pgbU-1)
	}

	return nil
}
