#!/usr/bin/env bash
#
# run-d3dmetal.sh - launch the unmodified Windows build of Casualties: Unknown on
# Apple Silicon via Apple's D3DMetal (D3D11 -> Metal at runtime).
#
# This is the "translation layer" path (ROADMAP Path 1). It runs the ORIGINAL, unpatched
# game .exe under Wine + Rosetta 2, translating Direct3D 11 to Metal - which sidesteps the
# shader wall (the Windows build ships D3D11-only shaders, incl. custom Shader Graphs whose
# source isn't recoverable, so a native Metal render path is not directly possible).
#
# FREE stack only - no CrossOver, no paid tools:
#   * Gcenx `game-porting-toolkit` Homebrew cask, which conveniently BUNDLES Apple's D3DMetal
#     (D3DMetal.framework + libd3dshared.dylib under wine/lib/external/).
#   * Rosetta 2 (Apple, built in) to run the x86-64 wine + game.
#
# Install prereqs once:
#   softwareupdate --install-rosetta --agree-to-license
#   brew install --cask gcenx/wine/game-porting-toolkit
#
# Usage:
#   ./run-d3dmetal.sh /path/to/CasualtiesUnknown.exe            # first run creates the prefix
#   ./run-d3dmetal.sh                                            # uses $EXE default below
#
# Env overrides: WINEPREFIX, GPTK (app path), HUD=1 (Metal FPS overlay), LOG=1 (verbose wine).
set -euo pipefail

# ── config ──────────────────────────────────────────────────────────────────
GPTK="${GPTK:-/Applications/Game Porting Toolkit.app/Contents/Resources}"
WINE="$GPTK/wine/bin/wine64"
EXTERNAL="$GPTK/wine/lib/external"
export WINEPREFIX="${WINEPREFIX:-$HOME/Games/CasualtiesUnknown}"

EXE="${1:-$HOME/Documents/casualtiesunknowncostam/CasualtiesUnknownDemo/CasualtiesUnknown.exe}"

# ── sanity ──────────────────────────────────────────────────────────────────
die(){ printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
[ -x "$WINE" ] || die "GPTK wine not found at $WINE - install: brew install --cask gcenx/wine/game-porting-toolkit"
[ -d "$EXTERNAL/D3DMetal.framework" ] || die "D3DMetal not bundled in this GPTK ($EXTERNAL). Need the Gcenx cask that ships D3DMetal."
[ -f "$EXE" ] || die "game .exe not found: $EXE  (pass the path as arg 1)"

# ── D3DMetal env ────────────────────────────────────────────────────────────
# Force the BUILTIN d3d11/d3d10core/dxgi so calls route to D3DMetal (not DXVK / not a native PE).
export WINEDLLOVERRIDES="d3d11=b;d3d10core=b;dxgi=b"
# REQUIRED rpath fix: the Gcenx cask's wine/lib/wine/x86_64-unix/d3d11.so links
# @rpath/libd3dshared.dylib with RPATH=@loader_path, but libd3dshared.dylib actually lives in
# wine/lib/external/. Without this, D3D11CoreCreateDevice crashes. Add external/ so dlopen finds it.
export DYLD_FALLBACK_LIBRARY_PATH="$EXTERNAL:$GPTK/wine/lib:/usr/lib:/usr/local/lib"
[ "${HUD:-0}" = 1 ] && export MTL_HUD_ENABLED=1
[ "${LOG:-0}" = 1 ] && export WINEDEBUG="" || export WINEDEBUG=-all

printf '\033[1;36m▸\033[0m prefix : %s\n' "$WINEPREFIX"
printf '\033[1;36m▸\033[0m d3dmetal: %s\n' "$EXTERNAL"
printf '\033[1;36m▸\033[0m exe    : %s\n' "$EXE"
printf '\033[1;36m▸\033[0m launching under Rosetta (arch -x86_64)…\n'

# ── go ──────────────────────────────────────────────────────────────────────
exec arch -x86_64 "$WINE" "$EXE"
