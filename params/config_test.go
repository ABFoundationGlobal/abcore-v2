// Copyright 2017 The go-ethereum Authors
// This file is part of the go-ethereum library.
//
// The go-ethereum library is free software: you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// The go-ethereum library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License
// along with the go-ethereum library. If not, see <http://www.gnu.org/licenses/>.

package params

import (
	"math"
	"math/big"
	"reflect"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/stretchr/testify/require"
)

func TestCheckCompatible(t *testing.T) {
	type test struct {
		stored, new   *ChainConfig
		headBlock     uint64
		headTimestamp uint64
		wantErr       *ConfigCompatError
	}
	tests := []test{
		{stored: AllEthashProtocolChanges, new: AllEthashProtocolChanges, headBlock: 0, headTimestamp: 0, wantErr: nil},
		{stored: AllEthashProtocolChanges, new: AllEthashProtocolChanges, headBlock: 0, headTimestamp: uint64(time.Now().Unix()), wantErr: nil},
		{stored: AllEthashProtocolChanges, new: AllEthashProtocolChanges, headBlock: 100, wantErr: nil},
		{
			stored:    &ChainConfig{EIP150Block: big.NewInt(10)},
			new:       &ChainConfig{EIP150Block: big.NewInt(20)},
			headBlock: 9,
			wantErr:   nil,
		},
		{
			stored:    AllEthashProtocolChanges,
			new:       &ChainConfig{HomesteadBlock: nil},
			headBlock: 3,
			wantErr: &ConfigCompatError{
				What:          "Homestead fork block",
				StoredBlock:   big.NewInt(0),
				NewBlock:      nil,
				RewindToBlock: 0,
			},
		},
		{
			stored:    AllEthashProtocolChanges,
			new:       &ChainConfig{HomesteadBlock: big.NewInt(1)},
			headBlock: 3,
			wantErr: &ConfigCompatError{
				What:          "Homestead fork block",
				StoredBlock:   big.NewInt(0),
				NewBlock:      big.NewInt(1),
				RewindToBlock: 0,
			},
		},
		{
			stored:    &ChainConfig{HomesteadBlock: big.NewInt(30), EIP150Block: big.NewInt(10)},
			new:       &ChainConfig{HomesteadBlock: big.NewInt(25), EIP150Block: big.NewInt(20)},
			headBlock: 25,
			wantErr: &ConfigCompatError{
				What:          "EIP150 fork block",
				StoredBlock:   big.NewInt(10),
				NewBlock:      big.NewInt(20),
				RewindToBlock: 9,
			},
		},
		{
			stored:    &ChainConfig{ConstantinopleBlock: big.NewInt(30)},
			new:       &ChainConfig{ConstantinopleBlock: big.NewInt(30), PetersburgBlock: big.NewInt(30)},
			headBlock: 40,
			wantErr:   nil,
		},
		{
			stored:    &ChainConfig{ConstantinopleBlock: big.NewInt(30)},
			new:       &ChainConfig{ConstantinopleBlock: big.NewInt(30), PetersburgBlock: big.NewInt(31)},
			headBlock: 40,
			wantErr: &ConfigCompatError{
				What:          "Petersburg fork block",
				StoredBlock:   nil,
				NewBlock:      big.NewInt(31),
				RewindToBlock: 30,
			},
		},
		{
			stored:        &ChainConfig{ShanghaiTime: newUint64(10)},
			new:           &ChainConfig{ShanghaiTime: newUint64(20)},
			headTimestamp: 9,
			wantErr:       nil,
		},
		{
			stored:        &ChainConfig{ShanghaiTime: newUint64(10)},
			new:           &ChainConfig{ShanghaiTime: newUint64(20)},
			headTimestamp: 25,
			wantErr: &ConfigCompatError{
				What:         "Shanghai fork timestamp",
				StoredTime:   newUint64(10),
				NewTime:      newUint64(20),
				RewindToTime: 9,
			},
		},
	}

	for _, test := range tests {
		err := test.stored.CheckCompatible(test.new, test.headBlock, test.headTimestamp)
		if !reflect.DeepEqual(err, test.wantErr) {
			t.Errorf("error mismatch:\nstored: %v\nnew: %v\nheadBlock: %v\nheadTimestamp: %v\nerr: %v\nwant: %v", test.stored, test.new, test.headBlock, test.headTimestamp, err, test.wantErr)
		}
	}
}

func TestConfigRules(t *testing.T) {
	c := &ChainConfig{
		LondonBlock:  new(big.Int),
		ShanghaiTime: newUint64(500),
	}
	var stamp uint64
	if r := c.Rules(big.NewInt(0), true, stamp); r.IsShanghai {
		t.Errorf("expected %v to not be shanghai", stamp)
	}
	stamp = 500
	if r := c.Rules(big.NewInt(0), true, stamp); !r.IsShanghai {
		t.Errorf("expected %v to be shanghai", stamp)
	}
	stamp = math.MaxInt64
	if r := c.Rules(big.NewInt(0), true, stamp); !r.IsShanghai {
		t.Errorf("expected %v to be shanghai", stamp)
	}
}

func TestGetBuiltInChainConfig_ABCore(t *testing.T) {
	// ABCore mainnet: genesis hash must resolve to the mainnet config.
	mainCfg := GetBuiltInChainConfig(ABCoreMainGenesisHash)
	require.NotNil(t, mainCfg, "ABCoreMainGenesisHash should resolve to a built-in config")
	require.Equal(t, int64(36888), mainCfg.ChainID.Int64(), "mainnet chain ID")
	require.NotNil(t, mainCfg.Clique, "mainnet Clique config must be set")
	require.Equal(t, uint64(3), mainCfg.Clique.Period, "mainnet Clique period")
	require.Equal(t, uint64(30000), mainCfg.Clique.Epoch, "mainnet Clique epoch")

	// ABCore testnet: genesis hash must resolve to the testnet config.
	testCfg := GetBuiltInChainConfig(ABCoreTestGenesisHash)
	require.NotNil(t, testCfg, "ABCoreTestGenesisHash should resolve to a built-in config")
	require.Equal(t, int64(26888), testCfg.ChainID.Int64(), "testnet chain ID")
	require.NotNil(t, testCfg.Clique, "testnet Clique config must be set")
	require.Equal(t, uint64(1), testCfg.Clique.Period, "testnet Clique period")
	require.Equal(t, uint64(30000), testCfg.Clique.Epoch, "testnet Clique epoch")

	// ABCore devnet: genesis hash must resolve to the devnet config.
	devCfg := GetBuiltInChainConfig(ABCoreDevnetGenesisHash)
	require.NotNil(t, devCfg, "ABCoreDevnetGenesisHash should resolve to a built-in config")
	require.Equal(t, int64(17140), devCfg.ChainID.Int64(), "devnet chain ID")
	require.NotNil(t, devCfg.Clique, "devnet Clique config must be set")
	require.Equal(t, uint64(3), devCfg.Clique.Period, "devnet Clique period")
	require.Equal(t, uint64(30000), devCfg.Clique.Epoch, "devnet Clique epoch")
	require.NotNil(t, devCfg.ParliaGenesisBlock, "devnet ParliaGenesisBlock is scheduled for Phase 2 cutover")
	require.Equal(t, int64(50000), devCfg.ParliaGenesisBlock.Int64(), "devnet ParliaGenesisBlock = 50000 (target activation 2026-05-14 ~08:00 UTC)")

	// Phase 3 (v0.3.0): LondonBlock + 13 BSC block forks all scheduled at the
	// same block 165400 (target activation 2026-05-18 ~08:00 UTC). Asserting
	// each field explicitly makes diffs and grep-by-field-name easy when the
	// schedule changes again. 165400 is a Parlia epoch boundary (% 200 == 0)
	// so the first Luban-form epoch block lands exactly on the fork.
	require.NotNil(t, devCfg.LondonBlock, "devnet LondonBlock is scheduled for v0.3.0")
	require.Equal(t, int64(165400), devCfg.LondonBlock.Int64(), "devnet LondonBlock = 165400")
	require.Equal(t, int64(165400), devCfg.RamanujanBlock.Int64(), "devnet RamanujanBlock = 165400")
	require.Equal(t, int64(165400), devCfg.NielsBlock.Int64(), "devnet NielsBlock = 165400")
	require.Equal(t, int64(165400), devCfg.MirrorSyncBlock.Int64(), "devnet MirrorSyncBlock = 165400")
	require.Equal(t, int64(165400), devCfg.BrunoBlock.Int64(), "devnet BrunoBlock = 165400")
	require.Equal(t, int64(165400), devCfg.EulerBlock.Int64(), "devnet EulerBlock = 165400")
	require.Equal(t, int64(165400), devCfg.GibbsBlock.Int64(), "devnet GibbsBlock = 165400")
	require.Equal(t, int64(165400), devCfg.NanoBlock.Int64(), "devnet NanoBlock = 165400")
	require.Equal(t, int64(165400), devCfg.MoranBlock.Int64(), "devnet MoranBlock = 165400")
	require.Equal(t, int64(165400), devCfg.PlanckBlock.Int64(), "devnet PlanckBlock = 165400")
	require.Equal(t, int64(165400), devCfg.LubanBlock.Int64(), "devnet LubanBlock = 165400")
	require.Equal(t, int64(165400), devCfg.PlatoBlock.Int64(), "devnet PlatoBlock = 165400")
	require.Equal(t, int64(165400), devCfg.HertzBlock.Int64(), "devnet HertzBlock = 165400")
	require.Equal(t, int64(165400), devCfg.HertzfixBlock.Int64(), "devnet HertzfixBlock = 165400")

	// An unknown genesis hash must return nil.
	require.Nil(t, GetBuiltInChainConfig(common.Hash{}), "unknown genesis hash should return nil")
}

// TestABCoreDevnetCompatWithLiveGenesis verifies that ABCoreDevnetChainConfig
// is forward-compatible with the chain config stored on the live devnet's
// chaindata. The stored config is derived from the inline genesis.json
// produced by devnet-ops/jenkins/Jenkinsfile.init at the "生成 genesis.json"
// stage (chain ID 17140, Clique period=3 epoch=30000, base forks at block 0
// including muirGlacierBlock=0, no BSC fork fields).
//
// When a V2 binary boots on a node whose chaindata was written by an earlier
// V2 init, the chainConfigOrDefault path (core/genesis.go) reads the stored
// config, then computes the new config from ABCoreDevnetGenesisHash, and
// calls storedCfg.CheckCompatible(newCfg, head, time). This test pins the
// contract: any future change to ABCoreDevnetChainConfig that would break
// this rolling upgrade path must fail this test.
//
// Note: This test now mirrors the post-reset state. Pre-reset chaindata
// (initialized before devnet-ops PR #4) has muirGlacierBlock unset; the
// rolling upgrade carrying THIS commit must NOT be deployed against such
// chaindata. See PR description for the required reset-then-upgrade order.
func TestABCoreDevnetCompatWithLiveGenesis(t *testing.T) {
	storedCfg := &ChainConfig{
		ChainID:             big.NewInt(17140),
		HomesteadBlock:      big.NewInt(0),
		EIP150Block:         big.NewInt(0),
		EIP155Block:         big.NewInt(0),
		EIP158Block:         big.NewInt(0),
		ByzantiumBlock:      big.NewInt(0),
		ConstantinopleBlock: big.NewInt(0),
		PetersburgBlock:     big.NewInt(0),
		IstanbulBlock:       big.NewInt(0),
		MuirGlacierBlock:    big.NewInt(0),
		BerlinBlock:         big.NewInt(0),
		Clique:              &CliqueConfig{Period: 3, Epoch: 30000},
	}
	// Use a non-zero head and time so CheckCompatible cannot trivially
	// shortcut on block-zero handling — this is the regime a real rolling
	// upgrade hits, where the chain has been producing blocks for hours.
	//
	// Head=10000 simulates "rolling upgrade happens well before the
	// scheduled ParliaGenesisBlock=50000". storedCfg has no ParliaGenesisBlock
	// field (omitempty in v1.13.15 genesis.json) — that's the forward-
	// scheduling case where the new config adds a fork ahead of head.
	// CheckCompatible must report no error: stored=nil → new=50000 with
	// head=10000 < 50000 means the fork hasn't been crossed yet, so changing
	// the value is always safe.
	if err := storedCfg.CheckCompatible(ABCoreDevnetChainConfig, 10_000, 1_700_000_000); err != nil {
		t.Fatalf("ABCoreDevnetChainConfig is not backward-compatible with the "+
			"stored config produced by devnet-ops/Jenkinsfile.init (post PR #4): %v", err)
	}

	// Sanity: also verify head=49000 (close to but still before PGB=50000)
	// produces no error. This is the realistic state during rolling-upgrade
	// just before crossing — Layer A test scripts + Layer B runbook + Layer C
	// engine check all gate on this exact moment. CheckCompatible must not
	// be the one that breaks here.
	if err := storedCfg.CheckCompatible(ABCoreDevnetChainConfig, 49_000, 1_700_000_000); err != nil {
		t.Fatalf("ABCoreDevnetChainConfig must remain compatible at head=49000 (just before PGB): %v", err)
	}

	// Phase 3 (v0.3.0) just-before-fork case: head=165000 is the realistic
	// rolling-upgrade window for the LondonBlock + 13 BSC forks cutover at
	// block 165400. The stored config here mirrors what's actually on disk
	// after the live devnet crossed PGB=50000 on 2026-05-14: the prior V2
	// binary already wrote `parliaGenesisBlock=50000` into the persisted
	// chain config. A new V2 binary booting at head=165000 sees that stored
	// config and must accept the additional LondonBlock+13 BSC forks as a
	// forward-scheduled compatible change (head < 165400). Timestamp is set
	// to ~2026-05-18 07:53 UTC, a few minutes before the projected fork
	// arrival, so the compat check sees a current post-PGB clock.
	storedCfgPostPGB := *storedCfg
	storedCfgPostPGB.ParliaGenesisBlock = big.NewInt(50_000)
	if err := storedCfgPostPGB.CheckCompatible(ABCoreDevnetChainConfig, 165_000, 1_779_080_000); err != nil {
		t.Fatalf("ABCoreDevnetChainConfig must remain compatible at head=165000 (just before LondonBlock=165400, post-PGB stored config): %v", err)
	}
}

func TestTimestampCompatError(t *testing.T) {
	require.Equal(t, new(ConfigCompatError).Error(), "")

	errWhat := "Shanghai fork timestamp"
	require.Equal(t, newTimestampCompatError(errWhat, nil, newUint64(1681338455)).Error(),
		"mismatching Shanghai fork timestamp in database (have timestamp nil, want timestamp 1681338455, rewindto timestamp 1681338454)")

	require.Equal(t, newTimestampCompatError(errWhat, newUint64(1681338455), nil).Error(),
		"mismatching Shanghai fork timestamp in database (have timestamp 1681338455, want timestamp nil, rewindto timestamp 1681338454)")

	require.Equal(t, newTimestampCompatError(errWhat, newUint64(1681338455), newUint64(600624000)).Error(),
		"mismatching Shanghai fork timestamp in database (have timestamp 1681338455, want timestamp 600624000, rewindto timestamp 600623999)")

	require.Equal(t, newTimestampCompatError(errWhat, newUint64(0), newUint64(1681338455)).Error(),
		"mismatching Shanghai fork timestamp in database (have timestamp 0, want timestamp 1681338455, rewindto timestamp 0)")
}
