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
	// Phase 2 cutover scheduled at block 1600 (target activation 2026-05-21
	// ~08:55 UTC). PGB itself is treated as an epoch boundary by Parlia
	// regardless of `PGB % epochLength` — see `IsOnParliaGenesis` branches
	// in `getValidatorBytesFromHeader` / `verifyHeader` in
	// consensus/parlia/parlia.go. So 200-grid alignment for PGB is an
	// operational convention, not a protocol invariant, and not asserted
	// here. Future non-PGB fork blocks (LubanBlock etc.) do need to land
	// on epoch boundaries; those should be guarded when they are scheduled.
	require.NotNil(t, devCfg.ParliaGenesisBlock, "devnet ParliaGenesisBlock must be scheduled")
	require.Equal(t, int64(1600), devCfg.ParliaGenesisBlock.Int64(), "devnet ParliaGenesisBlock = 1600 (Phase 2 cutover)")
	require.NotNil(t, devCfg.Parlia, "devnet Parlia config must be set")
	require.Equal(t, uint64(200), devCfg.Parlia.Epoch, "devnet Parlia.Epoch = 200 (BSC defaultEpochLength)")

	// Post devnet-reset baseline: all PGB-and-later forks are nil. They will be
	// re-scheduled incrementally per docs/ops/devnet-upgrade-plan.md. Asserting
	// each field is nil prevents accidental partial schedules (mismatched fork
	// orderings broke the v0.3.0 cutover plan once already; see §10 retro).
	require.Nil(t, devCfg.LondonBlock, "devnet LondonBlock must be nil pre-PGB")
	require.Nil(t, devCfg.RamanujanBlock, "devnet RamanujanBlock must be nil pre-PGB")
	require.Nil(t, devCfg.NielsBlock, "devnet NielsBlock must be nil pre-PGB")
	require.Nil(t, devCfg.MirrorSyncBlock, "devnet MirrorSyncBlock must be nil pre-PGB")
	require.Nil(t, devCfg.BrunoBlock, "devnet BrunoBlock must be nil pre-PGB")
	require.Nil(t, devCfg.EulerBlock, "devnet EulerBlock must be nil pre-PGB")
	require.Nil(t, devCfg.GibbsBlock, "devnet GibbsBlock must be nil pre-PGB")
	require.Nil(t, devCfg.NanoBlock, "devnet NanoBlock must be nil pre-PGB")
	require.Nil(t, devCfg.MoranBlock, "devnet MoranBlock must be nil pre-PGB")
	require.Nil(t, devCfg.PlanckBlock, "devnet PlanckBlock must be nil pre-PGB")
	require.Nil(t, devCfg.LubanBlock, "devnet LubanBlock must be nil pre-PGB")
	require.Nil(t, devCfg.PlatoBlock, "devnet PlatoBlock must be nil pre-PGB")
	require.Nil(t, devCfg.HertzBlock, "devnet HertzBlock must be nil pre-PGB")
	require.Nil(t, devCfg.HertzfixBlock, "devnet HertzfixBlock must be nil pre-PGB")

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
// Note: This test mirrors the post-reset state. The previous v0.2.0/v0.3.0
// schedules (PGB=50000 and LondonBlock+13 BSC forks=165400) were retired with
// the devnet reset; new schedules are added to ABCoreDevnetChainConfig per
// docs/ops/devnet-upgrade-plan.md and validated here once filled in.
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
	// head=500 < ParliaGenesisBlock=1600 simulates "rolling upgrade happens
	// well before the scheduled PGB". storedCfg has no ParliaGenesisBlock
	// field (omitempty in v1.13.15 genesis.json) — that's the forward-
	// scheduling case where the new config adds a fork ahead of head.
	// CheckCompatible must report no error: stored=nil → new=1600 with
	// head=500 < 1600 means the fork hasn't been crossed yet, so adding
	// the field is always safe.
	if err := storedCfg.CheckCompatible(ABCoreDevnetChainConfig, 500, 1_700_000_000); err != nil {
		t.Fatalf("ABCoreDevnetChainConfig is not backward-compatible with the "+
			"stored config produced by devnet-ops/Jenkinsfile.init (post-reset): %v", err)
	}

	// Sanity: also verify head=1500 (just before PGB=1600) produces no error.
	// This is the realistic state during rolling-upgrade just before the
	// cutover — Layer A test scripts + Layer B runbook + Layer C engine
	// check all gate on this exact moment.
	if err := storedCfg.CheckCompatible(ABCoreDevnetChainConfig, 1500, 1_700_000_000); err != nil {
		t.Fatalf("ABCoreDevnetChainConfig must remain compatible at head=1500 (just before PGB=1600): %v", err)
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
