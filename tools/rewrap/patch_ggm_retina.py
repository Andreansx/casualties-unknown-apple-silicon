#!/usr/bin/env python3
"""
patch_ggm_retina.py - toggle PlayerSettings.macRetinaSupport in `globalgamemanagers`.

Why: the native Metal build renders at the full Retina drawable (3024x1898 on the 14" M2 Max),
which is 4x the pixels of the Path 1 / D3DMetal reference (1512x982) - the GPU saturates the
120 Hz frame budget (~8.4 ms/frame) and draws ~37 W at an idle menu. The game has NO resolution
logic of its own (no Screen.SetResolution anywhere in Assembly-CSharp), so the engine-level
switch is PlayerSettings.macRetinaSupport: False makes the CAMetalLayer render at 1x
(1512x949), macOS scales it 2x to the panel - the exact presentation regime of the wine run
(crisp integer scaling for the pixel art, GPU mostly idle per frame).

Like patch_ggm_metal.py this is a SURGICAL binary edit - UnityPy's full re-serialization
corrupts `globalgamemanagers`. The byte is located by re-serializing the PlayerSettings object
with UnityPy's typetree writer, verifying byte-identity with the on-disk object, then diffing
against the toggled serialization (guaranteed single-byte change for a bool).

Usage:  python3 patch_ggm_retina.py <Data/globalgamemanagers> [on|off]   (default: off)
"""
import io
import sys

import UnityPy
from UnityPy.helpers import TypeTreeHelper
from UnityPy.streams import EndianBinaryWriter


def serialize(obj, d):
    w = EndianBinaryWriter(endian="<")
    TypeTreeHelper.write_typetree(d, obj._get_typetree_node(), w, obj.assets_file)
    return w.bytes


def patch(path, want_retina):
    raw = bytearray(open(path, "rb").read())
    env = UnityPy.load(path)
    ps = [o for o in env.objects if getattr(o.type, "name", None) == "PlayerSettings"]
    if not ps:
        raise RuntimeError("no PlayerSettings object")
    o = ps[0]
    on_disk = bytes(raw[o.byte_start:o.byte_start + o.byte_size])
    d = o.read_typetree()
    cur = d["macRetinaSupport"]
    if cur == want_retina:
        print(f"macRetinaSupport already {cur} - nothing to do")
        return
    base = serialize(o, d)
    if base != on_disk:
        raise RuntimeError("typetree writer output differs from on-disk object; aborting (layout drift)")
    d["macRetinaSupport"] = want_retina
    mod = serialize(o, d)
    if len(mod) != len(base):
        raise RuntimeError("size changed; expected single-byte bool flip")
    diffs = [i for i, (a, b) in enumerate(zip(base, mod)) if a != b]
    if len(diffs) != 1:
        raise RuntimeError(f"expected exactly 1 differing byte, got {len(diffs)}")
    off = o.byte_start + diffs[0]
    raw[off] = mod[diffs[0]]
    open(path, "wb").write(raw)
    print(f"patched macRetinaSupport@{off}: {cur} -> {want_retina}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    patch(sys.argv[1], len(sys.argv) > 2 and sys.argv[2].lower() == "on")
