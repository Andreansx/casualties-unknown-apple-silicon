#!/usr/bin/env bash
# Build the D3DMetal harvest shim as an x86_64 dylib (the game runs under Rosetta).
# Output goes OUTSIDE iCloud-synced ~/Documents (com.apple.FinderInfo breaks codesign):
# default ~/Games/d3dm-harvest/libharvestshim.dylib
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/shim.m"
OUT="${1:-$HOME/Games/d3dm-harvest/libharvestshim.dylib}"
mkdir -p "$(dirname "$OUT")"
# Build UNIVERSAL (arm64 + x86_64). The game/wine/D3DMetal run x86_64 under Rosetta, but
# the launch chain (shell scripts) is arm64. A single-arch (x86_64) inserted dylib makes
# dyld reject/strip DYLD_INSERT_LIBRARIES in the arm64 shell before wine ever starts, so
# the shim silently never loads. Universal loads cleanly in both; the arm64 slice is inert
# (no Metal use in the shell), the x86_64 slice does the real work inside wine.
#
# Link NOTHING heavy: NO -framework Metal / Foundation. Linking them makes dyld map those
# frameworks EARLY (at insert time, in wine's preloader) and that steals wine's low address
# space → the game crashes before it renders. The shim reaches Metal lazily via dlopen +
# the ObjC runtime (libobjc, auto-linked) once D3DMetal has already loaded it. MRC, not ARC.
clang -arch arm64 -arch x86_64 -dynamiclib -fno-objc-arc -O1 \
  -lobjc \
  -o "$OUT" "$SRC"
codesign -s - -f "$OUT" >/dev/null 2>&1 || true
echo "built: $OUT"
file "$OUT"
