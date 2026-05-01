#!/usr/bin/env bash
# lib.sh — shared helpers for the no-genesis test suite.
# Sources test/compat/lib.sh for all low-level helpers, then adds
# ABCore testnet (chain ID 26888) specific constants and port layout.

# Save our own script directory BEFORE sourcing compat lib.sh, which sets its
# own SCRIPT_DIR. We restore ours afterwards so callers get the no-genesis
# directory, not the compat directory.
_NG_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Source the shared helper library from the compat suite for all low-level
# helpers (wait_for_ipc, wait_for_same_head, find_free_port_base, etc.).
# shellcheck source=../compat/lib.sh
source "${_NG_SCRIPT_DIR}/../compat/lib.sh"

# Restore our own SCRIPT_DIR, REPO_ROOT and DATADIR_ROOT after compat lib.sh
# overwrote them.  DATADIR_ROOT must be reset here so port/path functions
# below resolve under the no-genesis data directory, not the compat one.
SCRIPT_DIR="${_NG_SCRIPT_DIR}"
REPO_ROOT=$(cd "${SCRIPT_DIR}/../../.." && pwd)
# Only override if not explicitly set by caller (99-run-all.sh sets it after
# PORT_BASE is selected).
DATADIR_ROOT=${DATADIR_ROOT:-"${SCRIPT_DIR}/data-${PORT_BASE}"}

# ---- ABCore testnet constants ----
ABCORE_CHAIN_ID=26888
ABCORE_NETWORK_ID=26888
ABCORE_PERIOD=1      # testnet clique period (1-second blocks)
ABCORE_EPOCH=30000

# ---- Port layout ----
# All port functions below are specific to this suite; they do not conflict
# with compat-clique-v1-v2 ports (which use 30310-30328 / 8540-8558).
# The 99-run-all.sh uses find_free_port_base (from compat lib.sh) to pick a
# safe base automatically. Individual scripts inherit PORT_BASE from the env.

# Scn1 nodes: v1 sync node, v2 no-genesis node
scn1_v1_p2p_port()    { echo $((30410 + PORT_BASE)); }
scn1_v1_datadir()     { echo "${DATADIR_ROOT}/scn1-v1"; }
scn1_v1_ipc()         { echo "${DATADIR_ROOT}/scn1-v1/geth.ipc"; }
scn1_v1_log()         { echo "${DATADIR_ROOT}/scn1-v1/geth.log"; }
scn1_v1_pid()         { echo "${DATADIR_ROOT}/scn1-v1/geth.pid"; }

scn1_v2_p2p_port()    { echo $((30411 + PORT_BASE)); }
scn1_v2_datadir()     { echo "${DATADIR_ROOT}/scn1-v2"; }
scn1_v2_ipc()         { echo "${DATADIR_ROOT}/scn1-v2/geth.ipc"; }
scn1_v2_log()         { echo "${DATADIR_ROOT}/scn1-v2/geth.log"; }
scn1_v2_pid()         { echo "${DATADIR_ROOT}/scn1-v2/geth.pid"; }

# Scn2 nodes: v1 sync node, v2 validator
scn2_v1_p2p_port()    { echo $((30412 + PORT_BASE)); }
scn2_v1_datadir()     { echo "${DATADIR_ROOT}/scn2-v1"; }
scn2_v1_ipc()         { echo "${DATADIR_ROOT}/scn2-v1/geth.ipc"; }
scn2_v1_log()         { echo "${DATADIR_ROOT}/scn2-v1/geth.log"; }
scn2_v1_pid()         { echo "${DATADIR_ROOT}/scn2-v1/geth.pid"; }

scn2_v2_p2p_port()    { echo $((30413 + PORT_BASE)); }
scn2_v2_datadir()     { echo "${DATADIR_ROOT}/scn2-v2"; }
scn2_v2_ipc()         { echo "${DATADIR_ROOT}/scn2-v2/geth.ipc"; }
scn2_v2_log()         { echo "${DATADIR_ROOT}/scn2-v2/geth.log"; }
scn2_v2_pid()         { echo "${DATADIR_ROOT}/scn2-v2/geth.pid"; }

# Genesis file paths (written by 01-setup.sh).
# These are functions rather than variables so they always resolve against the
# current DATADIR_ROOT, even if DATADIR_ROOT is updated after lib.sh is sourced
# (as 99-run-all.sh does after selecting PORT_BASE).
testnet_genesis_json()       { echo "${DATADIR_ROOT}/testnet-genesis.json"; }
custom_genesis_json()        { echo "${DATADIR_ROOT}/custom-genesis.json"; }
scn2_validator_addr_file()   { echo "${DATADIR_ROOT}/scn2-validator/address.txt"; }
scn2_validator_pw_file()     { echo "${DATADIR_ROOT}/scn2-validator/password.txt"; }
