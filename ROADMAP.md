# Roadmap & Tracker — Casualties: Unknown → Apple Silicon

Living tracker of the three viable paths. Read this **and** `README.md` for full context.

**Current decision:** pursue **Path 1 (Whisky)** now — as the working game + a rendering
reference + a power baseline. Paths 2/3 (native) are the deep track to attempt afterward.

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

**Next best open option (untried): DXVK + MoltenVK + Gcenx `wine@staging`** — DXVK dlls are PE
(version-tolerant, dll-override based, NOT ABI-locked like DXMT's winemetal.so), MoltenVK is
mature. Most robust free path; hasn't been attempted yet.

**Status: BLOCKED on the translation layer — checkpoint; next attempt = DXVK+MoltenVK**

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
