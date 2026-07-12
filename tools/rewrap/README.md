# tools/rewrap — native Metal re-wrap of the 4 custom Shader Graphs (Path 3-lite, Step 2)

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

## Validation status

- **Container round-trip:** the injected assets reload via UnityPy with `platforms=['Metal']`,
  entry types `[2,23,3,24,23]`, and intact MSL. ✅
- **On-GPU:** `harness.m` (a standalone Metal program, in the session scratchpad) compiles each
  VS+FS via `newLibraryWithSource:` — exactly as Unity does — builds the render pipeline with
  Unity's binding layout, and runs a fullscreen draw. All four execute with no GPU error;
  `AberrationShader` produces the expected chromatic-aberration fringing. ✅
- **Full in-game render:** **gated on Path 2.** The native player only initialises Metal graphics
  once *every* shader it draws has a Metal variant; the other ~56 stock URP/built-in shaders still
  need their Metal variants (Path 2) before the game will boot far enough to show these four. Until
  then, on-GPU harness validation is the proof.

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
