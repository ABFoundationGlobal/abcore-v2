package miner

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/params"
)

func TestGetBlockIntervalUsesCliquePeriodBeforeParliaGenesis(t *testing.T) {
	chainConfig := *params.ABCoreTestChainConfig
	chainConfig.ParliaGenesisBlock = big.NewInt(10)

	b := &bidSimulator{chainConfig: &chainConfig}
	parentHeader := &types.Header{Number: big.NewInt(8)}

	got := b.getBlockInterval(parentHeader)
	want := chainConfig.Clique.Period * 1000
	if got != want {
		t.Fatalf("unexpected block interval: want %d, got %d", want, got)
	}
}
