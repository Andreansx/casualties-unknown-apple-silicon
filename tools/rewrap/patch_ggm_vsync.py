#!/usr/bin/env python3
"""
patch_ggm_vsync.py — force vSyncCount=1 in the low quality levels of `globalgamemanagers`.

WHY (the 37W mystery, solved 2026-07-12): the native macOS player boots at quality level 1
("Low") — NOT the serialized m_CurrentQuality=5 ("Ultra") — and "Very Low"/"Low" ship with
vSyncCount=0. On macOS Metal, vSyncCount=0 makes Unity disable CAMetalLayer.displaySyncEnabled
and free-run the main loop (~900 fps): it renders the ENTIRE frame pipeline offscreen ~7-8x per
presented frame (measured: 97 render encoders/frame instead of 12; GPU 8.8 ms/frame at 120 fps =
~105% duty -> governor pins max clocks -> ~37 W). The same engine logic ran under wine too, but
D3DMetal force-syncs its presents, which hid the bug (0.7 W).

Fix at the DATA level: flip vSyncCount 0->1 in quality levels "Very Low" and "Low". Measured
result: exactly 1 render pipeline per presented frame, GPU 8.8 -> ~3.2 ms/frame at vsynced
120 fps (beats wine's 4.06), display sync on. Visuals unchanged (same quality level as before,
and as the wine reference).

Surgical binary edit like patch_ggm_metal.py — UnityPy full re-serialization corrupts
`globalgamemanagers`. Each vSyncCount is located inside the QualitySettings object by the
16-byte field run [vSyncCount=0][realtimeGICPUUsage=25][lodBias][maximumLODLevel=0], anchored
by the level's unique lodBias float (Very Low 0.3f, Low 0.4f).

Usage:  python3 patch_ggm_vsync.py <path/to/Data/globalgamemanagers>
"""
import struct
import sys


LEVELS = [  # (name, lodBias) — anchors for the two vsync-off levels
    ("Very Low", 0.3),
    ("Low", 0.4),
]


def patch(path):
    b = bytearray(open(path, "rb").read())

    import UnityPy
    env = UnityPy.load(path)   # read-only: locate the QualitySettings object bytes
    qs = [o for o in env.objects if getattr(o.type, "name", None) == "QualitySettings"]
    if not qs:
        raise RuntimeError("no QualitySettings object in globalgamemanagers")
    o = qs[0]
    lo, hi = o.byte_start, o.byte_start + o.byte_size

    changed = []
    for name, lodbias in LEVELS:
        sig = (struct.pack("<i", 0)            # vSyncCount = 0
               + struct.pack("<i", 25)         # realtimeGICPUUsage
               + struct.pack("<f", lodbias)    # lodBias (unique per level)
               + struct.pack("<i", 0))         # maximumLODLevel
        i = bytes(b[lo:hi]).find(sig)
        if i < 0:
            print(f"  {name}: signature not found (already patched?) — skipping")
            continue
        if bytes(b[lo + i + 1:hi]).find(sig) >= 0:
            raise RuntimeError(f"{name}: vSyncCount signature not unique in QualitySettings")
        pos = lo + i
        b[pos:pos + 4] = struct.pack("<i", 1)
        changed.append((f"{name} vSyncCount@{pos}", "0->1"))

    open(path, "wb").write(b)
    return changed


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    for name, how in patch(sys.argv[1]):
        print(f"patched {name}: {how}")
    print("done — low quality levels now vsync (no more offscreen frame spinning on Metal).")
