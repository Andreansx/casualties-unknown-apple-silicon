# Porting the 7.0 Steam demo (from the working 5.1 native port)

## ✅ BUILT - 65/65 shaders Metal, awaiting the one check only a human can do

**Status (2026-07-13, overnight):** the port is **built, signed and verified headlessly**:

    ~/Applications/Casualties.Unknown.Demo.v7.0.macOS.arm64.Metal.Native.app

- **65/65 shaders carry Metal** (`verify_metal.py`) - 40 stock transplanted, 25 custom converted.
- **The hand-authored shader tail is GONE (4 → 0).** `packed_float2` closed it - see §4.
- Ran **196,530 frames in `-batchmode -nographics`** with **zero managed exceptions**: Mono, the
  swapped BCL and the new Discord `RPCManager` are all healthy on ARM64.
- Rebuilt from scratch **twice** by `tools/port.sh` (one command, reproducible).

**NOT yet done - needs a human at an unlocked Mac with a display:** actually looking at it.
A Unity player cannot come up behind the lock screen, so the boot check, the visual QA of the
5 new shaders + the 2 rebuilt post-fx, and any `powermetrics` numbers are all still open.

```bash
tools/run-native.sh ~/Applications/Casualties.Unknown.Demo.v7.0.macOS.arm64.Metal.Native.app
```

**Bottom line: 7.0 was a RE-RUN of the existing pipeline, not a rebuild.** Engine version,
scripting backend and stock-shader set unchanged. The only real engineering was two post-fx
shaders (§4) - and that work retires the hand-authored path permanently.

---

## 1. Getting the bits (done - files are on disk)

Steam store page: `store.steampowered.com/app/4576490` (full game).
**The DEMO is a separate app: appid `4576510`**, single depot `4576511`.

The demo is Windows-only and the depot **is platform-gated**, so the Mac Steam client can't
fetch it and `steamcmd` needs the override - which must come **before `+login`**:

```bash
cd ~/steamcmd            # curl -sqL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz | tar zxf -
arch -x86_64 ./steamcmd.sh \
  +@sSteamCmdForcePlatformType windows +@sSteamCmdForcePlatformBitness 64 \
  +force_install_dir "$HOME/Games/CU_demo_7" \
  +login <steam-user> +app_license_request 4576510 \
  +app_update 4576510 validate +quit
```

- steamcmd is x86_64 → needs `arch -x86_64` (Rosetta) on Apple Silicon.
- Anonymous login is refused ("No subscription"). A real login + `app_license_request` grants
  the free demo licence; the grant persists, so later runs only need `+login`.
- **Install dir is deliberately `~/Games/`, NOT `~/Documents/`** - iCloud re-stamps
  `com.apple.FinderInfo` and that breaks `codesign` on the resulting `.app` (ROADMAP env gotcha).

**Installed at `~/Games/CU_demo_7/`** - 542 MB, buildid `23560597`, `CasualtiesUnknown.exe` +
`CasualtiesUnknown_Data/` + `MonoBleedingEdge/` + `UnityPlayer.dll`. Same shape as the 5.1
folder in `CasualtiesUnknownDemo/`, i.e. a drop-in `--win` argument for `tools/transplant.sh`.

---

## 2. Triage - all three go/no-go checks PASS

| check | 5.1 | 7.0 | consequence |
|---|---|---|---|
| Unity version | 2022.3.62f3 | **2022.3.62f3** | donor `EmptyMac.app` reusable **as-is** - no Unity Hub, no editor rebuild |
| scripting backend | Mono | **Mono** (no `GameAssembly.dll`) | native ARM64 CIL premise holds |
| Steamworks | none | **none** (DRM-free even on Steam) | no `steam_api64.dll` P/Invoke to stub |

`Assembly-CSharp.dll` 687 KB → 879 KB. That is all the new mechanics, and it is pure IL -
it costs the port **nothing**. Data layout is unchanged (`Lang`, `custommusic`, `level0/1`,
`resources.assets`, `sharedassets0/1`).

### The one new native plugin: `NativeNamedPipe.dll`

New in `CasualtiesUnknown_Data/Plugins/x86_64/` alongside `lib_burst_generated.dll`. It is
**Discord Rich Presence** - lachee's `DiscordRPC` Unity package (`DiscordRPC.dll`,
`com.lachee.discordrpc.runtime.dll`, `Microsoft.Win32.Registry.dll` are the new managed
assemblies; `Assembly-CSharp` gained `RPCManager.cs` → `DiscordRpcClient`/`SetPresence`).

`transplant.sh` strips x86-only plugins, so this dll is dropped like Burst. Unlike Burst it has
no managed fallback, **but the failure mode is benign**: no Discord connection, same as any PC
without Discord running, and Unity swallows exceptions thrown in MonoBehaviour callbacks.
**Watch the player log for `DllNotFoundException`/`EntryPointNotFoundException` from
`RPCManager` on first boot.** If it turns out to be fatal, neutralise `RPCManager.Start()` in
CIL or ship a stub `libNativeNamedPipe.dylib` - do **not** try to make Discord RPC work.

---

## 3. Shaders: 60 → 65. The tooling absorbs 63 of them automatically.

Stock is **unchanged at 40** (same names) → `transplant_stock.py` works untouched.
Custom Shader Graphs **20 → 25**. Nothing was removed.

**Five NEW Shader Graphs** - all convert AND pass `--compile-check` with the existing
`inject_custom_metal2.py`, no code changes needed:

| shader | file | variants |
|---|---|---|
| `CrystalShimmer` | resources.assets | 1 VS + 1 FS |
| `HumanShader` | resources.assets | **18 VS + 18 FS** |
| `MagmaShader` | resources.assets | 3 VS + 3 FS |
| `ScreenSpaceDistortion` | resources.assets | 1 VS + 1 FS |
| `ObserverShader` | sharedassets1.assets | 1 VS + 1 FS |

The injector enumerates by the `Shader Graphs/` prefix (no hardcoded list), so new graphs are
picked up for free. It globs `*.assets`, which covers `globalgamemanagers.assets`,
`resources.assets` and `sharedassets1.assets` - all reachable.

### The four hand-authored post-fx: THREE OF THEM CHANGED

Path IDs are stable (`globalgamemanagers.assets` 68/69/70/71), but the DXBC was recompiled, so
**the hand-recovered MSL from 5.1 is STALE for three of them**:

| shader | pathID | vs 5.1 | v2 auto-convert on 7.0? |
|---|---|---|---|
| `BonusPass` | 68 | byte-identical | ✅ converts |
| `AberrationShader` | 71 | **CHANGED** | ✅ converts (no longer misaligned!) |
| `DamageScreen` | 69 | **CHANGED** | ❌ `_Pos@20 violates align 8` |
| `ScreenPass` | 70 | **CHANGED** | ❌ `_PlayerPos@148 violates align 8` |

So the hand-authored tail **shrinks from 4 to 2**. Do NOT reuse the old hand MSL for
`DamageScreen`/`ScreenPass` - it was written against 5.1 bytecode that no longer exists.

---

## 4. ✅ SOLVED: the 4-mod-8 misalignment - the hand-authored tail is retired (4 → 0)

`DamageScreen._Pos` sits at byte 20 and `ScreenPass._PlayerPos` at byte 148. Both are `float2`,
both offsets are ≡ 4 (mod 8), and MSL cannot align a `float2` member to a 4-mod-8 offset. That
single constraint is the *entire* reason four shaders stayed hand-authored through the 5.1 port.

**The fix is one MSL type: `packed_float2`.** D3D packs a vector at any 4-byte offset that
doesn't straddle a 16-byte row, so `@20` and `@148` are perfectly legal there. MSL's
`packed_floatN` is exactly the storage-only counterpart - **size 8, alignment 4**, byte-identical
layout - so it expresses the offset natively. Reads are converted back to the aligned type so
every downstream use (swizzles, arithmetic) is unchanged from what HLSLcc generated:

```
constant UnityPerMaterial& { ... packed_float2 _PlayerPos; ... }   // sits legally at 148
FGlobals._PlayerPos   ->   float2(FGlobals._PlayerPos)             // reads unchanged
```

Implemented in `inject_custom_metal2.py`: `PACKED` map + the `packed_*` branch in
`relayout_cb_structs()` (exactly where it used to `raise ... violates align N`), plus a
back-conversion `re.sub` anchored on `<cb>.` so the declaration itself is never rewritten.
Members that were already aligned take the byte-identical code path they always did - the new
logic lives *entirely* inside the branch that previously just threw.

**Result: 25/25 custom shaders convert, 0 failed, `--compile-check` (a real `xcrun metal`
compile) passes.** It also retroactively converts the 5.1 build's 20/20 - including all **four**
that were hand-authored there (`inject_metal.py`, path IDs 68-71: BonusPass, DamageScreen,
ScreenPass, AberrationShader) - which is strong independent evidence the layout is right.

**Why this mattered:** the hand path cost a full harvest-under-D3DMetal + manual MSL recovery
**every time the devs recompile a shader** - which they just did, in a single point release
(3 of the 4 changed). The port is now **65/65 fully automatic**, so 8.0 and the 1.0 release are
pure re-runs of `tools/port.sh`.

⚠️ The hand-authored MSL in `inject_metal.py` (`SHADERS = {68..71}`) is now **dead code for 7.0**
and its 5.1 bytecode assumptions are stale. Do not resurrect it; `inject_custom_metal2.py`
covers all 25.

---

## 5. The build: ONE COMMAND (`tools/port.sh`)

The four post-transplant fixes are no longer applied by hand - `tools/port.sh` is the whole
recipe, end to end, and it self-verifies:

```bash
tools/port.sh --win ~/Games/CU_demo_7 \
              --out ~/Applications/Casualties.Unknown.Demo.v7.0.macOS.arm64.Metal.Native.app
```

It does: transplant → BCL swap → dataPath symlinks → de-burst → bundle identity (+ keybinds
migration) → ggm patches (Metal/vsync/retina) → shaders (stock + custom, compile-checked) →
ad-hoc sign → headless verify. It refuses to build into iCloud, refuses on a Unity-version
mismatch, and **fails loudly if 0 stock shaders transplant** (see the trap below).

### TWO TRAPS THIS PORT HIT - both now guarded in port.sh

**1. There are TWO donors and they are NOT interchangeable.**
`EmptyMac.app` (kept locally; gitignored, like all `.app`s) is the **player skeleton** - the native
ARM64 UnityPlayer/Mono.
`~/UnityProjects/EmptyMac/Build/Donor.app` is the **shader donor** - the `DonorSetup` build whose
Always-Included-Shaders list forces all 40 stock shaders to compile to Metal. Point
`transplant_stock.py` at the skeleton and it skips all 40 with `NOT IN DONOR`, transplants
nothing, and you get a **signed, launchable app that renders pink** - no error anywhere. This
happened on the first build here and was caught only by `verify_metal.py` (25/65). `port.sh` now
takes `--shader-donor` (defaulting to `Donor.app`) and dies on `transplanted 0`.

**2. The bundle identifier IS the save/keybinds directory.**
macOS `persistentDataPath` = `~/Library/Application Support/<CFBundleIdentifier>`. The 5.1 port
inherited the donor's id (`com.DefaultCompany.2DProject`), which is where the **RMB→LeftAlt
trackpad fix in `keybinds.json`** lives. Giving the app a proper id moves that directory, the game
regenerates DEFAULT binds, and right-click is unusable again - with no in-game rebinding UI to fix
it. `port.sh` step 5 migrates `keybinds.json` across whenever it changes the id.

⚠️ Output to a **NEW bundle** so the working 5.1 port at `~/Applications/CU_metaltest.app`
survives. ⚠️ Build outside iCloud (`~/Applications`, `~/Games`) - iCloud's FinderInfo stamping
breaks `codesign`; `port.sh` refuses.

### What it produced (verified headlessly)

| check | result |
|---|---|
| shaders carrying Metal | **65/65** (`verify_metal.py`) |
| stock transplanted | 40, 0 skipped |
| custom converted | 25, 0 failed, `--compile-check` clean |
| executable arch | `arm64` slice present (universal) |
| codesign | `--verify --deep --strict` passes |
| BCL | mscorlib/System/System.Core = **donor's**, not Windows |
| game code | `Assembly-CSharp` = the **7.0** build's, byte-identical |
| Windows native plugins | stripped (no `.dll`/`.bundle` in `Plugins`) |
| `Contents/Lang`, `custommusic` | resolve |
| Burst bundle | absent |
| batchmode run | **196,530 frames, 0 managed exceptions** |

### The old by-hand recipe (kept for reference / other games)

```bash
WIN=~/Games/CU_demo_7
APP=~/Applications/CU7.app
DONOR=~/Projects/casualtiesunknowncostam/EmptyMac.app      # 2022.3.62f3, reusable
DATA="$APP/Contents/Resources/Data"

# 1. graft: Windows Data onto the native ARM64 Mac player
tools/transplant.sh --win "$WIN" --mac-app "$DONOR" --out "$APP"

# 2. runtime fixes (ROADMAP "Native runtime fixes" - transplant.sh does NOT do these)
#    a) BCL swap: 22 assemblies (mscorlib, System*, netstandard, Mono.Security) from the DONOR's
#       Managed/ over the game's - the Windows BCL P/Invokes kernel32 -> "Instantiating Chunks"
#       infinite hang on Descend. Game code / Unity.* / UnityEngine.* stay the GAME's.
#    b) symlinks INSIDE Contents (bundle-root symlinks break codesign sealing):
#       Contents/Lang -> Resources/Data/Lang ; Contents/custommusic -> Resources/Data/custommusic
#       (Application.dataPath is <app>/Contents on macOS, not Contents/Resources/Data)
#    c) remove Contents/PlugIns/lib_burst_generated.bundle (donor's, hash-mismatched) -> managed fallback

# 3. globalgamemanagers patches
python3 tools/rewrap/patch_ggm_metal.py  "$DATA/globalgamemanagers"   # shaderPlatform 4->14, m_GraphicsAPIs 2->16
python3 tools/rewrap/patch_ggm_vsync.py  "$DATA/globalgamemanagers"   # vSyncCount=1 in low quality levels - THE 37W BUG
python3 tools/rewrap/patch_ggm_retina.py "$DATA/globalgamemanagers" off

# 4. shaders (needs the UnityPy venv + tools/hlslcc/build.sh, already built)
python3 tools/rewrap/transplant_stock.py --donor-data "$DONOR/Contents/Resources/Data" --game-data "$DATA"
python3 tools/rewrap/inject_custom_metal2.py --src-data "$WIN/CasualtiesUnknown_Data" \
        --dst-data "$DATA" --compile-check

# 5. sign (REQUIRED on Apple Silicon or it will not launch)
codesign --force --deep -s - "$APP"

# 6. run
tools/run-native.sh "$APP"          # HUD=0 to drop the Metal overlay; LOG=1 for the player log
python3 tools/rewrap/patch_keybinds.py    # RMB->LeftAlt for trackpad; persistentDataPath/keybinds.json
```

`inject_custom_metal2.py` sources DXBC from the **untouched Windows build** (`--src-data`) and
patches the **app's** Data (`--dst-data`) - never the other way round.

---

## 5b. Post-launch findings from real gameplay (2026-07-13)

The port rendered correctly on first launch (player Expie visible, everything looks right).
**No rendering work was needed after the build.** Three issues surfaced in play; one was a real
port issue, one is still open, and one was NOT a bug at all.

### ✅ REAL: "Option doesn't work as RMB" - the bind store MOVED in 7.0

5.1 kept binds in `keybinds.json` (`{"binds": {"iteminteract": "Mouse1"}}` - KeyCode *names*).
**7.0 folded them into the Settings system:** `settings.json`, a flat list of
`{"name":…, "value":…}` where a keybind's value is the KeyCode's **integer** (`Mouse1 = 324`,
`LeftAlt = 308`). There is **no `keybinds.json` anywhere in the 7.0 assembly** - the one we
migrated was silently ignored, the game fell back to defaults (`iteminteract = 324`), and the
rebind looked like it did nothing.

Fix: `tools/rewrap/patch_keybinds.py iteminteract LeftAlt` (rewritten - auto-detects the 7.0
`settings.json` vs the 5.1 `keybinds.json` and speaks KeyCode names either way). 7.0 also has a
real in-game rebinding UI (`SettingKeybind`/`keybindnotset`), so Settings → Controls works too.
**The game rewrites `settings.json` on exit - quit it before editing (the tool refuses if it's
running).** ✅ User-confirmed: Option now works as RMB.

Rebinding is still worth doing on a laptop even though right-click *itself* works via two-finger
click: the game's drag hangs off ONE bind - `PlayerCamera::HandleDragging` starts on
`GetKeyDown(bind)` and DROPS on `GetKeyUp(bind)` - and holding a two-finger click steady while
moving the cursor with the same fingers is miserable. Hold Option, move with one finger, release.

### ❌ NOT A BUG: "the item won't stay in my inventory"

**This was a tutorial UX misunderstanding, not a port defect.** You must first put the **trash bag
itself into your inventory**, and only then drag the item out of the bag's inventory. The bag's
container UI looks *identical* whether or not the bag is in your inventory, so it reads as though
dragging straight out of the world container should work. The tutorial doesn't say this.

Confirmed identical behaviour on **both** the native Metal port and the D3DMetal reference, so
nothing about the port is involved. **Do not go looking for a coordinate-space/raycast bug here** -
an earlier revision of this doc wrongly blamed the keybind for it.

**The method that settled it is worth reusing** - this is what Path 1 is *for*. Run the untouched
Windows build under Wine + D3DMetal on the *same* game data and settings:

```bash
tools/run-d3dmetal.sh ~/Games/CU_demo_7/CasualtiesUnknown.exe
```

It shares everything that could be game logic (same `Assembly-CSharp`, same assets, same
`settings.json`, same trackpad) and none of what we changed (original D3D11 shaders via Apple's
translator, original Windows BCL, Burst intact, unpatched `globalgamemanagers`, x86 under Rosetta).
Same behaviour on both ⇒ the port is exonerated in one run. Seed the prefix's settings first so
the binds match, at:
`~/Games/CasualtiesUnknown/drive_c/users/crossover/AppData/LocalLow/Orsoniks/CasualtiesUnknown/`

FWIW the drop logic, for anyone who does end up in here: `GetKeyUp` →
`UIUtil.IsPointerOverUIElement()` (an `EventSystem.RaycastAll` at `Input.mousePosition`) →
`TryPerformInventoryAction`, which *first* requires the dragged image's rect to **`Overlaps`** the
slot's rect (not merely the pointer to be inside it - see the `inventoryuseleniency` setting) and
returns false otherwise.

Useful facts confirmed from the CIL while chasing this:
- The **only** direct mouse read in the whole assembly is `AdaptiveButton::Update` →
  `GetMouseButtonDown(0)`. Nothing else hardcodes a mouse button.
- There are **no** `PointerEventData.button` checks and **no** EventSystem drag handlers - all
  gameplay input goes through `KeyBinds.GetBind(name)`, and Unity's `KeyCode` enum covers
  `Mouse0..Mouse6`, which is how one bind table holds both mice and keys.
- `KeyBinds.GetBind` returns **`KeyCode.None` (0)** for an unknown action - a missing bind fails
  silently, it does not throw.

### ✅ FIXED: hang after screen-lock / display-sleep (`runInBackground`)

Symptom: lock the Mac mid-game (⌘⌃Q), let the display sleep, log back in → the game is wedged,
Metal HUD frozen on "Composited"/presentation OFF, and the process must be killed.
**No managed exception in `Player.log`** - so it's a graphics/window stall, not game code.

`fullscreenMode` was already `1` (borderless FullScreenWindow, not exclusive) and
`runInBackground` was **True** - and that last one is the suspect: the player keeps driving the
Metal loop while the display is asleep and the `CAMetalLayer` has no acquirable drawable, so it
wedges and never recovers. Applied `patch_ggm_bool.py runInBackground off`, so Unity parks the
player loop on resign-active and should resume cleanly on unlock.

```bash
python3 tools/rewrap/patch_ggm_bool.py <app>/Contents/Resources/Data/globalgamemanagers runInBackground off
codesign --force --deep -s - <app>
```

`patch_ggm_bool.py` is a generalised, surgical single-byte PlayerSettings bool patcher (UnityPy's
full re-serialization corrupts `globalgamemanagers`; it verifies byte-identity first, then asserts
exactly one byte changed). `--list` dumps every bool.

**✅ USER-CONFIRMED (2026-07-13):** lock the screen, let the display sleep, log back in - the game
is immediately alive. **`tools/port.sh` now applies this automatically** (step 6), so a rebuild
can't silently reintroduce the hang.

### ✅ FIXED: "This is a beta build (1.0)" - it WAS our bug (donor `Info.plist` leak)

⚠️ **An earlier revision of this doc claimed this was the devs' own stale version string. That was
WRONG.** The user disproved it in one run of Path 1: the D3DMetal build shows **7.0.1** in the menu
while the native build's banner showed **1.0**. Same `Assembly-CSharp`, same assets ⇒ the port.

**Root cause - `Application.version` reads from a DIFFERENT place on macOS:**

| platform | `Application.version` source |
|---|---|
| Windows | `bundleVersion` in `globalgamemanagers` → `7.0.1` ✅ |
| **macOS** | **`CFBundleShortVersionString` in the app's `Info.plist`** |

Both builds' `globalgamemanagers` carry `7.0.1` (verified byte-wise, identical). But the app's
`Info.plist` comes from the **donor**, an empty Unity project, whose default is **`1.0`** - so the
game's `betaBuild` banner (`versionText`, `Application.version` in `Assembly-CSharp`) rendered the
donor's version. Nothing else reads it, which is why it looked cosmetic.

Fix (in `port.sh` step 5, automatic): read the version out of the **game's** ggm and stamp it into
the plist, then re-sign. Tracks the real version across releases, so 8.0/1.0 need no change.

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 7.0.1" <app>/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 7.0.1"            <app>/Contents/Info.plist
codesign --force --deep -s - <app>
```

**Generalise this:** any Unity `Application.*` property that maps to bundle metadata on macOS
(`version`, `productName`, `companyName`, `identifier`) is read from `Info.plist`, i.e. **from the
donor**, not from the transplanted game data. If a value looks like an empty-project default,
suspect the plist.

---

## 5c. Steam build 24774057 (2026-08-17): Simplified Chinese - nothing to port

Steam's public demo branch moved from our `23560597` to **`24774057`** with the "Simplified
Chinese has been added to the demo" announcement. Fetched to `~/Games/CU_demo_7_b24774057`
(same steamcmd command, new `force_install_dir`) and diffed file-by-file against the old build:

- **one file added**: `CasualtiesUnknown_Data/Lang/zh-CN.json`
- **everything else byte-identical** - exe, `Assembly-CSharp.dll`, assets, shaders, plugins.
  `Application.version` is still `7.0.1`, so the co-op mod's version gate is unaffected.

No code change is needed for a new language: `Locale.cs` enumerates
`Application.dataPath + "/Lang/"` for `*.json`, and our `Contents/Lang` symlink (step 3) already
puts that directory where macOS `dataPath` looks. `tools/port.sh` rebuilt it unchanged
(65/65 Metal, 25/25 customs re-wrapped, signature verifies) and **Chinese loads and renders
in-game** (user-confirmed) - the CJK glyphs need no extra font work.

Harmless upstream quirk found on the way: the "open language folder" button builds
`Application.dataPath + "\\Lang"` (`PreRunScript.cs`, `ConsoleScript.cs`) - a backslash path,
so on macOS it likely opens nothing. Loading is unaffected (it uses `"/Lang/"`).

---

## 6. What needs a HUMAN (and what does not)

**Headless-safe (no display, screen may be locked/off):** the whole of §5 steps 1-5, and all of
§4. It is file manipulation + `xcrun metal` (an offline compiler) + `codesign`. The Mac must be
**awake** but the **display can be off**: `caffeinate -si` + `pmset displaysleepnow`.

**Needs a human at an unlocked Mac with an active display:** actually launching the game
(step 6). A Unity player needs a window-server session; it will not come up behind the lock
screen. So: boot check, visual QA of the 5 new shaders + the 2 post-fx, and any `powermetrics`
comparison against the 5.1 port / Path 1 all have to be done by you, awake.

**Verification that CAN be done headless** - all of this is automated in `port.sh`'s final step
plus `tools/rewrap/verify_metal.py`, and all of it passed: every shader carries Metal
(platform 14); `Lang`/`custommusic` symlinks resolve; no Burst bundle; BCL matches the donor;
`codesign --verify --deep --strict` passes; `lipo -archs` reports an arm64 slice.

Plus the strongest headless test available: **`-batchmode -nographics`**. It has no GPU, so every
shader logs *"not supported on this GPU"* - **ignore that, it is an artifact of `-nographics`,
not a port defect** - but it fully exercises Mono, the BCL and game code. 196,530 frames, zero
managed exceptions, no `DllNotFoundException` from Discord, and crucially no
`EntryPointNotFoundException` (the kernel32 signature of the BCL bug that caused the
"Instantiating Chunks" hang).

### The open QA list for the morning

1. Does it boot and render? `tools/run-native.sh <app>`
2. The 5 NEW shaders, never seen on Metal: `CrystalShimmer`, `HumanShader`, `MagmaShader`,
   `ObserverShader`, `ScreenSpaceDistortion`.
3. The 2 REBUILT post-fx, first ever machine-converted: `DamageScreen` (damage vignette - take a
   hit) and `ScreenPass`. Both use `packed_float2` for a player-position uniform, so the failure
   mode to watch for is an effect **mispositioned** relative to the player rather than absent.
4. `AberrationShader` + `BonusPass` (converted, previously hand-authored).
5. Right-click = **hold Option/LeftAlt** (`iteminteract`), migrated to the new bundle id.
6. Discord Rich Presence is expected NOT to work (native plugin stripped) - harmless.
7. Power: `powermetrics` vs the 5.1 native port. Process is now named **`CasualtiesUnknown`**,
   no longer `EmptyMac`.
