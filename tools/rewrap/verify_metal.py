#!/usr/bin/env python3
"""verify_metal.py - headless proof that a ported .app's shaders are actually Metal.

The native player only brings up a Metal device if the shaders carry Metal sub-programs;
a shader left as D3D11-only renders pink/black (or, if ALL of them are, you get
NullGfxDevice + "shaders will not be available"). This checks every Shader object in the
app's Data and reports its serialized `platforms` list:

    4  = D3D11  (kD3D11)        <- what the Windows build ships
    14 = Metal  (kMetal)        <- what a working native port must have

Exits non-zero if any shader lacks Metal, so it can gate a build script. This is the one
piece of end-to-end verification that does NOT need a display - a Unity player cannot be
launched behind a locked screen, but this can run at 4am.

Usage:  python3 verify_metal.py <App.app/Contents/Resources/Data>   [--quiet]
"""
import glob
import os
import sys

import UnityPy

D3D11, METAL = 4, 14


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    quiet = "--quiet" in sys.argv
    if len(args) != 1:
        sys.exit(__doc__)
    data = args[0]
    if not os.path.isdir(data):
        sys.exit(f"not a directory: {data}")

    metal, bad, total = [], [], 0
    for path in sorted(glob.glob(os.path.join(data, "*.assets")) +
                       [os.path.join(data, "globalgamemanagers")]):
        if not os.path.isfile(path):
            continue
        try:
            env = UnityPy.load(path)
        except Exception as ex:                                   # noqa: BLE001
            print(f"  ! could not load {os.path.basename(path)}: {ex}")
            continue
        for o in env.objects:
            if getattr(o.type, "name", None) != "Shader":
                continue
            d = o.read_typetree()
            name = d.get("m_ParsedForm", {}).get("m_Name", "?")
            plats = list(d.get("platforms") or [])
            total += 1
            (metal if METAL in plats else bad).append((name, plats, os.path.basename(path)))

    if not quiet:
        for name, plats, f in sorted(bad):
            tag = "D3D11-only" if plats == [D3D11] else f"platforms={plats}"
            print(f"  ✗ {name}  [{tag}]  ({f})")
    print(f"\n{len(metal)}/{total} shaders carry Metal (platform {METAL}); "
          f"{len(bad)} do NOT")
    if bad:
        print("→ those will render pink/black in the native build.")
        return 1
    print("→ every shader in this build is Metal. Native render path is complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
