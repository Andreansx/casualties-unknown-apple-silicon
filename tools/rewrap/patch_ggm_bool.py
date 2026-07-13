#!/usr/bin/env python3
"""patch_ggm_bool.py - flip ANY PlayerSettings bool in `globalgamemanagers`, surgically.

Generalises the trick patch_ggm_retina.py / patch_ggm_metal.py already use: UnityPy's full
re-serialization CORRUPTS globalgamemanagers, so instead we

  1. re-serialize the PlayerSettings object from its typetree and assert byte-identity with
     what is on disk (proves the writer round-trips this exact layout - if it doesn't, the
     layout drifted and we abort rather than write garbage),
  2. flip the field, re-serialize, and assert exactly ONE byte changed (it's a bool),
  3. poke that single byte into the file.

Usage:  python3 patch_ggm_bool.py <Data/globalgamemanagers> <field> <on|off>
        python3 patch_ggm_bool.py <Data/globalgamemanagers> --list

Known-useful fields:
  runInBackground     keep simulating/rendering when the app is not frontmost.
                      ⚠️ TRUE is what makes the game HANG after a screen lock on macOS: the
                      player keeps driving the Metal loop while the display is asleep and the
                      CAMetalLayer has no acquirable drawable, so it wedges and never recovers
                      (the Metal HUD freezes on "Composited", presentation OFF, and the process
                      has to be killed). FALSE makes Unity park the player loop on resign-active
                      and resume cleanly on unlock.
  visibleInBackground overlay/window visibility while another app is frontmost.
  macRetinaSupport    see patch_ggm_retina.py (kept separate; it has the perf rationale).
"""
import sys

import UnityPy
from UnityPy.helpers import TypeTreeHelper
from UnityPy.streams import EndianBinaryWriter


def serialize(obj, d):
    w = EndianBinaryWriter(endian="<")
    TypeTreeHelper.write_typetree(d, obj._get_typetree_node(), w, obj.assets_file)
    return w.bytes


def _player_settings(path):
    env = UnityPy.load(path)
    ps = [o for o in env.objects if getattr(o.type, "name", None) == "PlayerSettings"]
    if not ps:
        raise RuntimeError("no PlayerSettings object in " + path)
    return ps[0]


def list_bools(path):
    d = _player_settings(path).read_typetree()
    for k, v in sorted(d.items()):
        if isinstance(v, bool):
            print(f"   {k:<32} = {v}")


def patch(path, field, want):
    raw = bytearray(open(path, "rb").read())
    o = _player_settings(path)
    d = o.read_typetree()
    if field not in d:
        raise RuntimeError(f"no such PlayerSettings field: {field}  (try --list)")
    cur = d[field]
    if not isinstance(cur, bool):
        raise RuntimeError(f"{field} is {type(cur).__name__}, not a bool")
    if cur == want:
        print(f"{field} already {cur} - nothing to do")
        return

    on_disk = bytes(raw[o.byte_start:o.byte_start + o.byte_size])
    base = serialize(o, d)
    if base != on_disk:
        raise RuntimeError("typetree writer output differs from on-disk object; "
                           "aborting (layout drift)")
    d[field] = want
    mod = serialize(o, d)
    if len(mod) != len(base):
        raise RuntimeError("size changed; expected single-byte bool flip")
    diffs = [i for i, (a, b) in enumerate(zip(base, mod)) if a != b]
    if len(diffs) != 1:
        raise RuntimeError(f"expected exactly 1 differing byte, got {len(diffs)}")
    off = o.byte_start + diffs[0]
    raw[off] = mod[diffs[0]]
    open(path, "wb").write(raw)
    print(f"patched {field}@{off}: {cur} -> {want}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    if sys.argv[2] == "--list":
        list_bools(sys.argv[1])
    else:
        patch(sys.argv[1], sys.argv[2], sys.argv[3].lower() in ("on", "true", "1"))
