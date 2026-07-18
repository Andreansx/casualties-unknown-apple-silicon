# Casualties: Unknown - Apple Silicon Port

Making the Windows-only Unity game **Casualties: Unknown** run on Apple Silicon (M2 Max)
without full-system emulation - so it can actually be played on battery (e.g. on a train)
without the fans spinning up.

## Status: two working ports

**1. The practical one - run the unmodified Windows `.exe`** under Wine + Rosetta 2 + Apple's
**D3DMetal** (D3D11→Metal at runtime). One command, nothing patched, 100% correct rendering.
Measured on an M2 Max: **~2.5 W total** (CPU 1.77 W + GPU 0.71 W) at **120 FPS**, GPU frame
time **4.06 ms** - roughly **6-12× more power-efficient than UTM** (~15-30 W), fans off.
→ [Quick start](#quick-start---just-play-it-path-1)

**2. The impressive one - a FULLY NATIVE Apple Silicon build.** No Wine, no Rosetta, no D3D:
a native ARM64 Unity player running the game's original managed code and assets, rendering
**100% on Metal** - because we **converted all 65 of the game's D3D11-only shaders to Metal
offline**, including the 25 custom Shader Graphs whose source does not exist anywhere in the
build. This was supposed to be impossible (see [The shader wall](#the-shader-wall---and-how-we-broke-through-it));
the game is now **playable end-to-end natively**, and in active gameplay it draws **47% less
power than the translated Path-1 build** (winning on *both* CPU and GPU). The entire native
build is now reproducible in **one command** - [`tools/port.sh`](tools/port.sh).
→ [The native port](#the-native-port-path-23---the-impressive-one)

**Latest milestone (2026-07):** the current target is the **7.0 Steam demo** (65 shaders), and
it is fully ported - 65/65 Metal, one-command build, gameplay power re-measured. The old
"hand-authored shader tail" is **retired**: all 25 custom graphs now convert automatically. See
[`docs/port-7.0.md`](docs/port-7.0.md) for the 7.0 write-up; 8.0 / the full release are expected
to be pure re-runs of `tools/port.sh`.

**Also in progress - online multiplayer on the native port.** The community co-op mod
[**Casualties: Together**](https://github.com/creaturefeaturelarry/casualties-together) (KrokMP,
BepInEx 5 + Harmony) is Windows-only. We are bringing it to the native arm64 build *in this
repo* - not by forking the mod (it ships no source and no license; we only adapt a copy the user
downloads themselves). The one hard blocker was that Harmony/MonoMod cannot patch under Mono's
`MAP_JIT` W^X memory on Apple Silicon; the usual answer is "run it under Rosetta", which defeats
the whole point of the native port. **We solved it natively** with a tiny native helper
(`unprotect → write → reprotect → flush-icache` in one call) injected ahead of BepInEx's
preloader - BepInEx 5 now reaches `Chainloader startup complete` on a genuinely arm64 process.
The mod's own code is architecture-neutral MSIL and its two native deps (Steam, Opus) have arm64
builds, so the remaining work is packaging, not research. See
[`docs/port-7.0.md`](docs/port-7.0.md) for the analysis. Status: **experimental, not yet a
one-command install.**

The whole stack is **free**: Rosetta 2 (built into macOS) + the Gcenx `game-porting-toolkit`
cask (which bundles Apple's D3DMetal) + Unity 2022.3.62f3 for the native path. No CrossOver,
no paid tools, no Apple-developer download.

**Which should you use?** Path 1 if you just want to play - it is one command and always
renders correctly. The native port is the deeper, more interesting result, is now fully playable,
and *also* rebuilds in one command ([`tools/port.sh`](tools/port.sh)) - the only multi-step,
Unity-requiring part is a **one-time** build of the shader donor project.

---

## The native port (Path 2/3) - the impressive one

A native ARM64 macOS `.app` that runs the game's **original managed code and assets** on a stock
Apple Silicon Unity player, rendering **entirely on Metal**. No Wine. No Rosetta. No Direct3D.
No translation layer of any kind at runtime.

**Principle** (mirrors an x86-appliance port): *native macOS binaries stay; the cross-platform
payload comes from the Windows build.* You build an **empty** Unity 2022.3.62f3 macOS/Apple-Silicon
project to get a correct native player skeleton, then graft the game's `Data/` payload onto it.
Automated by **[`tools/transplant.sh`](tools/transplant.sh)**.

The managed half of this worked almost immediately. The GPU half is where the story is.

### The shader wall - and how we broke through it

The transplant boots, Mono loads `Assembly-CSharp.dll`, subsystems init… and then the player
logs `NullGfxDevice` and dies in the draw path. Root cause, found by diffing the game's
`globalgamemanagers` against an empty Mac build's with UnityPy:

> `GraphicsSettings.m_ShaderDefinesPerShaderCompiler.shaderPlatform` = **4 (D3D11)** in the game,
> **14 (Metal)** in the Mac build. **Every one of the 65 shaders in the build is D3D11-only
> bytecode. There are no Metal variants - not even engine blit shaders.**

`-force-metal` is a real flag and does force the Metal device, but then:
`Forced GfxDevice 'Metal' … shaders will not be available` → `InitializeEngineGraphics failed`.

And the nasty part: **25 of those shaders are the game's own custom Shader Graphs** - the 4 post-fx
(`BonusPass` / `DamageScreen` / `ScreenPass` / `AberrationShader`) plus 21 gameplay graphs like
`Limb`, `WallHole`, `RadBackground`, `HoverShader`, `HumanShader`. Unity ships **no source** for
them in a build - only compiled DXBC + ShaderLab metadata. Stock URP shaders you can re-obtain from
a Mac build. Custom graphs, conventional wisdom says, you cannot rebuild without the original project.

**That conclusion was wrong.** You don't need the source - you need the *bytecode*, and DXBC is
fully sufficient to reconstruct Metal. Two buckets:

#### Bucket A - the 40 stock shaders: donor transplant

Build a version-matched Mac URP donor project (`tools/donor/`, URP **14.0.12** + TMP 3.0.7, exact
match) with all 40 stock shaders in *Always Included Shaders* so every variant compiles. Then swap
each shader **wholesale** into the game data **by name** (built players keep no GUIDs) -
[`tools/rewrap/transplant_stock.py`](tools/rewrap/transplant_stock.py).

#### Bucket B - the 25 custom Shader Graphs: offline DXBC → Metal

This is the real work. We compile the game's own DXBC to Metal **offline with Unity's own HLSLcc**
([`tools/hlslcc/build.sh`](tools/hlslcc/)) - the very translator the Unity editor uses for Metal,
so its output natively speaks Unity's `xlatMtlMain` shader ABI. Every keyword variant of every
shader (~500+ programs) is translated and compile-checked against the real Metal toolchain by
[`tools/rewrap/inject_custom_metal2.py`](tools/rewrap/inject_custom_metal2.py).

**All 25 - including the 4 post-fx - now convert automatically.** Through the 5.1 port those four
(`BonusPass`/`DamageScreen`/`ScreenPass`/`AberrationShader`) had to be **hand-recovered MSL**,
because each carries a `float2` uniform at a 4-mod-8 byte offset (`_PlayerPos@148`) that MSL cannot
align to a plain `float2` member. The 7.0 port **retired that hand-authored tail entirely**: the
offset is expressible as an MSL **`packed_float2`** (size 8, align 4 - byte-identical to D3D's
packing), so `inject_custom_metal2.py` handles it like any other. The old hand-recovery path
([`tools/rewrap/inject_metal.py`](tools/rewrap/inject_metal.py)) is kept only as historical
reference - see [`docs/port-7.0.md`](docs/port-7.0.md) §4.

The catch: Unity **strips the RDEF reflection chunk** from shipped DXBC, and HLSLcc needs it. So
we **synthesize RDEF back** from the `SHDR` `dcl_*` declarations plus Unity's own serialized
parameter tables (`dxbc2msl.py`, `paramblob.py`).

We first proved the concept a harder way - **Path 3-lite**: harvest the Metal that D3DMetal
generates from the same DXBC *at runtime* under Wine (a `DYLD_INSERT_LIBRARIES` shim,
`tools/harvest/`, dumping every metallib), then re-wrap it. That produced GPU-validated math for
the 4 post-fx and taught us the binding model - but it also proved the harvested AIR **cannot be
binary-injected**: D3DMetal binds through bindless **argument-buffer heaps**, while Unity binds
**positionally** and compiles **MSL source** at load (`newLibraryWithSource:`). Hence: the re-wrap
must be **MSL source in Unity's ABI**. Full write-up: [`docs/native-shader-harvest.md`](docs/native-shader-harvest.md).

#### The three format secrets that actually made it work

Everything above still produces a black screen until you get these exactly right. All three were
found the hard way and are byte-verified against real donor/game shader entries:

1. **The trailing channel table.** A Unity code entry ends with a small platform-dependent
   input-binding table that **must be carried across the D3D→Metal swap**. Omit it and you get
   *"Failed to load GpuProgram from binary shader data"* even with perfect MSL.
2. **Constants are written at the SERIALIZED offsets.** Unity's Metal runtime writes uniforms at
   the byte offsets in `m_CommonParameters` ∪ the variant's **parameter blob** - but HLSLcc
   *repacks* its MSL structs. So we **re-lay every generated MSL constant-buffer struct** to sit
   at the serialized offsets, rather than trusting HLSLcc's layout.
3. **Vertex attributes are numbered by MSL, not D3D.** Each channel's value = the generated MSL's
   `[[attribute(n)]]` index **+ 13** - *not* the D3D ISGN register + 13. HLSLcc **compacts**
   attribute numbering when a shader declares inputs it doesn't use.

Secret #3 is the best bug of the whole project. The player character rendered **completely
invisible** - with a clean log and a valid pipeline state. The `Limb` vertex shader declares 5
inputs but uses 3, so the ISGN rule fed mesh **normals into the UV slot** and **tangents into
color** → `alpha = tangent.w = −1` → `discard` on every single pixel. Invisible player, zero
errors. Diagnosed by growing a Metal frame profiler (`tools/powerprof/`) that hooks PSO creation,
dumps vertex descriptors, and - critically - tracks `MTLParallelRenderCommandEncoder` sub-encoders
(Unity records the main pass through one; without hooking it, every bind and draw is invisible and
you chase a phantom "the draws never happen" theory).

**Result: all 65/65 shaders are Metal. The native build renders the game.**

### The 37 W mystery (a good one)

With everything rendering, the native build burned **~37 W at the main menu** - while the *Wine*
build sat at 0.7 W. Same machine, same scene, native supposedly "purer".

Cause: the player was booting a quality level whose serialized **`vSyncCount = 0`**. On macOS
Metal that disables `CAMetalLayer.displaySyncEnabled` and lets the main loop free-run at ~900 fps
- so Unity rendered the **entire frame pipeline offscreen ~8× per presented frame**: measured
**97 render encoders per frame instead of 12**, GPU 8.8 ms/frame ≈ 105% duty → pinned max clocks.

The same engine logic ran under Wine too - **D3DMetal force-syncs presents, which had masked it
the whole time.** Fix: [`tools/rewrap/patch_ggm_vsync.py`](tools/rewrap/patch_ggm_vsync.py)
surgically patches `vSyncCount 0→1` in the two offending quality levels. Verified: **exactly 12
render passes/frame, GPU 8.8 → 3.2 ms/frame** at a vsynced 120 fps, **GPU ~1.7 W steady / 2.1 W
peak** (−95%), machine barely warm.

### Runtime fixes needed to make it actually playable

Rendering was not the end. Three Windows-runtime leftovers, all fixed at the data/bundle level:

1. **"Instantiating Chunks" infinite hang** → the transplant shipped the game's **Windows-flavor
   .NET BCL**, whose `System.IO` P/Invokes `kernel32` (`EntryPointNotFoundException` ×69k - the
   "benign log noise" was never benign). Fix: copy the 22 BCL assemblies (`mscorlib`, `System*`,
   `netstandard`, `Mono.Security`) from the Mac donor's `Managed/` over the game's. Same Unity
   version → same API surface. Game/Unity assemblies stay the game's.
2. **"Failed to load a valid language file"** → the game loads `Application.dataPath + "/Lang"`,
   but on macOS `dataPath` is `<app>/Contents`, not `Contents/Resources/Data`. Fix: symlink
   `Contents/Lang` + `Contents/custommusic`. (Bundle-**root** symlinks break codesign sealing;
   these are inside `Contents`, which is fine.)
3. **Donor's `lib_burst_generated.bundle`** is hash-mismatched with the game's assemblies →
   remove it. Burst falls back to managed, and sprite-skin deformation still works (verified live).

#### Playing on a MacBook trackpad: right-click

The tutorial requires **right-click *drag*** (*"(RIGHT CLICK) me and drag me onto yourself"*).
Two things worth knowing, neither of which is a port bug:

- **RMB does reach the game.** A two-finger *tap* does nothing if macOS "Tap to click" is off; a
  two-finger **physical press** is a real right-click and works.
- **But RMB-drag is ergonomically impossible on a trackpad** - you can't hold a two-finger press
  *and* slide the cursor with those same fingers.

The game turns out to be on the **legacy Input Manager** (no `Unity.InputSystem.dll`), reading a
**data-driven bind table**: `Input.GetKey*(KeyBinds.GetBind("name"))`. Right-click is the
**`iteminteract`** bind.

**Where the binds live changed between demo versions** - watch for this on any future port:

- **5.1:** a dedicated `persistentDataPath/keybinds.json` (`KeyCode` enum *names*), and no in-game
  rebinding UI (`PreRunScript::{OpenBindsFile,ReloadBinds,ResetBinds}` was the intended UX).
- **7.0:** folded into the Settings system - `persistentDataPath/settings.json`, a flat list where a
  keybind's value is the KeyCode's **integer** (`Mouse1 = 324`, `LeftAlt = 308`). There is **no**
  `keybinds.json` anymore, *and* 7.0 adds a real in-game rebinding UI (Settings → Controls).

So: **rebind it to a held keyboard key.** [`tools/rewrap/patch_keybinds.py`](tools/rewrap/patch_keybinds.py)
does it (`iteminteract` → `LeftAlt`, i.e. hold **Option** to interact/drag; `--restore` to undo); it
auto-detects the 7.0 `settings.json` vs the 5.1 `keybinds.json` and speaks KeyCode names either way.
The bind file lives under the app's **`CFBundleIdentifier`** (`persistentDataPath` =
`~/Library/Application Support/<id>`); `port.sh` migrates it whenever it changes the id. The game
rewrites `settings.json` on exit, so **quit it before editing** (the tool refuses if it's running).

### Rebuilding the native port yourself

**It is one command** - [`tools/port.sh`](tools/port.sh) is the whole recipe, end to end, and it
self-verifies:

```bash
tools/port.sh --win ~/Games/CU_demo_7 \
              --out ~/Applications/Casualties.Unknown.Demo.v7.0.macOS.arm64.Metal.Native.app
```

It does: transplant → BCL swap → `dataPath` symlinks → de-burst → bundle identity (version stamp +
keybinds migration) → `globalgamemanagers` patches (Metal / vsync / retina / `runInBackground`) →
shaders (40 stock transplanted + 25 custom converted, compile-checked) → ad-hoc sign → headless
verify. It refuses to build into iCloud, refuses on a Unity-version mismatch, and fails loudly if 0
stock shaders transplant.

The **only** prerequisite that needs Unity is a **one-time** donor build:

- **Unity 2022.3.62f3** + Mac Build Support (Mono). Build **two** things (see the traps below - they
  are *not* interchangeable): the **player skeleton** (an empty macOS/Apple-Silicon project →
  `EmptyMac.app`) and the **shader donor** (the same project plus the URP/TMP scene from
  [`tools/donor/`](tools/donor/) (`DonorSetup.cs`) with all 40 stock shaders in *Always Included
  Shaders* → `Donor.app`).

Under the hood `port.sh` runs, in order: `transplant.sh` → the [runtime fixes](#runtime-fixes-needed-to-make-it-actually-playable)
(BCL swap, `Lang`/`custommusic` symlinks, remove `lib_burst_generated.bundle`) → `transplant_stock.py`
(Bucket A) → `inject_custom_metal2.py` (Bucket B, all 25) → `patch_ggm_metal.py` (shaderPlatform
4→14, `m_GraphicsAPIs` 2→16) → `patch_ggm_vsync.py` (the 37 W fix) → `patch_ggm_bool.py runInBackground off`
(the screen-lock fix) → `codesign`. The full by-hand sequence is preserved in
[`docs/port-7.0.md`](docs/port-7.0.md) §5 for reference or for porting other games.

> **Two traps `port.sh` now guards against** (both cost a build here):
>
> - **There are TWO donors.** The player skeleton (`EmptyMac.app`) and the shader donor (`Donor.app`)
>   are different builds. Point the stock-shader transplant at the skeleton and it silently transplants
>   nothing - you get a signed, launchable app that **renders pink**, with no error. `port.sh` takes
>   `--shader-donor` and dies on "transplanted 0".
> - **The bundle identifier IS the save/keybinds directory** (`persistentDataPath` =
>   `~/Library/Application Support/<CFBundleIdentifier>`). Change the id and the game regenerates
>   default binds - the RMB→Option trackpad fix vanishes. `port.sh` migrates the bind file when it
>   changes the id.

> **Environment gotcha:** this repo lives in iCloud-synced `~/Documents`, and the iCloud file
> provider re-stamps `com.apple.FinderInfo`, which **breaks `codesign`**. Build and keep the
> runnable `.app` **outside** iCloud (e.g. `~/Applications`); `port.sh` refuses to build into iCloud.

### Running the native port (with the Metal HUD)

The native `.app` double-clicks like any Mac game. But the Metal Performance HUD - the FPS /
frame-time / GPU-time overlay you get on Path 1 with `HUD=1` - is opted into with an **env var**,
and Finder does not pass your shell environment to an app. So there's a launcher for it:

```sh
./tools/run-native.sh              # launch with the HUD (default)
HUD=0   ./tools/run-native.sh      # plain launch, no overlay
WINDOWED=1 ./tools/run-native.sh   # 1600x900 window instead of fullscreen (RES=… to change)
PROF=1  ./tools/run-native.sh      # + the tools/powerprof JSONL frame profiler
```

It execs the bundle's binary **directly** (`…/CU_metaltest.app/Contents/MacOS/EmptyMac`) rather than
going through `open`, which is what makes `MTL_HUD_ENABLED` - and `DYLD_INSERT_LIBRARIES` for
`PROF=1` - actually reach the process. Defaults to `~/Applications/CU_metaltest.app`; pass another
path or set `APP=`. It refuses to run a bundle with no arm64 slice, so it can't quietly launch the
x86 player under Rosetta and call it "native".

Want the HUD on Finder/Dock launches too? `./tools/run-native.sh --install-hud-default` sets Metal's
per-app `MetalForceHudEnabled` default on the bundle ID (undo: `--uninstall-hud-default`).

Same overlay as Path 1 - but now it's reporting on **our** Metal frames, not D3DMetal's translated
ones, which is exactly how the [head-to-head numbers](#head-to-head-native-vs-d3dmetal---native-wins-gameplay-by-47)
below got sanity-checked.

---

## Power

### Approaches, worst → best

| Approach | What runs translated | Rendering | Measured on M2 Max | Verdict |
|---|---|---|---|---|
| **UTM (full-system emu)** | Entire PC + Win10 + DirectX + game; software GPU | ok | ~15-30 W, fans, throttling | baseline to beat |
| **Wine + Rosetta 2 + D3DMetal** (Gcenx GPTK) | Only the game's x86-64 code; OS native, D3D11→Metal live, real GPU | **100%** | **4.79 W marginal in gameplay** (CPU 3.50 + GPU 1.29), 120 FPS | **Works** - recommended if you just want to play |
| **Full native ARM64 + Metal** (this repo's deep track) | **Nothing.** Native engine, native Metal shaders | **100%** (65/65 shaders on 7.0) | **47% less power than D3DMetal in gameplay** - 2.54 W marginal (CPU 1.43, −59%: no Rosetta; GPU 1.11, −14%: offline-converted shaders beat live translation) | **Works** - the impressive one, and by far the most efficient |

### Measured: native build, active gameplay (M2 Max, `powermetrics`, 20 s in the tutorial, moving)

| | Idle baseline | Game (moving) | **Game's marginal cost** |
|---|---|---|---|
| CPU power | 394 mW | 1768 mW | **1374 mW** |
| GPU power | 70 mW | 1190 mW | **1120 mW** |
| **Combined (CPU+GPU+ANE)** | **466 mW** | **2966 mW** | **≈ 2.50 W** |
| GPU active residency | 3.5 % | 39 % | +35 pts |

The telling line is the GPU: it stayed pinned at **444 MHz - the M2 Max's lowest DVFS state - at
39% residency** for the whole run. The GPU never needed to clock up even once. (Before the vsync
fix, this same scene pulled **37 W**.)

### Head-to-head: native vs D3DMetal - **native wins gameplay by 47%**

Measured on the **7.0 demo** (2026-07-14, `tools/powermeasure.sh`): both builds, same scenes, same
movements, same resolution/refresh, 20 s each, idle baseline (189 mW CPU / 18 mW GPU) subtracted.
Two independent baselines agreed to within 12 mW, so these numbers are stable.

| **Gameplay** (tutorial, moving) | D3DMetal / Wine | **Native Metal** | Δ |
|---|---|---|---|
| CPU power | 3499 mW | **1433 mW** | **−2066 mW (−59%)** |
| GPU power | 1289 mW | **1106 mW** | **−183 mW (−14%)** |
| **Combined, baseline-subtracted** | 4788 mW | **2540 mW** | **−2248 mW (−47%)** |

**Going native cuts the game's in-game power draw by 47%, and it wins on BOTH processors.**

- **CPU - the Rosetta tax scales with the game.** x86→ARM64 translation costs **~2.07 W in
  gameplay** (vs ~1.07 W at the menu): the harder the game works, the more x86 there is to
  translate. **73% of D3DMetal's entire gameplay draw is CPU**, and most of that is pure overhead.
- **GPU - offline conversion beats live translation.** Our Metal shaders, converted once by
  `inject_custom_metal2.py`, render the same frame for **14% less GPU power** than D3DMetal
  translating D3D11 in the frame loop.

> **The old "native burns 2.5× the GPU" finding was a MENU ARTIFACT - retracted.** The 5.1
> head-to-head was taken on the main menu, which is the one scene where the native path has a bug.
> Never publish a menu number as the headline.

### The remaining bug: the native MENU wastes GPU (confirmed on 7.0)

| Menu | D3DMetal / Wine | **Native Metal** | Δ |
|---|---|---|---|
| CPU power | 1499 mW | **430 mW** | −1069 mW (−71%) |
| GPU power | **525 mW** | 1505 mW | **+980 mW (+187%)** |
| **Combined** | 2024 mW | **1934 mW** | −90 mW (**−4% only**) |

Native's *menu* GPU (1505 mW) is **higher than its own gameplay GPU** (1106 mW) and ~3× D3DMetal's
menu. A static menu cannot legitimately outweigh a moving game ⇒ redundant render work on the menu
scene (extra passes? the post-fx stack running over the menu?). It eats nearly the whole CPU win
there, collapsing the menu lead to −4%. **This does NOT affect gameplay** - it is scene-specific.
`tools/powerprof/` is the tool for it; it already caught the 37 W vsync bug with the same smell.

---

## Quick start - just play it (Path 1)

> **Bring your own copy.** This repo ships **no game files** - you point the launcher at the
> `.exe` from a copy of *Casualties: Unknown* that **you legally own**. Nothing here contains,
> downloads, or distributes the game.

**You need:** an Apple-Silicon Mac (M1/M2/M3/M4), macOS 14+, and [Homebrew](https://brew.sh).

**1. Install Rosetta 2** (translates the game's x86-64 code; built into macOS, no download):
```bash
softwareupdate --install-rosetta --agree-to-license
```

**2. Install the Game Porting Toolkit** (Gcenx cask - a prebuilt Wine that **bundles Apple's
D3DMetal**, the D3D11→Metal translator; no Apple-developer account, no compiling):
```bash
brew install --cask gcenx/wine/game-porting-toolkit
```
This drops `Game Porting Toolkit.app` in `/Applications`. It ships D3DMetal in
`…/Contents/Resources/wine/lib/external/D3DMetal.framework` - that is what does the graphics
translation.

**3. Get this repo** (you only need `tools/run-d3dmetal.sh`):
```bash
git clone https://github.com/Andreansx/casualities-unknown-apple-silicon.git
cd casualities-unknown-apple-silicon
```

**4. Launch, pointing at your own game `.exe`:**
```bash
./tools/run-d3dmetal.sh /path/to/CasualtiesUnknown.exe
```
The first run creates a Wine prefix at `~/Games/CasualtiesUnknown` (a few seconds), then the
game opens. Want the on-screen Metal FPS/power overlay? `HUD=1 ./tools/run-d3dmetal.sh …`.

**That's it.** No recompiling, no patching the game, no Windows VM.

### What it's actually doing (and why it's so light)

The untouched Windows `.exe` runs as a normal macOS process with **two runtime translators**
underneath - and crucially **no emulated PC**:

```
   CasualtiesUnknown.exe  (x86-64, Direct3D 11)   ← unmodified
        │
        ├─ Rosetta 2   :  x86-64 → ARM64 CPU instructions  (AOT-cached)
        └─ D3DMetal    :  Direct3D 11 → Metal, shaders included (DXBC → Metal, live)
        │
   your Apple-Silicon GPU + CPU  (native Metal)
```

UTM has to emulate an **entire virtual PC** - CPU, chipset, devices, the Windows kernel, and a
software GPU - which is why it burns 15-30 W. Here, only the game's own instructions and its
graphics API calls are translated; everything runs directly on macOS and the real GPU. That is
the whole difference, and it's why this sits at **~2.5 W / 120 FPS** on an M2 Max.

### Troubleshooting

- **Crash right at startup / black window that never renders** - almost always the D3DMetal
  library not being found. The launcher already handles this (it sets `DYLD_FALLBACK_LIBRARY_PATH`
  to the `wine/lib/external` folder, working around an rpath bug in the Gcenx cask). If you
  invoke Wine by hand, replicate that env - see the top of `tools/run-d3dmetal.sh`.
- **`D3DMetal not bundled in this GPTK`** - your GPTK cask version doesn't ship D3DMetal. Use the
  Gcenx `game-porting-toolkit` cask (it does); Apple's raw Wine build does not include it.
- **Saves** - land in the Wine prefix under
  `~/Games/CasualtiesUnknown/drive_c/users/crossover/AppData/LocalLow/Orsoniks/CasualtiesUnknown/`.

---

## Background

### Why

- The game ships **Windows 10 / x86-64 only** - a wall if the only hardware you have is Apple Silicon.
- An Apple-Silicon Mac is **ARM64**, so the only turn-key option is **UTM** - but Windows 10 x64 needs
  *full-system* emulation (QEMU TCG: whole CPU + MMU + devices + Win kernel + DirectX all
  translated, guest GPU software-rendered). Extremely power-hungry and thermally throttled -
  useless on battery.
- Goal: reuse the original binaries (**no recompilation**) but replace the OS/engine layer with a
  native one - the same idea as porting an x86-only appliance by removing its kernel module and
  running the untouched binaries under a userspace translator.

### The game

| | |
|---|---|
| Title | **Casualties: Unknown** (formerly *Scav Prototype*) |
| Developer / Publisher | Orsoniks (Moffee) / Oro Interactive |
| Genre | 2D pixel-art scavenge-survival roguelite |
| Engine | **Unity 2022.3.62f3 LTS** |
| Scripting backend | **Mono** (not IL2CPP) |
| Architecture | **x86-64** |

### Diagnosis (from inspecting the demo build)

Everything below was read from the shipped demo - no decompilation, no source.

| Check | Finding | Why it matters |
|---|---|---|
| Scripting backend | **Mono** - `MonoBleedingEdge/` present, `Managed/*.dll` present, **no** `GameAssembly.dll`, **no** `il2cpp_data/` | Managed DLLs are architecture-neutral CIL → reusable as-is on ARM64 |
| Unity version | **2022.3.62f3** (from `globalgamemanagers`) | LTS with a native macOS **Apple Silicon** player available |
| CPU arch | **x86-64** (`file` on `.exe`/`UnityPlayer.dll`) | 32-bit would have broken the Wine+Rosetta fallback; x64 is fine for both paths |
| Win32 P/Invoke | **none** - no `kernel32`/`user32`/`gdi32`/registry refs in `Assembly-CSharp.dll` | no Windows-only syscalls baked into game logic |
| Hardcoded paths | **none** - no `C:\`, `%APPDATA%`, `%USERPROFILE%` | no filesystem assumptions to patch |
| Middleware | only `Newtonsoft.Json.dll` (pure managed) | nothing native to port; no Steamworks/FMOD native in the demo |
| Native plugins | **exactly one:** `Plugins/x86_64/lib_burst_generated.dll` | the *only* architecture-specific artifact - see below |

**Conclusion:** the only piece of the entire build tied to x86-64 is the Unity Burst output.
Everything else is portable - *the code was never the problem. The shaders were.*

### The one arch-specific artifact: Unity Burst

`lib_burst_generated.dll` is AOT-compiled `[BurstCompile]` jobs for x86-64. On ARM64 it simply
won't load - **but Burst has a managed fallback**: the same jobs exist as plain C# in their managed
assemblies, so Unity runs the managed (Mono-JIT) version. Still multithreaded via the Job System -
only SIMD + Burst's optimizer are lost.

#### idalib RE of `lib_burst_generated.dll`

Static + Hex-Rays analysis via idalib (headless IDA Pro 9.4 - see `tools/`):

- **~32 Burst job entry points** (PE export table, hash-named), each compiled in **two x86 variants
  - AVX2 and SSE2**, and **no ARM64/NEON variant** → cannot run on Apple Silicon.
- DB: **389 functions, ~235 KB code, 103 AVX2 / 95 SSE / 147 looped**.
- Two heavy vectorized parallel-for bodies dominate:
  - `sub_18000E340` - 14.9 KB, 3442 insns, SSE, loop; **789 div, 262 mul, 43 sqrt** (`__m128`).
  - `sub_18002AA90` - 14.2 KB, 2886 insns, AVX2, loop; **144 div, 46 sqrt**, data-driven.
- Callbacks: `TransformAccess` / `TransformAccessArray` / `JobsUtility` / `UnsafeUtility`
  → `IJobParallelForTransform`.

**Origin - not game code.** `Assembly-CSharp.dll` has **no** `BurstCompile`/`IJob*`/`Schedule`
strings. The jobs come from stock Unity packages in `Managed/`:

- **2D Animation** (per-frame sprite skinning): `SkinDeformBatchedJob`, `BoneDeformBatchedJob`,
  `PrepareDeformJob`, `UpdateBoundJob`, `CalculateSpriteSkinAABBJob`, `CopySpriteRendererBuffersJob`.
- **SpriteShape** (spline→mesh): `MakeCreatorJob`, `MakeModifierJob`.
- **URP 2D** (per-frame light culling): `TilingJob`, `ZBinningJob`, `LightMinMaxZJob`,
  `TileRangeExpansionJob`, `DrawCallJob`.

The two heavy bodies map with high confidence: `sub_18000E340` (789 div / 43 sqrt / `__m128`
normalizations) = **`SkinDeformBatchedJob`**; `sub_18002AA90` = **SpriteShape tessellation**.

**Confirmed a non-issue.** These are first-party Unity jobs with **Unity-maintained managed
fallbacks** (a supported config). The native build runs with Burst removed entirely and sprite-skin
deformation works - verified live, deformed vertices animate, framerate holds. (If ever needed, a
NEON `lib_burst_generated.dylib` is **regenerable**: these are stock packages, so a minimal Mac
2022.3.62f3 project with the same packages makes Burst emit one.)

---

## Open questions / risks

- [x] `globalgamemanagers` portability - resolved: graphics/shader platform is baked in
      (`shaderPlatform 4 = D3D11`). Not a tunable, but it **is** surgically patchable
      (`patch_ggm_metal.py`).
- [x] ~~Custom shaders → unrecoverable, native path blocked~~ - **WRONG, and disproven.** All 25
      custom Shader Graphs were reconstructed from their shipped DXBC via Unity's own HLSLcc, and the
      4-post-fx hand-authored tail is now **retired** (`packed_float2`). **All 65/65 shaders have
      Metal variants; the native build renders 100%.**
- [x] ~~Burst-heavy code paths~~ - stock Unity 2D-animation/SpriteShape/URP jobs; managed fallback
      confirmed working in the real native build.
- [x] Native GPU power - 37 W at menu traced to `vSyncCount=0` quality levels; fixed, now ~1.7 W.
- [x] Input - **legacy Input Manager** (no `Unity.InputSystem.dll`), fully cross-platform. Binds are
      data-driven JSON; RMB rebound to Option for trackpad play (bind store = `settings.json` on 7.0).
- [x] Save location - `Application.persistentDataPath`. Under Wine:
      `%USERPROFILE%\AppData\LocalLow\Orsoniks\CasualtiesUnknown\`. Native: it lands under the app's
      `CFBundleIdentifier` in `~/Library/Application Support/<id>`.
- [x] **Head-to-head power measurement**, native vs GPTK - done and **re-measured on 7.0 in
      gameplay** (`tools/powermeasure.sh`, 2026-07-14): **native is 47% cheaper in active gameplay**
      (2540 vs 4788 mW marginal), winning on both CPU (−59%, no Rosetta) and GPU (−14%, offline
      shaders). The earlier "27% (menu)" number is superseded - it was a menu measurement.
- [ ] **Native menu wastes GPU** (scene-specific; does **not** affect gameplay). On the *main menu*
      only, native GPU (1505 mW) exceeds its own gameplay GPU (1106 mW) and ~3× D3DMetal's menu -
      redundant render work (extra passes? post-fx over the menu?). It collapses the menu lead to
      −4%. Profile with `tools/powerprof/` (the tool that caught the 37 W vsync bug).
      The older "native uses 2.5× the GPU for the same frame" framing was a **menu artifact and is
      retracted** - in gameplay native's GPU is *lower* than D3DMetal's.
- [ ] **DRM check on the retail build.** Demo scan is clean: no Steamworks/license/activation/
      tamper/checksum strings and no network endpoints in `Assembly-CSharp.dll` (the only
      `UnityWebRequest` use is `UnityWebRequestMultimedia` for the local `custommusic/` feature).
- [ ] Visual QA sweep of the 7.0 converted effects (esp. the 5 new graphs + the 2 rebuilt post-fx)
      across all gameplay states - the one step that still needs a human at an unlocked Mac.

## Distribution & legal (personal-use port)

Not legal advice. Intent: publish this repo as a **method** to run *your own legally-bought copy*
on Apple Silicon - never to distribute the game.

Guardrails that keep it defensible:

- **Tooling + docs only.** No game assets or binaries (already `.gitignore`d). The recovered
  shader MSL/AIR/DXBC is game-derived and is **gitignored too** - only the tools ship.
- **No Unity runtime redistribution.** The user installs Unity 2022.3.62f3 + Mac Build Support and
  builds the empty player locally - under their own Unity license, never shipped from this repo.
- **Bring-your-own-copy.** The scripts point at the user's own installed game files.
- **DRM check on release.** The demo has no Steam DRM/license stub; if the retail build is DRM-free
  too there is no protection measure to circumvent. If it wraps with Steam DRM, running outside
  that wrapper raises anti-circumvention concerns (US DMCA §1201) - re-evaluate then.

Favorable footing (EU / Poland): Software Directive 2009/24/EC Art. 5(1) (lawful acquirer may adapt
for intended use) and Art. 6 (RE for interoperability). US interop precedent: *Sony v. Connectix*,
*Sega v. Accolade* (RE a platform to run software on other hardware).

**The cleanest outcome would be an official Mac build.** Orsoniks is a solo indie dev, and solo devs
often welcome a community Apple-Silicon path - so if you want this upstreamed, reaching out to them
is worth a shot.

## Repository map

| Path | What |
|---|---|
| `tools/port.sh` | **The native build, one command** - transplant → runtime fixes → shaders → ggm patches → sign → headless verify. `--win <WindowsGameDir> --out <CU.app>`. |
| `tools/run-d3dmetal.sh` | **Path 1 launcher** - the one command that plays the game. `HUD=1` for the Metal overlay. |
| `tools/run-native.sh` | **Native launcher** - runs the ARM64/Metal `.app` with the same Metal HUD (`HUD=1` by default), plus `WINDOWED=1` / `PROF=1`. |
| `tools/transplant.sh` | Graft the Windows payload onto a native ARM64 Unity player (called by `port.sh`). |
| `tools/powermeasure.sh` | Baseline-subtracted CPU/GPU power for one scene → CSV; `--report` for the native-vs-D3DMetal table. |
| `tools/donor/` | Unity editor script to build the version-matched Mac shader donor. |
| `tools/rewrap/` | The shader pipeline: `transplant_stock.py` (40 stock), `inject_custom_metal2.py` (25 custom, via HLSLcc), `patch_ggm_*.py` (Metal / vsync / retina / bool), `patch_keybinds.py`, `verify_metal.py`. |
| `tools/hlslcc/` | Builds Unity's own HLSLcc DXBC→MSL translator + CLI. |
| `tools/harvest/` | Path 3-lite: `DYLD_INSERT_LIBRARIES` shim that dumps D3DMetal's runtime metallibs. |
| `tools/powerprof/` | Metal frame profiler shim (render passes / draws / GPU-ms as JSONL) - cracked both the 37 W bug and the invisible-player bug. |
| `docs/port-7.0.md` | The 7.0 Steam-demo port: one-command build, retired shader tail, traps, gameplay findings. |
| `docs/native-shader-harvest.md` | Full write-up of the shader recovery (Path 3-lite; historical). |
| `ROADMAP.md` | Living tracker: every path, task, and dead end, in detail. |

- **No game binaries are committed here** (copyright + ~300 MB). You bring your own legally-owned
  copy: point the scripts at it, or drop it in a local `CasualtiesUnknownDemo/` (`.gitignore`d).
  Built `.app`s are ignored too.
- Dead ends worth not repeating: **Whisky** (its Wine runtime hosting 404s) and **DXVK + MoltenVK**
  (loads, but crashes in `D3D11CoreCreateDevice`). Apple's raw GPTK dmg download was also broken.
  The working combination is the **Gcenx cask specifically, because it bundles D3DMetal**.

## Reference environment

Everything here was built and measured on:

- MacBook Pro **M2 Max**, macOS (Apple Silicon / ARM64).
- Unity toolchain for the native path: **2022.3.62f3** + Mac Build Support (Mono).
