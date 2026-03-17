package parliagenesis

import _ "embed"

// Bytecode for all system contracts injected at ParliaGenesisBlock.
// Fill each file with the compiled hex bytecode before deploying.
var (
	//go:embed ValidatorContract
	ValidatorContract string
	//go:embed SlashContract
	SlashContract string
	//go:embed SystemRewardContract
	SystemRewardContract string
	//go:embed LightClientContract
	LightClientContract string
	//go:embed TokenHubContract
	TokenHubContract string
	//go:embed RelayerIncentivizeContract
	RelayerIncentivizeContract string
	//go:embed RelayerHubContract
	RelayerHubContract string
	//go:embed GovHubContract
	GovHubContract string
	//go:embed TokenManagerContract
	TokenManagerContract string
	//go:embed CrossChainContract
	CrossChainContract string
	//go:embed StakingContract
	StakingContract string
	//go:embed StakeHubContract
	StakeHubContract string
	//go:embed StakeCreditContract
	StakeCreditContract string
	//go:embed GovernorContract
	GovernorContract string
	//go:embed GovTokenContract
	GovTokenContract string
	//go:embed TimelockContract
	TimelockContract string
	//go:embed TokenRecoverPortalContract
	TokenRecoverPortalContract string
)
