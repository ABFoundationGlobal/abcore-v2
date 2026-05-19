package systemcontracts

import (
	"context"
	"crypto/sha256"
	"log/slog"
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/state"
	"github.com/ethereum/go-ethereum/core/vm"
	gethlog "github.com/ethereum/go-ethereum/log"
	"github.com/ethereum/go-ethereum/params"
	"github.com/stretchr/testify/require"
)

func TestAllCodesHash(t *testing.T) {
	upgradesList := [13]map[string]*Upgrade{
		ramanujanUpgrade,
		nielsUpgrade,
		mirrorUpgrade,
		brunoUpgrade,
		eulerUpgrade,
		gibbsUpgrade,
		moranUpgrade,
		planckUpgrade,
		lubanUpgrade,
		platoUpgrade,
		keplerUpgrade,
		feynmanUpgrade,
		feynmanFixUpgrade}

	allCodes := make([]byte, 0, 10_000_000)
	for _, hardfork := range upgradesList {
		for _, network := range []string{mainNet, chapelNet} {
			allCodes = append(allCodes, []byte(network)...)
			if hardfork[network] != nil {
				for _, addressConfig := range hardfork[network].Configs {
					allCodes = append(allCodes, addressConfig.ContractAddr[:]...)
					allCodes = append(allCodes, addressConfig.Code[:]...)
				}
			}
		}
	}
	allCodeHash := sha256.Sum256(allCodes)
	require.Equal(t, allCodeHash[:], common.Hex2Bytes("833cc0fc87c46ad8a223e44ccfdc16a51a7e7383525136441bd0c730f06023df"))
}

func TestUpgradeBuildInSystemContractNilInterface(t *testing.T) {
	var (
		config               = params.BSCChainConfig
		blockNumber          = big.NewInt(37959559)
		lastBlockTime uint64 = 1713419337
		blockTime     uint64 = 1713419340
		statedb       vm.StateDB
	)

	GenesisHash = params.BSCGenesisHash

	upgradeBuildInSystemContract(config, blockNumber, lastBlockTime, blockTime, statedb)
}

func TestUpgradeBuildInSystemContractNilValue(t *testing.T) {
	var (
		config                   = params.BSCChainConfig
		blockNumber              = big.NewInt(37959559)
		lastBlockTime uint64     = 1713419337
		blockTime     uint64     = 1713419340
		statedb       vm.StateDB = (*state.StateDB)(nil)
	)

	GenesisHash = params.BSCGenesisHash

	upgradeBuildInSystemContract(config, blockNumber, lastBlockTime, blockTime, statedb)
}

// recordingHandler is a slog.Handler that captures every Record's message
// for assertion. Used by TestUpgradeBuildInSystemContractABCoreEarlyReturn
// below to confirm that ABCore networks short-circuit before the
// per-fork applySystemContractUpgrade(nil, ...) path can log
// "Empty upgrade config".
type recordingHandler struct {
	records []slog.Record
}

func (h *recordingHandler) Enabled(_ context.Context, _ slog.Level) bool { return true }
func (h *recordingHandler) Handle(_ context.Context, r slog.Record) error {
	h.records = append(h.records, r)
	return nil
}
func (h *recordingHandler) WithAttrs(_ []slog.Attr) slog.Handler { return h }
func (h *recordingHandler) WithGroup(_ string) slog.Handler      { return h }

// TestUpgradeBuildInSystemContractABCoreEarlyReturn pins the contract that
// upgradeBuildInSystemContract early-returns for the three ABCore networks
// (Main / Test / Devnet) before any per-fork applySystemContractUpgrade
// is invoked. ABCore deploys the final-version system-contract bytecode
// once at ParliaGenesisBlock (see parliaGenesisUpgrade[abcoreMainNet/...]
// and the "One-shot bytecode deployment" section in docs/ops/devnet-upgrade-plan.md);
// regressing this early return would re-introduce the misleading
// "Empty upgrade config network=Default" INFO noise at every fork block
// — and, worse, would expose ABCore state to BSC-mainnet hardfork
// bytecode payloads if any *Upgrade[defaultNet] entries are ever added.
//
// The test sets the global GenesisHash to each ABCore genesis hash, calls
// upgradeBuildInSystemContract at a block height that crosses every
// implemented hardfork, and asserts that the captured slog records
// contain no "Empty upgrade config" message. We use a far-future block
// number so every IsOnXxx gate would fire if the early return were
// removed.
func TestUpgradeBuildInSystemContractABCoreEarlyReturn(t *testing.T) {
	// Restore the global logger and GenesisHash after the test.
	prevHash := GenesisHash
	t.Cleanup(func() { GenesisHash = prevHash })

	abCoreCases := []struct {
		name string
		hash common.Hash
	}{
		{"ABCoreMainnet", params.ABCoreMainGenesisHash},
		{"ABCoreTestnet", params.ABCoreTestGenesisHash},
		{"ABCoreDevnet", params.ABCoreDevnetGenesisHash},
	}

	// Pick a block far enough in the future that every IsOnXxx (Ramanujan
	// through Plato) would trip if the early return were absent. The value
	// is irrelevant beyond crossing all block-height-based forks; chain
	// config is BSC's because we're only exercising upgradeBuildInSystemContract's
	// network-routing path, not its config-correctness.
	var (
		config               = params.BSCChainConfig
		blockNumber          = big.NewInt(1_000_000_000)
		lastBlockTime uint64 = 2_000_000_000
		blockTime     uint64 = 2_000_000_001
		statedb       vm.StateDB
	)

	for _, tc := range abCoreCases {
		t.Run(tc.name, func(t *testing.T) {
			GenesisHash = tc.hash

			handler := &recordingHandler{}
			gethlog.SetDefault(gethlog.NewLogger(handler))

			upgradeBuildInSystemContract(config, blockNumber, lastBlockTime, blockTime, statedb)

			for _, r := range handler.records {
				if strings.Contains(r.Message, "Empty upgrade config") {
					t.Fatalf("%s: unexpected log %q at block %d — upgradeBuildInSystemContract should early-return for ABCore networks, leaving the per-fork applySystemContractUpgrade(nil, ...) path unreachable",
						tc.name, r.Message, blockNumber.Int64())
				}
			}
		})
	}
}
