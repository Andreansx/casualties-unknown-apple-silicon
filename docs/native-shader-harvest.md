# Path 3-lite - harvesting D3DMetal's generated Metal shaders

> Goal: reach a **100% native** render (ROADMAP Path 3) for the 4 custom Shader Graphs
> (`BonusPass`, `DamageScreen`, `ScreenPass`, `AberrationShader`) **without** hand-transpiling
> their DXBC - by capturing the Metal shaders that **D3DMetal already generates at runtime**
> while the game runs under GPTK (the working Path 1 setup).

## ✅ Step 1 DONE (2026-07-12): frame capture taken + all 4 post-fx pipelines located & harvested

Both halves of step 1 are done:

**(a) An Xcode Metal frame capture exists.** `tools/harvest-shaders.sh CAPTURE=1` runs the game
with `MTL_CAPTURE_ENABLED=1` and writes a real `~/Games/d3dm-harvest/frame-NN.gputrace` (a 1.3 GB
bundle with the `CAMetalLayer` swapchain frames, heaps, buffers, and every `MTLRenderPipelineState`)
- openable in Xcode's GPU debugger. This is *capture-only* (the shim does NOT swizzle in this
mode), which is the one capture configuration that's stable with the game.

**(b) The 4 full-screen post-fx pipelines are located** - as concrete `MTLRenderPipelineState`s
and recovered as Metal (AIR), each disassemblable to readable shader IR:

| Custom Shader Graph | fragment samples (DXBC=AIR) | fragment metallib | vertex metallib (pipeline) |
|---|---|---|---|
| **BonusPass**        | 20 | `data-0019.metallib` | `data-0020` (shared fullscreen VS) |
| **ScreenPass**       | 13 (8 texture inputs) | `data-0022.metallib` | `data-0023` |
| **DamageScreen**     | 8  | `data-0021.metallib` | `data-0020` |
| **AberrationShader** | 5  | `data-0024.metallib` | `data-0020` |

Two independent methods agree: (1) the fragment **texture-sample count**, which D3DMetal preserves
1:1 DXBC→AIR (from the game's DXBC via UnityPy), and (2) the **runtime pipeline log** - the shim
correlates each `MTLRenderPipelineState` to its fragment shader's metallib. Three of the four share
the same fullscreen-passthrough vertex shader (`data-0020`), confirming they are full-screen post
passes. Named copies + `metal-objdump` disassembly (`.air`) + `mapping.json` land in
`~/Games/d3dm-harvest/identified/`. AberrationShader's AIR was eyeball-confirmed as chromatic
aberration (offset UV samples, per-channel recombine, offset const 0.1).

**Reproduce:**
- Shaders + pipeline map: `tools/harvest-shaders.sh` (run a few seconds, quit) → `tools/harvest/identify.sh`.
- Frame capture: `CAPTURE=1 tools/harvest-shaders.sh` (auto-captures ~12 s in, or `touch
  ~/Games/d3dm-harvest/trigger`), then open the `.gputrace` in Xcode.

### What actually worked (and the dead ends)

- **The shim must link NO frameworks.** `DYLD_INSERT_LIBRARIES` loads it during wine's
  *preloader* stage; a shim that links Metal/Foundation forces those to map early and steals
  the low address space wine reserves for the Windows image → the game crashes before it
  renders (`preloader: failed to reserve range 0x10000-0x110000`, then an execute-fault at a
  fixed Windows address), **even with zero swizzling**. The fix: a pure-C shim
  (`tools/harvest/shim.m`) linking only `libobjc` + `libSystem`. It stays inert until a poll
  sees Metal already loaded (`dlopen(Metal, RTLD_NOLOAD)`), then reaches Metal lazily via the
  ObjC runtime and swizzles `MTLDevice newLibraryWith{Data,File,URL,Source}`. Stable: 45 s
  in-game, no crash, 37 metallibs dumped.
- **Build the shim universal (arm64 + x86_64)** and `export DYLD_INSERT_LIBRARIES` inside the
  launcher, then `exec` wine directly. A single-arch (x86_64) shim makes dyld strip the insert
  var in the arm64 launch shell before wine starts; launching via `arch -x86_64` also strips
  all `DYLD_*` (it's SIP-protected). wine64 is x86_64-only, so exec'ing it directly runs it
  under Rosetta and the insert survives.
- **Frame capture is stable ONLY when the shim does not swizzle.** `MTL_CAPTURE_ENABLED=1`
  wraps every device in a `CaptureMTLDevice`; that wrapper together with the library-swizzle
  hooks crashes the game (each alone is fine). So the two modes are split: DUMP mode swizzles
  `newLibraryWith*` (+ optional PSO correlation) and takes no gputrace; CAPTURE mode
  (`CAPTURE=1`) does the reverse - it only starts/stops an `MTLCaptureManager` GPU-trace on the
  D3DMetal device (via the ObjC runtime, no swizzling) and writes a `.gputrace`. Both are stable.
  The dumped metallib *is* the translated shader (more directly than reading it out of a trace),
  so DUMP mode is the primary artifact; the gputrace is the Xcode-viewable companion.
- **Identification is by structure, not name:** D3DMetal names every entry point `main`, so we
  match on the fragment **texture-sample count**, which it preserves 1:1 when translating
  DXBC→AIR. The four counts (20/13/8/5) are distinct → an unambiguous map. The DXBC
  fingerprints come from the Unity build via UnityPy (`globalgamemanagers.assets`, path IDs
  68-71). D3DMetal's own internal library (`file-*.metallib`: `vertPassthrough`,
  `fragColorClear…`) is excluded by its function names.

## ✅ Step 2 DONE (2026-07-12): re-wrap tooling built + shaders recovered + on-GPU validated

The "hard tail" is built. Everything lives in [`tools/rewrap/`](../tools/rewrap/).

**The decisive finding - the harvest's binary output can't be dropped in as-is.** D3DMetal's
harvested `.metallib` has entry `main(...)` taking its **bindless argument-buffer heaps**
(`top_level_global_ab` / `res_desc_heap_ab` / `smp_desc_heap_ab`). Unity's native Metal backend
binds resources **positionally** (`[[buffer(n)]]` / `[[texture(n)]]` / `[[sampler(n)]]` +
`stage_in`) and never populates those heaps - so a binary re-wrap is impossible. Unity instead
compiles **MSL source** at load via `[MTLDevice newLibraryWithSource:]` (found in `UnityPlayer.dylib`
`sub_10E2460`; there is a `newLibraryWithData:` binary path too but it's gated off for these
shaders). So the harvest's real value isn't "skip the transpile" - it's that the AIR gives the
**exact, GPU-validated math**, which we transcribe into **Unity-ABI MSL**, pairing it with the
**D3D11 reflection tables** (the exact CB float-offsets / texture+sampler bind indices) for bindings.

**What got built:**
- `unity_metal_blob.py` - byte-exact builder/parser for Unity's Metal sub-program container
  (`0x0C0A75BA` wrapper → `0xF00DCAFE` payload → `xlatMtlMain` → MSL), RE'd from stock macOS Unity
  shaders + the loader.
- `inject_metal.py` - per shader (path IDs 68-71): keep the platform-neutral param tables
  (type 2/3), swap the VS/FS DXBC code for freshly built Metal blobs, flip `platforms [4]→[14]`,
  remap `m_GpuProgramType` 15→23 / 17→24. Injected assets reload as `platforms=['Metal']`,
  entry types `[2,23,3,24,23]`, MSL intact.
- Recovered MSL (all 4 fragments + shared fullscreen VS), each compiling on `xcrun metal -c`.
  Sample counts match the AIR (Aberration 5, Damage 7, Bonus 19; ScreenPass 12 of 13 - one blur
  tap merged). **The MSL is game-derived → gitignored** like the AIR/DXBC; only the tool ships.

**Validation:** a standalone Metal harness compiles each VS+FS with `newLibraryWithSource:` (as
Unity does), builds the pipeline with Unity's binding layout, and runs a fullscreen draw - all 4
execute with no GPU error and `AberrationShader` shows correct chromatic aberration. **Full in-game
render is gated on Path 2** (the native player won't init Metal graphics until the other ~56 stock
shaders also have Metal variants). Drop the injected `globalgamemanagers.assets` into the transplant
once Path 2 lands.

---

## Original plan (kept for context)

## The idea

The custom Shader Graphs are "non-recoverable" only from a *static / offline* point of view:
the build ships them as **D3D11 DXBC bytecode**, and the Shader Graph source is not in the build.
But D3DMetal, running the game under GPTK, **translates that DXBC to Metal Shading Language (MSL)
in memory every frame**. So the shader logic we thought was lost is being reconstructed live -
we just have to record it.

This is an alternative *front-end* to the classic Path 3 pipeline:

```
Classic Path 3:   DXBC ── vkd3d-shader ──▶ SPIR-V ── SPIRV-Cross ──▶ MSL ─┐
Harvest (this):   DXBC ── D3DMetal (runtime) ─────────────────────▶ MSL ─┤─▶ re-wrap into
                                                                          │   Unity Metal shader
                                                                          │   (by GUID) ──▶ native
```

Both converge on the same hard tail (re-serialize MSL into Unity's Metal shader container). The
harvest front-end has one big advantage: the MSL it yields **is already known to compile and run
correctly on this exact GPU** - it removes all "does the transpile even validate on Metal?" risk,
because you're copying the output of a translator Apple ships.

## How to capture (concrete)

Run the game via `tools/run-d3dmetal.sh` and capture the Metal work with one of:

1. **Xcode Metal frame capture (primary).**
   - Launch with Metal capture enabled: set `MTL_CAPTURE_ENABLED=1` in the launch env (add it to
     the script or export before running). Optionally `MTL_HUD_ENABLED=1` to confirm frames.
   - Attach Xcode → *Debug ▸ Capture GPU Frame* on the running Wine process (or use a programmatic
     `MTLCaptureManager` scope if attaching to a Wine child proc is awkward - a tiny `DYLD_INSERT_
     LIBRARIES` shim around `MTLCreateSystemDefaultDevice` can start/stop a capture to a `.gputrace`).
   - In the captured frame you get every `MTLRenderPipelineState` used, each with its **vertex +
     fragment MSL** (Xcode shows/reconstructs the source) and its pipeline/binding descriptors.

2. **`.gputrace` on disk.** `MTLCaptureManager` with `MTLCaptureDestinationGPUTraceDocument`
   writes a `.gputrace` bundle you can open later in Xcode and export the MSL from - good for a
   headless-ish capture without a live Xcode attach.

3. **RenderDoc is NOT useful here.** It captures D3D11/GL/Vulkan, not Metal, and the D3D side only
   gives back DXBC - which we already have. The whole point is to get the **Metal** side.

## Isolating the 4 custom shaders

A captured frame has dozens of pipelines (URP 2D, sprites, UI, blits). Identify the 4 by:

- **Trigger one effect at a time.** `DamageScreen` fires on taking damage; `BonusPass` on the
  relevant pickup/buff; `ScreenPass` / `AberrationShader` are typically always-on full-screen
  post. Capture a frame with only one active to narrow it down.
- **Shape of the pass.** These are full-screen post-processing passes: a fullscreen triangle/quad,
  sampling the camera color target, writing back - distinct from per-sprite draws.
- **Cross-check names/keywords.** UnityPy already gives each custom shader's pass/keyword layout
  from the D3D side; match the pass count + texture bindings to the captured pipeline.

## Re-wrapping into a native Unity Metal shader (the hard tail)

Same final step as classic Path 3:

1. Take the harvested MSL (per pass, per needed keyword variant).
2. **Adapt the binding model.** D3DMetal binds resources with its own buffer/texture index layout;
   Unity's native Metal backend expects Unity's convention. The MSL *math* transfers directly, but
   argument-buffer / texture / sampler indices and the constant-buffer packing likely need
   remapping to what Unity-native emits for the same ShaderLab pass. Diff a stock shader that
   exists in **both** a Mac URP build (native Metal) and under D3DMetal to learn the mapping.
3. Serialize into Unity's Metal `Shader` sub-program format (offsets, `m_SubPrograms`, keyword
   variants, passes) via **UnityPy**, tag platform = Metal (14), inject by **GUID** into the game
   data (this reuses the Path 2 injection machinery).
4. Validate each of the 4 effects renders correctly on the native ARM64 transplant build.

## Honest risk assessment

- **Front-end risk: low.** Getting correct MSL for the 4 graphs is nearly free once capture works.
- **Tail risk: unchanged from Path 3.** The binding-remap + exact Unity re-serialization is still
  the fiddly part; harvest doesn't remove it, it only removes the "is my transpiled shader valid
  Metal?" uncertainty and hands you cleaner, GPU-validated MSL to start from.
- **Payoff vs Path 1: small.** Path 1 already runs the game at ~2.5 W / 120 FPS. Going fully
  native might save a fraction of a watt. This is a purity/for-sport track, not a necessity.

## Prereqs to have ready next session

- Working Path 1 launch (`tools/run-d3dmetal.sh`) - the capture source.
- The native transplant build (`~/Applications/CasualtiesUnknown.app`, from `tools/transplant.sh`)
  - the injection target.
- A Mac URP donor project (same URP package version) - to learn the binding mapping + to source
  the ~56 stock shaders for Path 2.
- UnityPy env (`…/scratchpad/upyvenv`).
