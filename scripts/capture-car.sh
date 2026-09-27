#!/usr/bin/env bash
# Records everything spia needs from a real car into Tests/Fixtures/.
#
# Usage: scripts/capture-car.sh <label> [spia options...]
#   label: something like "ghibli-ignition-on" or "ghibli-idle"
#   spia options: passed to both runs, e.g. --port /dev/cu.<adapter> for a
#   Bluetooth adapter (only USB ports are picked automatically)
#
# Produces two transcripts: a probe (adapter + protocol + supported PIDs) and a
# scripted terminal session covering DTCs, freeze frame, VIN, readiness, and a
# few live PIDs. Every byte in both directions is captured; nothing is edited.
set -euo pipefail

label="${1:?usage: $0 <label> [spia options...]}"
shift
cd "$(dirname "$0")/.."
mkdir -p Tests/Fixtures

echo "== probe"
swift run -q spia probe --record "Tests/Fixtures/${label}-probe.txt" "$@"

echo
echo "== scripted terminal"
swift run -q spia term --record "Tests/Fixtures/${label}-term.txt" "$@" <<'EOF'
0100
0120
0140
0101
03
07
0A
0200
020200
020500
020C00
0902
0904
0906
090A
010C
0105
010F
0111
0142
0146
015C
ATDP
ATDPN
STPRS
quit
EOF

echo
echo "== done. Files:"
ls -la "Tests/Fixtures/${label}-probe.txt" "Tests/Fixtures/${label}-term.txt"
