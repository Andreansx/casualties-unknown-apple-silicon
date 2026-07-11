# Casualties: Unknown — Apple Silicon Port

Making the Windows-only Unity game **Casualties: Unknown** run on Apple Silicon
(M2 Max) in a way that is **more power-efficient than full-system emulation**, so
it can actually be played on battery (e.g. on a train) without the fans spinning up.

> **Status:** feasibility confirmed — this is a *clean Unity Mono* case.
> No source code is used or needed; the original managed assemblies and assets are
> reused untouched, only the native engine layer is swapped for a native ARM64 one.

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
plain C# inside `Assembly-CSharp.dll`, so when the native Burst library for the current
platform is missing, Unity runs the managed (Mono-JIT) version. Functionally identical,
only slower for those specific jobs — negligible for a 2D game that uses Burst lightly.
Regenerating a native ARM64 Burst library would require the source, so the managed
fallback is the intended path.

## Port plan (native Mono transplant)

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
low-power, playable baseline (~3–8 W) that already beats UTM — useful as a reference while
iterating on the native port.

## Open questions / risks

- [ ] `globalgamemanagers` portability (see above).
- [ ] Custom shaders → Metal variants present?
- [ ] Burst-heavy code paths — measure managed-fallback perf on the actual game.
- [ ] Save location: where `Application.persistentDataPath` lands on macOS
      (`~/Library/Application Support/Orsoniks/CasualtiesUnknown/`) vs the Windows path.
- [ ] Input remapping / controller behavior under the native player.

## Repository notes

- **The game binaries are not committed** (copyright + ~300 MB). Place the demo locally in
  `CasualtiesUnknownDemo/` — it is `.gitignore`d. The built `.app` is ignored too.
- This is a personal-use port of a legally-owned copy. Do not redistribute game binaries.

## Environment

- MacBook Pro **M2 Max**, macOS (Apple Silicon / ARM64).
- Target Unity toolchain: **2022.3.62f3** + Mac Build Support (Mono).
