#!/usr/bin/env bash
#
# mp-steam-probe.sh - answer "is the Steam path on this modded .app actually working?", headlessly.
#
#   ./mp-steam-probe.sh                 # probe the installed app as it stands
#   ./mp-steam-probe.sh --matrix        # run the full 4-way comparison (see below)
#
# WHY THIS EXISTS. From inside the game, every Steam problem looks the same: the mod just shows
# Direct Connect instead of the lobby browser. But the causes are very different, and one of them
# leaves the mod HALF-INITIALISED rather than merely Steam-less:
#
#   Steamworks initialized! <name> - <id>     Steam is up. Lobbies available.
#   Steamworks.NET: Init failed: <msg>        No Steam client (or not logged in / app not owned).
#                                             HARMLESS - KSteam.Loaded stays false, the UI falls
#                                             back to Direct Connect, direct IP works normally.
#   DllNotFoundException: steam_api[64]       BROKEN INSTALL. The exception escapes CheckSteam()
#                                             and aborts the rest of Plugin.Awake_Stage2(), so the
#                                             mod's assets and its multiplayer singleton GameObject
#                                             are never created. The game still runs and the log
#                                             still says "is loaded!", which is what makes this
#                                             worth a tool. Fix: re-run mp-install.sh.
#
# The last one happens whenever the macOS Steamworks.NET assembly and libsteam_api.dylib get out of
# sync - they are an atomic pair (docs/multiplayer-port.md §2h).
#
# --matrix reproduces the whole comparison on a throwaway APFS clone of the app, so it never
# touches your install:
#   A  Windows Steamworks.NET, no dylib, Steam path on   -> DllNotFoundException: steam_api64
#   B  macOS   Steamworks.NET, no dylib, Steam path on   -> DllNotFoundException: steam_api
#   C  macOS   Steamworks.NET + dylib,   Steam path on   -> Valve init result  <- the good one
#   D  Windows Steamworks.NET, --ksmulti-nosteam         -> clean, Steam never touched
#
# Options:
#   --app <app>    the modded .app                 [default: the 7.0 demo port in ~/Applications]
#   --matrix       run all four configurations on a clone instead of probing the app as-is
#   --secs <n>     how long to let the game run before reading the log            [default: 50]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/Casualties.Unknown.Demo.v7.0.macOS.arm64.Metal.Native.app"
MATRIX=0; SECS=50
CACHE="$HOME/.cache/casualties-port"

die(){ printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
say(){ printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok(){  printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m!\033[0m %s\n' "$*"; }
bad(){ printf '  \033[1;31m✗\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app)    APP="$2"; shift 2 ;;
    --matrix) MATRIX=1; shift ;;
    --secs)   SECS="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[ -d "$APP" ] || die "no such .app: $APP  (pass --app)"
APP="$(cd "$APP" && pwd)"
[ -x "$APP/Contents/MacOS/coop-launch" ] \
  || die "$APP is not modded - run: tools/mp-install.sh --app \"$APP\" --mod <KrokMP download>"

# ── run one headless launch and classify what the mod said about Steam ──────
# The mod logs through BepInEx, not the Unity log, so that is what we read.
probe(){
  local app="$1"; shift
  local beplog="$app/Contents/BepInEx/LogOutput.log"
  # FORCE_NO_STEAM makes CheckSteam() return before it logs anything at all, so "no Steam verdict"
  # is the expected result there rather than an inconclusive run. The flag can come from the
  # launcher (a --no-steam install) or from these args (matrix case D).
  local nosteam=0
  grep -q -- "--ksmulti-nosteam" "$app/Contents/MacOS/coop-launch" && nosteam=1
  case " $* " in *" --ksmulti-nosteam "*) nosteam=1 ;; esac
  rm -f "$beplog"
  # subshell + redirect: timeout -s KILL makes the shell announce "Killed: 9", which is expected
  # here (we always kill it) and would only look like a failure.
  ( timeout -s KILL "$SECS" "$app/Contents/MacOS/coop-launch" \
      -batchmode -nographics -logFile /dev/null \
      --ksmulti-setname SteamProbe "$@" ) >/dev/null 2>&1
  [ -f "$beplog" ] || { bad "no BepInEx log - the mod did not load at all"; return 3; }

  if grep -qa "Steamworks initialized!" "$beplog"; then
    ok "$(grep -a "Steamworks initialized!" "$beplog" | tail -1 | sed 's/.*\] //')"
    ok "Steam is UP - lobbies available"
    return 0
  elif grep -qa "DllNotFoundException: steam_api" "$beplog"; then
    bad "$(grep -a "DllNotFoundException: steam_api" "$beplog" | tail -1 | sed 's/.*\] //')"
    bad "BROKEN INSTALL - the mod is half-initialised. Re-run mp-install.sh."
    grep -qa "Created multiplayer singleton GameObject!" "$beplog" \
      || bad "confirmed: the multiplayer singleton GameObject was never created"
    return 2
  elif grep -qa "Steamworks.NET: Init failed" "$beplog"; then
    warn "$(grep -a -A1 "Steamworks.NET: Init failed" "$beplog" | tail -1 | sed 's/^[[:space:]]*//')"
    warn "no Steam client reachable - direct IP still works (this is the graceful path)"
    grep -qa "Created multiplayer singleton GameObject!" "$beplog" \
      && ok "mod initialised fully anyway (multiplayer singleton created)"
    return 1
  elif [ "$nosteam" = 1 ]; then
    ok "Steam path disabled by --ksmulti-nosteam - direct IP only, by design"
    grep -qa "Created multiplayer singleton GameObject!" "$beplog" \
      && ok "mod initialised fully (multiplayer singleton created)"
    return 1
  else
    warn "no Steam verdict in the log - the run may have been too short (--secs)"
    return 3
  fi
}

# ── plain mode: probe the app exactly as installed ──────────────────────────
if [ "$MATRIX" = 0 ]; then
  say "probing $APP"
  DLL="$APP/Contents/BepInEx/plugins/KrokMP/Steamworks.NET.dll"
  DYL="$APP/Contents/PlugIns/libsteam_api.dylib"
  case "$(shasum -a 256 "$DLL" 2>/dev/null | cut -d' ' -f1)" in
    c56f12c2*) say "Steamworks.NET: macOS build (Pack=4)" ;;
    53b9a17b*) say "Steamworks.NET: WINDOWS build (Pack=8)" ;;
    *)         say "Steamworks.NET: unrecognised build" ;;
  esac
  [ -f "$DYL" ] && say "libsteam_api.dylib: $(lipo -archs "$DYL")" || say "libsteam_api.dylib: absent"
  say "launching headless for ${SECS}s…"
  probe "$APP"
  exit $?
fi

# ── matrix mode: four configurations on a throwaway clone ───────────────────
SWVER="$(strings -a "$APP/Contents/BepInEx/plugins/KrokMP/Steamworks.NET.dll" \
         | grep -Eo '^[0-9]{2,4}\.[0-9]{1,3}\.[0-9]{1,3}$' | sort -u | head -1)"
SWVER="${SWVER:-2025.163.0}"
SWZIP="$CACHE/Steamworks.NET-Standalone_${SWVER}.zip"
[ -f "$SWZIP" ] || die "need $SWZIP - run mp-install.sh once so it is cached"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -oq "$SWZIP" -d "$TMP/sw" || die "cannot unzip $SWZIP"
WIN_DLL="$TMP/sw/Windows-x64/Steamworks.NET.dll"
OSX_DLL="$TMP/sw/OSX-Linux-x64/Steamworks.NET.dll"
DYLIB="$TMP/sw/OSX-Linux-x64/steam_api.bundle/Contents/MacOS/libsteam_api.dylib"

CLONE="$TMP/probe.app"
say "cloning the app (APFS clone - instant, ~0 bytes; your install is not touched)"
cp -Rc "$APP" "$CLONE" 2>/dev/null || cp -R "$APP" "$CLONE"
# a launcher with no hardcoded --ksmulti-nosteam, so the flag is ours to control per case
sed 's/ --ksmulti-nosteam//' "$APP/Contents/MacOS/coop-launch" > "$CLONE/Contents/MacOS/coop-launch"
chmod +x "$CLONE/Contents/MacOS/coop-launch"

run_case(){
  local label="$1" dll="$2" want_dylib="$3"; shift 3
  echo; say "CASE $label"
  rm -f "$CLONE/Contents/BepInEx/plugins/KrokMP/Steamworks.NET.dll" "$CLONE/Contents/PlugIns/libsteam_api.dylib"
  /bin/cp "$dll" "$CLONE/Contents/BepInEx/plugins/KrokMP/Steamworks.NET.dll"
  if [ "$want_dylib" = yes ]; then
    /bin/cp "$DYLIB" "$CLONE/Contents/PlugIns/libsteam_api.dylib"
    chmod u+w "$CLONE/Contents/PlugIns/libsteam_api.dylib"
    codesign -f -s - "$CLONE/Contents/PlugIns/libsteam_api.dylib" 2>/dev/null || true
  fi
  probe "$CLONE" "$@"
}

run_case "A  Windows dll, no dylib, Steam on"  "$WIN_DLL" no
run_case "B  macOS dll,   no dylib, Steam on"  "$OSX_DLL" no
run_case "C  macOS dll +  dylib,    Steam on"  "$OSX_DLL" yes
run_case "D  Windows dll, --ksmulti-nosteam"   "$WIN_DLL" no --ksmulti-nosteam
echo
say "A and B are the broken-install signature; C is what a correct install does"
say "(C says 'Init failed' until a Steam client is running - then it says 'Steamworks initialized!')"
