#!/usr/bin/env bash
# Build the native-build frame profiler shim (arm64 only — the native player is arm64).
# Output goes OUTSIDE iCloud-synced ~/Documents (com.apple.FinderInfo breaks codesign).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/frameprof.m"
OUT="${1:-$HOME/Games/frameprof/libframeprof.dylib}"
mkdir -p "$(dirname "$OUT")"
clang -arch arm64 -dynamiclib -fno-objc-arc -O1 \
  -framework Foundation -framework Metal \
  -o "$OUT" "$SRC"
codesign -s - -f "$OUT" >/dev/null 2>&1 || true
echo "built: $OUT"
file "$OUT"
