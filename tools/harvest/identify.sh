#!/usr/bin/env bash
# identify.sh — thin wrapper: fingerprint the harvested metallibs and map the 4 custom
# Shader Graphs to them (see identify.py). Needs the Xcode Metal Toolchain (metal-objdump)
# and a Python env with UnityPy + lz4.
#
#   HARVEST_DIR   default ~/Games/d3dm-harvest   (where harvest-shaders.sh dumped libs/)
#   GAME_DATA     default the demo's *_Data dir  (source of the custom shaders' DXBC)
#   PY            python to use (must have UnityPy + lz4). Auto-detects a upyvenv if present.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HARVEST_DIR="${HARVEST_DIR:-$HOME/Games/d3dm-harvest}"
GAME_DATA="${GAME_DATA:-$HOME/Documents/casualtiesunknowncostam/CasualtiesUnknownDemo/CasualtiesUnknown_Data}"

# find a python with UnityPy
PY="${PY:-}"
if [ -z "$PY" ]; then
  for c in python3; do "$c" -c 'import UnityPy,lz4' 2>/dev/null && PY="$c" && break; done
fi
[ -z "$PY" ] && { echo "✗ need a python with UnityPy + lz4 (set PY=/path/to/venv/bin/python)"; exit 1; }

xcrun -f metal-objdump >/dev/null 2>&1 || {
  echo "✗ metal-objdump missing — install the Metal Toolchain:"
  echo "    xcodebuild -downloadComponent MetalToolchain"; exit 1; }

exec "$PY" "$HERE/identify.py" --libs "$HARVEST_DIR/libs" --data "$GAME_DATA" --out "$HARVEST_DIR/identified"
