GENESIS_CONTRACT_REPO   ?= https://github.com/ABFoundationGlobal/abcore-v2-genesis-contract.git
GENESIS_CONTRACT_BRANCH := master
GENESIS_CONTRACT_COMMIT := 91fb231207f646661071a61edd5ca24a5e4cfb27
GENESIS_CONTRACT_DIR    := abcore-v2-genesis-contract
PARLIA_DIR            := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
FORGE                 := $(or $(shell which forge 2>/dev/null),$(HOME)/.foundry/bin/forge)
POETRY                := $(or $(shell which poetry 2>/dev/null),$(HOME)/.local/bin/poetry)
# Python 3.10–3.13 required; rpds-py does not support Python 3.14+
PYTHON                := $(or \
	$(shell which python3.13 2>/dev/null), \
	$(shell which python3.12 2>/dev/null), \
	$(shell which python3.11 2>/dev/null), \
	$(shell which python3.10 2>/dev/null))

# ---- Output sub-directory and generate.py command (set by each network target) ----
# Each environment directory must contain its own validators.conf.
# default/ validators are derived from default/keystores/; see default/README.md.
OUTDIR       ?= default
GENERATE_CMD ?= abchain-local

.PHONY: pre build mainnet testnet recover _build

## Clone abcore-v2-genesis-contract and install dependencies
pre:
	@if [ -z "$(PYTHON)" ]; then \
		echo "Error: python3.13 / 3.12 / 3.11 / 3.10 not found. Install one of them first (rpds-py does not support Python 3.14+)."; \
		exit 1; \
	fi
	@if [ ! -d "$(GENESIS_CONTRACT_DIR)" ]; then \
		git clone --branch $(GENESIS_CONTRACT_BRANCH) $(GENESIS_CONTRACT_REPO) $(GENESIS_CONTRACT_DIR); \
	else \
		actual_commit=$$(cd $(GENESIS_CONTRACT_DIR) && git rev-parse HEAD 2>/dev/null || echo "unknown"); \
		if [ "$$actual_commit" = "unknown" ]; then \
			echo "Error: $(GENESIS_CONTRACT_DIR) exists but is not a git repository. Remove it and re-run 'make pre'."; \
			exit 1; \
		fi; \
	fi
	@actual_commit=$$(cd $(GENESIS_CONTRACT_DIR) && git rev-parse HEAD); \
	if [ "$$actual_commit" != "$(GENESIS_CONTRACT_COMMIT)" ]; then \
		echo "Pinning $(GENESIS_CONTRACT_DIR) to $(GENESIS_CONTRACT_COMMIT)..."; \
		cd $(GENESIS_CONTRACT_DIR) && git fetch origin && git checkout $(GENESIS_CONTRACT_COMMIT); \
	else \
		echo "$(GENESIS_CONTRACT_DIR) already at pinned commit $(GENESIS_CONTRACT_COMMIT)"; \
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

## Generate contracts for ABCore mainnet (chain ID 36888) → mainnet/
mainnet: OUTDIR = mainnet
mainnet: GENERATE_CMD = abchain-main
mainnet: _build

## Generate contracts for ABCore testnet (chain ID 26888) → testnet/
testnet: OUTDIR = testnet
testnet: GENERATE_CMD = abchain-test
testnet: _build

## Generate contracts with local development parameters → default/
build: OUTDIR = default
build: GENERATE_CMD = abchain-local
build: _build

## Internal: compile contracts and extract deployedBytecode into $(PARLIA_DIR)$(OUTDIR)/
_build:
	@[ -f "$(PARLIA_DIR)$(OUTDIR)/validators.conf" ] || { \
		echo "Error: $(OUTDIR)/validators.conf not found. Create it with your validator addresses (see validators.conf.example)."; \
		exit 1; \
	}
	@[ -d "$(GENESIS_CONTRACT_DIR)/node_modules" ] || { \
		echo "Error: abcore-v2-genesis-contract not prepared. Run 'make pre' first."; \
		exit 1; \
	}
	mkdir -p "$(PARLIA_DIR)$(OUTDIR)"
	cp $(PARLIA_DIR)$(OUTDIR)/validators.conf $(GENESIS_CONTRACT_DIR)/validators.conf
	cd $(GENESIS_CONTRACT_DIR) && $(POETRY) run python -m scripts.generate generate-validators
	cd $(GENESIS_CONTRACT_DIR) && { \
		PATH="$(dir $(FORGE)):$$PATH" $(POETRY) run python -m scripts.generate $(GENERATE_CMD); \
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
		printf '%s' "$$bytecode" > "$(PARLIA_DIR)$(OUTDIR)/$${file}"; \
		echo "Written $(OUTDIR)/$${file}"; \
	done; \
	{ \
		echo "genesis_contract_repo:   $(GENESIS_CONTRACT_REPO)"; \
		echo "genesis_contract_commit: $(GENESIS_CONTRACT_COMMIT)"; \
		echo "generated_at:            $$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; \
		echo ""; \
		echo "# Build parameters"; \
		echo "OUTDIR:       $(OUTDIR)"; \
		echo "GENERATE_CMD: $(GENERATE_CMD)"; \
		echo ""; \
		echo "# SHA-256 checksums"; \
		for pair in $$pairs; do \
			file=$${pair%%:*}; \
			printf '%-38s %s\n' "$${file}" "$$(sha256sum "$(PARLIA_DIR)$(OUTDIR)/$${file}" | cut -d' ' -f1)"; \
		done; \
	} > "$(PARLIA_DIR)$(OUTDIR)/MANIFEST"; \
	echo "Written $(OUTDIR)/MANIFEST"
	$(PYTHON) "$(PARLIA_DIR)extract-params.py" \
		"$(GENESIS_CONTRACT_DIR)/scripts/generate.py" \
		"$(GENERATE_CMD)" \
		> "$(PARLIA_DIR)$(OUTDIR)/params.env"
	@echo "Written $(OUTDIR)/params.env"

## Restore contract source files if a previous build was interrupted
recover:
	cd $(GENESIS_CONTRACT_DIR) && $(POETRY) run python -m scripts.generate recover
