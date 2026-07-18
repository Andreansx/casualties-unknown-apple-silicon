#!/usr/bin/env bash
#
# mp-install.sh - ONE COMMAND: install the "Casualties: Together" co-op mod (KrokMP) into a
#                 ported native arm64 .app, adapted for macOS. No Rosetta.
#
#   ./mp-install.sh --app ~/Applications/Casualties.Unknown....app --mod ~/Downloads/KrokMP\ 67\ 4.0.1
#
# This is a POST-port.sh step: port.sh strips Plugins/x86_64 and re-signs the whole bundle, so it
# must run first (B9). Re-run this after every port.sh rebuild.
#
# Everything the mod ships is Windows-flavoured; this script is the macOS adapter (blocker ids
# refer to docs/multiplayer-port.md):
#   1. BepInEx      the macOS-UNIVERSAL build (the mod's guide points at BepInEx_win_x64 - wrong
#                   platform entirely). Laid INSIDE the bundle: BepInEx's root is derived from
#                   DOORSTOP_INVOKE_DLL_PATH (PreloaderRunner: ParentDirectory(dll, 2)), not from
#                   the executable, so Contents/BepInEx works and the .app stays self-contained.
#                   COST of that choice: BepInEx writes its log/config/cache back into the bundle,
#                   so after the first modded launch `codesign --verify --deep --strict` reports
#                   "a sealed resource is missing or invalid". Harmless here - the kernel validates
#                   the main Mach-O (which is untouched), and Gatekeeper only re-checks resources
#                   for quarantined apps, which a locally built ad-hoc-signed .app is not. Verified
#                   empirically: the game launches fine over and over with the seal broken.
#   2. arm64 fix    tools/bepinex-applesilicon - without it BepInEx's FIRST detour dies under
#                   Mono's MAP_JIT W^X and the preloader crashes before any plugin loads (B2).
#                   Injected as the Doorstop ENTRYPOINT (a BepInEx patcher is too late).
#   3. plugins      the mod's assemblies are all AnyCPU MSIL - nothing to recompile (B6 dissolved).
#   4. natives      opus.dll -> libopus.dylib (B5). steam_api64.dll is left out: it needs the
#                   universal libsteam_api.dylib AND a Steamworks.NET rebuilt with
#                   STEAMWORKS_LIN_OSX (B3/B4, Phase 2) - so this install runs --ksmulti-nosteam
#                   and multiplayer is direct-IP, which is exactly how the mod behaves when Steam
#                   is absent (KSteam.Loaded=false -> Direct Connect UI).
#   5. updater      autoupdater_patcher.dll is DROPPED (B8): it clones a staged update over
#                   Environment.CurrentDirectory and would overwrite every adapted file here.
#                   Multiupdater.dll is KEPT - the mod's settings GUI (DrawUpdateButton) references
#                   Multiupdater.AutoUpdater, so removing it throws TypeLoadException inside OnGUI.
#                   With the patcher gone, a staged update is simply never applied.
#   6. mic         NSMicrophoneUsageDescription, or the first Microphone.Start() TCC-KILLS the
#                   process (macOS does not merely deny it) (B7).
#   7. game-hash   Contents/Managed -> Resources/Data/Managed. The mod hashes
#                   Application.dataPath + "/Managed/Assembly-CSharp.dll"; on macOS dataPath is
#                   <app>/Contents, so without the symlink the hash stays 0 and a server with
#                   SERVER_TOGGLE_CHECK_GAME_HASH rejects us. Our Assembly-CSharp.dll is
#                   byte-identical to the Windows build, so with it we hash like a Windows player
#                   and cross-play survives (B11).
#   8. launcher    Doorstop needs DYLD_INSERT_LIBRARIES, so the modded game starts through a
#                   launcher (double-clicking the .app still starts VANILLA - by design).
#   9. sign        ad-hoc re-sign; required on Apple Silicon (B9).
#
# Options:
#   --app <app>        the ported .app to install into                              [required]
#   --mod <dir|zip>    the KrokMP download (the folder holding mod/, or its zip)     [required]
#   --bepinex <dir|zip> BepInEx macOS-universal 5.4.23.x  [default: cached, downloaded if absent]
#   --opus <dylib>     libopus.dylib to ship             [default: brew's, else voice is disabled]
#   --uninstall        remove the mod and restore the bundle (needs --app only)
#   --no-sign          skip the re-sign (the app will NOT launch on Apple Silicon)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

APP=""; MOD=""; BEPZIP=""; OPUS=""; DO_SIGN=1; UNINSTALL=0
BEP_VER="5.4.23.5"
BEP_URL="https://github.com/BepInEx/BepInEx/releases/download/v${BEP_VER}/BepInEx_macos_universal_${BEP_VER}.zip"
CACHE="$HOME/.cache/casualties-port"

die(){ printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
say(){ printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok(){  printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m!\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app)       APP="$2"; shift 2 ;;
    --mod)       MOD="$2"; shift 2 ;;
    --bepinex)   BEPZIP="$2"; shift 2 ;;
    --opus)      OPUS="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --no-sign)   DO_SIGN=0; shift ;;
    -h|--help)   sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$APP" ] || die "need --app <Game.app> (see --help)"
[ -d "$APP" ] || die "no such .app: $APP"
APP="$(cd "$APP" && pwd)"
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || die "$APP has no Contents/Info.plist - not an .app"
EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
CONTENTS="$APP/Contents"
BEP="$CONTENTS/BepInEx"
CORE="$BEP/core"
LAUNCHER="$CONTENTS/MacOS/coop-launch"
CMD="$(dirname "$APP")/$(basename "$APP" .app)-coop.command"

resign(){
  [ "$DO_SIGN" = 1 ] || { say "signing SKIPPED (--no-sign) - it will NOT launch on Apple Silicon"; return; }
  say "ad-hoc codesign (required on Apple Silicon)"
  xattr -cr "$APP" 2>/dev/null || true
  codesign --remove-signature "$APP" 2>/dev/null || true
  codesign --force --deep --sign - "$APP" 2>/dev/null || die "codesign failed (FinderInfo/iCloud?)"
  ok "signed"
}

# ── uninstall ───────────────────────────────────────────────────────────────
if [ "$UNINSTALL" = 1 ]; then
  say "uninstalling the co-op mod from $APP"
  rm -rf "$BEP" "$CONTENTS/Frameworks/libdoorstop.dylib" "$LAUNCHER" \
         "$CONTENTS/steam_appid.txt" "$CONTENTS/PlugIns/libopus.dylib" "$CMD"
  [ -L "$CONTENTS/Managed" ] && rm -f "$CONTENTS/Managed" || true
  /usr/libexec/PlistBuddy -c 'Delete :NSMicrophoneUsageDescription' "$PLIST" 2>/dev/null || true
  ok "mod files removed (saves in ~/Library/Application Support are untouched)"
  resign
  say "DONE - $APP is vanilla again"
  exit 0
fi

[ -n "$MOD" ] || die "need --mod <KrokMP dir or zip> (see --help)"

# ── 0. sanity ───────────────────────────────────────────────────────────────
say "0/9  checking the target"
ARCHS="$(lipo -archs "$CONTENTS/MacOS/$EXEC_NAME")"
case "$ARCHS" in *arm64*) ok "'$EXEC_NAME' has an arm64 slice [$ARCHS]" ;;
                 *) die "no arm64 slice ($ARCHS) - this is not the native port" ;; esac
[ -f "$CONTENTS/Resources/Data/Managed/Assembly-CSharp.dll" ] \
  || die "no Resources/Data/Managed/Assembly-CSharp.dll - is this a ported Unity app?"

# mod payload: accept the download folder, the inner mod/ folder, or a zip
WORKTMP=""
cleanup(){ [ -n "$WORKTMP" ] && rm -rf "$WORKTMP"; }
trap cleanup EXIT
case "$MOD" in
  *.zip) WORKTMP="$(mktemp -d)"; unzip -q "$MOD" -d "$WORKTMP/mod"; MOD="$WORKTMP/mod" ;;
esac
[ -d "$MOD" ] || die "no such mod payload: $MOD"
MODSRC="$(/usr/bin/find "$MOD" -type d -name KrokMP -path '*plugins*' -print -quit)"
[ -n "$MODSRC" ] || die "no BepInEx/plugins/KrokMP inside $MOD - is that the KrokMP download?"
[ -f "$MODSRC/KrokoshaCasualtiesMP.dll" ] || die "no KrokoshaCasualtiesMP.dll in $MODSRC"
ok "mod payload: $MODSRC"

# ── 1. BepInEx (macOS universal) ────────────────────────────────────────────
say "1/9  BepInEx $BEP_VER (macOS universal) -> Contents/BepInEx"
if [ -z "$BEPZIP" ]; then
  BEPZIP="$CACHE/BepInEx_macos_universal_${BEP_VER}.zip"
  if [ ! -f "$BEPZIP" ]; then
    mkdir -p "$CACHE"
    say "     downloading $BEP_URL"
    curl -fsSL -o "$BEPZIP" "$BEP_URL" || { rm -f "$BEPZIP"; die "download failed - pass --bepinex <zip>"; }
  fi
fi
BEPSRC=""
if [ -d "$BEPZIP" ]; then
  BEPSRC="$BEPZIP"
else
  WORKTMP="${WORKTMP:-$(mktemp -d)}"; mkdir -p "$WORKTMP/bep"
  unzip -oq "$BEPZIP" -d "$WORKTMP/bep" || die "cannot unzip $BEPZIP"
  BEPSRC="$WORKTMP/bep"
fi
[ -f "$BEPSRC/BepInEx/core/BepInEx.Preloader.dll" ] || die "no BepInEx/core in $BEPSRC"
[ -f "$BEPSRC/libdoorstop.dylib" ] || die "no libdoorstop.dylib in $BEPSRC - that is not the macOS build
    (the mod's INSTALLATION.txt points at BepInEx_win_x64, which is the WINDOWS build)"
case "$(lipo -archs "$BEPSRC/libdoorstop.dylib")" in
  *arm64*) ;; *) die "libdoorstop.dylib has no arm64 slice" ;;
esac

# keep the user's config/plugins across re-installs; replace core outright
rm -rf "$CORE"
mkdir -p "$BEP" "$CONTENTS/Frameworks"
cp -a "$BEPSRC/BepInEx/core" "$CORE"
cp -a "$BEPSRC/libdoorstop.dylib" "$CONTENTS/Frameworks/libdoorstop.dylib"
ok "core + libdoorstop ($(lipo -archs "$CONTENTS/Frameworks/libdoorstop.dylib"))"

# ── 2. the Apple Silicon detour fix ─────────────────────────────────────────
say "2/9  Apple Silicon detour fix (B2) -> BepInEx/core"
DIST="$HERE/bepinex-applesilicon/dist"
if [ ! -f "$DIST/AppleSiliconShim.dll" ] || [ ! -f "$DIST/libas_jit.dylib" ] \
   || [ "$HERE/bepinex-applesilicon/src/Entrypoint.cs" -nt "$DIST/AppleSiliconShim.dll" ]; then
  say "     building it (needs dotnet + clang)…"
  "$HERE/bepinex-applesilicon/build.sh" --core "$CORE" >/dev/null || die "bepinex-applesilicon build failed"
fi
cp -f "$DIST/AppleSiliconShim.dll" "$CORE/AppleSiliconShim.dll"
cp -f "$DIST/libas_jit.dylib"      "$CORE/libas_jit.dylib"
ok "AppleSiliconShim.dll + libas_jit.dylib ($(lipo -archs "$CORE/libas_jit.dylib"))"

# ── 3. the mod's plugins ────────────────────────────────────────────────────
say "3/9  KrokMP plugins -> BepInEx/plugins/KrokMP"
PLUG="$BEP/plugins/KrokMP"
rm -rf "$PLUG"; mkdir -p "$PLUG"
n=0
for f in "$MODSRC"/*.dll; do
  b="$(basename "$f")"
  case "$b" in
    # Windows natives - replaced (opus) or deferred to Phase 2 (steam)
    opus.dll|steam_api64.dll) continue ;;
  esac
  cp -p "$f" "$PLUG/$b"; n=$((n+1))
done
ok "$n managed assemblies (AnyCPU MSIL - Mono JITs them arm64 unchanged)"
# B8: the patcher is what applies a staged update over the game dir. Never install it.
if [ -d "$(dirname "$(dirname "$MODSRC")")/patchers" ]; then
  warn "autoupdater_patcher NOT installed (B8) - it would overwrite these adapted files"
fi

# ── 4. natives ──────────────────────────────────────────────────────────────
say "4/9  native libraries"
if [ -z "$OPUS" ]; then
  for c in /opt/homebrew/opt/opus/lib/libopus.dylib /usr/local/opt/opus/lib/libopus.dylib; do
    if [ -f "$c" ]; then OPUS="$c"; break; fi
  done
fi
mkdir -p "$CONTENTS/PlugIns"
if [ -n "$OPUS" ] && [ -f "$OPUS" ]; then
  # OpusSharp does DllImport("opus"); Mono resolves that to libopus.dylib on the native search
  # path. PlugIns/ is the Unity player's own native-plugin dir, and the launcher adds it to
  # DYLD_LIBRARY_PATH. Copy the real file (brew ships symlinks).
  cp -L "$OPUS" "$CONTENTS/PlugIns/libopus.dylib"
  ok "libopus.dylib ($(lipo -archs "$CONTENTS/PlugIns/libopus.dylib")) - voice chat enabled"
else
  warn "no libopus.dylib found (brew install opus) - voice chat will be unavailable"
fi
warn "steam_api64.dll NOT installed - Steam lobbies are Phase 2 (B3/B4); direct-IP works now"

# ── 5. microphone permission (B7) ───────────────────────────────────────────
say "5/9  Info.plist: NSMicrophoneUsageDescription (B7)"
/usr/libexec/PlistBuddy -c 'Delete :NSMicrophoneUsageDescription' "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string Voice chat in co-op multiplayer.' "$PLIST"
ok "set (without it the first Microphone.Start() TCC-kills the process)"

# ── 6. game-hash symlink (B11) ──────────────────────────────────────────────
say "6/9  Contents/Managed -> Resources/Data/Managed (B11)"
ln -sfn "Resources/Data/Managed" "$CONTENTS/Managed"
[ -f "$CONTENTS/Managed/Assembly-CSharp.dll" ] || die "symlink does not resolve"
ok "the mod's FNV-1a game-hash now sees Assembly-CSharp.dll (cross-play with Windows)"

# steam_appid.txt: Steamworks reads it from the CWD, and the launcher cd's to Contents/.
APPID_SRC="$(/usr/bin/find "$MOD" -name steam_appid.txt -print -quit)"
[ -n "$APPID_SRC" ] && cp -p "$APPID_SRC" "$CONTENTS/steam_appid.txt" && \
  ok "steam_appid.txt ($(cat "$CONTENTS/steam_appid.txt")) staged for Phase 2" || true

# ── 7. launcher ─────────────────────────────────────────────────────────────
say "7/9  launcher (Doorstop needs DYLD_INSERT_LIBRARIES)"
# Steam is not wired up yet, so force the mod's no-Steam path: with the Windows Steamworks.NET
# still in place, DllCheck.Test() would P/Invoke kernel32 and throw. --ksmulti-nosteam returns
# from KSteam.CheckSteam() before that (Plugin.FORCE_NO_STEAM), and the UI falls back to
# Direct Connect over LiteNetLib.
EXTRA_ARGS="--ksmulti-nosteam"
cat > "$LAUNCHER" <<LAUNCH
#!/bin/sh
# Launch this game with BepInEx + Casualties: Together, natively on arm64.
# Generated by tools/mp-install.sh - self-locating, so the .app can be moved anywhere.
set -e
a="/\$0"; a=\${a%/*}; a=\${a#/}; a=\${a:-.}; MACOS=\$(cd "\$a" && pwd -P)
CONTENTS=\$(dirname "\$MACOS")

export DOORSTOP_ENABLED=1
export DOORSTOP_IGNORE_DISABLED_ENV=1
# The Doorstop target is OUR shim, not BepInEx.Preloader: it installs the arm64 detour platform
# and then chains to the real preloader. BepInEx's root is derived from this path (two levels up).
export DOORSTOP_TARGET_ASSEMBLY="\$CONTENTS/BepInEx/core/AppleSiliconShim.dll"
export DOORSTOP_MONO_DLL_SEARCH_PATH_OVERRIDE="\$CONTENTS/BepInEx/core:\$CONTENTS/Resources/Data/Managed"
export ARCHPREFERENCE="arm64,x86_64"
cd "\$CONTENTS"

# 'arch' strips every DYLD_* variable unless it is passed with -e, and it is needed to guarantee
# the arm64 slice (a universal binary inherits the parent process's arch otherwise).
exec arch -arm64 \\
  -e DYLD_INSERT_LIBRARIES="\$CONTENTS/Frameworks/libdoorstop.dylib" \\
  -e DYLD_LIBRARY_PATH="\$CONTENTS/PlugIns:\$CONTENTS/Frameworks:\$CONTENTS/Resources/Data/Managed" \\
  "\$MACOS/$EXEC_NAME" $EXTRA_ARGS "\$@"
LAUNCH
chmod +x "$LAUNCHER"
ok "in-bundle: Contents/MacOS/coop-launch"

APPBASE="$(basename "$APP")"
cat > "$CMD" <<CMDEOF
#!/bin/sh
# Double-click to play Casualties: Unknown with the co-op mod.
# Keep this file next to $APPBASE. Double-clicking the .app itself starts VANILLA.
a="/\$0"; a=\${a%/*}; a=\${a#/}; a=\${a:-.}; HERE=\$(cd "\$a" && pwd -P)
exec "\$HERE/$APPBASE/Contents/MacOS/coop-launch" "\$@"
CMDEOF
chmod +x "$CMD"
ok "double-clickable: $(basename "$CMD")"

# ── 8. sign ─────────────────────────────────────────────────────────────────
say "8/9  re-signing the bundle (B9)"
resign

# ── 9. verify ───────────────────────────────────────────────────────────────
say "9/9  verification"
for f in "$CORE/BepInEx.Preloader.dll" "$CORE/AppleSiliconShim.dll" "$CORE/libas_jit.dylib" \
         "$CONTENTS/Frameworks/libdoorstop.dylib" "$PLUG/KrokoshaCasualtiesMP.dll" "$LAUNCHER"; do
  [ -e "$f" ] || die "missing after install: $f"
done
ok "all files in place"
if [ -e "$BEP/patchers/KrokMP/autoupdater_patcher.dll" ]; then die "the auto-updater patcher got installed (B8)"; fi
ok "no auto-updater patcher"

echo
say "DONE -> $APP"
echo "  play (co-op):  \"$CMD\"   (or $LAUNCHER)"
echo "  play (vanilla): double-click the .app as usual"
echo "  the mod is direct-IP only until Steam lands (Phase 2): host, then share your IP:7790"
