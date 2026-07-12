# tools/donor — URP donor build for the 40 stock shaders (Path 2 / Bucket A)

The game's ~40 stock shaders (URP post-fx, 2D lights/shadows, Blit, TextMeshPro, sprites) are
D3D11-only in the Windows build. Instead of transpiling them, we let Unity itself compile the
**exact same shaders** to Metal: an empty Mac project with the game's **exact engine + package
versions** builds them natively, and `tools/rewrap/transplant_stock.py` swaps them into the game
data wholesale, matched by shader name.

**Version match is the whole trick** (same serialized Shader typetree + same keyword/variant
layout): Unity **2022.3.62f3**, `com.unity.render-pipelines.universal` **14.0.12**
(→ core + shadergraph 14.0.12), `com.unity.textmeshpro` **3.0.7**.

## Setup (once)

1. Empty 2022.3.62f3 project (ours: `~/UnityProjects/EmptyMac`). Add to `Packages/manifest.json`:
   `"com.unity.render-pipelines.universal": "14.0.12"` (TMP 3.0.7 + 2D feature already default).
2. Copy `DonorSetup.cs` into `Assets/Editor/`.
3. Import TMP essential resources (must be the CLI flag — `AssetDatabase.ImportPackage` is async
   and dies with `-quit`):
   ```
   Unity -batchmode -quit -projectPath <proj> \
     -importPackage "<proj>/Library/PackageCache/com.unity.textmeshpro@3.0.7/Package Resources/TMP Essential Resources.unitypackage"
   ```
4. `Unity -batchmode -quit -projectPath <proj> -executeMethod DonorSetup.Setup`
   → creates the URP + 2D-renderer pipeline assets, assigns them, and puts all **40** stock
   shaders in **Always Included Shaders** (⇒ every keyword variant compiles, no stripping).
   Must log `always-included: 40 shaders, 0 missing`.

## Build + transplant

```
Unity -batchmode -quit -projectPath <proj> -executeMethod DonorSetup.Build
python3 ../rewrap/transplant_stock.py \
  --donor-data <proj>/Build/Donor.app/Contents/Resources/Data \
  --game-data  <CU.app>/Contents/Resources/Data        # --dry-run first
```

The donor build's `globalgamemanagers.assets` carries all 40 with `platforms=[14]` (Metal) and
variant supersets of the game's (e.g. TMP Distance Field 96 vs 8 sub-programs — always-included
compiles everything, which is exactly what we want: any variant the game asks for at runtime
exists).

**Result (2026-07-12):** with these 40 transplanted + the 4 custom post-fx from
`tools/rewrap/inject_metal.py`, the native ARM64 build renders the game on Metal —
full main-menu frame, 0 GpuProgram errors. Only the 16 remaining custom Shader Graphs
(Bucket B) are still D3D11.
