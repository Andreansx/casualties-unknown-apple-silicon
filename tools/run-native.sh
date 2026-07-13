#!/usr/bin/env bash
#
# run-native.sh - launch the NATIVE ARM64/Metal build of Casualties: Unknown with Apple's
# Metal Performance HUD, the same overlay `HUD=1 ./run-d3dmetal.sh` gives you on Path 1.
#
# This is the native path (ROADMAP Path 2/3): a real arm64 Unity player, 100% Metal, no Wine,
# no Rosetta, no D3D11 translation. Built by tools/transplant.sh + the shader work in
# tools/rewrap/, and normally installed at ~/Applications/CU_metaltest.app.
#
# Why a script instead of double-clicking the .app: the Metal HUD is opted into with the
# MTL_HUD_ENABLED env var, and `open`/Finder do NOT pass your shell environment into the app
# (they also strip DYLD_*). So we exec the bundle's binary directly - the bundle is ad-hoc
# signed with no hardened runtime, so injected env vars survive. Same trick tools/powerprof
# uses. If you want the HUD on Finder/Dock launches too, see --install-hud-default below.
#
# Usage:
#   ./run-native.sh                          # launch with the Metal HUD (default)
#   ./run-native.sh /path/to/Some.app        # a different bundle
#   HUD=0 ./run-native.sh                    # plain launch, no overlay
#   WINDOWED=1 ./run-native.sh               # 1600x900 window instead of fullscreen
#   PROF=1 ./run-native.sh                   # + powerprof JSONL frame profiler (tools/powerprof)
#   ./run-native.sh -- -force-glcore         # everything after `--` goes to the Unity player
#
#   ./run-native.sh --install-hud-default    # HUD on every launch, incl. Finder/Dock, then exit
#   ./run-native.sh --uninstall-hud-default  # undo that, then exit
#
# Env: APP, HUD (default 1), WINDOWED, RES (default 1600x900), PROF, LOG (Unity player log to stdout).
set -euo pipefail

# ── config ──────────────────────────────────────────────────────────────────
APP="${APP:-$HOME/Applications/CU_metaltest.app}"
RES="${RES:-1600x900}"
PROFDIR="${PROFDIR:-$HOME/Games/frameprof}"          # outside iCloud: FinderInfo xattrs break codesign
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die(){ printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
say(){ printf '\033[1;36m▸\033[0m %s\n' "$*"; }

# ── arg parsing: flags, then optional app path, then `--` passthrough ───────
PASSTHRU=()
HUD_DEFAULT_ACTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install-hud-default)   HUD_DEFAULT_ACTION=install;   shift ;;
    --uninstall-hud-default) HUD_DEFAULT_ACTION=uninstall; shift ;;
    --) shift; PASSTHRU=("$@"); break ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) APP="$1"; shift ;;
  esac
done

# ── sanity ──────────────────────────────────────────────────────────────────
[ -d "$APP" ] || die "native .app not found: $APP  (pass its path, or set APP=…)"
BIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$BIN" ] || die "no CFBundleExecutable in $APP/Contents/Info.plist - is that a real .app?"
EXEC="$APP/Contents/MacOS/$BIN"
[ -x "$EXEC" ] || die "bundle executable missing/not executable: $EXEC"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"

# The whole point of this path is that it is NOT Rosetta. Refuse to pretend if it would be.
# (The transplanted player is a universal binary; on Apple Silicon dyld picks the arm64 slice.
# Verified once with `lsappinfo info -only arch <pid>` -> "LSArchitecture"="arm64".)
ARCHS="$(lipo -archs "$EXEC" 2>/dev/null || echo unknown)"
case "$ARCHS" in
  *arm64*) ;;
  *) die "$BIN has no arm64 slice ($ARCHS) - that's the x86 player, not the native build." ;;
esac

# ── --install-hud-default: HUD for Finder/Dock launches, then exit ──────────
# `defaults write <bundle-id> MetalForceHudEnabled -bool YES` is Metal's per-app opt-in; unlike
# the env var it survives `open`, so a double-clicked .app shows the overlay too.
if [ -n "$HUD_DEFAULT_ACTION" ]; then
  case "$HUD_DEFAULT_ACTION" in
    install)
      defaults write "$BUNDLE_ID" MetalForceHudEnabled -bool YES
      say "Metal HUD is now ON for every launch of $BUNDLE_ID (Finder/Dock included)."
      say "undo with: $0 --uninstall-hud-default" ;;
    uninstall)
      defaults delete "$BUNDLE_ID" MetalForceHudEnabled 2>/dev/null || true
      say "Metal HUD default cleared for $BUNDLE_ID (this script's HUD=1 still works)." ;;
  esac
  exit 0
fi

# ── HUD ─────────────────────────────────────────────────────────────────────
# Apple's Metal Performance HUD: FPS + frame-time graph, GPU time, present interval, memory,
# and the pipeline/allocation counters. Identical overlay to Path 1's HUD=1 - but here it's
# reporting on OUR Metal frames, not D3DMetal's translated ones.
if [ "${HUD:-1}" = 1 ]; then
  export MTL_HUD_ENABLED=1
  HUD_STATE="on"
else
  HUD_STATE="off (HUD=1 to enable)"
fi

# ── optional: powerprof frame profiler ──────────────────────────────────────
# The HUD tells you *that* a frame is expensive; frameprof tells you *why* (encoders, passes,
# draws, per-cmdbuf GPU ms). This is what found the 97-passes/frame vsync bug - see
# tools/powerprof/README.md.
PROF_LOG=""
if [ "${PROF:-0}" = 1 ]; then
  DYLIB="$PROFDIR/libframeprof.dylib"
  [ -f "$DYLIB" ] || { say "building powerprof shim…"; "$HERE/powerprof/build.sh" "$DYLIB" >/dev/null || die "powerprof build failed"; }
  PROF_LOG="$PROFDIR/run-$(date +%Y%m%d-%H%M%S).jsonl"
  export DYLD_INSERT_LIBRARIES="$DYLIB"
  export FRAMEPROF_LOG="$PROF_LOG"
fi

# ── Unity player args ───────────────────────────────────────────────────────
ARGS=()
if [ "${WINDOWED:-0}" = 1 ]; then
  ARGS+=(-screen-fullscreen 0 -screen-width "${RES%x*}" -screen-height "${RES#*x}")
fi
[ "${LOG:-0}" = 1 ] && ARGS+=(-logFile -)          # Unity player log to stdout instead of ~/Library/Logs
[ ${#PASSTHRU[@]} -gt 0 ] && ARGS+=("${PASSTHRU[@]}")

# ── go ──────────────────────────────────────────────────────────────────────
say "app     : $APP"
say "binary  : $BIN [$ARCHS] - runs arm64 here: no Wine, no Rosetta, no D3D11"
say "hud     : $HUD_STATE"
[ -n "$PROF_LOG" ] && say "powerprof: $PROF_LOG"
[ ${#ARGS[@]} -gt 0 ] && say "args    : ${ARGS[*]}"
say "launching…"

exec "$EXEC" ${ARGS[@]+"${ARGS[@]}"}
