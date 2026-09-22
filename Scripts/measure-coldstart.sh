#!/bin/zsh
# Mesure le lancement : N démarrages de processus, puis médiane et p90 par phase.
#
#   Scripts/measure-coldstart.sh [N] [chemin-du-dépôt]
#   FRESH=1 Scripts/measure-coldstart.sh 10 ~/dépôt   # binaire recopié avant chaque lancement
#   PURGE=1 Scripts/measure-coldstart.sh 10 ~/dépôt   # purge du cache disque (sudo requis)
#
# Horloge : de la création du processus par le noyau (p_starttime, voir
# Sources/Shell/LaunchMetrics.swift) jusqu'au repère. Le temps entre le clic et
# la création du processus (LaunchServices, Dock) n'est pas compté.
#   firstFrame  : tour de boucle qui suit makeKeyAndOrderFront, contenu issu du
#                 snapshot. La fenêtre apparaît ensuite en fondu de 160 ms.
#   interactive : statistiques dérivées calculées, tableau de bord complet.
#   warm        : tâches de fond lancées (empreinte, surveillance).
# Sans FRESH ni PURGE, le binaire et le snapshot sont dans le cache disque
# (lancements successifs) : c'est un démarrage de processus à froid, pas un
# démarrage de machine à froid.
#
# p90 : rang le plus proche (valeur de rang ⌈0,9·N⌉ dans la série triée).
# Médiane : moyenne des deux valeurs centrales si N est pair.
set -euo pipefail
N=${1:-20}
REPO=${2:-}
APP=${LANES_APP:-$HOME/Applications/Lanes.app}
PAUSE=${PAUSE:-1}
FRESH=${FRESH:-0}
PURGE=${PURGE:-0}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ "$PURGE" == 1 ]] && ! sudo -n true 2>/dev/null; then
  echo "PURGE=1 exige sudo sans mot de passe : lance « sudo -v » avant, ou retire PURGE." >&2
  exit 1
fi

echo "machine    : $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) Go, macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "mémoire    : $(memory_pressure -Q 2>/dev/null | tail -1 | sed 's/^ *//'), swap $(sysctl -n vm.swapusage | awk '{print $6}') utilisés"
if [[ -n "$REPO" ]]; then
  echo "dépôt      : $REPO ($(git -C "$REPO" rev-list --all --count 2>/dev/null || echo '?') commits, toutes références)"
fi
echo "lancements : $N, scénario $([[ $PURGE == 1 ]] && echo 'cache disque purgé' || { [[ $FRESH == 1 ]] && echo 'binaire recopié' || echo 'cache disque chaud'; })"
echo

for i in $(seq 1 $N); do
  BIN="$APP/Contents/MacOS/Lanes"
  if [[ "$FRESH" == 1 ]]; then
    # Nouvelle copie, nouveau chemin : dyld et la vérification de signature
    # repartent de zéro pour ce binaire. Les pages copiées restent en cache.
    rm -rf "$TMP/app"; mkdir -p "$TMP/app"
    cp -R "$APP" "$TMP/app/Lanes-$i.app"
    BIN="$TMP/app/Lanes-$i.app/Contents/MacOS/Lanes"
  fi
  [[ "$PURGE" == 1 ]] && { sudo -n purge; sleep 2; }
  line=$(LANES_MEASURE=1 LANES_AUTOQUIT=1 "$BIN" ${REPO:+"$REPO"} 2>&1 | grep -E "^(firstFrame|interactive|warm):" | tr '\n' ' ')
  printf '%2d  %s\n' "$i" "$line"
  for phase in firstFrame interactive warm; do
    echo "$line" | sed -nE "s/.*$phase: ([0-9]+) ms.*/\1/p" >> "$TMP/$phase"
  done
  sleep "$PAUSE"
done

echo
printf '%-12s %6s %6s %6s %6s %4s\n' phase min médiane p90 max n
for phase in firstFrame interactive warm; do
  [[ -s "$TMP/$phase" ]] || continue
  sort -n "$TMP/$phase" | awk -v p="$phase" '
    { v[NR] = $1 }
    END {
      n = NR
      med = (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
      r = int(0.9 * n); if (r < 0.9 * n) r++
      printf "%-12s %6d %6g %6d %6d %4d   (ms)\n", p, v[1], med, v[r], v[n], n
    }'
done
