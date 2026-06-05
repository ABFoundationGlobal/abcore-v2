#!/usr/bin/env bash
# diagnose-breathe-nonce.sh
#
# Analyses geth logs produced with GETH_VMODULE="txpool=5,parlia=5,state_processor=4"
# to investigate why changing StakeHub's BREATHE_BLOCK_INTERVAL from 1 day to 5 s
# causes user transactions to be dropped from the txpool.
#
# Usage:
#   # Run the drill with verbose logging enabled:
#   GETH_VERBOSITY=5 \
#   GETH_VMODULE="txpool=5,parlia=5,state_processor=4" \
#   GETH=./build/bin/geth \
#   bash script/test/upgrade-drill/99-run-all.sh
#
#   # Then analyse the captured logs:
#   bash script/test/upgrade-drill/diagnose-breathe-nonce.sh
#
# What it looks for:
#   1. System-transaction nonce increments  (parlia: applyTransaction → SetNonce)
#   2. Txpool drop/evict events             (txpool: Dropping / Discarding)
#   3. Breathe-block firing windows         (isBreatheBlock = true)
#   4. Nonce timeline for each validator    (nonce seen per address per block)
#   5. Correlation: tx submitted just before nonce-consuming breathe block

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib.sh"

LOGDIR="${DATADIR_ROOT}"
REPORT="${LOGDIR}/nonce-diagnosis-$(date +%Y%m%d-%H%M%S).txt"

echo "=== BREATHE-BLOCK / NONCE DIAGNOSIS ===" | tee "$REPORT"
echo "Log directory: ${LOGDIR}" | tee -a "$REPORT"
echo "Generated at:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

# ── 1. Breathe blocks ─────────────────────────────────────────────────────────
echo "=== 1. BREATHE BLOCKS (BAL=true lines) ===" | tee -a "$REPORT"
echo "  These are blocks where updateValidatorSetV2 system tx ran." | tee -a "$REPORT"
for n in 1 2 3; do
  logfile=$(val_log "$n")
  [[ -f "$logfile" ]] || continue
  echo "--- validator-${n} ---" | tee -a "$REPORT"
  grep "BAL=true\|isBreatheBlock\|updateValidatorSetV2\|breathe" "$logfile" 2>/dev/null \
    | grep -v "^$" | head -30 | tee -a "$REPORT" || echo "  (none found)" | tee -a "$REPORT"
done
echo "" | tee -a "$REPORT"

# ── 2. Nonce changes from system transactions ─────────────────────────────────
echo "=== 2. NONCE CHANGES FROM SYSTEM TRANSACTIONS ===" | tee -a "$REPORT"
echo "  Look for SetNonce calls (verbosity 5 / vmodule state_processor=4)." | tee -a "$REPORT"
for n in 1 2 3; do
  logfile=$(val_log "$n")
  [[ -f "$logfile" ]] || continue
  addr=$(val_addr "$n" | tr '[:upper:]' '[:lower:]')
  echo "--- validator-${n} (${addr}) ---" | tee -a "$REPORT"
  grep -i "SetNonce\|nonce.*${addr:0:10}\|${addr:0:10}.*nonce\|NonceChange" "$logfile" 2>/dev/null \
    | head -30 | tee -a "$REPORT" || echo "  (none found)" | tee -a "$REPORT"
done
echo "" | tee -a "$REPORT"

# ── 3. Txpool drop / eviction events ─────────────────────────────────────────
echo "=== 3. TXPOOL DROP / EVICTION EVENTS ===" | tee -a "$REPORT"
echo "  These appear when a tx is removed due to stale nonce or other reasons." | tee -a "$REPORT"
for n in 1 2 3; do
  logfile=$(val_log "$n")
  [[ -f "$logfile" ]] || continue
  echo "--- validator-${n} ---" | tee -a "$REPORT"
  grep -iE "Dropping|Discarding|evict|underpriced|nonce too low|future nonce|stale" \
    "$logfile" 2>/dev/null | head -30 | tee -a "$REPORT" || echo "  (none found)" | tee -a "$REPORT"
done
echo "" | tee -a "$REPORT"

# ── 4. Submitted transactions (our registration / governance txs) ─────────────
echo "=== 4. SUBMITTED TRANSACTIONS ===" | tee -a "$REPORT"
echo "  All txs submitted via eth_sendTransaction — show nonce and timing." | tee -a "$REPORT"
logfile=$(val_log 1)
if [[ -f "$logfile" ]]; then
  grep "Submitted transaction\|sendTransaction" "$logfile" 2>/dev/null \
    | head -40 | tee -a "$REPORT" || echo "  (none found)" | tee -a "$REPORT"
fi
echo "" | tee -a "$REPORT"

# ── 5. System transaction execution (parlia applyTransaction) ─────────────────
echo "=== 5. SYSTEM TRANSACTION EXECUTION ===" | tee -a "$REPORT"
echo "  System txs from applyTransaction — these increment header.Coinbase nonce." | tee -a "$REPORT"
for n in 1 2 3; do
  logfile=$(val_log "$n")
  [[ -f "$logfile" ]] || continue
  echo "--- validator-${n} ---" | tee -a "$REPORT"
  grep -iE "applyTransaction|system.tx|system_tx|SystemTx|Apply.*system|Executing.*system" \
    "$logfile" 2>/dev/null | head -20 | tee -a "$REPORT" || echo "  (none found)" | tee -a "$REPORT"
done
echo "" | tee -a "$REPORT"

# ── 6. Nonce timeline correlation: submitted tx vs breathe block ──────────────
echo "=== 6. NONCE TIMELINE CORRELATION ===" | tee -a "$REPORT"
echo "  Cross-reference: tx submitted with nonce N, then breathe block increments" | tee -a "$REPORT"
echo "  sealer nonce, making the tx stale." | tee -a "$REPORT"
logfile=$(val_log 1)
if [[ -f "$logfile" ]]; then
  python3 - <<'PYEOF' 2>/dev/null | tee -a "$REPORT" || echo "  (python3 analysis failed)" | tee -a "$REPORT"
import re, sys

logfile_path = None
import os
# find the logfile
for root, dirs, files in os.walk(os.environ.get('LOGDIR', 'data')):
    for f in files:
        if f == 'geth.log':
            logfile_path = os.path.join(root, f)
            break
    if logfile_path:
        break

if not logfile_path or not os.path.exists(logfile_path):
    print("  geth.log not found")
    sys.exit(0)

events = []
with open(logfile_path) as fh:
    for line in fh:
        # Submitted transaction with nonce
        m = re.search(r'(\d{2}:\d{2}:\d{2}\.\d+).*Submitted transaction.*nonce=(\d+).*from=(\S+)', line)
        if m:
            events.append(('SUBMIT', m.group(1), int(m.group(2)), m.group(3).rstrip(',')))
        # BAL=true (breathe block)
        m2 = re.search(r'(\d{2}:\d{2}:\d{2}\.\d+).*number=(\d+).*miner=(\S+).*BAL=true', line)
        if m2:
            events.append(('BREATHE', m2.group(1), int(m2.group(2)), m2.group(3).rstrip(',')))
        # Dropping transaction
        m3 = re.search(r'(\d{2}:\d{2}:\d{2}\.\d+).*(Dropping|Discarding).*nonce.*?(\d+)', line)
        if m3:
            events.append(('DROP', m3.group(1), int(m3.group(3)), ''))

if not events:
    print("  No relevant events found (check verbosity level)")
    sys.exit(0)

events.sort(key=lambda x: x[1])
print(f"  {'Time':<16} {'Event':<10} {'Nonce/Block':<14} {'Address/Miner'}")
print(f"  {'-'*16} {'-'*10} {'-'*14} {'-'*42}")
for ev in events[:60]:
    kind, ts, num, addr = ev
    print(f"  {ts:<16} {kind:<10} {str(num):<14} {addr[:42]}")
PYEOF
fi
echo "" | tee -a "$REPORT"

# ── 7. Gas usage anomaly check ────────────────────────────────────────────────
echo "=== 7. GAS USAGE IN BREATHE BLOCKS ===" | tee -a "$REPORT"
echo "  High gas in breathe blocks might starve user txs." | tee -a "$REPORT"
logfile=$(val_log 1)
if [[ -f "$logfile" ]]; then
  grep "BAL=true" "$logfile" 2>/dev/null \
    | grep -oE "mgas=[0-9.]+" | sort -t= -k2 -rn | head -10 | tee -a "$REPORT" \
    || echo "  (no BAL=true blocks or no mgas field)" | tee -a "$REPORT"
fi
echo "" | tee -a "$REPORT"

echo "=== SUMMARY ===" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
echo "Key things to check in the report above:" | tee -a "$REPORT"
echo "  1. Section 3: If 'nonce too low' or 'future nonce' appears → confirms eviction" | tee -a "$REPORT"
echo "     by stale nonce caused by section-5 system txs incrementing coinbase nonce." | tee -a "$REPORT"
echo "  2. Section 6: If a BREATHE event appears between SUBMIT and DROP with the" | tee -a "$REPORT"
echo "     same nonce → confirms breathe-block nonce collision." | tee -a "$REPORT"
echo "  3. Section 5: If system txs appear frequently per block → nonce increments" | tee -a "$REPORT"
echo "     faster than expected, widening the collision window." | tee -a "$REPORT"
echo "  4. Section 7: If mgas is high in breathe blocks → system tx gas is large," | tee -a "$REPORT"
echo "     potentially leaving less room for user txs (less likely cause)." | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
echo "Full report written to: ${REPORT}"
