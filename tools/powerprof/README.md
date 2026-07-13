# powerprof - Metal frame profiler for the native build

Diagnoses GPU power/pacing issues in the **native ARM64** player without the Xcode GUI. A
`DYLD_INSERT_LIBRARIES` shim (`frameprof.m`) swizzles the AGX command-buffer/encoder classes and
`CAMetalLayer` and logs JSONL:

- `agg` every 120 frames: fps, cmdbufs / render / compute / blit encoders, draws, vertices,
  `waitUntilCompleted` count, mean GPU-ms per frame (from per-cmdbuf `GPUStartTime/GPUEndTime`).
- Periodic detail windows: every render-pass attachment (size / pixelformat / MSAA / load / store /
  storage mode), every draw, pipeline binds, per-cmdbuf GPU ms, drawable size + `displaySyncEnabled`.
- `setDisplaySyncEnabled:` calls with backtraces (who toggles vsync).
- A **mono governor** (probe/fix testing): reads runtime `QualitySettings.vSyncCount` /
  `Application.targetFrameRate` / `GetQualityLevel` via `mono_runtime_invoke` on the main queue;
  `FRAMEPROF_TFR=<n>` sets `targetFrameRate`, `FRAMEPROF_QL=<n>` calls `SetQualityLevel` mid-run.

Build: `./build.sh` → `~/Games/frameprof/libframeprof.dylib` (arm64; output outside iCloud dirs).

Run (binary directly - `open` drops DYLD vars; ad-hoc-signed app, no hardened runtime):

```sh
DYLD_INSERT_LIBRARIES=$HOME/Games/frameprof/libframeprof.dylib \
FRAMEPROF_LOG=$HOME/Games/frameprof/run.jsonl \
~/Applications/CU_metaltest.app/Contents/MacOS/EmptyMac
```

Notes: frame boundary = `CAMetalLayer.nextDrawable` (Unity's macOS player presents via a
scheduled handler + `[drawable present]`, NOT `presentDrawable:`). Swizzles use
class_addMethod-first so shared superclass IMPs are never mutated. Env knobs:
`FRAMEPROF_DETAIL_START/_PERIOD/_N` control the detail windows.

## What it found (2026-07-12): the ~37 W menu mystery

The player booted into a quality level with serialized `vSyncCount=0` → Unity disables
`CAMetalLayer.displaySyncEnabled` and free-runs the loop (~900 fps), rendering the whole frame
pipeline offscreen ~8× per presented frame: **97 render encoders/frame instead of 12**,
GPU 8.8 ms/frame ≈ 105% duty → pinned max clocks → ~37 W. Under wine the same logic ran, but
D3DMetal force-syncs presents (0.7 W) - which is why Path 1 never showed it. Fix:
`tools/rewrap/patch_ggm_vsync.py` (vSyncCount 0→1 in "Very Low"/"Low"). After: 12 passes/frame,
3.2 ms GPU/frame, vsynced 120 fps.
