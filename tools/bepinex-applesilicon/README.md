# bepinex-applesilicon

Make **BepInEx 5 + Harmony/MonoMod work on a native arm64 macOS Unity (Mono) game** — no
Rosetta. This is the enabling layer for running the *Casualties: Together* co-op mod on our
native Metal port, but it is **game-agnostic**: nothing here is specific to Casualties, so it
should unlock BepInEx for any arm64 Mono Unity title. (Intended to be extracted to its own repo
once it has a one-command installer — see *Status* below.)

## The problem

On Apple Silicon, Harmony/MonoMod cannot apply a single detour under Mono's `MAP_JIT` W^X memory:

- `mprotect(RW)` on a JIT code page returns **EACCES** — MAP_JIT pages can't be repermissioned.
- `pthread_jit_write_protect_np(0)` disables execution of **all** the calling thread's JIT
  pages — including the managed code doing the patching — so it can't be driven from managed code.

BepInEx's own preloader hits this at its first detour (`HarmonyInteropFix`, `Preloader.Run`
~line 57), so the preloader dies before any plugin loads. The usual workaround is "run under
Rosetta (`arch -x86_64`)", which defeats the whole point of a native port (~47% power win, see
`../../docs/port-7.0.md`). MonoMod fixed this for CoreCLR in v25 (PR #241); **BepInEx 5 ships
MonoMod 22.x, which predates it.**

## The fix

Two pieces:

1. **`native/as_jit.c`** → `libas_jit.dylib` (universal). One native function that does
   `pthread_jit_write_protect_np(0)` → `memcpy` → `(1)` → `sys_icache_invalidate` in a single
   call that never returns to managed code mid-toggle. This is the missing primitive.

2. **`src/` → `AppleSiliconShim.dll`** (netstandard2.0, AnyCPU). `AppleSiliconMonoPlatform`
   wraps MonoMod's `DetourNativeARMPlatform` (its AArch64 trampoline encoding is already correct)
   and routes every code-page write through `as_jit_write`. It is installed by a Doorstop
   **entrypoint shim** (`Doorstop.Entrypoint.Start`) that sets `DetourHelper.Native`, runs a
   self-test, then hands off to BepInEx's real preloader.

Injection is via the Doorstop entrypoint (set `DOORSTOP_TARGET_ASSEMBLY` to the shim), **not** a
BepInEx patcher — patchers `Initialize()` after the first detour has already fired.

Two things that bite and are handled in the shim: don't lock `PlatformHelper.Current` (BepInEx
sets it later and throws if locked; setting `DetourHelper.Native` directly makes the ARM-bit
detection irrelevant anyway), and release `_currentLocked` after the self-test.

## Build

```sh
./build.sh --core /path/to/<Game.app>/Contents/Resources/Data/Managed/../../BepInEx/core
# i.e. any BepInEx 5.4.23.x  BepInEx/core  (for the MonoMod reference assemblies)
```
Produces `dist/libas_jit.dylib` + `dist/AppleSiliconShim.dll`. Neither the MonoMod refs nor the
built artifacts are redistributed — they derive from the user's own BepInEx download.

## Test (reproduce the spike)

```sh
./test/run-harness.sh --app <Game.app-with-BepInEx> --dist ./dist
```
PASS = `silicon_shim.log` shows `SELF-TEST native detour: PASS` **and** `BepInEx/LogOutput.log`
reaches `Chainloader startup complete` with no `preloader_*.log` crash next to the executable,
on a forced-`arch -arm64` run.

## Status

- ✅ **Core mechanism proven** (2026-07-17): BepInEx 5.4.23.5 reaches `Chainloader startup
  complete` on a native arm64 process; self-test detour redirects. Reproducible.
- ⬜ `install.sh` — lay the two artifacts into a ported `.app`'s `BepInEx/core`, rewrite the
  launcher's `DOORSTOP_TARGET_ASSEMBLY`, re-sign. (Currently done by hand / `test/run-harness.sh`.)
- ⬜ Exercise a real plugin's Harmony patches (the mod's 67 patch classes), not just the self-test.
- ⬜ Extract to its own repo once `install.sh` lands.

See `../../docs/multiplayer-port.md` for the full mod-port picture this feeds into.
