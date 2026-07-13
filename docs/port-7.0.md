# Porting the 7.0 Steam demo (from the working 5.1 native port)

**Status: triage DONE (2026-07-13), build NOT started.** Everything below is verified fact,
not plan. Read `ROADMAP.md` "Native runtime fixes" + `tools/rewrap/README.md` first — same
machinery, same traps.

**Bottom line: 7.0 is a RE-RUN of the existing pipeline, not a rebuild.** The engine version,
scripting backend and stock-shader set are unchanged. The only genuine engineering is two
post-fx shaders (see §4).

---

## 1. Getting the bits (done — files are on disk)

Steam store page: `store.steampowered.com/app/4576490` (full game).
**The DEMO is a separate app: appid `4576510`**, single depot `4576511`.

The demo is Windows-only and the depot **is platform-gated**, so the Mac Steam client can't
fetch it and `steamcmd` needs the override — which must come **before `+login`**:

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
- **Install dir is deliberately `~/Games/`, NOT `~/Documents/`** — iCloud re-stamps
  `com.apple.FinderInfo` and that breaks `codesign` on the resulting `.app` (ROADMAP env gotcha).

**Installed at `~/Games/CU_demo_7/`** — 542 MB, buildid `23560597`, `CasualtiesUnknown.exe` +
`CasualtiesUnknown_Data/` + `MonoBleedingEdge/` + `UnityPlayer.dll`. Same shape as the 5.1
folder in `CasualtiesUnknownDemo/`, i.e. a drop-in `--win` argument for `tools/transplant.sh`.

---

## 2. Triage — all three go/no-go checks PASS

| check | 5.1 | 7.0 | consequence |
|---|---|---|---|
| Unity version | 2022.3.62f3 | **2022.3.62f3** | donor `EmptyMac.app` reusable **as-is** — no Unity Hub, no editor rebuild |
| scripting backend | Mono | **Mono** (no `GameAssembly.dll`) | native ARM64 CIL premise holds |
| Steamworks | none | **none** (DRM-free even on Steam) | no `steam_api64.dll` P/Invoke to stub |

`Assembly-CSharp.dll` 687 KB → 879 KB. That is all the new mechanics, and it is pure IL —
it costs the port **nothing**. Data layout is unchanged (`Lang`, `custommusic`, `level0/1`,
`resources.assets`, `sharedassets0/1`).

### The one new native plugin: `NativeNamedPipe.dll`

New in `CasualtiesUnknown_Data/Plugins/x86_64/` alongside `lib_burst_generated.dll`. It is
**Discord Rich Presence** — lachee's `DiscordRPC` Unity package (`DiscordRPC.dll`,
`com.lachee.discordrpc.runtime.dll`, `Microsoft.Win32.Registry.dll` are the new managed
assemblies; `Assembly-CSharp` gained `RPCManager.cs` → `DiscordRpcClient`/`SetPresence`).

`transplant.sh` strips x86-only plugins, so this dll is dropped like Burst. Unlike Burst it has
no managed fallback, **but the failure mode is benign**: no Discord connection, same as any PC
without Discord running, and Unity swallows exceptions thrown in MonoBehaviour callbacks.
**Watch the player log for `DllNotFoundException`/`EntryPointNotFoundException` from
`RPCManager` on first boot.** If it turns out to be fatal, neutralise `RPCManager.Start()` in
CIL or ship a stub `libNativeNamedPipe.dylib` — do **not** try to make Discord RPC work.

---

## 3. Shaders: 60 → 65. The tooling absorbs 63 of them automatically.

Stock is **unchanged at 40** (same names) → `transplant_stock.py` works untouched.
Custom Shader Graphs **20 → 25**. Nothing was removed.

**Five NEW Shader Graphs** — all convert AND pass `--compile-check` with the existing
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
`resources.assets` and `sharedassets1.assets` — all reachable.

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
`DamageScreen`/`ScreenPass` — it was written against 5.1 bytecode that no longer exists.

---

## 4. THE ONLY REAL ENGINEERING: kill the 4-mod-8 misalignment in v2

`DamageScreen._Pos` sits at byte 20 and `ScreenPass._PlayerPos` at byte 148. Both are `float2`,
both offsets are ≡ 4 (mod 8), and MSL cannot align a `float2` member to a 4-mod-8 offset — this
is the exact reason those shaders stayed hand-authored in 5.1.

**Fix (recommended over re-doing hand recovery): emit misaligned vectors as float arrays.**
`float _PlayerPos[2]` has **alignment 4**, so it legally sits at offset 148 and occupies
148..155 (inside one float4 row → matches D3D packing). Then rewrite the generated MSL's
references:

```
FGlobals._PlayerPos   ->   float2(FGlobals._PlayerPos[0], FGlobals._PlayerPos[1])
```

Trailing swizzles still work (`float2(...).x` is valid). Implement in the struct re-layout step
of `inject_custom_metal2.py` (the code that currently raises `violates align N`), generalise to
any `floatN` at a bad offset, and gate it behind `--compile-check`.

**Why this and not another hand re-wrap:** the hand path costs a full harvest-under-D3DMetal +
manual MSL recovery **every single time the devs recompile a shader** — which they just did, in
one point release. The array trick gets to **65/65 fully automatic** and makes the next port
(8.0, and 1.0 release) a pure re-run. This is the single highest-leverage change left in the
whole project.

---

## 5. The build recipe (nothing here is invented — it is the 5.1 recipe with new paths)

⚠️ Output to a **NEW bundle** so the working 5.1 port at `~/Applications/CU_metaltest.app`
survives. ⚠️ Build outside iCloud (`~/Applications`, `~/Games`), then ad-hoc sign.

The four post-transplant fixes below are **still not folded into `transplant.sh`** (ROADMAP says
so). **Fold them into a single `tools/port.sh` while doing this** — re-applying them by hand is
where a port loses a day.

```bash
WIN=~/Games/CU_demo_7
APP=~/Applications/CU7.app
DONOR=~/Documents/casualtiesunknowncostam/EmptyMac.app      # 2022.3.62f3, reusable
DATA="$APP/Contents/Resources/Data"

# 1. graft: Windows Data onto the native ARM64 Mac player
tools/transplant.sh --win "$WIN" --mac-app "$DONOR" --out "$APP"

# 2. runtime fixes (ROADMAP "Native runtime fixes" — transplant.sh does NOT do these)
#    a) BCL swap: 22 assemblies (mscorlib, System*, netstandard, Mono.Security) from the DONOR's
#       Managed/ over the game's — the Windows BCL P/Invokes kernel32 -> "Instantiating Chunks"
#       infinite hang on Descend. Game code / Unity.* / UnityEngine.* stay the GAME's.
#    b) symlinks INSIDE Contents (bundle-root symlinks break codesign sealing):
#       Contents/Lang -> Resources/Data/Lang ; Contents/custommusic -> Resources/Data/custommusic
#       (Application.dataPath is <app>/Contents on macOS, not Contents/Resources/Data)
#    c) remove Contents/PlugIns/lib_burst_generated.bundle (donor's, hash-mismatched) -> managed fallback

# 3. globalgamemanagers patches
python3 tools/rewrap/patch_ggm_metal.py  "$DATA/globalgamemanagers"   # shaderPlatform 4->14, m_GraphicsAPIs 2->16
python3 tools/rewrap/patch_ggm_vsync.py  "$DATA/globalgamemanagers"   # vSyncCount=1 in low quality levels — THE 37W BUG
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
patches the **app's** Data (`--dst-data`) — never the other way round.

Until §4 lands, `DamageScreen` + `ScreenPass` stay D3D11-only: the game **boots and plays**
(63/65 shaders are Metal — the NullGfxDevice wall only triggers when the API is unsupported
wholesale), but the damage vignette and that screen pass will render wrong/pink.

---

## 6. What needs a HUMAN (and what does not)

**Headless-safe (no display, screen may be locked/off):** the whole of §5 steps 1–5, and all of
§4. It is file manipulation + `xcrun metal` (an offline compiler) + `codesign`. The Mac must be
**awake** but the **display can be off**: `caffeinate -si` + `pmset displaysleepnow`.

**Needs a human at an unlocked Mac with an active display:** actually launching the game
(step 6). A Unity player needs a window-server session; it will not come up behind the lock
screen. So: boot check, visual QA of the 5 new shaders + the 2 post-fx, and any `powermetrics`
comparison against the 5.1 port / Path 1 all have to be done by you, awake.

**Verification that CAN be done headless** (do this before handing back): all 65 shaders carry
Metal subprograms in the output `.assets`; `globalgamemanagers` shows shaderPlatform 14;
the `Lang`/`custommusic` symlinks resolve; `lib_burst_generated.bundle` is gone; the BCL
assemblies match the donor's; `codesign --verify --deep --strict` passes; `lipo -archs` on the
bundle executable reports arm64.
