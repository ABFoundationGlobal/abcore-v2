# node-posa.toml.tpl — Parlia PoSA upgrade phase node configuration.
# Extends node-clique.toml.tpl with all block/time fork overrides.
# Placeholders replaced by 01-setup.sh:
#   {{CHAIN_ID}}, {{DATADIR}}, {{P2P_PORT}}, {{AUTH_PORT}},
#   {{CLIQUE_PERIOD}}, {{CLIQUE_EPOCH}},
#   {{PARLIA_GENESIS_BLOCK}}, {{TIME_FORK_TIME}}

[Eth]
NetworkId = {{CHAIN_ID}}
SyncMode = "full"
EthDiscoveryURLs = []
SnapDiscoveryURLs = []
NoPruning = false
NoPrefetch = false
TxLookupLimit = 0
DatabaseCache = 256
TrieCleanCache = 75
TrieDirtyCache = 128
SnapshotCache = 64
Preimages = false
FilterLogCacheSize = 32
RPCGasCap = 50000000
RPCEVMTimeout = 5000000000
RPCTxFeeCap = 10.0

[Eth.Miner]
GasFloor = 0
GasCeil = 21000000
GasPrice = 1000000000
Recommit = 2000000000

[Eth.TxPool]
Locals = []
NoLocals = true
Journal = "transactions.rlp"
Rejournal = 3600000000000
PriceLimit = 1000000000
PriceBump = 10
AccountSlots = 64
GlobalSlots = 4096
AccountQueue = 64
GlobalQueue = 1024
Lifetime = 10800000000000

[Node]
DataDir = "{{DATADIR}}"
NoUSB = true
IPCPath = "geth.ipc"
HTTPHost = "127.0.0.1"
HTTPPort = 0
WSHost = ""
WSPort = 0
AuthAddr = "127.0.0.1"
AuthPort = {{AUTH_PORT}}
AuthVirtualHosts = ["localhost"]

[Node.P2P]
MaxPeers = 10
NoDiscovery = true
BootstrapNodes = []
StaticNodes = []
TrustedNodes = []
ListenAddr = ":{{P2P_PORT}}"
EnableMsgEvents = false

# Chain config upgrade: all block-based forks activate at PARLIA_GENESIS_BLOCK,
# all time-based forks activate at TIME_FORK_TIME.
# The Clique section is retained because the chain started as Clique; it is still
# needed for blocks before ParliaGenesisBlock.
[Eth.Genesis.Config]
ChainID = {{CHAIN_ID}}
LondonBlock = {{PARLIA_GENESIS_BLOCK}}
ArrowGlacierBlock = {{PARLIA_GENESIS_BLOCK}}
GrayGlacierBlock = {{PARLIA_GENESIS_BLOCK}}
RamanujanBlock = {{PARLIA_GENESIS_BLOCK}}
NielsBlock = {{PARLIA_GENESIS_BLOCK}}
MirrorSyncBlock = {{PARLIA_GENESIS_BLOCK}}
BrunoBlock = {{PARLIA_GENESIS_BLOCK}}
EulerBlock = {{PARLIA_GENESIS_BLOCK}}
GibbsBlock = {{PARLIA_GENESIS_BLOCK}}
NanoBlock = {{PARLIA_GENESIS_BLOCK}}
MoranBlock = {{PARLIA_GENESIS_BLOCK}}
PlanckBlock = {{PARLIA_GENESIS_BLOCK}}
LubanBlock = {{PARLIA_GENESIS_BLOCK}}
PlatoBlock = {{PARLIA_GENESIS_BLOCK}}
HertzBlock = {{PARLIA_GENESIS_BLOCK}}
HertzfixBlock = {{PARLIA_GENESIS_BLOCK}}
ParliaGenesisBlock = {{PARLIA_GENESIS_BLOCK}}
ShanghaiTime = {{TIME_FORK_TIME}}
KeplerTime = {{TIME_FORK_TIME}}
FeynmanTime = {{TIME_FORK_TIME}}
FeynmanFixTime = {{TIME_FORK_TIME}}
CancunTime = {{TIME_FORK_TIME}}
HaberTime = {{TIME_FORK_TIME}}
HaberFixTime = {{TIME_FORK_TIME}}
BohrTime = {{TIME_FORK_TIME}}
PascalTime = {{TIME_FORK_TIME}}
PragueTime = {{TIME_FORK_TIME}}
LorentzTime = {{TIME_FORK_TIME}}
MaxwellTime = {{TIME_FORK_TIME}}
FermiTime = {{TIME_FORK_TIME}}
OsakaTime = {{TIME_FORK_TIME}}
MendelTime = {{TIME_FORK_TIME}}
BPO1Time = {{TIME_FORK_TIME}}
BPO2Time = {{TIME_FORK_TIME}}
BPO3Time = {{TIME_FORK_TIME}}
BPO4Time = {{TIME_FORK_TIME}}
BPO5Time = {{TIME_FORK_TIME}}
AmsterdamTime = {{TIME_FORK_TIME}}
PasteurTime = {{TIME_FORK_TIME}}

[Eth.Genesis.Config.Clique]
Period = {{CLIQUE_PERIOD}}
Epoch = {{CLIQUE_EPOCH}}

# Non-nil Parlia section signals Parlia consensus is enabled after ParliaGenesisBlock.
[Eth.Genesis.Config.Parlia]
