#!/usr/bin/env bash
#
# transplant.sh — turn a Windows Unity (Mono) build into a native Apple Silicon .app
# by grafting the game's cross-platform data onto a stock macOS ARM64 Unity player.
#
# Model: managed CIL + assets are architecture-neutral. The macOS player (built by you
# from the SAME Unity version) provides the native ARM64 engine, Mono runtime, UnityPlayer
# and Metal built-in shaders. We swap the Data payload and drop the x86-only native plugins
# (Burst etc.), which fall back to managed. No game binary is patched.
#
#   ./transplant.sh --win <WindowsGameDir> --mac-app <EmptyMac.app> --out <Ported.app>
#
# You provide:
#   --win      Windows game folder containing "<Name>_Data/", the .exe, MonoBleedingEdge/, UnityPlayer.dll
#   --mac-app  An EMPTY project built with the exact same Unity version (e.g. 2022.3.62f3),
#              target macOS / Apple Silicon. This is the native ARM64 player skeleton.
#   --out      Destination .app to create (overwritten if it exists).
#
# Options:
#   --dry-run       Print actions, change nothing.
#   --mac-ggm       Keep the Mac player's globalgamemanagers (try if the game refuses to
#                   start with a platform/graphics mismatch). Default: use the Windows one.
#   --win-builtin   Use the Windows built-in resources (unity default resources /
#                   unity_builtin_extra). Default: keep the Mac ones (Metal shader variants).
#   --no-sign       Skip ad-hoc codesign (NOT recommended on Apple Silicon — it won't launch).
#   -h|--help       This help.
#
# Empirical test points (documented in ../README.md):
#   * globalgamemanagers portability  -> --mac-ggm
#   * pink/black sprites (shader API)  -> toggle --win-builtin
set -euo pipefail

WIN=""; MACAPP=""; OUT=""; DRY=0; MAC_GGM=0; WIN_BUILTIN=0; SIGN=1
log(){ printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m! \033[0m%s\n' "$*" >&2; }
die(){ printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
run(){ if [ "$DRY" = 1 ]; then printf '   [dry] %s\n' "$*"; else eval "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --win) WIN="$2"; shift 2;;
    --mac-app) MACAPP="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    --mac-ggm) MAC_GGM=1; shift;;
    --win-builtin) WIN_BUILTIN=1; shift;;
    --no-sign) SIGN=0; shift;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

[ -n "$WIN" ] && [ -n "$MACAPP" ] && [ -n "$OUT" ] || die "need --win, --mac-app and --out (see --help)"
[ -d "$WIN" ] || die "--win not a directory: $WIN"
[ -d "$MACAPP" ] || die "--mac-app not a directory: $MACAPP"
case "$OUT" in *.app) :;; *) die "--out should end in .app";; esac

# ── locate source pieces ────────────────────────────────────────────────────
WIN_DATA="$(find "$WIN" -maxdepth 1 -type d -name '*_Data' | head -1)"
[ -n "$WIN_DATA" ] || die "no <Name>_Data/ under --win ($WIN)"
[ -f "$WIN_DATA/globalgamemanagers" ] || die "no globalgamemanagers in $WIN_DATA — is this a Unity build?"
[ -d "$WIN_DATA/Managed" ] || die "no Managed/ in $WIN_DATA"
if [ -f "$WIN_DATA/il2cpp_data" ] || [ -d "$WIN_DATA/il2cpp_data" ] || ls "$WIN"/GameAssembly.dll >/dev/null 2>&1; then
  die "this looks like IL2CPP, not Mono — a native transplant is not possible without source"
fi
[ -d "$WIN_DATA/MonoBleedingEdge" ] || [ -d "$WIN/MonoBleedingEdge" ] || warn "no MonoBleedingEdge found on Windows side (unusual, but we use the Mac Mono anyway)"

MAC_DATA="$MACAPP/Contents/Resources/Data"
[ -d "$MAC_DATA" ] || die "no Contents/Resources/Data in --mac-app — is it a macOS Unity build?"
MAC_PLAYER_DYLIB="$(find "$MACAPP/Contents" -maxdepth 3 -name 'UnityPlayer.dylib' | head -1 || true)"
[ -n "$MAC_PLAYER_DYLIB" ] || warn "UnityPlayer.dylib not found in --mac-app (some layouts embed it in the exe)"

# ── Unity version sanity check ──────────────────────────────────────────────
ver(){ LC_ALL=C strings -n 6 "$1/globalgamemanagers" 2>/dev/null | grep -aoE '[0-9]{4}\.[0-9]+\.[0-9]+[a-z][0-9]+' | head -1; }
WV="$(ver "$WIN_DATA" || true)"; MV="$(ver "$MAC_DATA" || true)"
log "Windows build Unity version: ${WV:-unknown}"
log "macOS  player Unity version: ${MV:-unknown}"
if [ -n "$WV" ] && [ -n "$MV" ] && [ "$WV" != "$MV" ]; then
  die "Unity version mismatch ($WV vs $MV). Build the empty Mac player with EXACTLY $WV."
fi

log "Windows Data: $WIN_DATA"
log "Output app:   $OUT   (from $MACAPP)"

# ── 1) clone the Mac player skeleton to --out ───────────────────────────────
run "rm -rf \"$OUT\""
run "rsync -a \"$MACAPP/\" \"$OUT/\""
OUT_DATA="$OUT/Contents/Resources/Data"

# ── 2) preserve the Mac-native bits we want to keep across the Data swap ─────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ "$WIN_BUILTIN" = 0 ]; then
  for f in "Resources/unity default resources" "Resources/unity_builtin_extra"; do
    if [ -e "$OUT_DATA/$f" ]; then run "mkdir -p \"$TMP/$(dirname "$f")\"" ; run "cp -p \"$OUT_DATA/$f\" \"$TMP/$f\""; fi
  done
fi
if [ "$MAC_GGM" = 1 ] && [ -f "$OUT_DATA/globalgamemanagers" ]; then run "cp -p \"$OUT_DATA/globalgamemanagers\" \"$TMP/globalgamemanagers.mac\""; fi

# ── 3) wholesale Data swap: Windows payload → Mac Data (IL + assets are portable) ──
# Copying the entire Managed/ is safe: engine DLLs are identical IL across platforms for the
# same Unity version, and this guarantees every package the game uses (URP, 2D Animation, …).
run "rm -rf \"$OUT_DATA\""
run "mkdir -p \"$OUT_DATA\""
run "rsync -a \"$WIN_DATA/\" \"$OUT_DATA/\""

# ── 4) strip x86-only native plugins (Burst etc.) → managed fallback ─────────
for d in x86_64 x86; do
  if [ -d "$OUT_DATA/Plugins/$d" ]; then log "dropping x86 native plugins: Plugins/$d"; run "rm -rf \"$OUT_DATA/Plugins/$d\""; fi
done
# never carry over the Windows Mono runtime / native player if they slipped into Data
run "rm -rf \"$OUT_DATA/MonoBleedingEdge\""

# ── 5) restore the Mac-native pieces ────────────────────────────────────────
if [ "$WIN_BUILTIN" = 0 ]; then
  for f in "Resources/unity default resources" "Resources/unity_builtin_extra"; do
    if [ -e "$TMP/$f" ]; then run "mkdir -p \"$OUT_DATA/$(dirname "$f")\""; run "cp -p \"$TMP/$f\" \"$OUT_DATA/$f\""; log "kept Mac built-in resource: $f"; fi
  done
fi
if [ "$MAC_GGM" = 1 ] && [ -f "$TMP/globalgamemanagers.mac" ]; then run "cp -p \"$TMP/globalgamemanagers.mac\" \"$OUT_DATA/globalgamemanagers\""; log "using Mac globalgamemanagers"; fi

# ── 6) Gatekeeper: strip quarantine + ad-hoc sign (required on Apple Silicon) ─
run "xattr -dr com.apple.quarantine \"$OUT\" || true"
if [ "$SIGN" = 1 ]; then
  log "ad-hoc code signing (Apple Silicon requires a valid signature to launch)"
  run "codesign --remove-signature \"$OUT\" 2>/dev/null || true"
  run "codesign --force --deep --sign - \"$OUT\"" || warn "codesign failed — the app may be Gatekeeper-blocked; sign manually"
fi

log "done → $OUT"
cat <<EOF

Next:
  open "$OUT"                # or run the executable in Contents/MacOS directly to see stdout
  # watch for:
  #   • pink / black sprites  -> re-run with --win-builtin (shader variant issue)
  #   • refuses to start / platform mismatch -> re-run with --mac-ggm
  # saves land in: ~/Library/Application Support/Orsoniks/CasualtiesUnknown/
  # engine log:    ~/Library/Logs/Orsoniks/CasualtiesUnknown/Player.log
EOF
