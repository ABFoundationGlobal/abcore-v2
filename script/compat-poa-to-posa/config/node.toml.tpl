# node-clique.toml.tpl — Clique PoA phase node configuration.
# Placeholders replaced by 01-setup.sh:
#   {{CHAIN_ID}}, {{DATADIR}}, {{P2P_PORT}}, {{AUTH_PORT}},
#   {{CLIQUE_PERIOD}}, {{CLIQUE_EPOCH}}

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
