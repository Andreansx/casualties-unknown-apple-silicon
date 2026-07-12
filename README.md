# Casualties: Unknown — Apple Silicon Port

Making the Windows-only Unity game **Casualties: Unknown** run on Apple Silicon
(M2 Max) in a way that is **more power-efficient than full-system emulation**, so
it can actually be played on battery (e.g. on a train) without the fans spinning up.

> **Status:** the native **code** port works — a native ARM64 Mono player runs the game's
> CIL + assets (validated: assemblies load, engine boots). But it hits a hard **shader wall**:
> the Windows build's shaders are **D3D11-only bytecode** (incl. non-recoverable custom Shader
> Graphs), so nothing renders natively on Metal. **Conclusion for this game: ship it via
> Wine + Rosetta 2 + D3DMetal (Whisky / Apple GPTK)**, which translates D3D→Metal at runtime
> (shaders included) and still beats UTM on power. See "Result: the shader wall" below.

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
| **Wine + Rosetta 2** (Whisky / Apple GPTK) | Only the game's x86-64 code; OS native, DirectX→Metal, real GPU. Rosetta AOT-caches translations + uses Apple-Silicon TSO | ~3–8 W | quick win |
| **Native Mono player swap** | Nothing — native ARM64 engine runs the original CIL + assets | ~2–5 W | the prize |

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

### The shipping path: Wine + Rosetta 2 + D3DMetal

Run the **original, unmodified** Windows build under **Whisky** or **Apple Game Porting
Toolkit**. D3DMetal (or DXVK + MoltenVK) translates **D3D11 → Metal at runtime, including the
shaders** (DXBC → Metal), so the shader wall disappears — the whole D3D pipeline is translated
live. Still ~3–8 W (Rosetta AOT + real GPU), still far below UTM's full-system emulation.

### Hardcore-hobby alternative (partial)

Native swap + **Metal shader injection**: build a Mac URP project, extract Metal-compiled URP/
built-in shaders, inject them into the game data by GUID, and patch graphics-device selection.
Feasible for package shaders; the custom Shader Graphs stay broken (pink) with no source.
Multi-day RE for an imperfect result — a fun challenge, not a clean port.

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
