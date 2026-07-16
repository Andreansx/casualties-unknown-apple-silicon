#!/usr/bin/env bash
# Baseline-subtracted CPU/GPU power for one scene, appended to a CSV.
#
# The ONLY valid method for this project (see docs/port-7.0.md §6, README head-to-head):
# whole-system powermetrics minus an idle baseline taken on the SAME session. Raw
# powermetrics numbers are whole-system and include WindowServer/chat/editor — never
# quote them unsubtracted.
#
#   sudo tools/powermeasure.sh baseline                 # quit the game first!
#   sudo tools/powermeasure.sh native-menu
#   sudo tools/powermeasure.sh native-gameplay
#   sudo tools/powermeasure.sh d3dmetal-menu
#   sudo tools/powermeasure.sh d3dmetal-gameplay
#   tools/powermeasure.sh --report
#
# Get the scene on screen and STEADY first; the script gives you a countdown, then
# samples for $SECS seconds. For gameplay: keep moving for the whole window.
#
# PARITY IS EVERYTHING — both builds must be at the same resolution/refresh or the
# comparison is meaningless:
#   native : defaults read <CFBundleIdentifier>            # 7.0 has a NEW bundle id
#   wine   : ~/Games/CasualtiesUnknown/user.reg            # grep Screenmanager
set -euo pipefail

CSV="${CSV:-$HOME/Documents/casualtiesunknowncostam/power-7.0.csv}"
SECS="${SECS:-20}"

if [[ "${1:-}" == "--report" ]]; then
  [[ -f "$CSV" ]] || { echo "no samples yet: $CSV"; exit 1; }
  python3 - "$CSV" <<'PY'
import csv, sys
rows = {r['label']: r for r in csv.DictReader(open(sys.argv[1]))}
if 'baseline' not in rows:
    sys.exit("no 'baseline' row — run: sudo tools/powermeasure.sh baseline")
b = rows.pop('baseline')
bc, bg = float(b['cpu_mw']), float(b['gpu_mw'])
print(f"\nidle baseline: CPU {bc:.0f} mW  GPU {bg:.0f} mW  (subtracted from everything below)\n")
print(f"{'scene':<20} {'CPU mW':>8} {'GPU mW':>8} {'TOTAL mW':>9}   {'GPU res':>7}   (marginal)")
print("-" * 72)
for k, r in rows.items():
    c, g = float(r['cpu_mw']) - bc, float(r['gpu_mw']) - bg
    print(f"{k:<20} {c:>8.0f} {g:>8.0f} {c+g:>9.0f}   {r['gpu_res']:>6}%")
def cmp(a, z, name):
    if a in rows and z in rows:
        ac = float(rows[a]['cpu_mw']) - bc; ag = float(rows[a]['gpu_mw']) - bg
        zc = float(rows[z]['cpu_mw']) - bc; zg = float(rows[z]['gpu_mw']) - bg
        d = ((zc+zg) - (ac+ag)) / (ac+ag) * 100
        print(f"\n{name}: d3dmetal {ac+ag:.0f} mW -> native {zc+zg:.0f} mW  "
              f"({d:+.0f}%)   CPU {ac:.0f}->{zc:.0f}  GPU {ag:.0f}->{zg:.0f}")
cmp('d3dmetal-menu', 'native-menu', 'MENU')
cmp('d3dmetal-gameplay', 'native-gameplay', 'GAMEPLAY  <- the one that matters')
print()
PY
  exit 0
fi

LABEL="${1:-}"
[[ -n "$LABEL" ]] || { sed -n '2,20p' "$0"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "powermetrics needs root: sudo $0 $LABEL"; exit 1; }

echo "==> scene: $LABEL"
if [[ "$LABEL" == "baseline" ]]; then
  echo "    QUIT THE GAME. Leave everything else exactly as it will be during the runs."
else
  echo "    Get the game to the scene, fullscreen, focused, and steady."
  echo "    Gameplay = keep MOVING for the whole ${SECS}s window."
fi
for i in 5 4 3 2 1; do printf "\r    sampling in %d... " "$i"; sleep 1; done
echo -e "\r    sampling ${SECS}s...    "

OUT=$(powermetrics --samplers cpu_power,gpu_power -i 1000 -n "$SECS" 2>/dev/null)

avg() { grep -E "$1" <<<"$OUT" | grep -oE '[0-9]+(\.[0-9]+)?' | awk '{s+=$1; n++} END {if(n) printf "%.1f", s/n; else print "0"}'; }
CPU=$(avg '^CPU Power:')
GPU=$(avg '^GPU Power:')
RES=$(grep -E 'GPU (HW )?active residency' <<<"$OUT" | grep -oE '[0-9]+\.[0-9]+%' | tr -d '%' \
      | awk '{s+=$1; n++} END {if(n) printf "%.1f", s/n; else print "0"}')

[[ -f "$CSV" ]] || echo "label,cpu_mw,gpu_mw,gpu_res,secs" > "$CSV"
grep -v "^$LABEL," "$CSV" > "$CSV.tmp" 2>/dev/null || true
mv "$CSV.tmp" "$CSV"
echo "$LABEL,$CPU,$GPU,$RES,$SECS" >> "$CSV"

echo "    CPU ${CPU} mW   GPU ${GPU} mW   GPU residency ${RES}%   (raw, whole-system)"
echo "    -> $CSV"
echo "    report:  tools/powermeasure.sh --report"
