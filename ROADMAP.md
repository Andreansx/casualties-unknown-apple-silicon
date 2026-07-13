# Roadmap & Tracker - Casualties: Unknown → Apple Silicon

Living tracker of the three viable paths. Read this **and** `README.md` for full context.

**Current status:** ✅ **BOTH paths work.**
- **Path 1** - the unmodified Windows build renders on Apple Silicon via **Gcenx GPTK's bundled
  Apple D3DMetal** (D3D11→Metal at runtime). Free stack, no CrossOver, no Apple download. Real
  D3D11 device (not NullGfxDevice); shader wall *bypassed*. ~2.5 W / 120 fps / 4.06 ms.
- **Paths 2+3** - ✅ **the shader wall was BROKEN, not bypassed.** All **60/60** shaders now have
  Metal variants (40 stock via donor transplant; 16 custom graphs via offline Unity-HLSLcc
  DXBC→MSL; 4 post-fx hand-recovered). The **fully native ARM64 + Metal build is PLAYABLE**
  end-to-end - no Wine, no Rosetta, no D3D. 120 fps @ **3.2 ms** GPU frame (beats Path 1's 4.06),
  GPU ~1.7 W at menu after the vsync fix. Remaining: broad visual QA + a head-to-head whole-package
  power measurement vs Path 1.

**Hard constraint:** the tool must rely on **free resources only** (it is meant to be a
publishable free tool) - so **no CrossOver** (paid/proprietary). Whisky (free, from GitHub)
is the Wine layer; fallback is raw **Apple GPTK** (free, official) if Whisky's runtime is dead.

---

## Where we are (validated facts)

- Unity **2022.3.62f3 LTS**, **Mono**, **x86-64**. Managed CIL + assets are portable.
- **Native code port PROVEN:** the ARM64 Mono player boots and loads `Assembly-CSharp.dll`
  + all assemblies (PhysX/Input/subsystems init, version + save-path correct).
- **The original blocker was shaders - now SOLVED.** As shipped, all **60** shaders are
  **D3D11-only bytecode** (`shaderPlatform 4`), incl. **20 custom Shader Graphs** whose **source
  is NOT in the build** (only DXBC + ShaderLab metadata). Untreated, the native render path fails
  (`NullGfxDevice`; `-force-metal` → "shaders will not be available" → `InitializeEngineGraphics
  failed`). **All 60 have since been converted to Metal offline** (Paths 2+3 below) - the DXBC
  turned out to be sufficient; source was never needed.
- `tools/transplant.sh` works end-to-end. ⚠️ The later runtime fixes (BCL swap, Lang/custommusic
  symlinks, burst-bundle removal - see "Native runtime fixes") are **not yet folded into it**;
  apply by hand on a rebuild.
- **Env gotchas (important for any session):**
  - Repo lives in **iCloud-synced `~/Documents`** → the iCloud file provider re-stamps
    `com.apple.FinderInfo`, which **breaks `codesign`**. Build/sign the `.app` **outside**
    iCloud and keep the runnable app in **`~/Applications`** (local). Ad-hoc sign there.
  - Current signed native build (code-only, does not render): `~/Applications/CasualtiesUnknown.app`.
  - idalib venv: `~/Documents/TNC640unix/scratchpad/idalibvenv` (import `idapro`).
  - UnityPy venv (session scratchpad): `…/scratchpad/upyvenv`.

---

## Path 1 - Whisky / Apple GPTK (Wine + Rosetta 2 + D3DMetal)   ← CURRENT

Run the **original, unmodified** Windows build; translate **D3D11 → Metal at runtime,
including shaders**. Sidesteps the shader wall entirely.

- **Rendering:** 100% correct (live translation handles all shaders).
- **Power:** ~3-8 W (Rosetta AOT + real GPU). Beats UTM (~15-30 W). Mild overhead vs native.
- **Purity:** translation stack, not native. Serves as working baseline + render reference.
- **Effort:** ~1 h.

Tasks:
- [x] Install Whisky - brew cask **DISABLED** (unmaintained; disabled 2026-04-09). Installed
      Whisky.app **2.3.5 manually from GitHub releases** → `~/Applications/Whisky.app`
      (notarized, Developer ID: Isaac Marovitz, launches clean, curl download = no quarantine).
- [x] Create bottle `CasualtiesUnknown` (Windows 10) via `WhiskyCmd` CLI.
      Real path: `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/32BC5B6E-…`
- [x] Install WhiskyWine/GPTK runtime - **DEAD END.** Whisky pulls the runtime from
      `https://data.getwhisky.app/Wine/{WhiskyWineVersion.plist,Libraries.tar.gz}` - **both 404**
      (hosting pulled; site homepage still 200). Runtime is unobtainable; Whisky can't create a
      working prefix. **Whisky abandoned as the Wine layer.**

**Pivot - CHOSEN: raw Apple GPTK (D3DMetal)** (free, best perf; Whisky dead).

Setup checklist ([user] = interactive/gated, [me] = scriptable):
- [ ] [user] Install **x86_64 Homebrew** under Rosetta (needs sudo):
      `arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- [ ] [me] `arch -x86_64 /usr/local/bin/brew tap apple/apple https://github.com/apple/homebrew-apple`
- [ ] [me] `arch -x86_64 /usr/local/bin/brew install apple/apple/game-porting-toolkit` (compiles wine, ~30 min)
- [ ] [user] Download **Game Porting Toolkit** dmg from developer.apple.com (free Apple ID), mount it
- [ ] [me] Copy D3DMetal libs from the dmg into the wine prefix
- [ ] [me] Create wineprefix, run `CasualtiesUnknown.exe`, check for a real D3D11 device (not NullGfxDevice)
- [ ] [me] Measure power (`powermetrics`) vs UTM

**Tooling reality check (2026) - the Wine+D3D→Metal layer is a swamp:**
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

**BREAKTHROUGH (2026-07-12): the Gcenx GPTK cask already BUNDLES Apple's D3DMetal** - free,
no Apple developer download needed. Located at:
`/Applications/Game Porting Toolkit.app/Contents/Resources/wine/lib/external/`
→ `D3DMetal.framework` + `libd3dshared.dylib`. This is the native, best-performing
D3D11/D3D12→Metal translator (strictly better than DXVK+MoltenVK). **So the whole DXVK detour
is unnecessary.** DXVK was tried and it loaded (spoofs fileVersion 10.0.17763.1) but **crashed
in `D3D11CoreCreateDevice`** - it couldn't reach Vulkan through GPTK's winevulkan/MoltenVK.
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
`IDXGIResource::GetSharedHandle` D3DMetal stub - game ignores it. Visual confirmation of pixels
was blocked only because the Mac auto-locked (screenshot showed the login screen, not the game).

**Remaining to close the original goal:**
- [x] [user] Confirmed rendering + playable - intro cinematic + dialogue render perfectly,
      full-screen, audio works. (Screenshot with Metal HUD captured 2026-07-12.)
- [x] **Power measured (D3DMetal, in-game): CPU 1774 mW + GPU 707 mW + ANE 0 = 2481 mW ≈ 2.5 W.**
      Crushes the ~3-8 W estimate and UTM's ~15-30 W (≈6-12× more efficient). Genuinely
      battery/train-friendly.
- [x] **Perf (Metal HUD): 120.00 FPS (ProMotion-capped), GPU frame time 4.06 ms (~246 FPS
      headroom), 1512×982, Metal 556 MB / App 1.11 GB, Draw 53, present mode "Direct".**
      GPTK 3.0, D3D11. The M2 Max is barely working.
- [x] Launcher script `tools/run-d3dmetal.sh` (one-command; sets WINEDLLOVERRIDES + the DYLD
      rpath fix, runs under `arch -x86_64`).

---

## Path 2 - Native + inject Metal for URP/built-in, DISABLE the 4 custom effects

Truly native (ARM64 Mono CPU + native Metal GPU). ~56 of 60 shaders are stock URP/built-in →
obtain their **Metal** variants from a Mac URP build (same package GUIDs), inject by GUID,
set `GraphicsSettings` shaderPlatform → Metal. **Disable** the 4 custom post-fx to avoid
transpiling them.

- **Rendering:** ~95% (missing 4 screen effects).
- **Power/purity:** lowest power, fully native.
- **Effort:** medium (UnityPy asset surgery). **Risk:** medium (GUID match, mixed-shader acceptance).

Tasks:
- [x] Build a Mac URP donor project - `~/UnityProjects/EmptyMac`, 2022.3.62f3 + URP **14.0.12**
      + TMP 3.0.7 (exact match), all 40 stock shaders in Always Included Shaders (all variants
      compile). Automation: [`tools/donor/`](tools/donor/) (`DonorSetup.cs` + README).
- [x] Map game ↔ donor shaders - by **name** (built players keep no GUIDs); all 40 matched.
- [x] Inject Metal shaders - [`tools/rewrap/transplant_stock.py`](tools/rewrap/transplant_stock.py)
      swaps each stock shader **wholesale** (m_ParsedForm + platforms + blob from donor; keeps the
      game's m_Dependencies/m_NonModifiableTextures - PPtrs are file-local). shaderPlatform flip =
      `patch_ggm_metal.py` (as in Path 3-lite).
- [x] ~~Disable the 4 custom post-fx~~ - not needed; they were already re-wrapped (Path 3-lite).
- [x] **✅ RENDERS (2026-07-12): the native ARM64 build draws the game on Metal (M2 Max)** -
      full main-menu frame (sprites, background art, TMP text, UI), 0 GpuProgram errors,
      0 "not supported". 44/60 shaders Metal; the 16 remaining custom Shader Graphs are Bucket B.
- **Bug fixed en route:** in-place `env.file.save()` after `open(out,"wb")` truncates the source
  while UnityPy still lazily reads untouched objects from it → silently corrupts every
  non-rewritten object. Both inject tools now materialize `save()` before opening the output.

**Status: ✅ DONE - the scene renders natively. Remaining for 100%: Bucket B (16 custom graphs).**

---

## Path 3 - Native + transpile the 4 custom Shader Graphs (100% rendering)

Path 2 **plus** giving the 4 custom shaders Metal variants. No source exists → work from the
compiled **DXBC**: `DXBC → SPIR-V → MSL` (spirv-cross), then repackage into Unity Metal shader
blobs (offsets/lengths/keyword-variants/passes) and inject by GUID. This is hand-building
offline exactly what D3DMetal does at runtime.

**Path 3-lite (recommended front-end): harvest D3DMetal's runtime output** instead of
hand-transpiling - record the Metal that D3DMetal generates from the game's DXBC while it runs
under GPTK, then re-wrap into Unity Metal shaders by GUID. Removes all "does the transpile
validate on Metal?" risk. **Full plan + results: [`docs/native-shader-harvest.md`](docs/native-shader-harvest.md).**

- **Rendering:** 100%. **Power/purity:** best.
- **Effort:** high. **Risk:** high (per-variant/pass transpile + exact re-serialization).

**Step-1 tasks - ✅ DONE (2026-07-12): frame capture taken + all 4 post-fx pipelines located & harvested.**
- [x] **Xcode Metal frame capture.** `CAPTURE=1 tools/harvest-shaders.sh` runs the game with
      `MTL_CAPTURE_ENABLED=1` and writes `~/Games/d3dm-harvest/frame-NN.gputrace` (1.3 GB, real
      swapchain frames + every pipeline; opens in Xcode). Capture is stable ONLY without swizzling,
      so it's capture-only - the shim just starts/stops an `MTLCaptureManager` GPU-trace via the
      ObjC runtime. (Capture + swizzle together crash the game; each alone is fine.)
- [x] Harvest D3DMetal's runtime Metal output via a **library-dump shim** (`tools/harvest/shim.m`,
      launched by `tools/harvest-shaders.sh`) that swizzles `MTLDevice newLibraryWith*` and dumps
      every AIR metallib D3DMetal builds. 37 dumped in a 45 s stable run. **Key: the shim links no
      frameworks (pure C + libobjc), else it steals wine's preloader low-memory and crashes; it
      reaches Metal lazily once D3DMetal has loaded it. Universal arm64+x86_64; exec wine directly
      (no `arch`, which strips DYLD_*).**
- [x] Locate the 4 post-fx **pipelines** (`tools/harvest/identify.sh`), two agreeing methods:
      (1) fragment **texture-sample count**, preserved 1:1 DXBC→AIR (D3DMetal names every entry
      `main`, so names are useless) - BonusPass=20, ScreenPass=13, DamageScreen=8, AberrationShader=5,
      all distinct → unambiguous; DXBC fingerprints from UnityPy (`globalgamemanagers.assets`, path
      IDs 68-71). (2) a **runtime PSO log** (shim's `HARVEST_HOOK_PSO`, on by default in dump mode)
      that ties each `MTLRenderPipelineState`→its fragment metallib. Result:
      BonusPass=`data-0019`, ScreenPass=`data-0022`, DamageScreen=`data-0021`, Aberration=`data-0024`
      (3 share fullscreen VS `data-0020`; ScreenPass VS `data-0023`). AberrationShader AIR confirmed
      = chromatic aberration. Artifacts + `mapping.json` in `~/Games/d3dm-harvest/identified/`.
- [x] Readable disassembly per shader: `xcrun metal-objdump --disassemble` (Metal Toolchain).

**Step-2 tasks (the hard tail) - ✅ tooling DONE (2026-07-12); full in-game render Path-2-gated.**
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
      Aberration 5/5, DamageScreen 7/7, BonusPass 19/19, ScreenPass 12/13 (one blur tap merged -
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
- [x] **✅ VALIDATED IN THE REAL NATIVE BUILD (`~/Applications/CasualtiesUnknown.app`) ON METAL.**
      Two more discoveries closed it: (a) a Unity code entry ends with a **trailing input-binding/
      channel table** (10 B for a no-attribute fullscreen VS/FS) that is platform-independent and
      MUST be carried across the D3D→Metal swap - omitting it gives "Failed to load GpuProgram from
      binary shader data" even with perfect MSL; (b) the blob is stored **LZ4-compressed** (raw
      storage → "Failed to find expected binary data"). Both fixed in `inject_metal.py`; the builder
      now reproduces real native entries byte-for-byte. To make the Windows-origin transplant target
      Metal, `tools/rewrap/patch_ggm_metal.py` surgically patches `globalgamemanagers`
      (`shaderPlatform 4→14` + `BuildSettings.m_GraphicsAPIs 2→16`). Result: the native ARM64 player
      **boots on a real Metal device (M2 Max)** and the engine's GPU shader loader accepts all 4
      re-wrapped shaders - **0 GpuProgram-load errors; none of the 4 are "not supported on this GPU"**
      (a control Shader Graph left in D3D11, `WallHole`, still is). The 4 crossed from unsupported to
      loaded natively.
- [x] **Full-frame visual - DONE via Path 2** (donor transplant, see Path 2 section): the native
      build renders the game on Metal.
- [x] **The remaining 16 custom Shader Graphs - DONE (2026-07-12), and better than harvesting:**
      `tools/rewrap/inject_custom_metal.py` translates every keyword variant's DXBC to Unity-ABI
      MSL **offline with Unity's own HLSLcc** (`tools/hlslcc/build.sh` - the same translator the
      editor uses for Metal; its output IS the `xlatMtlMain` ABI). The RDEF reflection chunk that
      Unity strips from builds is synthesized back from the SHDR `dcl_*`s + Unity's serialized
      param tables (`dxbc2msl.py`). All 16 shaders × all variants (~500 programs) re-wrapped and
      compile-checked on the Metal toolchain. Key extra format fact: the trailing vertex-channel
      table is platform-DEPENDENT for attribute VS - on Metal each channel's value = ISGN
      register + 13 (verified on 56 donor/game entry pairs). **All 60/60 game shaders now Metal.**
- [x] **Native GPU-power mystery (~37 W at menu vs wine 0.7 W) - SOLVED (2026-07-12).** Root cause
      found with a new Metal frame profiler ([`tools/powerprof/`](tools/powerprof/) - a
      `DYLD_INSERT_LIBRARIES` shim that logs every render pass / draw / cmdbuf GPU-ms as JSONL; no
      Xcode GUI needed): the player was booting a quality level whose serialized `vSyncCount=0`.
      On macOS Metal that disables `CAMetalLayer.displaySyncEnabled` and free-runs the main loop
      (~900 fps): the ENTIRE frame pipeline rendered offscreen ~8× per presented frame - measured
      **97 render encoders/frame instead of 12**, GPU 8.8 ms/frame ≈ 105% duty → pinned max clocks.
      The same engine logic ran under wine too; **D3DMetal force-syncs presents, which masked it**.
      Fix: [`tools/rewrap/patch_ggm_vsync.py`](tools/rewrap/patch_ggm_vsync.py) - surgical binary
      patch of `globalgamemanagers`, `vSyncCount 0→1` in the two vsync-off quality levels
      ("Very Low", "Low"). Verified: boot-time display-sync ON, **exactly 12 render passes/frame,
      GPU 8.8 → 3.2 ms/frame** at vsynced 120 fps - beats the wine reference (4.06 ms).
      **Measured (sudo powermetrics, game focused, at menu): GPU ~1.7 W steady, 2.1 W peak -
      down from ~37 W (−95%), machine barely warm.**
      (The game also has an in-game console command `framerate <n>` - its only
      `Application.targetFrameRate` call - usable for 60 fps battery capping.)

---

## Native runtime fixes (2026-07-12 late session) - game is PLAYABLE natively

Gameplay QA after the power fix surfaced three Windows-runtime leftovers; all fixed at the
data/bundle level in `~/Applications/CU_metaltest.app` (fold into `transplant.sh` when
rebuilding):

1. **"Instantiating Chunks" infinite hang on Descend** → the transplant shipped the game's
   **Windows-flavor .NET BCL**, whose `System.IO` P/Invokes kernel32 (`SetThreadErrorMode`
   `EntryPointNotFoundException` ×69k - the "benign noise" was never benign). FIX: copy the
   22 BCL assemblies (`mscorlib`, `System*`, `netstandard`, `Mono.Security`) from the donor
   Mac build's `Managed/` over the game's. Same Unity version → same API surface. Game code /
   Unity.* / UnityEngine.* stay the game's. Windows originals: `~/Games/bcl-backup-win/`.
2. **"Failed to load a valid language file"** + placeholder strings everywhere → the game loads
   `Application.dataPath + "/Lang"`; on macOS `dataPath` = `<app>/Contents`, not
   `Contents/Resources/Data`. FIX: symlinks `Contents/Lang` + `Contents/custommusic` →
   `Resources/Data/…`. (Backslash path variants exist in game code - `'\Lang'`,
   `'\custommusic'`, `'\save.sv'` - but bundle-root symlinks break codesign sealing; the
   forward-slash paths are the ones the loader actually hit. Saves self-create their file.)
3. **Donor's `lib_burst_generated.bundle`** (Contents/PlugIns) is hash-mismatched with the
   game's assemblies → removed (backup in bcl-backup-win); Burst falls back to managed.

**✅ SOLVED (2026-07-12 night) - the invisible player Expie.** Entirely the PORT's fault (two
stacked bugs in the v1 custom-shader conversion, `inject_custom_metal.py`); the game data was
always correct (wine rendered fine off the same assets). Fixed by
**`tools/rewrap/inject_custom_metal2.py`** (Limb re-injected; player visible, user-confirmed):

1. **Serialized-vs-MSL constant offsets.** Unity's Metal runtime writes constants at the byte
   offsets recorded in the SERIALIZED tables - `m_CommonParameters` PLUS per-variant
   **parameter blob** entries inside the shader blob (wrapper types 2/3/4, addressed by
   `progX.m_ParameterBlobIndices[tier][i]`; binary parser: `tools/rewrap/paramblob.py`).
   `_RendererColor` for the lit VS lives ONLY in those blobs (`$Globals@2064+` per variant) -
   v1's synthesized RDEF never read them, so it became an anonymous pad slot; HLSLcc also
   repacks `$Globals` (VP 1216→16 etc.) and misaligns sub-float4 scalars in partially-used
   CBs (`UnityPerMaterial._Wetness` 180→176). v2 keeps every serialized table byte-identical
   and RE-LAYS the generated MSL CB structs to the serialized offsets - the exact pattern the
   4 hand-recovered post-fx shaders already proved on-device.
2. **Vertex-attribute numbering - the actual invisibility.** The Metal trailing channel-table
   pair value = **the MSL `[[attribute(n)]]` index + 13**, NOT the D3D ISGN register + 13
   (v1's rule; it held on the 56 donor stock pairs only because stock shaders use every
   input). Limb's VS declares 5 ISGN inputs but uses 3 → HLSLcc compacts the numbering →
   v1's table fed mesh NORMALS into the shader's TEXCOORD slot and TANGENTS into COLOR0 →
   vertex alpha = tangent.w = −1 → `discard_fragment()` everywhere → invisible, clean log.
   Also explains the broken roster Expies. v2 derives the table from the MSL stage_in.

Diagnosis was live-GPU via `tools/powerprof/frameprof.m`, which gained: newLibraryWithSource +
PSO-creation hooks with a library→function→PSO fingerprint registry (identifies UNLABELED
pipelines by source markers), buffer-binding capture incl. the plural
`setVertexBuffers:offsets:withRange:` (Unity's actual CB path), per-draw peeks of live
constant/vertex buffers, vertex-descriptor dumps at PSO creation (the smoking gun), and
MTLParallelRenderCommandEncoder sub-encoder tracking (Unity records the main pass through one;
without hooking `-renderCommandEncoder` its binds/draws are invisible to the shim).

**✅ v2 rolled out to ALL 16 custom Shader Graphs** (same session): 12 in the first batch +
WallHole/RadBackground/HoverShader/RadLine after adding shared-blob-entry handling (multi-pass
shaders reference the same code entry from several passes). The 4 hand-recovered post-fx
(ScreenPass/DamageScreen/BonusPass/AberrationShader) intentionally remain hand-authored - v2
can't express their `float2 _PlayerPos@148` (4-mod-8 offset) as an MSL member, and the hand MSL
already matches the serialized offsets. **User confirmed the port WORKS in gameplay.** Pre-v2
backups of all four `.assets`: `~/Games/assets-backup-v1/`. All of this is REQUIRED READING
before porting the newer 6.0 Steam demo - same machinery, same traps.

## ✅ SOLVED - Right Mouse Button on MacBook trackpads (2026-07-13)

The tutorial gates on right-click ("*(RIGHT CLICK) me and drag me onto yourself*"), which a
MacBook user couldn't perform. **No patching was needed - and the port was never at fault.**
Two independent findings:

1. **RMB does reach the game.** A two-finger *tap* does nothing when macOS "Tap to click" is
   off; a two-finger **physical press** is a real `rightMouseDown` and the game sees it. So
   Unity/Metal input is fine - this was a trackpad-usage issue, not a port bug.
2. **But right-click *drag* is the real blocker**, and it's unfixable ergonomically: you cannot
   hold a two-finger press *and* slide the cursor with the same fingers. The tutorial's item
   interactions are all RMB-**drag**.

**Fix: rebind the action to a held keyboard key.** The game is NOT on the new Input System -
`Managed/` has no `Unity.InputSystem.dll`, only `UnityEngine.InputLegacyModule`. Input goes
through a **data-driven bind table**: `KeyBinds::GetBind(string) -> KeyCode`, fed by
`Application.persistentDataPath + "/keybinds.json"` whose values are KeyCode enum *names*
(`Enum.Parse`). Right-click is the bind **`iteminteract` = `Mouse1`** (`attack` = `Mouse0`);
there is exactly ONE KeyCode per action. `KeyBinds` has **no `SetBind`** and there is no
in-game rebinding UI - `PreRunScript::{OpenBindsFile,ReloadBinds,ResetBinds}` (open the JSON in
an editor, then reload) IS the developer's intended rebinding UX, so editing that file is
supported, not a hack.

Applied: `iteminteract: Mouse1 -> LeftAlt` - hold **Option** (left) to item-interact/drag.
User-confirmed working through the tutorial drag steps. Only the LEFT Option fires, which is
correct: Unity has distinct `LeftAlt`/`RightAlt` KeyCodes and a bind holds one. (`expanddesc` =
`LeftShift` is precedent that modifier keys bind fine.)

Tool: **`tools/rewrap/patch_keybinds.py`** (show / rebind / `--restore`). Gotcha: the bind file
lives under the **donor's** bundle id - `~/Library/Application Support/com.DefaultCompany.2DProject/`
- not `Orsoniks/CasualtiesUnknown`, because the transplant inherits `EmptyMac.app`'s Info.plist.
Binds are cached in a static after the first `GetBind`, so **restart the game** after editing.

Recon note: no decompiler on the box; `GetMouseButton` appears exactly ONCE in Assembly-CSharp
(button 0, `AdaptiveButton`) - everything else is `Input.GetKey*(KeyBinds.GetBind("name"))`.
The IL scanners used to find this are in the session scratchpad pattern: dnfile + a small
call/ldstr walker (resolve MemberRef tokens, print the `ldstr` immediately preceding each
`GetBind`). Reusable for the 6.0 demo port.

## Resuming in a new session

1. Read this file + `README.md` (esp. "Result: the shader wall").
2. Check which Path's tasks are unchecked. Current focus = **Path 1**.
3. Tooling in `tools/` (`transplant.sh`, idalib recon scripts). Demo lives locally in
   `CasualtiesUnknownDemo/` (git-ignored). Never commit game binaries.
