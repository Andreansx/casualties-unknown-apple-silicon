#!/usr/bin/env bash
#
# run-harness.sh - reproduce the arm64 BepInEx detour spike headlessly.
#
# Installs the shim into a game .app that already has a macOS-universal BepInEx 5 laid down,
# forces the arm64 slice, injects Doorstop pointed at the shim, boots the game headless, and
# reports whether BepInEx reached "Chainloader startup complete" WITHOUT a preloader crash.
#
# Usage:
#   ./run-harness.sh --app <Game.app> --dist <path-to/dist> [--seconds 18]
#
# <Game.app> must contain BepInEx/ (macOS-universal 5.4.23.x, libdoorstop.dylib) at its root
# alongside Contents/. Build the shim first with ../build.sh.
#
set -euo pipefail
APP=""; DIST=""; SECS=18
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --dist) DIST="$2"; shift 2 ;;
    --seconds) SECS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -d "$APP" ] && [ -n "$DIST" ] || { echo "usage: $0 --app <Game.app> --dist <dist>" >&2; exit 2; }

ROOT="$(dirname "$APP")"                              # dir holding BepInEx/ + Game.app
CORE="$ROOT/BepInEx/core"
EXE="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable)"
DOORSTOP_LIB="$ROOT/libdoorstop.dylib"
CORLIB="$APP/Contents/Resources/Data/Managed"

# install shim + helper next to BepInEx core
cp -f "$DIST/AppleSiliconShim.dll" "$CORE/AppleSiliconShim.dll"
cp -f "$DIST/libas_jit.dylib"      "$CORE/libas_jit.dylib"
rm -f "$CORE/silicon_shim.log" "$ROOT/BepInEx/LogOutput.log" "$APP/Contents/MacOS/preloader_"*.log 2>/dev/null || true

export DOORSTOP_ENABLED=1
export DOORSTOP_TARGET_ASSEMBLY="$CORE/AppleSiliconShim.dll"       # <-- entrypoint override
export DOORSTOP_IGNORE_DISABLED_ENV=1
export DOORSTOP_MONO_DLL_SEARCH_PATH_OVERRIDE="$CORE:$CORLIB"
export DYLD_LIBRARY_PATH="$ROOT:$CORLIB:${DYLD_LIBRARY_PATH:-}"

echo "[harness] forcing arm64, Doorstop -> AppleSiliconShim -> BepInEx.Preloader"
arch -arm64 -e DYLD_INSERT_LIBRARIES="$DOORSTOP_LIB" \
    "$EXE" -batchmode -nographics -logFile "$ROOT/harness.stdout.log" --ksmulti-nosteam 2>/dev/null &
PID=$!; sleep "$SECS"; kill -9 $PID 2>/dev/null || true; wait $PID 2>/dev/null || true

echo "=== silicon_shim.log ==="; cat "$CORE/silicon_shim.log" 2>/dev/null || echo "(none)"
echo "=== BepInEx/LogOutput.log ==="; cat "$ROOT/BepInEx/LogOutput.log" 2>/dev/null || echo "(none)"
echo "=== VERDICT ==="
if grep -q "Chainloader startup complete" "$ROOT/BepInEx/LogOutput.log" 2>/dev/null \
   && ! ls "$APP/Contents/MacOS/preloader_"*.log >/dev/null 2>&1; then
  echo "PASS: BepInEx booted on native arm64, no preloader crash"
else
  echo "FAIL/INCONCLUSIVE: inspect logs above (+ any preloader_*.log next to the executable)"
fi
