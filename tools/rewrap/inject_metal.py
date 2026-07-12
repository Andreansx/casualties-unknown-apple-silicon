#!/usr/bin/env python3
"""
inject_metal.py — re-wrap harvested/recovered Metal (MSL) into the 4 custom Shader Graphs
and inject them into the game's Unity data by path ID, flipping the shader platform to Metal.

Path 3-lite STEP 2 "hard tail". For each of BonusPass / DamageScreen / ScreenPass /
AberrationShader (path IDs 68..71 in globalgamemanagers.assets):

  * decompress the shader's existing D3D11 sub-program blob and parse its 5 entries
      [0] type2  $Globals param table         (platform-neutral — reused verbatim)
      [1] type15 vertex DXBC (DrawProcedural)  -> replaced with Metal VS (type23)
      [2] type3  UnityPerMaterial param table  (platform-neutral — reused verbatim)
      [3] type17 fragment DXBC                 -> replaced with Metal FS (type24)
      [4] type15 vertex DXBC (Blit)            -> replaced with Metal VS (type23)
  * rebuild the blob (stored uncompressed: compressedLen == decompressedLen), set
      platforms=[14 Metal], and remap every sub-program m_GpuProgramType 15->23 / 17->24.
  * write the modified assets file.

MSL sources come from tools/rewrap/msl/<Shader>.frag.metal (fragment) and Fullscreen.vert.metal
(shared vertex). The recovered MSL is committed; the harvested .metallib/.air binaries are not.

Usage:
  python3 inject_metal.py --assets <globalgamemanagers.assets> --msl <dir> --out <assets>
  python3 inject_metal.py --assets ... --msl ... --dry-run     # report only, write nothing
"""
import argparse
import struct
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from unity_metal_blob import build_metal_program, parse_metal_program, D3D_TO_METAL, METAL_VS, METAL_FS

import UnityPy
import lz4.block

# path ID -> (shader short name, fragment MSL filename)
SHADERS = {
    68: "BonusPass",
    69: "DamageScreen",
    70: "ScreenPass",
    71: "AberrationShader",
}
VERT_MSL = "Fullscreen.vert.metal"

# code entries that must be replaced, and their Metal target type
CODE_TYPE = {15: METAL_VS, 17: METAL_FS}


def decompress_blob(d, plat_index):
    blob = bytes(d["compressedBlob"])
    offs, clens, dlens = d["offsets"][plat_index], d["compressedLengths"][plat_index], d["decompressedLengths"][plat_index]
    if isinstance(offs, int):
        offs, clens, dlens = [offs], [clens], [dlens]
    out = b""
    for o, c, dl in zip(offs, clens, dlens):
        seg = blob[o:o + c]
        out += seg if c == dl else lz4.block.decompress(seg, uncompressed_size=dl)
    return out


def parse_entries(blob):
    n = struct.unpack_from("<I", blob, 0)[0]
    entries = []
    for i in range(n):
        o, l, s = struct.unpack_from("<III", blob, 4 + 12 * i)
        entries.append({"type": struct.unpack_from("<i", blob, o + 4)[0], "seg": s, "raw": blob[o:o + l]})
    return entries


def serialize_blob(entries):
    """Rebuild an (uncompressed) SerializedSubProgramBlob from raw entry payloads."""
    n = len(entries)
    table_size = 4 + 12 * n
    payloads = b""
    table = struct.pack("<I", n)
    off = table_size
    for e in entries:
        raw = e["raw"]
        table += struct.pack("<III", off, len(raw), e["seg"])
        payloads += raw
        off += len(raw)
    return table + payloads


def remap_program_types(node, counts):
    """Recursively bump every m_GpuProgramType 15->23 / 17->24 in the parsed form."""
    if isinstance(node, dict):
        if "m_GpuProgramType" in node:
            t = node["m_GpuProgramType"]
            if t in D3D_TO_METAL:
                node["m_GpuProgramType"] = D3D_TO_METAL[t]
                counts[t] = counts.get(t, 0) + 1
        for v in node.values():
            remap_program_types(v, counts)
    elif isinstance(node, list):
        for v in node:
            remap_program_types(v, counts)


def rewrap_shader(d, frag_msl, vert_msl, name):
    plats = list(d["platforms"])
    if plats != [4]:
        raise RuntimeError(f"{name}: expected platforms==[4] (D3D11), got {plats}")
    blob = decompress_blob(d, 0)
    entries = parse_entries(blob)
    types = [e["type"] for e in entries]

    new_entries = []
    report = []
    for i, e in enumerate(entries):
        t = e["type"]
        if t == 15:
            e = {"type": METAL_VS, "seg": e["seg"], "raw": build_metal_program(vert_msl, METAL_VS)}
            report.append(f"entry[{i}] VS DXBC(15) -> Metal VS(23) {len(e['raw'])}B")
        elif t == 17:
            e = {"type": METAL_FS, "seg": e["seg"], "raw": build_metal_program(frag_msl, METAL_FS)}
            report.append(f"entry[{i}] FS DXBC(17) -> Metal FS(24) {len(e['raw'])}B")
        else:
            report.append(f"entry[{i}] type{t} param table reused verbatim {len(e['raw'])}B")
        new_entries.append(e)

    new_blob = serialize_blob(new_entries)
    # round-trip check every code entry
    parsed = parse_entries(new_blob)
    for i, e in enumerate(parsed):
        if e["type"] in (METAL_VS, METAL_FS):
            pm = parse_metal_program(e["raw"])
            assert pm["entry_name"] == "xlatMtlMain", pm
            assert pm["source"] in (frag_msl, vert_msl), f"entry[{i}] source mismatch"

    d["platforms"] = [14]
    d["offsets"] = [[0]]
    d["compressedLengths"] = [[len(new_blob)]]
    d["decompressedLengths"] = [[len(new_blob)]]
    d["compressedBlob"] = list(new_blob)

    counts = {}
    remap_program_types(d["m_ParsedForm"], counts)
    report.append(f"platforms [4]->[14]; remapped GpuProgramType {counts}; blob {len(blob)}->{len(new_blob)}B (uncompressed)")
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--assets", required=True, help="globalgamemanagers.assets containing the shaders")
    ap.add_argument("--msl", required=True, help="dir with <Shader>.frag.metal + Fullscreen.vert.metal")
    ap.add_argument("--out", help="output assets path (default: overwrite --assets)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    vert_msl = open(os.path.join(args.msl, VERT_MSL)).read()
    env = UnityPy.load(args.assets)
    by_pathid = {o.path_id: o for o in env.objects if getattr(o.type, "name", None) == "Shader"}

    done = 0
    for pid, name in SHADERS.items():
        obj = by_pathid.get(pid)
        if obj is None:
            print(f"!! pathID {pid} ({name}) not found in assets", file=sys.stderr)
            continue
        d = obj.read_typetree()
        got = d.get("m_ParsedForm", {}).get("m_Name", "?")
        frag_path = os.path.join(args.msl, f"{name}.frag.metal")
        if not os.path.exists(frag_path):
            print(f"-- {name} (pathID {pid}, {got!r}): SKIP, no MSL at {frag_path}")
            continue
        frag_msl = open(frag_path).read()
        print(f"== {name} (pathID {pid}, {got!r})")
        for line in rewrap_shader(d, frag_msl, vert_msl, name):
            print(f"   {line}")
        if not args.dry_run:
            obj.save_typetree(d)
        done += 1

    if args.dry_run:
        print("\n[dry-run] no file written")
        return
    out = args.out or args.assets
    with open(out, "wb") as f:
        f.write(env.file.save())
    print(f"\nwrote {done} re-wrapped shader(s) -> {out}")


if __name__ == "__main__":
    main()
