# tools/rewrap — native Metal re-wrap of the custom Shader Graphs + stock transplant

Three tools now live here:

- **`inject_metal.py`** — the original Path 3-lite re-wrap of the 4 custom post-fx from
  hand-recovered MSL (see below).
- **`transplant_stock.py`** — Path 2 / Bucket A: wholesale swap of the ~40 stock shaders
  (URP/2D/TMP) from a version-matched Mac donor build, by shader name. See `tools/donor/`.
- **`inject_custom_metal.py`** — Path 3 / Bucket B: the **generalized, fully automatic**
  re-wrap of the remaining 16 custom Shader Graphs. No harvest, no hand transcription:
  it translates every keyword variant's DXBC to Unity-ABI MSL with **Unity's own HLSLcc**
  (`tools/hlslcc/build.sh`), which is exactly the translator Unity's editor uses for Metal
  (hence `xlatMtlMain`, `FGlobals_Type`, `Mtl_FragmentIn` — byte-level ABI parity).
  Supporting modules: `entrytools.py` (generic code-entry/keyword/blob (de)serializer),
  `dxbc2msl.py` (synthesizes the RDEF reflection chunk Unity strips from builds — from the
  SHDR `dcl_*` instructions + the shader's own serialized param tables — then drives the
  HLSLcc CLI).

  Key format facts encoded there (all verified against donor/game entry pairs):
  - a code entry is `magic 0x0C0A75BA | type | stats[4] | keywordCount | {len,str,pad4}* |
    payloadLen | payload | trailing`;
  - the trailing vertex-channel table is **platform-dependent** when the VS has attributes:
    each (channel, value) pair's value on Metal = **the channel's ISGN register + 13**
    (verified on 56 stock entry pairs, 0 contradictions);
  - fragment outputs use Unity 2022.3's `rp_output_remap_mask [[function_constant(1)]]`
    preamble (public HLSLcc's `XLT_REMAP_O` macro is post-processed into it), VS position
    gets `[[position, invariant]]`;
  - the MSL is newline-padded so `payloadLen % 4` matches the original D3D payload's,
    keeping the engine's trailing-table read phase identical.

  ```bash
  tools/hlslcc/build.sh   # once: fetch+build Unity HLSLcc + CLI
  python3 inject_custom_metal.py --game-data <CU.app>/Contents/Resources/Data \
      --compile-check     # add --only <Short> / --dry-run to scope
  ```

---

## The original story: hand re-wrap of the 4 post-fx (Path 3-lite, Step 2)

This is the **hard tail** of Path 3-lite: take the Metal that D3DMetal generates for the game's
four custom post-fx (`BonusPass`, `DamageScreen`, `ScreenPass`, `AberrationShader`) and re-wrap it
into **native Unity Metal shader sub-programs**, injected into the game data by path ID so a native
ARM64 Unity player can render them — no D3D11 translation layer.

> **What's committed here vs. not.** Only the *tool* (`*.py`) is committed. The recovered MSL
> (`msl/*.metal`) is **game-derived content** — the exact post-fx logic reconstructed from the
> game's own shaders — so it is `.gitignore`d, exactly like the harvested `.air`/`.metallib`/`.dxbc`.
> You regenerate the MSL locally (see "Recovering the MSL").

## The key finding (why this works the way it does)

D3DMetal's harvested `.metallib` **cannot be injected as a binary blob.** Its entry point is
`main(...)` taking D3DMetal's **bindless argument-buffer heaps** (`top_level_global_ab`,
`res_desc_heap_ab`, `smp_desc_heap_ab`) — a resource model Unity's native Metal backend never
populates. Unity binds resources **positionally** (`[[buffer(n)]]` / `[[texture(n)]]` /
`[[sampler(n)]]` + `stage_in`) and, at load time, compiles **MSL source** via
`[MTLDevice newLibraryWithSource:]` (confirmed in `UnityPlayer.dylib`; a precompiled-metallib path
via `newLibraryWithData:` also exists but is gated behind a flag Unity doesn't set for these).

So the re-wrap is **MSL source, in Unity's ABI** — recovered 1:1 from the harvested AIR
(the GPU-validated math) plus the D3D11 reflection tables (the exact binding layout), then
serialised into the container Unity parses.

## Files

- **`unity_metal_blob.py`** — byte-exact builder/parser for a Unity 2022.3 Metal sub-program blob
  (`0x0C0A75BA` wrapper → `0xF00DCAFE` payload → `xlatMtlMain` name → MSL source). Reverse-engineered
  from stock macOS Unity shaders + the engine loader. `python3 unity_metal_blob.py` self-tests it.
- **`inject_metal.py`** — for each custom shader (path IDs 68–71 in `globalgamemanagers.assets`):
  decompress its D3D11 blob, keep the platform-neutral param tables (type 2/3), replace the VS/FS
  DXBC code entries with freshly-built Metal blobs from the MSL, flip `platforms [4]→[14]` (Metal),
  and remap every `m_GpuProgramType` 15→23 (VS) / 17→24 (FS). Reuses UnityPy.
- **`msl/`** *(gitignored)* — recovered MSL: `Fullscreen.vert.metal` (shared blit VS) +
  `<Shader>.frag.metal` per effect.

## Usage

```bash
# dry-run (reports the plan, writes nothing)
python3 inject_metal.py --assets .../CasualtiesUnknown_Data/globalgamemanagers.assets \
                        --msl ./msl --dry-run

# write a Metal-platform copy of the assets
python3 inject_metal.py --assets .../globalgamemanagers.assets --msl ./msl \
                        --out /tmp/globalgamemanagers.metal.assets
```

Needs a Python env with `UnityPy` + `lz4`.

To make a native transplant actually run on Metal (so the injected shaders load), also patch
`globalgamemanagers` — the Windows-origin build declares itself D3D11-only:

```bash
python3 patch_ggm_metal.py <App>/Contents/Resources/Data/globalgamemanagers
# shaderPlatform 4->14  +  BuildSettings.m_GraphicsAPIs 2->16 (Metal), as surgical binary edits
```

Then re-sign the app (`codesign --force --deep --sign - <App>`).

## Validation status

- **Container round-trip:** the injected assets reload via UnityPy with `platforms=['Metal']`,
  entry types `[2,23,3,24,23]`, and intact MSL. ✅
- **On-GPU (standalone):** `harness.m` (a standalone Metal program, in the session scratchpad)
  compiles each VS+FS via `newLibraryWithSource:` — exactly as Unity does — builds the render
  pipeline with Unity's binding layout, and runs a fullscreen draw. All four execute with no GPU
  error; `AberrationShader` produces the expected chromatic-aberration fringing. ✅
- **In the real native player (the decisive test):** with `patch_ggm_metal.py` applied to make the
  transplant target Metal, `~/Applications/CasualtiesUnknown.app` **boots on a real Metal device
  (M2 Max)** and the engine's own GPU shader loader accepts all four re-wrapped shaders — **0
  "Failed to load GpuProgram" errors, and none of the four appear as "not supported on this GPU"**
  (a control Shader Graph left in D3D11, `WallHole`, still does). The four crossed from unsupported
  to fully loaded natively. ✅
- **Full-frame visual render:** still needs the other ~30 game shaders (sprites/URP/TextMeshPro/
  other Shader Graphs) given Metal variants — that is **Path 2**. The scene can't fully draw until
  they're converted, but the four custom post-fx themselves are validated in-engine.

### The critical serialization detail

A Unity code entry is `wrapper(32B) | 0xF00DCAFE payload | trailing input-binding/channel table`.
The trailing table (10B for a no-attribute fullscreen VS/FS; larger when the VS has vertex
attributes) is **platform-independent** and MUST be carried across the D3D→Metal swap — the engine
reads it after the source, and omitting it yields "Failed to load GpuProgram from binary shader
data" even when the MSL is perfect. `inject_metal.py` preserves each original entry's trailing
bytes. Also: the blob is stored **LZ4-block-compressed** (`compressedLen < decompressedLen`); an
uncompressed blob yields "Failed to find expected binary data".

## Recovering the MSL (regenerate `msl/` locally)

1. Harvest the D3DMetal AIR (`tools/harvest-shaders.sh` → `tools/harvest/identify.sh`) → the four
   `.air`/`.metallib` in `~/Games/d3dm-harvest/identified/`.
2. Disassemble each fragment: `xcrun metal-objdump --disassemble <shader>.metallib`.
3. Pull the D3D11 reflection (CB float offsets, texture/sampler bind indices) for each shader from
   `globalgamemanagers.assets` (path IDs 68–71) with UnityPy.
4. Transcribe the AIR math into Unity-ABI MSL: entry `xlatMtlMain`, `[[buffer(0)]]`=`$Globals`,
   `[[buffer(1)]]`=`UnityPerMaterial` (struct padded to the reflection's float offsets), textures/
   samplers at their reflection indices, the `rp_output_remap_mask` function-constant preamble, and
   `interp0` in `stage_in`. Ignore D3DMetal's arg-buffer/`texture_2d_array` binding machinery — that
   is its bindless emulation, not shader logic. Compile with `xcrun metal -c <file>.metal`.
