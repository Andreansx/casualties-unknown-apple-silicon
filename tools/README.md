# tools/

The native port builds in one command with **[`port.sh`](port.sh)** (`--win <WindowsGameDir>
--out <CU.app>`): it runs `transplant.sh`, the runtime fixes, the shader passes
([`rewrap/`](rewrap/): `transplant_stock.py` for the 40 stock shaders, `inject_custom_metal2.py`
for the 25 custom graphs, the `patch_ggm_*.py` passes, `verify_metal.py`), ad-hoc signs, and
verifies headlessly. Power comparisons use **[`powermeasure.sh`](powermeasure.sh)**; the launchers
are `run-native.sh` (native `.app`) and `run-d3dmetal.sh` (Path 1). The rest of this file covers the
one-off RE tooling.

**Online co-op (native arm64):** [`bepinex-applesilicon/`](bepinex-applesilicon/) makes BepInEx 5
+ Harmony work on a native arm64 Mono game (the hard blocker for running the *Casualties: Together*
co-op mod without Rosetta) — **solved**, see its README. **[`mp-install.sh`](mp-install.sh)**
(`--app <CU.app> --mod <KrokMP download>`) then installs the mod itself in one command: macOS
BepInEx + the arm64 fix into the bundle, the mod's AnyCPU plugins, `libopus.dylib`, the mic
Info.plist key, the game-hash symlink, a launcher, re-sign (`--uninstall` reverses it).
**[`mp-playtest.sh`](mp-playtest.sh)** then lets you actually play it alone: it starts a second
player headless (a real character, no window) and launches your game already connected, so co-op
is testable on one Mac. **Direct-IP co-op verified working** between two native instances. Full picture + roadmap:
[`../docs/multiplayer-port.md`](../docs/multiplayer-port.md).

---

# RE tooling (idalib)

Headless IDA Pro scripts used to characterize the shipped native Burst plugin
(`CasualtiesUnknown_Data/Plugins/x86_64/lib_burst_generated.dll`). They load only that
one Unity-generated native plugin - no game code, no assets.

Requires IDA Pro 9.x with the idalib Python package activated (see
`<IDA>/idalib/python/py-activate-idalib.py`). Run with the idalib-enabled interpreter:

```sh
# characterize all functions: sizes, SIMD (AVX2/SSE), loops, call targets
python3 burst_recon.py /path/to/lib_burst_generated.dll

# Hex-Rays decompile specific functions + math-op keyword scan
python3 decomp_top.py /path/to/lib_burst_generated.dll 0x18000E340 0x18002AA90
```

## What we found

- ~32 Burst job entry points, each compiled AVX2 **and** SSE2, **no ARM64/NEON** variant.
- 389 functions / ~235 KB; two heavy `IJobParallelForTransform` bodies (sqrt/div-heavy).
- Jobs originate from stock Unity packages (2D Animation / IK / SpriteShape / URP 2D),
  **not** `Assembly-CSharp.dll` → supported managed fallback on Apple Silicon.

See the root `README.md` → "idalib RE of `lib_burst_generated.dll`" for the full writeup.

## `transplant.sh` - build the native Apple Silicon `.app`

Grafts the Windows build's cross-platform data (managed CIL + assets) onto a stock macOS
ARM64 Unity player you build yourself, drops the x86-only native plugins (Burst → managed
fallback), keeps the Mac's Metal built-in shaders, and ad-hoc signs the bundle (required to
launch on Apple Silicon). No game binary is patched.

```sh
# 1) In Unity Hub: install 2022.3.62f3 + Mac Build Support (Mono), build an EMPTY
#    project for macOS / Apple Silicon  -> EmptyMac.app
# 2) Graft the game onto it:
./transplant.sh --win /path/to/CasualtiesUnknownDemo \
                --mac-app /path/to/EmptyMac.app \
                --out ~/Desktop/CasualtiesUnknown.app

# iterate on the two empirical unknowns if needed:
#   --mac-ggm       keep Mac globalgamemanagers (platform/graphics mismatch on start)
#   --win-builtin   use Windows built-in resources (only if Mac ones misbehave)
#   --dry-run       print the plan, change nothing
```

Refuses to run on IL2CPP builds and on a Unity-version mismatch. Validated end-to-end on the
demo data (all transplant invariants pass); the only pieces needing a real device are the
Mac player itself and code signing.
