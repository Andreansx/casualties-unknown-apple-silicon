#!/usr/bin/env bash
#
# port.sh - ONE COMMAND: Windows Unity build -> native ARM64 + Metal macOS .app.
#
# This is transplant.sh PLUS everything that used to be applied by hand afterwards and was
# therefore re-discovered painfully on every rebuild (ROADMAP: "fold into transplant.sh when
# rebuilding"). Nothing here is new science - it is the exact recipe that produced the working
# 5.1 port, parameterised so the 7.0 demo (and 8.0, and 1.0) is a single invocation.
#
#   ./port.sh --win ~/Games/CU_demo_7 --out ~/Applications/Casualties.Unknown.Demo.v7.0.macOS.arm64.Metal.Native.app
#
# Steps (each is a documented fix - see ROADMAP.md "Native runtime fixes" + docs/port-7.0.md):
#   1. transplant   Windows Data -> stock macOS ARM64 Unity player (donor), x86 plugins dropped
#   2. BCL swap     22 .NET assemblies from the DONOR over the game's WINDOWS-flavor ones.
#                   The Windows BCL P/Invokes kernel32 -> EntryPointNotFoundException x69k ->
#                   "Instantiating Chunks" INFINITE HANG on Descend. Game code stays the game's.
#   3. symlinks     Contents/Lang + Contents/custommusic -> Resources/Data/*  (macOS dataPath is
#                   <app>/Contents, not Contents/Resources/Data). INSIDE Contents: bundle-ROOT
#                   symlinks break codesign sealing.
#   4. de-burst     drop the donor's lib_burst_generated.bundle (hash-mismatched with the game's
#                   assemblies) -> Burst falls back to managed. SpriteSkin deformation verified.
#   5. identity     rename the bundle exec off the donor's "EmptyMac" so powermetrics/Activity
#                   Monitor show a real name; set CFBundle* metadata.
#   6. ggm patches  shaderPlatform 4->14 + m_GraphicsAPIs 2->16 (Metal); vSyncCount=1 in the low
#                   quality levels (THE 37W BUG); Retina off (4x pixels otherwise).
#   7. shaders      40 stock transplanted from the donor; every custom Shader Graph converted
#                   DXBC->MSL via Unity's own HLSLcc. Verified with a real metal compile.
#   8. sign+verify  ad-hoc codesign (REQUIRED on Apple Silicon) then headless verification.
#
# Options:
#   --win <dir>     Windows game folder (contains <Name>_Data/, .exe, UnityPlayer.dll)   [required]
#   --out <app>     destination .app                                                     [required]
#   --donor <app>   macOS ARM64 donor player, same Unity version   [default: repo EmptyMac.app]
#   --exec-name <n> bundle executable name                         [default: CasualtiesUnknown]
#   --keep-exec     keep the donor's executable name (skip step 5)
#   --no-shaders    skip step 7 (fast structural rebuild)
#   --no-sign       skip step 8
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

WIN=""; OUT=""; DONOR="$REPO/EmptyMac.app"; EXEC_NAME="CasualtiesUnknown"
# TWO donors, and they are NOT interchangeable:
#   --donor         the player SKELETON (native ARM64 UnityPlayer/Mono/built-in resources)
#   --shader-donor  the DonorSetup build, whose Always-Included-Shaders list forces all 40 stock
#                   shaders to compile to Metal. A plain empty build does NOT contain them, and
#                   transplant_stock.py then skips all 40 with "NOT IN DONOR" -> a build that
#                   looks fine and renders pink. Guarded below.
SHADER_DONOR="$HOME/UnityProjects/EmptyMac/Build/Donor.app"
# NB: this also decides persistentDataPath (~/Library/Application Support/<id>) - i.e. where
# saves and keybinds.json live. Changing it starts the game with a fresh bind table; step 5
# migrates keybinds.json so the RMB->LeftAlt trackpad fix survives.
BUNDLE_ID="com.orsoniks.casualtiesunknown.metal"
DO_SHADERS=1; DO_SIGN=1; DO_RENAME=1

die(){ printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
say(){ printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok(){  printf '  \033[1;32m✓\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --win)       WIN="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    --donor)     DONOR="$2"; shift 2 ;;
    --shader-donor) SHADER_DONOR="$2"; shift 2 ;;
    --exec-name) EXEC_NAME="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --keep-exec) DO_RENAME=0; shift ;;
    --no-shaders) DO_SHADERS=0; shift ;;
    --no-sign)   DO_SIGN=0; shift ;;
    -h|--help)   sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$WIN" ] && [ -n "$OUT" ] || die "need --win and --out (see --help)"
[ -d "$WIN" ]   || die "no such Windows build dir: $WIN"
[ -d "$DONOR" ] || die "no such donor .app: $DONOR"

WIN_DATA="$(echo "$WIN"/*_Data)"
[ -d "$WIN_DATA" ] || die "no <Name>_Data/ inside $WIN - is that a Unity build?"

# iCloud re-stamps com.apple.FinderInfo, which BREAKS codesign. Refuse to build into it.
case "$OUT" in
  "$HOME/Documents"/*|"$HOME/Library/Mobile Documents"/*|"$HOME/Desktop"/*)
    die "refusing to build into iCloud-synced path ($OUT).
    iCloud re-stamps com.apple.FinderInfo and codesign then fails.
    Build into ~/Applications (local) instead." ;;
esac

# ── Unity version must match the donor exactly ──────────────────────────────
uver(){ /usr/bin/strings -a "$1" 2>/dev/null | /usr/bin/grep -m1 -E '^[0-9]{4}\.[0-9]+\.[0-9]+[a-z][0-9]+' || true; }
WV="$(uver "$WIN_DATA/globalgamemanagers")"
DV="$(uver "$DONOR/Contents/Resources/Data/globalgamemanagers")"
[ -n "$WV" ] && [ "$WV" = "$DV" ] || die "Unity version mismatch: game=$WV donor=$DV
    The donor MUST be an empty project built from the game's EXACT Unity version.
    Rebuild the donor with tools/donor/DonorSetup.cs."
if [ "$DO_SHADERS" = 1 ]; then
  [ -d "$SHADER_DONOR" ] || die "no shader donor at $SHADER_DONOR
    This is the DonorSetup build (tools/donor/README.md), NOT the plain player skeleton.
    Without it all 40 stock shaders are skipped and the game renders pink.
    Pass --shader-donor <app>, or rebuild it:
      Unity -batchmode -quit -projectPath ~/UnityProjects/EmptyMac -executeMethod DonorSetup.Build"
  SV="$(uver "$SHADER_DONOR/Contents/Resources/Data/globalgamemanagers")"
  [ "$SV" = "$WV" ] || die "shader donor is Unity $SV but the game is $WV"
fi
say "Unity $WV - game and donor(s) agree"

# ── python with UnityPy (persistent; the session scratchpad does not survive) ─
VENV="$HOME/.cache/casualties-port/venv"
PY="$VENV/bin/python"
if [ ! -x "$PY" ]; then
  say "creating UnityPy venv at $VENV (one time)…"
  mkdir -p "$(dirname "$VENV")"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install UnityPy lz4 || die "pip install UnityPy lz4 failed"
fi
"$PY" -c 'import UnityPy, lz4.block' 2>/dev/null || die "venv at $VENV lacks UnityPy/lz4"

if [ "$DO_SHADERS" = 1 ] && [ ! -x "$HERE/hlslcc/hlslcc-cli" ]; then
  say "building Unity HLSLcc (one time)…"
  "$HERE/hlslcc/build.sh" || die "hlslcc build failed"
fi

DATA="$OUT/Contents/Resources/Data"

# ── 1. transplant ───────────────────────────────────────────────────────────
say "1/8  transplant: $WIN -> $OUT"
"$HERE/transplant.sh" --win "$WIN" --mac-app "$DONOR" --out "$OUT" --no-sign >/dev/null
ok "grafted onto the native ARM64 player"

# ── 2. BCL swap (the "Instantiating Chunks" infinite hang) ──────────────────
say "2/8  BCL swap: donor's .NET assemblies over the game's Windows-flavor ones"
DMAN="$DONOR/Contents/Resources/Data/Managed"
GMAN="$DATA/Managed"
BCL_BAK="$OUT/Contents/Resources/bcl-backup-win"
mkdir -p "$BCL_BAK"
n=0
for f in "$DMAN"/*.dll; do
  b="$(basename "$f")"
  case "$b" in
    mscorlib.dll|netstandard.dll|Mono.Security.dll|System.dll|System.*.dll) ;;
    *) continue ;;
  esac
  [ -f "$GMAN/$b" ] || continue          # only replace what the game actually ships
  cp -p "$GMAN/$b" "$BCL_BAK/$b"
  cp -p "$f" "$GMAN/$b"
  n=$((n+1))
done
[ "$n" -ge 20 ] || die "only swapped $n BCL assemblies (expected ~22) - donor Managed/ looks wrong"
ok "$n BCL assemblies swapped (Windows originals kept in Contents/Resources/bcl-backup-win)"

# ── 3. dataPath symlinks (language files + custom music) ────────────────────
say "3/8  dataPath symlinks (macOS dataPath = <app>/Contents)"
for d in Lang custommusic; do
  if [ -d "$DATA/$d" ]; then
    ln -sfn "Resources/Data/$d" "$OUT/Contents/$d"
    ok "Contents/$d -> Resources/Data/$d"
  fi
done

# ── 4. de-burst ─────────────────────────────────────────────────────────────
say "4/8  removing the donor's Burst bundle (hash-mismatched -> managed fallback)"
if [ -e "$OUT/Contents/PlugIns/lib_burst_generated.bundle" ]; then
  rm -rf "$OUT/Contents/PlugIns/lib_burst_generated.bundle"; ok "lib_burst_generated.bundle removed"
else
  ok "none present"
fi

# ── 5. bundle identity ──────────────────────────────────────────────────────
PLIST="$OUT/Contents/Info.plist"
if [ "$DO_RENAME" = 1 ]; then
  say "5/8  bundle identity: exec -> $EXEC_NAME"
  CUR="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
  if [ "$CUR" != "$EXEC_NAME" ]; then
    mv "$OUT/Contents/MacOS/$CUR" "$OUT/Contents/MacOS/$EXEC_NAME"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXEC_NAME" "$PLIST"
  fi
  OLD_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Casualties Unknown"      "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID"        "$PLIST" 2>/dev/null || true
  ok "process will show as '$EXEC_NAME' (was '$CUR')"

  # Application.version on macOS = CFBundleShortVersionString from THIS Info.plist - NOT the
  # bundleVersion in globalgamemanagers (that is the Windows path). The donor is an empty Unity
  # project, whose default is "1.0", so without this the game's own beta banner renders
  # "This is a beta build (1.0)" while the Windows/D3DMetal build correctly says 7.0.1.
  # Source of truth = the GAME's ggm, so this tracks the real version across releases.
  GAME_VER="$(strings -a "$WIN_DATA/globalgamemanagers" \
              | grep -m1 -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || true)"
  if [ -n "$GAME_VER" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $GAME_VER" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GAME_VER"            "$PLIST" 2>/dev/null || true
    ok "Application.version -> $GAME_VER (was the donor's 1.0)"
  else
    say "     WARNING: could not read game version from ggm - beta banner will show the donor's 1.0"
  fi

  # persistentDataPath on macOS is ~/Library/Application Support/<CFBundleIdentifier> - so
  # changing the bundle id MOVES the game's settings/save directory. That directory holds the
  # bind table, and the RMB->LeftAlt trackpad fix lives in it, so a fresh id silently restores
  # DEFAULT binds (iteminteract = Mouse1) and the tutorial's right-click DRAG becomes unusable.
  # NB: 7.0 keeps binds in settings.json (ints); 5.1 used keybinds.json (names). Carry both.
  SUP="$HOME/Library/Application Support"
  if [ "$OLD_ID" != "$BUNDLE_ID" ]; then
    for f in settings.json keybinds.json; do
      if [ -f "$SUP/$OLD_ID/$f" ] && [ ! -f "$SUP/$BUNDLE_ID/$f" ]; then
        mkdir -p "$SUP/$BUNDLE_ID"
        cp -p "$SUP/$OLD_ID/$f" "$SUP/$BUNDLE_ID/$f"
        ok "migrated $f from $OLD_ID"
      fi
    done
  fi
  say "     after first launch: tools/rewrap/patch_keybinds.py iteminteract LeftAlt"
else
  say "5/8  bundle identity: --keep-exec, leaving as-is"
fi

# ── 6. globalgamemanagers patches ───────────────────────────────────────────
say "6/8  globalgamemanagers: Metal + vsync + retina + screen-lock fix"
"$PY" "$HERE/rewrap/patch_ggm_metal.py"  "$DATA/globalgamemanagers" | sed 's/^/     /'
"$PY" "$HERE/rewrap/patch_ggm_vsync.py"  "$DATA/globalgamemanagers" | sed 's/^/     /'
"$PY" "$HERE/rewrap/patch_ggm_retina.py" "$DATA/globalgamemanagers" off | sed 's/^/     /'
# runInBackground=True makes the player keep driving the Metal loop while the display is
# ASLEEP, against a CAMetalLayer with no acquirable drawable -> it wedges and never recovers
# (HUD frozen on "Composited", process must be killed). False parks the loop on resign-active
# and it resumes instantly on unlock. USER-CONFIRMED FIX - do not drop this on a rebuild.
"$PY" "$HERE/rewrap/patch_ggm_bool.py" "$DATA/globalgamemanagers" runInBackground off | sed 's/^/     /'

# ── 7. shaders ──────────────────────────────────────────────────────────────
if [ "$DO_SHADERS" = 1 ]; then
  say "7/8  shaders: stock transplant + custom DXBC->MSL (this is the slow part)"
  STOCK_LOG="$(mktemp)"
  "$PY" "$HERE/rewrap/transplant_stock.py" \
      --donor-data "$SHADER_DONOR/Contents/Resources/Data" --game-data "$DATA" > "$STOCK_LOG" 2>&1 \
      || { tail -20 "$STOCK_LOG"; die "transplant_stock.py failed"; }
  tail -1 "$STOCK_LOG" | sed 's/^/     /'
  # "transplanted 0 stock shaders" means the shader donor is the wrong build - a silent
  # pink-render bug that shipped once already. Never let it pass again.
  if grep -q "^transplanted 0 " "$STOCK_LOG"; then
    grep -c "NOT IN DONOR" "$STOCK_LOG" | sed 's/^/     NOT IN DONOR: /'
    die "0 stock shaders transplanted - $SHADER_DONOR is not a DonorSetup build (see tools/donor/README.md)"
  fi
  rm -f "$STOCK_LOG"
  "$PY" "$HERE/rewrap/inject_custom_metal2.py" \
      --src-data "$WIN_DATA" --dst-data "$DATA" --compile-check | tail -6 | sed 's/^/     /'
else
  say "7/8  shaders: SKIPPED (--no-shaders)"
fi

# ── 8. sign + verify ────────────────────────────────────────────────────────
if [ "$DO_SIGN" = 1 ]; then
  say "8/8  ad-hoc codesign (required on Apple Silicon)"
  xattr -cr "$OUT" 2>/dev/null || true
  codesign --remove-signature "$OUT" 2>/dev/null || true
  codesign --force --deep --sign - "$OUT" 2>/dev/null || die "codesign failed (FinderInfo/iCloud?)"
  codesign --verify --deep --strict "$OUT" 2>/dev/null && ok "signature verifies"
else
  say "8/8  signing: SKIPPED (--no-sign) - it will NOT launch on Apple Silicon"
fi

echo
say "verification (headless - no display needed)"
BIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
ARCHS="$(lipo -archs "$OUT/Contents/MacOS/$BIN")"
case "$ARCHS" in *arm64*) ok "executable '$BIN' has an arm64 slice [$ARCHS]" ;;
                 *) die "NO arm64 slice ($ARCHS) - that is the x86 player!" ;; esac
for d in Lang custommusic; do
  [ -d "$DATA/$d" ] && { [ -d "$OUT/Contents/$d" ] && ok "Contents/$d resolves" || die "broken symlink: Contents/$d"; }
done
[ -e "$OUT/Contents/PlugIns/lib_burst_generated.bundle" ] && die "burst bundle still present"
ok "no Burst bundle"
if [ "$DO_SHADERS" = 1 ]; then
  "$PY" "$HERE/rewrap/verify_metal.py" "$DATA" | sed 's/^/     /'
fi

echo
say "DONE -> $OUT"
say "launch it (needs an unlocked Mac with a display):  tools/run-native.sh \"$OUT\""
