# Casualties: Unknown — Apple Silicon Port

Making the Windows-only Unity game **Casualties: Unknown** run on Apple Silicon (M2 Max)
without full-system emulation — so it can actually be played on battery (e.g. on a train)
without the fans spinning up.

> ## Status: ✅ two working ports
>
> **1. The practical one — run the unmodified Windows `.exe`** under Wine + Rosetta 2 + Apple's
> **D3DMetal** (D3D11→Metal at runtime). One command, nothing patched, 100% correct rendering.
> Measured on an M2 Max: **~2.5 W total** (CPU 1.77 W + GPU 0.71 W) at **120 FPS**, GPU frame
> time **4.06 ms** — roughly **6–12× more power-efficient than UTM** (~15–30 W), fans off.
> → [Quick start](#quick-start--just-play-it-path-1)
>
> **2. The impressive one — a FULLY NATIVE Apple Silicon build.** No Wine, no Rosetta, no D3D:
> a native ARM64 Unity player running the game's original managed code and assets, rendering
> **100% on Metal** — because we **converted all 60 of the game's D3D11-only shaders to Metal
> offline**, including the 20 custom Shader Graphs whose source does not exist anywhere in the
> build. This was supposed to be impossible (see [The shader wall](#the-shader-wall-and-how-we-broke-through-it));
> the game is now **playable end-to-end natively**, at **120 FPS with a 3.2 ms GPU frame time**
> (i.e. *faster* than the translated build's 4.06 ms).
> → [The native port](#the-native-port-path-23--the-impressive-one)
>
> The whole stack is **free**: Rosetta 2 (built into macOS) + the Gcenx `game-porting-toolkit`
> cask (which bundles Apple's D3DMetal) + Unity 2022.3.62f3 for the native path. No CrossOver,
> no paid tools, no Apple-developer download.

**Which should you use?** Path 1 if you just want to play — it is one command and always
renders correctly. The native port is the deeper, more interesting result and is now fully
playable, but rebuilding it is a multi-step pipeline that needs a Unity install.

---

## Quick start — just play it (Path 1)

> **Bring your own copy.** This repo ships **no game files** — you point the launcher at the
> `.exe` from a copy of *Casualties: Unknown* that **you legally own**. Nothing here contains,
> downloads, or distributes the game.

**You need:** an Apple-Silicon Mac (M1/M2/M3/M4), macOS 14+, and [Homebrew](https://brew.sh).

**1. Install Rosetta 2** (translates the game's x86-64 code; built into macOS, no download):
```bash
softwareupdate --install-rosetta --agree-to-license
```

**2. Install the Game Porting Toolkit** (Gcenx cask — a prebuilt Wine that **bundles Apple's
D3DMetal**, the D3D11→Metal translator; no Apple-developer account, no compiling):
```bash
brew install --cask gcenx/wine/game-porting-toolkit
```
This drops `Game Porting Toolkit.app` in `/Applications`. It ships D3DMetal in
`…/Contents/Resources/wine/lib/external/D3DMetal.framework` — that is what does the graphics
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
underneath — and crucially **no emulated PC**:

```
   CasualtiesUnknown.exe  (x86-64, Direct3D 11)   ← unmodified
        │
        ├─ Rosetta 2   :  x86-64 → ARM64 CPU instructions  (AOT-cached)
        └─ D3DMetal    :  Direct3D 11 → Metal, shaders included (DXBC → Metal, live)
        │
   your Apple-Silicon GPU + CPU  (native Metal)
```

UTM has to emulate an **entire virtual PC** — CPU, chipset, devices, the Windows kernel, and a
software GPU — which is why it burns 15–30 W. Here, only the game's own instructions and its
graphics API calls are translated; everything runs directly on macOS and the real GPU. That is
the whole difference, and it's why this sits at **~2.5 W / 120 FPS** on an M2 Max.

### Troubleshooting

- **Crash right at startup / black window that never renders** — almost always the D3DMetal
  library not being found. The launcher already handles this (it sets `DYLD_FALLBACK_LIBRARY_PATH`
  to the `wine/lib/external` folder, working around an rpath bug in the Gcenx cask). If you
  invoke Wine by hand, replicate that env — see the top of `tools/run-d3dmetal.sh`.
- **`D3DMetal not bundled in this GPTK`** — your GPTK cask version doesn't ship D3DMetal. Use the
  Gcenx `game-porting-toolkit` cask (it does); Apple's raw Wine build does not include it.
- **Saves** — land in the Wine prefix under
  `~/Games/CasualtiesUnknown/drive_c/users/crossover/AppData/LocalLow/Orsoniks/CasualtiesUnknown/`.

---

## Why

- The game ships **Windows 10 / x86-64 only**. No Windows devices in the household.
- The MacBook Pro is **ARM64**, so the only turn-key option is **UTM** — but Windows 10 x64 needs
  *full-system* emulation (QEMU TCG: whole CPU + MMU + devices + Win kernel + DirectX all
  translated, guest GPU software-rendered). Extremely power-hungry and thermally throttled —
  useless on battery.
- Goal: reuse the original binaries (**no recompilation**) but replace the OS/engine layer with a
  native one — the same idea as porting an x86-only appliance by removing its kernel module and
  running the untouched binaries under a userspace translator.

## The game

| | |
|---|---|
| Title | **Casualties: Unknown** (formerly *Scav Prototype*) |
| Developer / Publisher | Orsoniks (Moffee) / Oro Interactive |
| Genre | 2D pixel-art scavenge-survival roguelite |
| Engine | **Unity 2022.3.62f3 LTS** |
| Scripting backend | **Mono** (not IL2CPP) |
| Architecture | **x86-64** |

## Diagnosis (from inspecting the demo build)

Everything below was read from the shipped demo — no decompilation, no source.

| Check | Finding | Why it matters |
|---|---|---|
| Scripting backend | **Mono** — `MonoBleedingEdge/` present, `Managed/*.dll` present, **no** `GameAssembly.dll`, **no** `il2cpp_data/` | Managed DLLs are architecture-neutral CIL → reusable as-is on ARM64 |
| Unity version | **2022.3.62f3** (from `globalgamemanagers`) | LTS with a native macOS **Apple Silicon** player available |
| CPU arch | **x86-64** (`file` on `.exe`/`UnityPlayer.dll`) | 32-bit would have broken the Wine+Rosetta fallback; x64 is fine for both paths |
| Win32 P/Invoke | **none** — no `kernel32`/`user32`/`gdi32`/registry refs in `Assembly-CSharp.dll` | no Windows-only syscalls baked into game logic |
| Hardcoded paths | **none** — no `C:\`, `%APPDATA%`, `%USERPROFILE%` | no filesystem assumptions to patch |
| Middleware | only `Newtonsoft.Json.dll` (pure managed) | nothing native to port; no Steamworks/FMOD native in the demo |
| Native plugins | **exactly one:** `Plugins/x86_64/lib_burst_generated.dll` | the *only* architecture-specific artifact — see below |

**Conclusion:** the only piece of the entire build tied to x86-64 is the Unity Burst output.
Everything else is portable — *the code was never the problem. The shaders were.*

## Approaches, worst → best

| Approach | What runs translated | Rendering | Measured on M2 Max | Verdict |
|---|---|---|---|---|
| **UTM (full-system emu)** | Entire PC + Win10 + DirectX + game; software GPU | ok | ~15–30 W, fans, throttling | baseline to beat |
| **Wine + Rosetta 2 + D3DMetal** (Gcenx GPTK) | Only the game's x86-64 code; OS native, D3D11→Metal live, real GPU | **100%** | **~2.5 W total**, 120 FPS, **4.06 ms** GPU frame | ✅ **works — recommended** |
| **Full native ARM64 + Metal** (this repo's deep track) | **Nothing.** Native engine, native Metal shaders | **100%** (60/60 shaders) | 120 FPS, **3.2 ms** GPU frame; GPU rail ~1.7 W at menu | ✅ **works — the impressive one** |

> **Honesty note on power:** the two are not measured head-to-head on the same scene. Path 1's
> 2.5 W is a whole-package figure in gameplay; the native build's 1.7 W is the **GPU rail at the
> menu**. What *is* directly comparable is GPU frame time on the same content: **3.2 ms native vs
> 4.06 ms translated**. Native removes Rosetta from the CPU side entirely, so it should win on
> total package power too — but that measurement hasn't been run yet, and this README won't claim
> a number it doesn't have.

---

# The native port (Path 2/3) — the impressive one

A native ARM64 macOS `.app` that runs the game's **original managed code and assets** on a stock
Apple Silicon Unity player, rendering **entirely on Metal**. No Wine. No Rosetta. No Direct3D.
No translation layer of any kind at runtime.

**Principle** (mirrors an x86-appliance port): *native macOS binaries stay; the cross-platform
payload comes from the Windows build.* You build an **empty** Unity 2022.3.62f3 macOS/Apple-Silicon
project to get a correct native player skeleton, then graft the game's `Data/` payload onto it.
Automated by **[`tools/transplant.sh`](tools/transplant.sh)**.

The managed half of this worked almost immediately. The GPU half is where the story is.

## The shader wall — and how we broke through it

The transplant boots, Mono loads `Assembly-CSharp.dll`, subsystems init… and then the player
logs `NullGfxDevice` and dies in the draw path. Root cause, found by diffing the game's
`globalgamemanagers` against an empty Mac build's with UnityPy:

> `GraphicsSettings.m_ShaderDefinesPerShaderCompiler.shaderPlatform` = **4 (D3D11)** in the game,
> **14 (Metal)** in the Mac build. **Every one of the 60 shaders in the build is D3D11-only
> bytecode. There are no Metal variants — not even engine blit shaders.**

`-force-metal` is a real flag and does force the Metal device, but then:
`Forced GfxDevice 'Metal' … shaders will not be available` → `InitializeEngineGraphics failed`.

And the nasty part: **20 of those shaders are the game's own custom Shader Graphs** (the 4 post-fx
`BonusPass` / `DamageScreen` / `ScreenPass` / `AberrationShader`, plus 16 gameplay graphs like
`Limb`, `WallHole`, `RadBackground`, `HoverShader`). Unity ships **no source** for them in a build
— only compiled DXBC + ShaderLab metadata. Stock URP shaders you can re-obtain from a Mac build.
Custom graphs, conventional wisdom says, you cannot rebuild without the original project.

**That conclusion was wrong.** You don't need the source — you need the *bytecode*, and DXBC is
fully sufficient to reconstruct Metal. Two buckets:

### Bucket A — the 40 stock shaders: donor transplant
Build a version-matched Mac URP donor project (`tools/donor/`, URP **14.0.12** + TMP 3.0.7, exact
match) with all 40 stock shaders in *Always Included Shaders* so every variant compiles. Then swap
each shader **wholesale** into the game data **by name** (built players keep no GUIDs) —
[`tools/rewrap/transplant_stock.py`](tools/rewrap/transplant_stock.py).

### Bucket B — the 20 custom Shader Graphs: offline DXBC → Metal
This is the real work. For the **16 gameplay graphs** we compile the game's own DXBC to Metal
**offline with Unity's own HLSLcc** ([`tools/hlslcc/build.sh`](tools/hlslcc/)) — the very
translator the Unity editor uses for Metal, so its output natively speaks Unity's `xlatMtlMain`
shader ABI. Every keyword variant of every shader (~500 programs) is translated and compile-checked
against the real Metal toolchain by
[`tools/rewrap/inject_custom_metal2.py`](tools/rewrap/inject_custom_metal2.py). The **4 post-fx**
(`BonusPass`/`DamageScreen`/`ScreenPass`/`AberrationShader`) are instead hand-recovered MSL,
injected by [`tools/rewrap/inject_metal.py`](tools/rewrap/inject_metal.py) — see below.

The catch: Unity **strips the RDEF reflection chunk** from shipped DXBC, and HLSLcc needs it. So
we **synthesize RDEF back** from the `SHDR` `dcl_*` declarations plus Unity's own serialized
parameter tables (`dxbc2msl.py`, `paramblob.py`).

We first proved the concept a harder way — **Path 3-lite**: harvest the Metal that D3DMetal
generates from the same DXBC *at runtime* under Wine (a `DYLD_INSERT_LIBRARIES` shim,
`tools/harvest/`, dumping every metallib), then re-wrap it. That produced GPU-validated math for
the 4 post-fx and taught us the binding model — but it also proved the harvested AIR **cannot be
binary-injected**: D3DMetal binds through bindless **argument-buffer heaps**, while Unity binds
**positionally** and compiles **MSL source** at load (`newLibraryWithSource:`). Hence: the re-wrap
must be **MSL source in Unity's ABI**. Full write-up: [`docs/native-shader-harvest.md`](docs/native-shader-harvest.md).

### The three format secrets that actually made it work
Everything above still produces a black screen until you get these exactly right. All three were
found the hard way and are byte-verified against real donor/game shader entries:

1. **The trailing channel table.** A Unity code entry ends with a small platform-dependent
   input-binding table that **must be carried across the D3D→Metal swap**. Omit it and you get
   *"Failed to load GpuProgram from binary shader data"* even with perfect MSL.
2. **Constants are written at the SERIALIZED offsets.** Unity's Metal runtime writes uniforms at
   the byte offsets in `m_CommonParameters` ∪ the variant's **parameter blob** — but HLSLcc
   *repacks* its MSL structs. So we **re-lay every generated MSL constant-buffer struct** to sit
   at the serialized offsets, rather than trusting HLSLcc's layout.
3. **Vertex attributes are numbered by MSL, not D3D.** Each channel's value = the generated MSL's
   `[[attribute(n)]]` index **+ 13** — *not* the D3D ISGN register + 13. HLSLcc **compacts**
   attribute numbering when a shader declares inputs it doesn't use.

Secret #3 is the best bug of the whole project. The player character rendered **completely
invisible** — with a clean log and a valid pipeline state. The `Limb` vertex shader declares 5
inputs but uses 3, so the ISGN rule fed mesh **normals into the UV slot** and **tangents into
color** → `alpha = tangent.w = −1` → `discard` on every single pixel. Invisible player, zero
errors. Diagnosed by growing a Metal frame profiler (`tools/powerprof/`) that hooks PSO creation,
dumps vertex descriptors, and — critically — tracks `MTLParallelRenderCommandEncoder` sub-encoders
(Unity records the main pass through one; without hooking it, every bind and draw is invisible and
you chase a phantom "the draws never happen" theory).

**Result: all 60/60 shaders are Metal. The native build renders the game.**

## The 37 W mystery (a good one)

With everything rendering, the native build burned **~37 W at the main menu** — while the *Wine*
build sat at 0.7 W. Same machine, same scene, native supposedly "purer".

Cause: the player was booting a quality level whose serialized **`vSyncCount = 0`**. On macOS
Metal that disables `CAMetalLayer.displaySyncEnabled` and lets the main loop free-run at ~900 fps
— so Unity rendered the **entire frame pipeline offscreen ~8× per presented frame**: measured
**97 render encoders per frame instead of 12**, GPU 8.8 ms/frame ≈ 105% duty → pinned max clocks.

The same engine logic ran under Wine too — **D3DMetal force-syncs presents, which had masked it
the whole time.** Fix: [`tools/rewrap/patch_ggm_vsync.py`](tools/rewrap/patch_ggm_vsync.py)
surgically patches `vSyncCount 0→1` in the two offending quality levels. Verified: **exactly 12
render passes/frame, GPU 8.8 → 3.2 ms/frame** at a vsynced 120 fps, **GPU ~1.7 W steady / 2.1 W
peak** (−95%), machine barely warm.

## Runtime fixes needed to make it actually playable

Rendering was not the end. Three Windows-runtime leftovers, all fixed at the data/bundle level:

1. **"Instantiating Chunks" infinite hang** → the transplant shipped the game's **Windows-flavor
   .NET BCL**, whose `System.IO` P/Invokes `kernel32` (`EntryPointNotFoundException` ×69k — the
   "benign log noise" was never benign). Fix: copy the 22 BCL assemblies (`mscorlib`, `System*`,
   `netstandard`, `Mono.Security`) from the Mac donor's `Managed/` over the game's. Same Unity
   version → same API surface. Game/Unity assemblies stay the game's.
2. **"Failed to load a valid language file"** → the game loads `Application.dataPath + "/Lang"`,
   but on macOS `dataPath` is `<app>/Contents`, not `Contents/Resources/Data`. Fix: symlink
   `Contents/Lang` + `Contents/custommusic`. (Bundle-**root** symlinks break codesign sealing;
   these are inside `Contents`, which is fine.)
3. **Donor's `lib_burst_generated.bundle`** is hash-mismatched with the game's assemblies →
   remove it. Burst falls back to managed, and sprite-skin deformation still works (verified live).

### Playing on a MacBook trackpad: right-click

The tutorial requires **right-click *drag*** (*"(RIGHT CLICK) me and drag me onto yourself"*).
Two things worth knowing, neither of which is a port bug:

- **RMB does reach the game.** A two-finger *tap* does nothing if macOS "Tap to click" is off; a
  two-finger **physical press** is a real right-click and works.
- **But RMB-drag is ergonomically impossible on a trackpad** — you can't hold a two-finger press
  *and* slide the cursor with those same fingers.

The game turns out to be on the **legacy Input Manager** (no `Unity.InputSystem.dll`), reading a
**data-driven bind table**: `Input.GetKey*(KeyBinds.GetBind("name"))`, backed by
`persistentDataPath/keybinds.json` whose values are `KeyCode` enum names. Right-click is the
**`iteminteract`** bind. There's no in-game rebinding UI — `PreRunScript::{OpenBindsFile,
ReloadBinds,ResetBinds}` (edit the JSON, hit reload) **is** the developer's intended rebinding UX.

So: **rebind it to a held keyboard key.** [`tools/rewrap/patch_keybinds.py`](tools/rewrap/patch_keybinds.py)
does it (`iteminteract` → `LeftAlt`, i.e. hold **Option** to interact/drag; `--restore` to undo).
Note the bind file lives under the **donor's** bundle id
(`~/Library/Application Support/com.DefaultCompany.2DProject/`), since the transplant inherits the
donor `.app`'s `Info.plist`; and binds are cached in a static, so restart the game after editing.

## Rebuilding the native port yourself

Not a one-command flow yet — it needs Unity and a few passes. Order:

1. **Unity 2022.3.62f3** + Mac Build Support (Mono). Build the **donor**: an empty macOS/Apple-Silicon
   project, plus the URP/TMP donor scene from [`tools/donor/`](tools/donor/) (`DonorSetup.cs`) with
   all 40 stock shaders in *Always Included Shaders*.
2. `tools/transplant.sh --win <WindowsGameDir> --mac-app <EmptyMac.app> --out <CU.app>` — grafts the
   payload, drops the x86 plugins, ad-hoc signs.
3. `tools/rewrap/transplant_stock.py` — Bucket A, the 40 stock shaders from the donor.
4. `tools/hlslcc/build.sh` (once), then `tools/rewrap/inject_custom_metal2.py --src-data <WindowsBuild>/CasualtiesUnknown_Data --dst-data <CU.app>/Contents/Resources/Data --compile-check` — Bucket B, the 16 custom gameplay graphs. Then `tools/rewrap/inject_metal.py` for the 4 hand-recovered post-fx.
5. `tools/rewrap/patch_ggm_metal.py` (shaderPlatform 4→14, `m_GraphicsAPIs` 2→16) and
   `tools/rewrap/patch_ggm_vsync.py` (the 37 W fix).
6. Apply the [runtime fixes](#runtime-fixes-needed-to-make-it-actually-playable) (BCL swap, `Lang`/
   `custommusic` symlinks, remove `lib_burst_generated.bundle`), then
   `codesign --force --deep -s - <CU.app>`.

> **Known rough edges.** The runtime fixes in step 6 are **not yet folded into `transplant.sh`** —
> apply them by hand on a rebuild. The 4 hand-recovered post-fx stay hand-authored on purpose
> (their `float2 _PlayerPos@148` sits at a 4-mod-8 offset, unrepresentable as an MSL `float2`
> member). `ScreenPass` merges one blur tap (12/13 samples) — a minor fidelity gap.
>
> **Environment gotcha:** this repo lives in iCloud-synced `~/Documents`, and the iCloud file
> provider re-stamps `com.apple.FinderInfo`, which **breaks `codesign`**. Build and keep the
> runnable `.app` **outside** iCloud (e.g. `~/Applications`).

---

## The one arch-specific artifact: Unity Burst

`lib_burst_generated.dll` is AOT-compiled `[BurstCompile]` jobs for x86-64. On ARM64 it simply
won't load — **but Burst has a managed fallback**: the same jobs exist as plain C# in their managed
assemblies, so Unity runs the managed (Mono-JIT) version. Still multithreaded via the Job System —
only SIMD + Burst's optimizer are lost.

### idalib RE of `lib_burst_generated.dll`

Static + Hex-Rays analysis via idalib (headless IDA Pro 9.4 — see `tools/`):

- **~32 Burst job entry points** (PE export table, hash-named), each compiled in **two x86 variants
  — AVX2 and SSE2**, and **no ARM64/NEON variant** → cannot run on Apple Silicon.
- DB: **389 functions, ~235 KB code, 103 AVX2 / 95 SSE / 147 looped**.
- Two heavy vectorized parallel-for bodies dominate:
  - `sub_18000E340` — 14.9 KB, 3442 insns, SSE, loop; **789 div, 262 mul, 43 sqrt** (`__m128`).
  - `sub_18002AA90` — 14.2 KB, 2886 insns, AVX2, loop; **144 div, 46 sqrt**, data-driven.
- Callbacks: `TransformAccess` / `TransformAccessArray` / `JobsUtility` / `UnsafeUtility`
  → `IJobParallelForTransform`.

**Origin — not game code.** `Assembly-CSharp.dll` has **no** `BurstCompile`/`IJob*`/`Schedule`
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
deformation works — verified live, deformed vertices animate, framerate holds. (If ever needed, a
NEON `lib_burst_generated.dylib` is **regenerable**: these are stock packages, so a minimal Mac
2022.3.62f3 project with the same packages makes Burst emit one.)

## Open questions / risks

- [x] `globalgamemanagers` portability — resolved: graphics/shader platform is baked in
      (`shaderPlatform 4 = D3D11`). Not a tunable, but it **is** surgically patchable
      (`patch_ggm_metal.py`).
- [x] ~~Custom shaders → unrecoverable, native path blocked~~ — **WRONG, and disproven.** All 20
      custom Shader Graphs were reconstructed from their shipped DXBC via Unity's own HLSLcc.
      **All 60/60 shaders now have Metal variants; the native build renders 100%.**
- [x] ~~Burst-heavy code paths~~ — stock Unity 2D-animation/SpriteShape/URP jobs; managed fallback
      confirmed working in the real native build.
- [x] Native GPU power — 37 W at menu traced to `vSyncCount=0` quality levels; fixed, now ~1.7 W.
- [x] Input — **legacy Input Manager** (no `Unity.InputSystem.dll`), fully cross-platform. Binds are
      data-driven JSON; RMB rebound to Option for trackpad play.
- [x] Save location — `Application.persistentDataPath`. Under Wine:
      `%USERPROFILE%\AppData\LocalLow\Orsoniks\CasualtiesUnknown\`. Native: note the transplant
      inherits the **donor's** bundle id, so it lands in
      `~/Library/Application Support/com.DefaultCompany.2DProject/`.
- [ ] **Head-to-head power measurement**, native vs GPTK, same scene, whole package.
- [ ] **DRM check on the retail build.** Demo scan is clean: no Steamworks/license/activation/
      tamper/checksum strings and no network endpoints in `Assembly-CSharp.dll` (the only
      `UnityWebRequest` use is `UnityWebRequestMultimedia` for the local `custommusic/` feature).
- [ ] Visual QA sweep of the converted effects across all gameplay states.

## Distribution & legal (personal-use port)

Not legal advice. Intent: publish this repo as a **method** to run *your own legally-bought copy*
on Apple Silicon — never to distribute the game.

Guardrails that keep it defensible:
- **Tooling + docs only.** No game assets or binaries (already `.gitignore`d). The recovered
  shader MSL/AIR/DXBC is game-derived and is **gitignored too** — only the tools ship.
- **No Unity runtime redistribution.** The user installs Unity 2022.3.62f3 + Mac Build Support and
  builds the empty player locally — under their own Unity license, never shipped from this repo.
- **Bring-your-own-copy.** The scripts point at the user's own installed game files.
- **DRM check on release.** The demo has no Steam DRM/license stub; if the retail build is DRM-free
  too there is no protection measure to circumvent. If it wraps with Steam DRM, running outside
  that wrapper raises anti-circumvention concerns (US DMCA §1201) — re-evaluate then.

Favorable footing (EU / Poland): Software Directive 2009/24/EC Art. 5(1) (lawful acquirer may adapt
for intended use) and Art. 6 (RE for interoperability). US interop precedent: *Sony v. Connectix*,
*Sega v. Accolade* (RE a platform to run software on other hardware).

**Best practical move:** ask the developer (Orsoniks) — a solo indie dev often welcomes a community
Apple-Silicon path, or may ship an official Mac build.

## Repository map

| Path | What |
|---|---|
| `tools/run-d3dmetal.sh` | **Path 1 launcher** — the one command that plays the game. |
| `tools/transplant.sh` | Graft the Windows payload onto a native ARM64 Unity player. |
| `tools/donor/` | Unity editor script to build the version-matched Mac shader donor. |
| `tools/rewrap/` | The shader pipeline: `transplant_stock.py` (40 stock), `inject_custom_metal2.py` (20 custom, via HLSLcc), `patch_ggm_*.py` (Metal / vsync / retina), `patch_keybinds.py`. |
| `tools/hlslcc/` | Builds Unity's own HLSLcc DXBC→MSL translator + CLI. |
| `tools/harvest/` | Path 3-lite: `DYLD_INSERT_LIBRARIES` shim that dumps D3DMetal's runtime metallibs. |
| `tools/powerprof/` | Metal frame profiler shim (render passes / draws / GPU-ms as JSONL) — cracked both the 37 W bug and the invisible-player bug. |
| `docs/native-shader-harvest.md` | Full write-up of the shader recovery. |
| `ROADMAP.md` | Living tracker: every path, task, and dead end, in detail. |

- **The game binaries are not committed** (copyright + ~300 MB). Place the demo locally in
  `CasualtiesUnknownDemo/` — `.gitignore`d. Built `.app`s are ignored too.
- Dead ends worth not repeating: **Whisky** (its Wine runtime hosting 404s) and **DXVK + MoltenVK**
  (loads, but crashes in `D3D11CoreCreateDevice`). Apple's raw GPTK dmg download was also broken.
  The working combination is the **Gcenx cask specifically, because it bundles D3DMetal**.

## Environment

- MacBook Pro **M2 Max**, macOS (Apple Silicon / ARM64).
- Unity toolchain for the native path: **2022.3.62f3** + Mac Build Support (Mono).
