# Casualties: Unknown — Apple Silicon Port

Making the Windows-only Unity game **Casualties: Unknown** run on Apple Silicon
(M2 Max) in a way that is **more power-efficient than full-system emulation**, so
it can actually be played on battery (e.g. on a train) without the fans spinning up.

> **Status: ✅ WORKING.** The game runs on Apple Silicon from its **unmodified Windows binary**,
> via **Wine + Rosetta 2 + Apple's D3DMetal** (D3D11→Metal at runtime). Measured in-game on an
> M2 Max: **~2.5 W total** (CPU 1.77 W + GPU 0.71 W) at a **120 FPS** cap with **4 ms** GPU frame
> time — roughly **6–12× more power-efficient than UTM** (~15–30 W), and the fans stay off.
> One command: [`tools/run-d3dmetal.sh`](#quick-start--run-your-own-copy).
>
> The whole stack is **free**: Rosetta 2 (built into macOS) + the Gcenx `game-porting-toolkit`
> Homebrew cask, which conveniently **bundles Apple's D3DMetal** — no CrossOver, no paid tools,
> no Apple-developer download.
>
> Background: a native ARM64 engine transplant was also proven to *run the code*, but it hits a
> hard **shader wall** (the Windows build ships D3D11-only shaders incl. non-recoverable custom
> Shader Graphs, so nothing renders natively on Metal). Runtime D3D→Metal translation sidesteps
> that wall entirely. See "Result: the shader wall" below.

---

## Quick start — run your own copy

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
- The MacBook Pro is **ARM64**, so the only tur-key option is **UTM** — but Windows 10
  x64 needs *full-system* emulation (QEMU TCG: whole CPU + MMU + devices + Win kernel +
  DirectX are all translated, and the guest GPU is software-rendered). That is extremely
  power-hungry and thermally throttled — useless on battery.
- Goal: reuse the original binaries (**no recompilation**) but replace the OS/engine
  layer with a native one — the same idea as porting an x86-only appliance by removing
  its kernel module and running the untouched binaries under a userspace translator.

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

**Conclusion:** the only piece of the entire build that is tied to x86-64 is the Unity
Burst output. Everything else is portable.

## Approaches, worst → best (energy)

| Approach | What runs translated | Est. package power on M2 Max | Verdict |
|---|---|---|---|
| **UTM (full-system emu)** | Entire PC + Win10 + DirectX + game; software GPU | ~15–30 W, fans, throttling | baseline to beat |
| **Wine + Rosetta 2 + D3DMetal** (Gcenx GPTK) | Only the game's x86-64 code; OS native, DirectX→Metal, real GPU. Rosetta AOT-caches translations + uses Apple-Silicon TSO | **~2.5 W (measured)** | ✅ **works — the answer** |
| **Native Mono player swap** | Nothing — native ARM64 engine runs the original CIL + assets | ~2–5 W (est.) | blocked by the shader wall (see below) |

## The one arch-specific artifact: Unity Burst

`lib_burst_generated.dll` is AOT-compiled `[BurstCompile]` jobs for x86-64. On ARM64 it
simply won't load — **but Burst has a managed fallback**: the same jobs also exist as
plain C# in their managed assemblies, so when the native Burst library for the current
platform is missing, Unity runs the managed (Mono-JIT) version. Still multithreaded via
the Job System — only SIMD + Burst's optimizer are lost for those jobs.

### idalib RE of `lib_burst_generated.dll`

Static + Hex-Rays analysis via idalib (headless IDA Pro 9.4 — see `tools/`):

- **~32 Burst job entry points** (PE export table, hash-named), each compiled in **two x86
  variants — AVX2 and SSE2**, and **no ARM64/NEON variant** → cannot run on Apple Silicon.
- DB: **389 functions, ~235 KB code, 103 AVX2 / 95 SSE / 147 looped**.
- Two heavy vectorized parallel-for bodies dominate:
  - `sub_18000E340` — 14.9 KB, 3442 insns, SSE, loop; **789 div, 262 mul, 43 sqrt** (`__m128`).
  - `sub_18002AA90` — 14.2 KB, 2886 insns, AVX2, loop; **144 div, 46 sqrt**, data-driven.
- Callbacks: `TransformAccess` / `TransformAccessArray` / `JobsUtility` / `UnsafeUtility`
  → `IJobParallelForTransform`.

**Origin — not game code.** `Assembly-CSharp.dll` has **no** `BurstCompile`/`IJob*`/`Schedule`
strings. The jobs come from stock Unity packages in `Managed/`, named from their assemblies:

- **2D Animation** (per-frame sprite skinning): `SkinDeformBatchedJob`, `BoneDeformBatchedJob`,
  `PrepareDeformJob`, `UpdateBoundJob`, `CalculateSpriteSkinAABBJob`, `CopySpriteRendererBuffersJob`,
  `*TransformAccessJob`.
- **SpriteShape** (spline→mesh, on shape change): `MakeCreatorJob`, `MakeModifierJob`.
- **URP 2D** (per-frame light culling, tiny): `TilingJob`, `ZBinningJob`, `LightMinMaxZJob`,
  `TileRangeExpansionJob`, `DrawCallJob` (decals).

The two heavy bodies map with high confidence: `sub_18000E340` (789 div / 43 sqrt / `__m128`,
normalizations) = **`SkinDeformBatchedJob`** (per-vertex skinning); `sub_18002AA90` =
**SpriteShape tessellation**. So the only per-frame fallback cost is sprite skinning + URP
light binning — negligible on an M2 Max. Implication: the game uses **bone-rigged, skinned 2D
characters**.

**Risk downgraded → likely non-issue.** These are first-party Unity jobs with
**Unity-maintained managed fallbacks** (a supported config, not janky). Low-vertex 2D
animation on an M2 Max should hold framerate on the scalar path. And because they are
**stock packages, not proprietary code, a native ARM64 Burst lib is regenerable**: a minimal
Mac 2022.3.62f3 project using the same packages + a skinned/IK/SpriteShape/2D-light scene
makes Burst emit a NEON `lib_burst_generated.dylib` to drop in.

## Port plan (native Mono transplant)

> Automated by **`tools/transplant.sh`** (validated end-to-end on the demo data). You supply
> the Windows build + an empty macOS ARM64 player you build in Unity; it does the graft,
> drops the x86 plugins, keeps Metal built-ins, and ad-hoc signs the bundle.

Principle (mirrors an x86-appliance port): **native macOS binaries stay, the
cross-platform payload comes from the Windows build.**

1. Install **Unity 2022.3.62f3** (exact version) + **Mac Build Support (Mono)**, build an
   **empty** project for **macOS / Apple Silicon**. This yields a correct `.app` skeleton
   with the native ARM64 player, `UnityPlayer.dylib`, and the **macOS** `MonoBleedingEdge/`.
2. Into `Game.app/Contents/Resources/Data/`, copy the **payload** from the Windows build
   (these files are portable across desktop targets):
   `level0`, `level1`, `sharedassets*`, `resources.assets*`, `resources.resource`,
   `globalgamemanagers.assets*`, `Resources/`, `Lang/`, `custommusic/`,
   `RuntimeInitializeOnLoads.json`, `ScriptingAssemblies.json`, `app.info`, and from
   `Managed/` **only** the game's own DLLs: `Assembly-CSharp.dll`, `Newtonsoft.Json.dll`
   (the other ~119 are engine DLLs — keep the macOS copies).
3. **Do NOT** copy: `Plugins/x86_64/lib_burst_generated.dll` (skip → managed fallback),
   the Windows `MonoBleedingEdge/`, `UnityPlayer.dll`, or the `.exe`.

### Two things to verify by eye

- **`globalgamemanagers`** (the file, not `.assets`) holds the graphics API + platform id.
  Usually transplantable; if the player reports a mismatch, keep the macOS empty-build's
  copy and bring over only the scene/asset payload. This is the one finicky file.
- **Shaders** — Windows build variants are compiled for D3D. For pixel art on
  `Sprites/Default` + UI shaders these are built into the macOS player, so covered.
  Custom shaders without a Metal variant would show as pink/black sprites → visual test.

Textures: Apple Silicon **Macs** (unlike iOS devices) support BCn/DXT in Metal, and pixel
art is often uncompressed RGBA32 anyway → safe.

## Quick-win baseline (before the transplant)

Run the original build under **Whisky** / **Apple Game Porting Toolkit** (Wine + Rosetta 2).
Because it's x86-64, Rosetta handles it; DirectX→Metal via D3DMetal. Gives an immediately
low-power, playable baseline (~3–8 W) that already beats UTM.

**Update: for this game this is not just the quick win — it is THE answer** (see below).

## Result: the shader wall (why native rendering is blocked)

The transplant was built and run end-to-end. Findings from the real launch (`Player.log`):

- **Native code path works.** ARM64 player boots, Mono loads `Assembly-CSharp.dll` + all
  assemblies, PhysX/Input/subsystems init, version + save-path correct. The game's logic runs
  natively on Apple Silicon — the hard part is proven.
- **Graphics path is blocked.** The player logs `NullGfxDevice` and crashes in the draw path.
  Root cause found via UnityPy diff of the game vs an empty macOS build's `globalgamemanagers`:
  `GraphicsSettings.m_ShaderDefinesPerShaderCompiler.shaderPlatform` = **4 (D3D11)** in the
  game vs **14 (Metal)** in the Mac build. **Every shader in the build is D3D11-only bytecode;
  there are no Metal variants.**
- `-force-metal` is a real flag and forces the Metal device, but then:
  `Forced GfxDevice 'Metal' ... shaders will not be available` →
  `InitializeEngineGraphics failed`. No Metal shaders exist, not even engine blit shaders.
- **Non-recoverable bit:** the game ships **custom Shader Graphs** (`BonusPass`, `DamageScreen`,
  `AberrationShader`, `ScreenPass` — post-processing) that exist only as D3D bytecode. URP/
  built-in package shaders could be re-obtained from a Mac URP build, but custom graphs cannot
  be rebuilt without the project source.

**Therefore a pure data-swap cannot produce a fully-rendering native port for this game.**
The code is portable; the compiled shaders are platform-locked to D3D.

### The shipping path: Wine + Rosetta 2 + D3DMetal ✅ (this is what works)

Run the **original, unmodified** Windows build under the **Gcenx Game Porting Toolkit** (Wine +
Rosetta 2). Apple's **D3DMetal** translates **D3D11 → Metal at runtime, including the shaders**
(DXBC → Metal), so the shader wall disappears — the whole D3D pipeline is translated live.
One-command launcher: [`tools/run-d3dmetal.sh`](#quick-start--run-your-own-copy).

**Measured result (M2 Max, in the intro/gameplay):**
- Real D3D11 device via D3DMetal (`Renderer: AMD Compatibility Mode` — D3DMetal's identity;
  runs on the Metal backend), **not** `NullGfxDevice`. The 4 custom Shader Graphs render fine —
  D3DMetal translates them live because it sees the compiled DXBC at runtime.
- **~2.5 W total** (CPU 1.77 W + GPU 0.71 W, ANE 0). **120 FPS** (ProMotion-capped), GPU frame
  time **4.06 ms** (≈246 FPS of headroom). Metal HUD reports GPTK 3.0 / D3D11, Draw 53.
- Far below UTM's ~15–30 W full-system emulation, and fans stay off — the original battery goal,
  comfortably met.

> **Tooling notes.** Two other free routes were dead ends: **Whisky** (its Wine runtime hosting
> now 404s) and **DXVK + MoltenVK** (loads, but crashes in `D3D11CoreCreateDevice` — couldn't
> reach Vulkan through GPTK's winevulkan). Apple's raw GPTK dmg download was also broken. The
> working combination is the **Gcenx cask specifically, because it bundles D3DMetal**.

### Hardcore-hobby alternative (fully native, optional)

Native swap + **Metal shader injection**: build a Mac URP project, extract Metal-compiled URP/
built-in shaders, inject them into the game data by GUID, and patch graphics-device selection.
Feasible for the ~56 stock package shaders (**Path 2**, ~95%). The 4 custom Shader Graphs have no
source — but you can still recover them: **capture the Metal that D3DMetal generates from their
DXBC at runtime** and re-wrap it into native Unity Metal shaders (**Path 3-lite**).

**Path 3-lite step 1 is done (2026-07-12):** all four custom post-fx (`BonusPass`, `ScreenPass`,
`DamageScreen`, `AberrationShader`) are harvested as Metal (AIR) and identified. A pure-C
`DYLD_INSERT_LIBRARIES` shim (`tools/harvest/shim.m`, run via `tools/harvest-shaders.sh`) dumps
every metallib D3DMetal builds at runtime; `tools/harvest/identify.sh` maps them to the four by
fragment texture-sample count (20/13/8/5), cross-checked against the DXBC via UnityPy. Full write-up
in [`docs/native-shader-harvest.md`](docs/native-shader-harvest.md). Still a for-sport track — Path 1
already runs the game at ~2.5 W, so going native buys at most a fraction of a watt.

## Open questions / risks

- [x] `globalgamemanagers` portability — resolved: graphics/shader platform is baked in
      (`shaderPlatform 4 = D3D11`); this is the wall, not a tunable. See "Result".
- [x] Custom shaders → Metal variants present? — **No.** Build is D3D11-only; custom Shader
      Graphs are unrecoverable. This blocks the native render path → use Wine+Rosetta+D3DMetal.
- [x] ~~Burst-heavy code paths~~ — characterized: stock Unity 2D-animation/IK/SpriteShape/URP
      jobs, supported managed fallback, regenerable ARM64 lib if needed. Measure on the real
      game to confirm, but expected fine on M2 Max.
- [x] Save location — resolved: `Application.persistentDataPath` (game uses `WorldSaveData`),
      company=`Orsoniks` product=`CasualtiesUnknown` → macOS
      `~/Library/Application Support/Orsoniks/CasualtiesUnknown/`. Migrate a Windows/UTM save
      from `%USERPROFILE%\AppData\LocalLow\Orsoniks\CasualtiesUnknown\`.
- [x] Input — resolved: no `Unity.InputSystem.dll` → **legacy Input Manager**, fully
      cross-platform, no work needed (controllers included).
- [ ] **DRM check on the retail build.** Demo scan is clean: no Steamworks/license/activation/
      tamper/checksum strings and no network endpoints in `Assembly-CSharp.dll` (the only
      `UnityWebRequest` use is `UnityWebRequestMultimedia` for the local `custommusic/` feature).

## Distribution & legal (personal-use port)

Not legal advice. Intent: publish this repo as a **method** to run *your own legally-bought
copy* on Apple Silicon — never to distribute the game.

Guardrails that keep it defensible:
- **Tooling + docs only.** No game assets or binaries (already `.gitignore`d).
- **No Unity runtime redistribution.** The user installs Unity 2022.3.62f3 + Mac Build
  Support and builds the empty player locally — produced under their own Unity license,
  never shipped from this repo.
- **Bring-your-own-copy.** The script points at the user's own installed game files.
- **DRM check on release.** The demo has no Steam DRM/license stub; if the retail build is
  DRM-free too there is no protection measure to circumvent. If it wraps with Steam DRM,
  running outside that wrapper raises anti-circumvention concerns (US DMCA §1201) —
  re-evaluate then.

Favorable footing (EU / Poland): Software Directive 2009/24/EC Art. 5(1) (lawful acquirer may
adapt for intended use) and Art. 6 (RE for interoperability). US interop precedent:
*Sony v. Connectix*, *Sega v. Accolade* (RE a platform to run software on other hardware).

**Best practical move:** ask the developer (Orsoniks) — a solo indie dev often welcomes a
community Apple-Silicon path, or may ship an official Mac build.

## Repository notes

- **The game binaries are not committed** (copyright + ~300 MB). Place the demo locally in
  `CasualtiesUnknownDemo/` — it is `.gitignore`d. The built `.app` is ignored too.
- This is a personal-use port of a legally-owned copy. Do not redistribute game binaries.
- `tools/` holds the idalib RE scripts used for the Burst analysis (run via IDA Pro's
  idalib; they load no game code, only the shipped native plugin).

## Environment

- MacBook Pro **M2 Max**, macOS (Apple Silicon / ARM64).
- Target Unity toolchain: **2022.3.62f3** + Mac Build Support (Mono).
