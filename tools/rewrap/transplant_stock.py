#!/usr/bin/env python3
"""
transplant_stock.py - Path 2 (Bucket A): give the game's ~40 STOCK shaders native Metal
variants by transplanting them wholesale from a donor Mac build.

The donor is an empty Unity project built on macOS with EXACTLY the game's engine +
package versions (2022.3.62f3, URP 14.0.12, TMP 3.0.7) and the target shaders forced in
via Always Included Shaders - so Unity itself compiles every keyword variant to Metal.
Because engine + package versions match, the donor's serialized Shader object is the
same shader, same typetree - so unlike the custom Shader Graphs (per-entry MSL surgery
in inject_metal.py), a stock shader can be swapped as a whole:

    m_ParsedForm            <- donor (passes/keywords/param tables, internally consistent)
    platforms               <- donor ([14] Metal)
    offsets/compressedLengths/decompressedLengths/compressedBlob <- donor
    m_Dependencies          <- GAME (PPtrs are file-local; donor file IDs are meaningless here)
    m_NonModifiableTextures <- GAME (same reason)

Matching is by m_ParsedForm.m_Name (built players keep no GUIDs; the name is the
runtime identity Shader.Find/materials use).

Usage:
  python3 transplant_stock.py --donor-data <Donor.app/Contents/Resources/Data> \
                              --game-data  <CU.app/Contents/Resources/Data> [--dry-run]

Writes each modified game .assets file in place (make a copy first / run on CU_metaltest).
Needs UnityPy (same venv as inject_metal.py).
"""
import argparse
import glob
import os
import sys

import UnityPy

# fields taken from the donor; everything else (m_Dependencies, m_NonModifiableTextures,
# m_ShaderIsBaked, m_Name, ...) stays the game's
DONOR_FIELDS = ["m_ParsedForm", "platforms", "offsets", "compressedLengths",
                "decompressedLengths", "compressedBlob", "stageCounts"]

CUSTOM_PREFIX = "Shader Graphs/"  # Bucket B - never touched here


def load_shaders(data_dir):
    """-> {shader name: (env, obj, typetree)} across every .assets/level file."""
    out = {}
    files = sorted(glob.glob(os.path.join(data_dir, "*.assets")) +
                   glob.glob(os.path.join(data_dir, "level*")))
    envs = []
    for f in files:
        try:
            env = UnityPy.load(f)
        except Exception as e:
            print(f"!! {os.path.basename(f)}: {e}", file=sys.stderr)
            continue
        envs.append((f, env))
        for obj in env.objects:
            if getattr(obj.type, "name", None) != "Shader":
                continue
            d = obj.read_typetree()
            name = d.get("m_ParsedForm", {}).get("m_Name", "")
            if name:
                out.setdefault(name, (f, env, obj, d))
    return out, envs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--donor-data", required=True)
    ap.add_argument("--game-data", required=True)
    ap.add_argument("--only", nargs="*", help="restrict to these shader names")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    donor, _ = load_shaders(args.donor_data)
    game, game_envs = load_shaders(args.game_data)
    print(f"donor: {len(donor)} shaders, game: {len(game)} shaders\n")

    touched_files = set()
    done, skipped = [], []
    for name, (f, env, obj, d) in sorted(game.items()):
        if name.startswith(CUSTOM_PREFIX):
            continue
        if args.only and name not in args.only:
            continue
        if list(d.get("platforms", [])) != [4]:
            skipped.append((name, f"platforms={list(d.get('platforms', []))} (already converted?)"))
            continue
        if name not in donor:
            skipped.append((name, "NOT IN DONOR"))
            continue
        dd = donor[name][3]
        dplats = list(dd.get("platforms", []))
        if 14 not in dplats:
            skipped.append((name, f"donor platforms={dplats} (no Metal?)"))
            continue
        for field in DONOR_FIELDS:
            if field in dd:
                d[field] = dd[field]
            elif field in d:
                del d[field]
        gsubs = sum(len(x) if isinstance(x, list) else 1 for x in dd.get("offsets", []))
        print(f"== {name}\n   <- donor {os.path.basename(donor[name][0])} pid={donor[name][2].path_id} "
              f"platforms={dplats} blob={len(dd.get('compressedBlob', []))}B segs={gsubs}")
        if not args.dry_run:
            obj.save_typetree(d)
        touched_files.add((f, env))
        done.append(name)

    for name, why in skipped:
        print(f"-- SKIP {name}: {why}")

    if args.dry_run:
        print(f"\n[dry-run] {len(done)} transplantable, {len(skipped)} skipped - nothing written")
        return
    for f, env in touched_files:
        # materialize before truncating: UnityPy reads untouched objects lazily from the source
        data = env.file.save()
        with open(f, "wb") as fh:
            fh.write(data)
        print(f"wrote {f}")
    print(f"\ntransplanted {len(done)} stock shaders into {len(touched_files)} file(s); "
          f"{len(skipped)} skipped")


if __name__ == "__main__":
    main()
