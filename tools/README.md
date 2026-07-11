# RE tooling (idalib)

Headless IDA Pro scripts used to characterize the shipped native Burst plugin
(`CasualtiesUnknown_Data/Plugins/x86_64/lib_burst_generated.dll`). They load only that
one Unity-generated native plugin — no game code, no assets.

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
