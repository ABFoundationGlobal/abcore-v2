GENESIS_CONTRACT_REPO := https://github.com/bnb-chain/bsc-genesis-contract.git
GENESIS_CONTRACT_TAG  := v1.2.5
GENESIS_CONTRACT_DIR  := bsc-genesis-contract
PARLIA_DIR            := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
FORGE                 := $(or $(shell which forge 2>/dev/null),$(HOME)/.foundry/bin/forge)
POETRY                := $(or $(shell which poetry 2>/dev/null),$(HOME)/.local/bin/poetry)
# Python 3.10–3.13 required; rpds-py does not support Python 3.14+
PYTHON                := $(or \
	$(shell which python3.13 2>/dev/null), \
	$(shell which python3.12 2>/dev/null), \
	$(shell which python3.11 2>/dev/null), \
	$(shell which python3.10 2>/dev/null))

# ---- Chain parameters ----
# Edit these values or override on the command line.
# Values containing spaces must be quoted:
#   make build CHAIN_ID=1234 BLOCK_INTERVAL="5 seconds"
CHAIN_ID                       ?= 714
MAX_ELECTED_VALIDATORS         ?= 3
BLOCK_INTERVAL                 ?= 3 seconds
BREATHE_BLOCK_INTERVAL         ?= 10 minutes
UNBOND_PERIOD                  ?= 2 minutes
DOWNTIME_JAIL_TIME             ?= 2 minutes
FELONY_JAIL_TIME               ?= 3 minutes
MISDEMEANOR_THRESHOLD          ?= 50
FELONY_THRESHOLD               ?= 150
FELONY_SLASH_SCOPE             ?= 60
INIT_BURN_RATIO                ?= 1000
STAKE_HUB_PROTECTOR            ?= address(0xdEaD)
GOVERNOR_PROTECTOR             ?= address(0xdEaD)
TOKEN_RECOVER_PORTAL_PROTECTOR ?= address(0xdEaD)
SOURCE_CHAIN_ID                ?= Binance-Chain-Ganges
INIT_VOTING_PERIOD             ?= 2 minutes / BLOCK_INTERVAL
INIT_MIN_PERIOD_AFTER_QUORUM   ?= uint64(1 minutes / BLOCK_INTERVAL)
INIT_MINIMAL_DELAY             ?= 1 minutes

.PHONY: pre build recover

## Clone bsc-genesis-contract and install dependencies
pre:
	@if [ -z "$(PYTHON)" ]; then \
		echo "Error: python3.13 / 3.12 / 3.11 / 3.10 not found. Install one of them first (rpds-py does not support Python 3.14+)."; \
		exit 1; \
	fi
	@if [ ! -d "$(GENESIS_CONTRACT_DIR)" ]; then \
		git clone --branch $(GENESIS_CONTRACT_TAG) $(GENESIS_CONTRACT_REPO) $(GENESIS_CONTRACT_DIR); \
	else \
		actual_tag=$$(cd $(GENESIS_CONTRACT_DIR) && git describe --tags --exact-match 2>/dev/null || echo "unknown"); \
		if [ "$$actual_tag" != "$(GENESIS_CONTRACT_TAG)" ]; then \
			echo "Error: $(GENESIS_CONTRACT_DIR) is at tag '$$actual_tag', expected '$(GENESIS_CONTRACT_TAG)'. Remove the directory and re-run 'make pre'."; \
			exit 1; \
		fi; \
		echo "$(GENESIS_CONTRACT_DIR) already at $(GENESIS_CONTRACT_TAG), skipping clone"; \
	fi
	cd $(GENESIS_CONTRACT_DIR) && npm install
	@if [ ! -d "$(GENESIS_CONTRACT_DIR)/lib/forge-std" ]; then \
		cd $(GENESIS_CONTRACT_DIR) && $(FORGE) install foundry-rs/forge-std --no-git; \
	else \
		echo "forge-std already installed, skipping"; \
	fi
	@if ! command -v poetry > /dev/null 2>&1 && [ ! -f "$(HOME)/.local/bin/poetry" ]; then \
		curl -sSL https://install.python-poetry.org | $(PYTHON) -; \
	fi
	cd $(GENESIS_CONTRACT_DIR) && $(POETRY) env use $(PYTHON) && $(POETRY) install

## Generate contracts with chain parameters and extract deployedBytecode into this directory.
## Edit validators.conf and chain parameters above before running.
build:
	@[ -f "$(PARLIA_DIR)validators.conf" ] || { \
		echo "Error: validators.conf not found. Copy validators.conf.example and fill in your validators."; \
		exit 1; \
	}
	@[ -d "$(GENESIS_CONTRACT_DIR)/node_modules" ] || { \
		echo "Error: bsc-genesis-contract not prepared. Run 'make pre' first."; \
		exit 1; \
	}
	cp $(PARLIA_DIR)validators.conf $(GENESIS_CONTRACT_DIR)/validators.conf
	cd $(GENESIS_CONTRACT_DIR) && $(POETRY) run python -m scripts.generate generate-validators
	cd $(GENESIS_CONTRACT_DIR) && { \
		PATH="$(dir $(FORGE)):$$PATH" $(POETRY) run python -m scripts.generate dev \
			--dev-chain-id $(CHAIN_ID) \
			--block-interval "$(BLOCK_INTERVAL)" \
			--breathe-block-interval "$(BREATHE_BLOCK_INTERVAL)" \
			--max-elected-validators "$(MAX_ELECTED_VALIDATORS)" \
			--unbond-period "$(UNBOND_PERIOD)" \
			--downtime-jail-time "$(DOWNTIME_JAIL_TIME)" \
			--felony-jail-time "$(FELONY_JAIL_TIME)" \
			--misdemeanor-threshold "$(MISDEMEANOR_THRESHOLD)" \
			--felony-threshold "$(FELONY_THRESHOLD)" \
			--init-felony-slash-scope "$(FELONY_SLASH_SCOPE)" \
			--init-burn-ratio "$(INIT_BURN_RATIO)" \
			--stake-hub-protector "$(STAKE_HUB_PROTECTOR)" \
			--governor-protector "$(GOVERNOR_PROTECTOR)" \
			--token-recover-portal-protector "$(TOKEN_RECOVER_PORTAL_PROTECTOR)" \
			--source-chain-id "$(SOURCE_CHAIN_ID)" \
			--init-voting-period "$(INIT_VOTING_PERIOD)" \
			--init-min-period-after-quorum "$(INIT_MIN_PERIOD_AFTER_QUORUM)" \
			--init-minimal-delay "$(INIT_MINIMAL_DELAY)"; \
		exit_code=$$?; \
		$(POETRY) run python -m scripts.generate recover; \
		exit $$exit_code; \
	}
	@pairs=" \
		ValidatorContract:BSCValidatorSet.sol/BSCValidatorSet \
		SlashContract:SlashIndicator.sol/SlashIndicator \
		SystemRewardContract:SystemReward.sol/SystemReward \
		LightClientContract:TendermintLightClient.sol/TendermintLightClient \
		TokenHubContract:TokenHub.sol/TokenHub \
		RelayerIncentivizeContract:RelayerIncentivize.sol/RelayerIncentivize \
		RelayerHubContract:RelayerHub.sol/RelayerHub \
		GovHubContract:GovHub.sol/GovHub \
		TokenManagerContract:TokenManager.sol/TokenManager \
		CrossChainContract:CrossChain.sol/CrossChain \
		StakingContract:Staking.sol/Staking \
		StakeHubContract:StakeHub.sol/StakeHub \
		StakeCreditContract:StakeCredit.sol/StakeCredit \
		GovernorContract:BSCGovernor.sol/BSCGovernor \
		GovTokenContract:GovToken.sol/GovToken \
		TimelockContract:BSCTimelock.sol/BSCTimelock \
		TokenRecoverPortalContract:TokenRecoverPortal.sol/TokenRecoverPortal \
	"; \
	for pair in $$pairs; do \
		file=$${pair%%:*}; \
		artifact=$${pair##*:}; \
		bytecode=$$(jq -re '.deployedBytecode.object' \
			"$(GENESIS_CONTRACT_DIR)/out/$${artifact}.json" 2>/dev/null) || { \
			echo "Error: failed to extract bytecode for $${file} from $${artifact}.json"; \
			exit 1; \
		}; \
		bytecode=$${bytecode#0x}; \
		[ -n "$$bytecode" ] || { \
			echo "Error: empty bytecode for $${file}"; \
			exit 1; \
		}; \
		printf '%s' "$$bytecode" > "$(PARLIA_DIR)$${file}"; \
		echo "Written $${file}"; \
	done

## Restore contract source files if a previous build was interrupted
recover:
	cd $(GENESIS_CONTRACT_DIR) && $(POETRY) run python -m scripts.generate recover
