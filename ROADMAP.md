# Roadmap & Tracker — Casualties: Unknown → Apple Silicon

Living tracker of the three viable paths. Read this **and** `README.md` for full context.

**Current status:** ✅ **Path 1 WORKS** — the unmodified Windows build renders on Apple Silicon
via **Gcenx GPTK's bundled Apple D3DMetal** (D3D11→Metal at runtime). Free stack, no CrossOver,
no Apple download. Real D3D11 device confirmed (not NullGfxDevice); shader wall bypassed.
Paths 2/3 (native) remain the optional deep track for max power efficiency.

**Hard constraint:** the tool must rely on **free resources only** (it is meant to be a
publishable free tool) — so **no CrossOver** (paid/proprietary). Whisky (free, from GitHub)
is the Wine layer; fallback is raw **Apple GPTK** (free, official) if Whisky's runtime is dead.

---

## Where we are (validated facts)

- Unity **2022.3.62f3 LTS**, **Mono**, **x86-64**. Managed CIL + assets are portable.
- **Native code port PROVEN:** the ARM64 Mono player boots and loads `Assembly-CSharp.dll`
  + all assemblies (PhysX/Input/subsystems init, version + save-path correct).
- **Blocker = shaders.** All **60** shaders are **D3D11-only bytecode** (`shaderPlatform 4`),
  incl. **4 custom Shader Graphs** — `BonusPass`, `DamageScreen`, `ScreenPass`,
  `AberrationShader` — whose **source is NOT in the build** (only DXBC + ShaderLab metadata).
  No Metal variants anywhere → native render path fails (`NullGfxDevice`; `-force-metal` →
  "shaders will not be available" → `InitializeEngineGraphics failed`).
- `tools/transplant.sh` works end-to-end (code runs); only the GPU side is blocked natively.
- **Env gotchas (important for any session):**
  - Repo lives in **iCloud-synced `~/Documents`** → the iCloud file provider re-stamps
    `com.apple.FinderInfo`, which **breaks `codesign`**. Build/sign the `.app` **outside**
    iCloud and keep the runnable app in **`~/Applications`** (local). Ad-hoc sign there.
  - Current signed native build (code-only, does not render): `~/Applications/CasualtiesUnknown.app`.
  - idalib venv: `~/Documents/TNC640unix/scratchpad/idalibvenv` (import `idapro`).
  - UnityPy venv (session scratchpad): `…/scratchpad/upyvenv`.

---

## Path 1 — Whisky / Apple GPTK (Wine + Rosetta 2 + D3DMetal)   ← CURRENT

Run the **original, unmodified** Windows build; translate **D3D11 → Metal at runtime,
including shaders**. Sidesteps the shader wall entirely.

- **Rendering:** 100% correct (live translation handles all shaders).
- **Power:** ~3–8 W (Rosetta AOT + real GPU). Beats UTM (~15–30 W). Mild overhead vs native.
- **Purity:** translation stack, not native. Serves as working baseline + render reference.
- **Effort:** ~1 h.

Tasks:
- [x] Install Whisky — brew cask **DISABLED** (unmaintained; disabled 2026-04-09). Installed
      Whisky.app **2.3.5 manually from GitHub releases** → `~/Applications/Whisky.app`
      (notarized, Developer ID: Isaac Marovitz, launches clean, curl download = no quarantine).
- [x] Create bottle `CasualtiesUnknown` (Windows 10) via `WhiskyCmd` CLI.
      Real path: `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/32BC5B6E-…`
- [x] Install WhiskyWine/GPTK runtime — **DEAD END.** Whisky pulls the runtime from
      `https://data.getwhisky.app/Wine/{WhiskyWineVersion.plist,Libraries.tar.gz}` — **both 404**
      (hosting pulled; site homepage still 200). Runtime is unobtainable; Whisky can't create a
      working prefix. **Whisky abandoned as the Wine layer.**

**Pivot — CHOSEN: raw Apple GPTK (D3DMetal)** (free, best perf; Whisky dead).

Setup checklist ([user] = interactive/gated, [me] = scriptable):
- [ ] [user] Install **x86_64 Homebrew** under Rosetta (needs sudo):
      `arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- [ ] [me] `arch -x86_64 /usr/local/bin/brew tap apple/apple https://github.com/apple/homebrew-apple`
- [ ] [me] `arch -x86_64 /usr/local/bin/brew install apple/apple/game-porting-toolkit` (compiles wine, ~30 min)
- [ ] [user] Download **Game Porting Toolkit** dmg from developer.apple.com (free Apple ID), mount it
- [ ] [me] Copy D3DMetal libs from the dmg into the wine prefix
- [ ] [me] Create wineprefix, run `CasualtiesUnknown.exe`, check for a real D3D11 device (not NullGfxDevice)
- [ ] [me] Measure power (`powermetrics`) vs UTM

**Tooling reality check (2026) — the Wine+D3D→Metal layer is a swamp:**
- Whisky: **dead** (runtime hosting 404).
- Apple GPTK dmg: **download broken on Apple's side** (blank page on every browser/device/network,
  agreement accepted) → couldn't obtain Apple's D3DMetal.
- `brew apple/apple/game-porting-toolkit`: bitrotted (needs removed `openssl@1.1`) + long wine
  compile. x86 Homebrew installed at /usr/local; openssl@1.1 extract attempted (moot now).
- Gcenx `game-porting-toolkit` cask: installs cleanly (no Apple, no compile) → but bundles
  **wine-7.7 (GPTK 1.1)**, and **DXMT v0.80 needs wine ≥8** (winemetal.so is ABI-locked). Too old.
- DXMT ships only `builtin` dlls (no wine); real use = cross-build DXMT against your own wine
  (LLVM 15 + wine build). Heavy.

Installed so far: `/Applications/Game Porting Toolkit.app` (Gcenx wine 7.7), DXMT v0.80 dlls in
session scratchpad, x86 Homebrew at /usr/local, Whisky.app (dead) in ~/Applications.

**BREAKTHROUGH (2026-07-12): the Gcenx GPTK cask already BUNDLES Apple's D3DMetal** — free,
no Apple developer download needed. Located at:
`/Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib/external/`
→ `D3DMetal.framework` + `libd3dshared.dylib`. This is the native, best-performing
D3D11/D3D12→Metal translator (strictly better than DXVK+MoltenVK). **So the whole DXVK detour
is unnecessary.** DXVK was tried and it loaded (spoofs fileVersion 10.0.17763.1) but **crashed
in `D3D11CoreCreateDevice`** — it couldn't reach Vulkan through GPTK's winevulkan/MoltenVK.
DXVK is abandoned; D3DMetal is the path.

**The one gotcha (rpath bug in the Gcenx cask):** `wine/lib/wine/x86_64-unix/d3d11.so` links
`@rpath/libd3dshared.dylib` with `RPATH=@loader_path` (the `x86_64-unix/` dir), but the dylib
lives in `wine/lib/external/`. Out of the box the builtin d3d11 → D3DMetal path therefore
crashes at device creation. **Fix:** set
`DYLD_FALLBACK_LIBRARY_PATH=".../wine/lib/external:.../wine/lib:/usr/lib:/usr/local/lib"`
so dlopen finds `libd3dshared.dylib` by leaf name. Force builtin d3d11 with
`WINEDLLOVERRIDES="d3d11=b;d3d10core=b;dxgi=b"`.

Working launch recipe (prefix `~/Games/CasualtiesUnknown`, wine = GPTK `wine/bin/wine64`,
run under `arch -x86_64`):
```
export WINEPREFIX=~/Games/CasualtiesUnknown
export WINEDLLOVERRIDES="d3d11=b;d3d10core=b;dxgi=b"
export DYLD_FALLBACK_LIBRARY_PATH="$GPTK/wine/lib/external:$GPTK/wine/lib:/usr/lib:/usr/local/lib"
export MTL_HUD_ENABLED=1   # optional Metal HUD overlay
arch -x86_64 "$GPTK/wine/bin/wine64" CasualtiesUnknown.exe
```

**Status: ✅ SUCCESS (2026-07-12 04:1x).** Game boots fully under GPTK wine + D3DMetal:
```
GfxDevice: creating device client; threaded=1; jobified=1
Direct3D 11.0 [level 11.1] · Renderer: AMD Compatibility Mode (ID=0x66af) · Vendor: ATI · VRAM 25559 MB
- Loaded All Assemblies, in 0.397 s ; Input initialized ; [PhysX] 4 workers
```
Process healthy at ~36% CPU, no crash. "AMD Compatibility Mode" = D3DMetal's device identity
(runs on the M2 Max Metal backend; VRAM 25559 MB = unified memory). Only warning is a benign
`IDXGIResource::GetSharedHandle` D3DMetal stub — game ignores it. Visual confirmation of pixels
was blocked only because the Mac auto-locked (screenshot showed the login screen, not the game).

**Remaining to close the original goal:**
- [x] [user] Confirmed rendering + playable — intro cinematic + dialogue render perfectly,
      full-screen, audio works. (Screenshot with Metal HUD captured 2026-07-12.)
- [x] **Power measured (D3DMetal, in-game): CPU 1774 mW + GPU 707 mW + ANE 0 = 2481 mW ≈ 2.5 W.**
      Crushes the ~3–8 W estimate and UTM's ~15–30 W (≈6–12× more efficient). Genuinely
      battery/train-friendly.
- [x] **Perf (Metal HUD): 120.00 FPS (ProMotion-capped), GPU frame time 4.06 ms (~246 FPS
      headroom), 1512×982, Metal 556 MB / App 1.11 GB, Draw 53, present mode "Direct".**
      GPTK 3.0, D3D11. The M2 Max is barely working.
- [x] Launcher script `tools/run-d3dmetal.sh` (one-command; sets WINEDLLOVERRIDES + the DYLD
      rpath fix, runs under `arch -x86_64`).

---

## Path 2 — Native + inject Metal for URP/built-in, DISABLE the 4 custom effects

Truly native (ARM64 Mono CPU + native Metal GPU). ~56 of 60 shaders are stock URP/built-in →
obtain their **Metal** variants from a Mac URP build (same package GUIDs), inject by GUID,
set `GraphicsSettings` shaderPlatform → Metal. **Disable** the 4 custom post-fx to avoid
transpiling them.

- **Rendering:** ~95% (missing 4 screen effects).
- **Power/purity:** lowest power, fully native.
- **Effort:** medium (UnityPy asset surgery). **Risk:** medium (GUID match, mixed-shader acceptance).

Tasks:
- [ ] Build a Mac URP donor project (same URP package version as the game)
- [ ] Map game's URP/built-in shaders ↔ donor Metal shaders by GUID
- [ ] Inject Metal shader blobs into game data; flip shaderPlatform to Metal
- [ ] Identify + disable the 4 custom post-fx (Volume profiles / renderer features)
- [ ] Launch; confirm sprites + URP-2D lighting render natively on Metal

**Status: not started**

---

## Path 3 — Native + transpile the 4 custom Shader Graphs (100% rendering)

Path 2 **plus** giving the 4 custom shaders Metal variants. No source exists → work from the
compiled **DXBC**: `DXBC → SPIR-V → MSL` (spirv-cross), then repackage into Unity Metal shader
blobs (offsets/lengths/keyword-variants/passes) and inject by GUID. This is hand-building
offline exactly what D3DMetal does at runtime.

**Path 3-lite (recommended front-end): harvest D3DMetal's runtime output** instead of
hand-transpiling — record the Metal that D3DMetal generates from the game's DXBC while it runs
under GPTK, then re-wrap into Unity Metal shaders by GUID. Removes all "does the transpile
validate on Metal?" risk. **Full plan + results: [`docs/native-shader-harvest.md`](docs/native-shader-harvest.md).**

- **Rendering:** 100%. **Power/purity:** best.
- **Effort:** high. **Risk:** high (per-variant/pass transpile + exact re-serialization).

**Step-1 tasks — ✅ DONE (2026-07-12): frame capture taken + all 4 post-fx pipelines located & harvested.**
- [x] **Xcode Metal frame capture.** `CAPTURE=1 tools/harvest-shaders.sh` runs the game with
      `MTL_CAPTURE_ENABLED=1` and writes `~/Games/d3dm-harvest/frame-NN.gputrace` (1.3 GB, real
      swapchain frames + every pipeline; opens in Xcode). Capture is stable ONLY without swizzling,
      so it's capture-only — the shim just starts/stops an `MTLCaptureManager` GPU-trace via the
      ObjC runtime. (Capture + swizzle together crash the game; each alone is fine.)
- [x] Harvest D3DMetal's runtime Metal output via a **library-dump shim** (`tools/harvest/shim.m`,
      launched by `tools/harvest-shaders.sh`) that swizzles `MTLDevice newLibraryWith*` and dumps
      every AIR metallib D3DMetal builds. 37 dumped in a 45 s stable run. **Key: the shim links no
      frameworks (pure C + libobjc), else it steals wine's preloader low-memory and crashes; it
      reaches Metal lazily once D3DMetal has loaded it. Universal arm64+x86_64; exec wine directly
      (no `arch`, which strips DYLD_*).**
- [x] Locate the 4 post-fx **pipelines** (`tools/harvest/identify.sh`), two agreeing methods:
      (1) fragment **texture-sample count**, preserved 1:1 DXBC→AIR (D3DMetal names every entry
      `main`, so names are useless) — BonusPass=20, ScreenPass=13, DamageScreen=8, AberrationShader=5,
      all distinct → unambiguous; DXBC fingerprints from UnityPy (`globalgamemanagers.assets`, path
      IDs 68–71). (2) a **runtime PSO log** (shim's `HARVEST_HOOK_PSO`, on by default in dump mode)
      that ties each `MTLRenderPipelineState`→its fragment metallib. Result:
      BonusPass=`data-0019`, ScreenPass=`data-0022`, DamageScreen=`data-0021`, Aberration=`data-0024`
      (3 share fullscreen VS `data-0020`; ScreenPass VS `data-0023`). AberrationShader AIR confirmed
      = chromatic aberration. Artifacts + `mapping.json` in `~/Games/d3dm-harvest/identified/`.
- [x] Readable disassembly per shader: `xcrun metal-objdump --disassemble` (Metal Toolchain).

**Step-2 tasks (the hard tail) — ✅ tooling DONE (2026-07-12); full in-game render Path-2-gated.**
All machinery in [`tools/rewrap/`](tools/rewrap/) (`unity_metal_blob.py` + `inject_metal.py`).
- [x] **Binding model learned → decisive finding: the harvested `.metallib` CANNOT be
      binary-injected.** D3DMetal's AIR entry is `main(...)` taking bindless **argument-buffer
      heaps** (`top_level_global_ab`/`res_desc_heap_ab`/`smp_desc_heap_ab`); Unity-native binds
      **positionally** (`[[buffer(n)]]`/`[[texture(n)]]`/`[[sampler(n)]]` + `stage_in`) and, at
      load, compiles **MSL source** via `[MTLDevice newLibraryWithSource:]` (verified in
      `UnityPlayer.dylib`: `sub_10E2460`; a `newLibraryWithData:` binary path exists but is gated
      off for these). **So the re-wrap is MSL source in Unity's ABI**, recovered 1:1 from the
      harvested AIR (the GPU-validated math) + the D3D11 reflection tables (the exact bindings).
- [x] **All 4 fragments + the shared fullscreen VS recovered as Unity-ABI MSL**, each compiling
      clean on the real Metal toolchain (`xcrun metal -c`). Sample counts vs the AIR:
      Aberration 5/5, DamageScreen 7/7, BonusPass 19/19, ScreenPass 12/13 (one blur tap merged —
      minor fidelity gap, noted). MSL is game-derived → **gitignored** (like the AIR/DXBC); only
      the tool ships.
- [x] **Re-serialized into Unity's Metal sub-program container + injected by path ID** (UnityPy):
      per shader, keep the platform-neutral param tables (type 2/3), swap VS/FS DXBC → freshly
      built Metal blobs (`0x0C0A75BA`→`0xF00DCAFE`→`xlatMtlMain`→MSL), flip `platforms [4]→[14]`,
      remap `m_GpuProgramType` 15→23 / 17→24. Injected assets reload with `platforms=['Metal']`,
      entry types `[2,23,3,24,23]`, MSL intact. ✅
- [x] **On-GPU validation** via a standalone Metal harness (`newLibraryWithSource:` + Unity's exact
      binding layout + fullscreen draw): all 4 build a valid VS+FS pipeline and execute with no GPU
      error; `AberrationShader` renders correct chromatic-aberration fringing (channel split ≤215).
- [ ] **Full in-game render — blocked on Path 2.** The native player only inits Metal graphics once
      *every* drawn shader has a Metal variant; the ~56 stock URP/built-in shaders still need theirs
      (Path 2). Until then the harness is the proof. Once Path 2 lands, drop the injected
      `globalgamemanagers.assets` into the transplant build and the 4 post-fx should render natively.

---

## Resuming in a new session

1. Read this file + `README.md` (esp. "Result: the shader wall").
2. Check which Path's tasks are unchecked. Current focus = **Path 1**.
3. Tooling in `tools/` (`transplant.sh`, idalib recon scripts). Demo lives locally in
   `CasualtiesUnknownDemo/` (git-ignored). Never commit game binaries.
