#!/usr/bin/env bash
#
# mp-playtest.sh - play co-op against a second player ON THIS MAC, in one command.
#
#   ./mp-playtest.sh
#
# You cannot test a co-op mod alone, and you do not need a friend (or a second machine) to check
# that it works. This starts a HEADLESS second player - a real game process with a real character,
# just with no window (-batchmode -nographics, ~0 GPU) - and then launches YOUR game already
# connected to it. You end up standing next to the other player in a generated world.
#
# Why a clone of the .app for the host: both processes would otherwise write the same
# BepInEx/LogOutput.log inside the same bundle. The clone is an APFS copy-on-write clone, so it
# costs ~0 bytes and is instant; it is refreshed automatically when you re-run mp-install.sh.
#
# Why the clone also gets its OWN bundle id: persistentDataPath is derived from
# CFBundleIdentifier, so a plain clone shares your settings.json - and the host's
# --ksmulti-setname then persists into YOUR profile, after which your client tries to join under
# the host's name and the server answers "Player with this name already exists." Giving the clone
# a distinct id gives the second player its own profile and its own saves, and leaves yours alone.
#
# Options:
#   --app <app>      the modded .app          [default: the 7.0 demo port in ~/Applications]
#   --name <name>    name of the headless second player                     [default: TestHost]
#   --port <port>    UDP port to use                                              [default: 7790]
#   --host-only      just start the second player and leave it running; join it yourself from the
#                    in-game menu (Open Multiplayer Mod Menu -> IP:PORT field -> connect)
#   --batch-client   run YOUR client headless too - proves the plumbing without taking the screen
#   --stop           kill a host left running by --host-only
#   --refresh        force the host clone to be rebuilt from --app
#   --host-fps <n>   frame cap for the second player                              [default: 30]
#   --no-throttle    leave the second player uncapped and on the P-cores. It will then burn
#                    ~1.5 CORES doing nothing and cook the laptop - only for measuring that.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/Casualties.Unknown.Demo.v7.0.macOS.arm64.Metal.Native.app"
NAME="TestHost"; PORT=7790; HOST_ONLY=0; BATCH_CLIENT=0; STOP=0; REFRESH=0
HOSTFPS=30; THROTTLE=1
CACHE="$HOME/.cache/casualties-port"
CLONE="$CACHE/coop-testhost.app"
PIDF="$CACHE/coop-testhost.pid"

die(){ printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
say(){ printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok(){  printf '  \033[1;32m✓\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app)          APP="$2"; shift 2 ;;
    --name)         NAME="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --host-only)    HOST_ONLY=1; shift ;;
    --batch-client) BATCH_CLIENT=1; shift ;;
    --stop)         STOP=1; shift ;;
    --refresh)      REFRESH=1; shift ;;
    --host-fps)     HOSTFPS="$2"; shift 2 ;;
    --no-throttle)  THROTTLE=0; shift ;;
    -h|--help)      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

stop_host(){
  if [ -f "$PIDF" ]; then
    kill -9 "$(cat "$PIDF")" 2>/dev/null || true
    rm -f "$PIDF"
  fi
}

if [ "$STOP" = 1 ]; then
  stop_host; ok "second player stopped"; exit 0
fi

[ -d "$APP" ] || die "no such .app: $APP  (pass --app)"
APP="$(cd "$APP" && pwd)"
[ -x "$APP/Contents/MacOS/coop-launch" ] \
  || die "$APP is not modded yet - run: tools/mp-install.sh --app \"$APP\" --mod <KrokMP download>"

# ── the headless second player ──────────────────────────────────────────────
mkdir -p "$CACHE"
if [ "$REFRESH" = 1 ] || [ ! -d "$CLONE" ] \
   || [ "$APP/Contents/Info.plist" -nt "$CLONE/Contents/Info.plist" ]; then
  say "cloning the modded app for the second player (APFS clone - instant, ~0 bytes)"
  rm -rf "$CLONE"; cp -a "$APP" "$CLONE"
  # own identity => own persistentDataPath => own settings.json, own name, own saves
  BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BID}.coophost" "$CLONE/Contents/Info.plist"
  xattr -cr "$CLONE" 2>/dev/null || true
  codesign --remove-signature "$CLONE" 2>/dev/null || true
  codesign --force --deep --sign - "$CLONE" 2>/dev/null || die "could not re-sign the host clone"
  ok "$CLONE (id ${BID}.coophost - separate profile, your saves untouched)"
fi

# The mod remembers the player name in PlayerPrefs (KrokoshaMultiplayer_LastPlayerName), which on
# macOS lives in ~/Library/Preferences/<CFBundleIdentifier>.plist. If YOUR remembered name happens
# to equal the host's, the server answers "Player with this name already exists." Rename the host
# rather than your character - your identity is yours.
CLIENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
YOURNAME="$(defaults read "$CLIENT_ID" KrokoshaMultiplayer_LastPlayerName 2>/dev/null || true)"
if [ -n "$YOURNAME" ] && [ "$YOURNAME" = "$NAME" ]; then
  NAME="${NAME}-2"
  say "you already play as \"$YOURNAME\", so the second player is \"$NAME\" instead"
fi

stop_host                                    # never leave two hosts fighting for the port
BEPLOG="$CLONE/Contents/BepInEx/LogOutput.log"
rm -f "$BEPLOG"
say "starting the second player \"$NAME\" (headless, capped to ${HOSTFPS}fps) on 127.0.0.1:$PORT"
# THROTTLE, do not skip this. With -nographics there is no display to pace against, so Unity's
# loop spins as fast as it can: measured ~145% CPU (1.5 cores) for a character standing still,
# which is what makes the laptop hot. The game's own `framerate` console command sets
# Application.targetFrameRate and DOES work in a build (its help text doubts it) -> ~42%.
# The host is authoritative but only simulates; 30 Hz is plenty for a test partner.
HOSTCAP=()
[ "$THROTTLE" = 1 ] && HOSTCAP=(--ksmulti-runcommand "framerate $HOSTFPS")
"$CLONE/Contents/MacOS/coop-launch" -batchmode -nographics -logFile "$CACHE/coop-testhost.unity.log" \
    --ksmulti-setname "$NAME" --ksmulti-starthost --ksmulti-immidiate-start \
    "${HOSTCAP[@]}" >/dev/null 2>&1 &
echo $! > "$PIDF"

# wait until it is actually hosting AND has generated the world, else the join races worldgen
for i in $(seq 1 60); do
  sleep 1
  grep -qa "FinishWorldGeneration" "$BEPLOG" 2>/dev/null && break
  if ! kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    tail -5 "$BEPLOG" 2>/dev/null; die "the second player died on startup (see $BEPLOG)"
  fi
done
grep -qa "Succesfully started: Host" "$BEPLOG" 2>/dev/null \
  || { tail -5 "$BEPLOG" 2>/dev/null; die "never started hosting (see $BEPLOG)"; }
# Worldgen is genuinely CPU-hungry, so demote only afterwards: background QoS parks the process
# on the efficiency cores, taking the idle host to ~20-40% of one core. Verified that a client
# still joins and syncs against an E-core host.
if [ "$THROTTLE" = 1 ]; then
  taskpolicy -b -p "$(cat "$PIDF")" 2>/dev/null \
    && ok "second player demoted to the efficiency cores (background QoS)"
fi
ok "second player is in a generated world, listening on 127.0.0.1:$PORT"

if [ "$HOST_ONLY" = 1 ]; then
  echo
  say "now join it from your own game:"
  echo "     1. launch the co-op game (the …-coop.command next to the .app)"
  echo "     2. main menu -> Open Multiplayer Mod Menu"
  echo "     3. put  127.0.0.1:$PORT  in the IP:PORT field, then press the client/connect button"
  echo
  echo "  when you are done:  $0 --stop"
  exit 0
fi

# ── your client, already connected ──────────────────────────────────────────
trap 'stop_host' EXIT
say "launching YOUR game, already connecting to the second player"
CLIENT_ARGS=""
[ "$BATCH_CLIENT" = 1 ] && CLIENT_ARGS="-batchmode -nographics"
# NB: connect via the mod's own console command. --ksmulti-startclient is broken UPSTREAM (it
# passes a hardcoded "localhost:7790", and the mod's parser sends any dotless host down the IPv6
# branch into Dns.GetHostEntry -> "Unknown Host"). See docs/multiplayer-port.md §2e.
"$APP/Contents/MacOS/coop-launch" $CLIENT_ARGS -logFile "$CACHE/coop-client.unity.log" \
    --ksmulti-runcommand "connect 127.0.0.1:$PORT" || true

say "your game exited - stopping the second player"
