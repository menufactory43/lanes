#!/bin/zsh
# Mesure le lancement : N démarrages de processus, rapport des phases.
# Usage : Scripts/measure-coldstart.sh [N] [chemin-du-dépôt]
set -euo pipefail
N=${1:-5}
REPO=${2:-}
BIN=~/Applications/Lanes.app/Contents/MacOS/Lanes
for i in $(seq 1 $N); do
  LANES_MEASURE=1 LANES_AUTOQUIT=1 "$BIN" $REPO 2>&1 | grep -E "^(firstFrame|interactive|warm):" | tr '\n' ' '
  echo
  sleep 0.5
done
