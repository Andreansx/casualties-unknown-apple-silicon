# Roadmap & Tracker — Casualties: Unknown → Apple Silicon

Living tracker of the three viable paths. Read this **and** `README.md` for full context.

**Current decision:** pursue **Path 1 (Whisky)** now — as the working game + a rendering
reference + a power baseline. Paths 2/3 (native) are the deep track to attempt afterward.

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
- [ ] Install Whisky (`brew install --cask whisky`) + its GPTK runtime (or note if unmaintained → CrossOver/GPTK)
- [ ] Create a bottle; run the demo's `CasualtiesUnknown.exe`
- [ ] Confirm it renders + is playable
- [ ] Measure power with `powermetrics` and compare vs UTM

**Status: IN PROGRESS**

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

- **Rendering:** 100%. **Power/purity:** best.
- **Effort:** high. **Risk:** high (per-variant/pass transpile + exact re-serialization).

Tasks:
- [ ] Decompress each custom shader's DXBC variants from `compressedBlob`
- [ ] `DXBC → SPIR-V → MSL` per variant/pass
- [ ] Repackage as a Unity Metal shader; inject by GUID; set platform tag
- [ ] Validate each of the 4 renders correctly

**Status: not started**

---

## Resuming in a new session

1. Read this file + `README.md` (esp. "Result: the shader wall").
2. Check which Path's tasks are unchecked. Current focus = **Path 1**.
3. Tooling in `tools/` (`transplant.sh`, idalib recon scripts). Demo lives locally in
   `CasualtiesUnknownDemo/` (git-ignored). Never commit game binaries.
