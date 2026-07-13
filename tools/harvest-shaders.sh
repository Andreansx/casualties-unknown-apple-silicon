#!/usr/bin/env bash
#
# harvest-shaders.sh - run the game exactly like run-d3dmetal.sh, but with the D3DMetal
# shader-harvest shim injected (ROADMAP Path 3-lite, step 1). It records the Metal shaders
# D3DMetal generates at runtime from the game's D3D11 DXBC - the very shaders that are
# "non-recoverable" from the static build - so they can be re-wrapped into a native Unity
# Metal build later.
#
# HOW IT WORKS: the shim (tools/harvest/shim.m, built to $HARVEST_DIR/libharvestshim.dylib)
# is injected via DYLD_INSERT_LIBRARIES. It stays inert until D3DMetal has loaded Metal, then
# swizzles MTLDevice's newLibraryWith{Data,File,URL,Source} and dumps every AIR metallib
# D3DMetal hands to Metal. Each dumped .metallib is one translated shader stage; disassemble
# it with `xcrun metal-objdump --disassemble` to read the generated shader.
#
# What you get in $HARVEST_DIR (default ~/Games/d3dm-harvest):
#   libs/data-*.metallib   every AIR library D3DMetal creates from the game's shaders
#   libs/file-*.metallib   (a couple) D3DMetal's OWN internal blit/clear library - ignore
#   manifest.jsonl         one JSON line per event (shimLoaded / device / installed / each dump)
# Then identify + name the 4 custom post-fx with:  tools/harvest/identify.sh
#
# Usage:  ./tools/harvest-shaders.sh [/path/to/CasualtiesUnknown.exe]
# Env:    HARVEST_DIR, WINEPREFIX, GPTK, HUD=1, LOG=1  (same as run-d3dmetal.sh)
#
# NOTE ON FRAME CAPTURE: an Xcode/gputrace Metal capture is NOT done here. MTL_CAPTURE_ENABLED
# wraps every device in a CaptureMTLDevice, and that layer together with any injected shim
# crashes the game (each is fine alone). Harvesting the metallib IS the capture we want - it
# yields the actual translated shader, more directly than a frame trace. If you ever want a
# gputrace anyway, run the game with `MTL_CAPTURE_ENABLED=1` and NO shim, and attach Xcode.
set -euo pipefail

# ── config (mirrors run-d3dmetal.sh) ────────────────────────────────────────
GPTK="${GPTK:-/Applications/Game Porting Toolkit.app/Contents/Resources}"
WINE="$GPTK/wine/bin/wine64"
EXTERNAL="$GPTK/wine/lib/external"
export WINEPREFIX="${WINEPREFIX:-$HOME/Games/CasualtiesUnknown}"
export HARVEST_DIR="${HARVEST_DIR:-$HOME/Games/d3dm-harvest}"
SHIM="$HARVEST_DIR/libharvestshim.dylib"
EXE="${1:-$HOME/Documents/casualtiesunknowncostam/CasualtiesUnknownDemo/CasualtiesUnknown.exe}"

die(){ printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
[ -x "$WINE" ] || die "GPTK wine not found at $WINE"
[ -d "$EXTERNAL/D3DMetal.framework" ] || die "D3DMetal not bundled in this GPTK ($EXTERNAL)"
[ -f "$EXE" ] || die "game .exe not found: $EXE"
mkdir -p "$HARVEST_DIR/libs"
[ -f "$SHIM" ] || "$(dirname "$0")/harvest/build-shim.sh" "$SHIM"

# ── D3DMetal env (same as run-d3dmetal.sh) ──────────────────────────────────
export WINEDLLOVERRIDES="d3d11=b;d3d10core=b;dxgi=b"
export DYLD_FALLBACK_LIBRARY_PATH="$EXTERNAL:$GPTK/wine/lib:/usr/lib:/usr/local/lib"
[ "${HUD:-0}" = 1 ] && export MTL_HUD_ENABLED=1
[ "${LOG:-0}" = 1 ] && export WINEDEBUG="" || export WINEDEBUG=-all

# ── inject the harvest shim ─────────────────────────────────────────────────
# CRITICAL: export DYLD_INSERT_LIBRARIES *here* (in this script) and exec wine DIRECTLY.
#  * The shim is a UNIVERSAL (arm64+x86_64) dylib. A single-arch x86_64 shim would make dyld
#    reject/strip DYLD_INSERT_LIBRARIES in this arm64 shell before wine ever starts.
#  * Do NOT launch via `arch -x86_64` - `arch` is SIP-protected and strips all DYLD_* vars.
#    wine64 is x86_64-only, so exec'ing it directly runs it under Rosetta automatically AND
#    lets DYLD_INSERT_LIBRARIES survive into it. Verified 2026-07-12.
export DYLD_INSERT_LIBRARIES="$SHIM"

# CAPTURE=1 → write a real Xcode .gputrace frame capture instead of dumping metallibs. This is
# CAPTURE-ONLY (the shim does NOT swizzle in this mode) which mirrors the one capture config
# that's stable with the game: MTL_CAPTURE_ENABLED + no library hooks. The shim auto-captures
# ~12s in and on every `touch $HARVEST_DIR/trigger`. Open the .gputrace in Xcode.
if [ "${CAPTURE:-0}" = 1 ]; then
  export MTL_CAPTURE_ENABLED=1
  export HARVEST_CAPTURE=1
  export HARVEST_CAPTURE_ONLY=1
else
  # DUMP mode: also correlate each render pipeline to its fragment shader's metallib, so the
  # 4 custom post-fx are located at the pipeline level (not just the shader level). Stable.
  # Set HARVEST_HOOK_PSO=0 to turn this off if ever needed.
  export HARVEST_HOOK_PSO="${HARVEST_HOOK_PSO:-1}"
fi

printf '\033[1;36m▸\033[0m harvest: %s\n' "$HARVEST_DIR"
printf '\033[1;36m▸\033[0m shim   : %s\n' "$SHIM"
printf '\033[1;36m▸\033[0m exe    : %s\n' "$EXE"
if [ "${CAPTURE:-0}" = 1 ]; then
  printf '\033[1;36m▸\033[0m mode   : CAPTURE → writing %s/frame-NN.gputrace (auto ~12s + on `touch %s/trigger`)\n' "$HARVEST_DIR" "$HARVEST_DIR"
else
  printf '\033[1;36m▸\033[0m mode   : DUMP → translated metallibs to %s/libs/  (then run tools/harvest/identify.sh)\n' "$HARVEST_DIR"
fi

exec "$WINE" "$EXE"
