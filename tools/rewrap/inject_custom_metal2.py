#!/usr/bin/env python3
"""inject_custom_metal2.py - v2 of the custom-shader Metal conversion. Fixes the
constant-binding bug that made every HLSLcc-converted shader receive garbage/zero
constants at runtime (invisible player Expie, roster Expies, etc.).

Root cause (2026-07-12): Unity's Metal runtime writes shader constants at the byte
offsets recorded in the SERIALIZED param tables - m_CommonParameters PLUS the
per-variant parameter-blob entries referenced by m_ParameterBlobIndices (wrapper types
2/3/4 inside the same shader blob; that is where _RendererColor and the _ShapeLight*
uniforms live). v1 had two fatal gaps:
  1. its synthesized RDEF only used m_CommonParameters, so blob-only params became
     anonymous `pad_$Globals_N[k]` slots the engine never writes (=> INTERP1 alpha 0
     => discard => invisible);
  2. HLSLcc (REMOVE_UNUSED_GLOBALS) repacks $Globals - and float4-granular padding
     also shifts sub-float4 scalars in partially-used CBs like UnityPerMaterial
     (_Wetness 180 -> 176) - so even table-listed constants landed at wrong offsets.

v2 strategy = the one the 4 hand-recovered shaders (ScreenPass, AberrationShader, ...)
already proved on-device: leave EVERY serialized table byte-identical to the Windows
build (whose correctness wine demonstrates) and re-lay the generated MSL constant-
buffer structs so each named member sits at its SERIALIZED byte offset:
  * RDEF is synthesized from the UNION of m_CommonParameters and the variant's
    parameter blob, so every engine-written constant becomes a NAMED member;
  * after translation, each `constant X& [[buffer(n)]]` struct body is rebuilt:
    members sorted by serialized offset, gaps filled with float/float4 padding;
    accessed-but-unnamed pad slots (engine never writes them; they read as zeros
    exactly like on D3D11) are packed into leftover gaps;
  * texture/sampler register numbering is identity through HLSLcc (asserted);
  * code entries re-wrapped exactly like v1 (trailing vertex-channel table from ISGN
    reg+13, payload length mod-4 preserved, program types 15/16->23, 17/18->24).

Usage:
  python3 inject_custom_metal2.py \
      --src-data  <WindowsBuild>/CasualtiesUnknown_Data \
      --dst-data  <CU.app>/Contents/Resources/Data \
      [--only Limb ...] [--dry-run] [--compile-check]
"""
import argparse
import glob
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from entrytools import parse_code_entry, build_code_entry, parse_blob, serialize_blob
from dxbc2msl import dxbc_to_msl
from inject_metal import decompress_blob
from inject_custom_metal import (CUSTOM_PREFIX, D3D_TO_METAL_ALL, FS_TYPES, HLSLCC_FLAGS,
                                 SEM_CHAN, build_metal_payload, build_names, compile_check,
                                 postprocess_fs, postprocess_vs, remap_program_types)
from paramblob import parse_params_entry

import UnityPy
import lz4.block

SVC_SCALAR, SVC_VECTOR, SVC_MATRIX_COLUMNS = 0, 1, 3
UNITY_TYPE_TO_SVT = {0: 3, 1: 2, 2: 1}
MTX_PREFIX = "hlslcc_mtx4x4"

TYPE_INFO = {  # MSL constant-address-space size/alignment
    "float": (4, 4), "int": (4, 4), "uint": (4, 4), "bool": (4, 4),
    "float2": (8, 8), "int2": (8, 8), "uint2": (8, 8),
    "float3": (16, 16), "int3": (16, 16), "uint3": (16, 16),
    "float4": (16, 16), "int4": (16, 16), "uint4": (16, 16),
    # packed_* - same bytes, alignment 4. The escape hatch for D3D-packed vectors
    # whose serialized offset MSL cannot align a normal vector to (see PACKED).
    "packed_float2": (8, 4), "packed_int2": (8, 4), "packed_uint2": (8, 4),
    "packed_float3": (12, 4), "packed_int3": (12, 4), "packed_uint3": (12, 4),
    "packed_float4": (16, 4), "packed_int4": (16, 4), "packed_uint4": (16, 4),
}

# D3D packs a vector at ANY 4-byte offset that doesn't straddle a 16-byte row, so a float2
# legitimately lands at e.g. @20 or @148 (4 mod 8) - and MSL simply cannot align a `float2`
# member there. `packed_float2` has alignment 4 with identical size and byte layout, so it
# expresses the offset exactly; reads are then converted back with `float2(cb.member)`.
# This is what kept ScreenPass/DamageScreen hand-authored until 7.0 - now they're automatic.
PACKED = {
    "float2": "packed_float2", "int2": "packed_int2", "uint2": "packed_uint2",
    "float3": "packed_float3", "int3": "packed_int3", "uint3": "packed_uint3",
    "float4": "packed_float4", "int4": "packed_int4", "uint4": "packed_uint4",
}


# ── serialized-side helpers ──────────────────────────────────────────────────

def name_table(pass_d):
    return {i: n for n, i in pass_d.get("m_NameIndices", [])}


def flat_subs(prog):
    """[(sub_dict, tier, idx_in_tier)] mirroring m_ParameterBlobIndices addressing."""
    if prog.get("m_SubPrograms"):
        raise RuntimeError("non-empty m_SubPrograms not supported (expected player tiers)")
    out = []
    for t, tier in enumerate(prog.get("m_PlayerSubPrograms", []) or []):
        items = tier if isinstance(tier, list) else [tier]
        for i, sp in enumerate(items):
            out.append((sp, t, i))
    return out


def enrich_names(pass_d, prog_d, pentry):
    """v1 build_names (common) + the variant's parameter blob -> full RDEF names.
    Also returns serialized byte offsets per CB name for the re-layout step."""
    idx2name = name_table(pass_d)
    names = build_names(pass_d, prog_d)
    byname = {}
    for b in prog_d.get("m_CommonParameters", {}).get("m_ConstantBufferBindings", []):
        cbdef = names["cbs"].get(b["m_Index"])
        if cbdef:
            byname[idx2name.get(b["m_NameIndex"])] = cbdef
    for cb in pentry["cbs"]:
        cbdef = byname.get(cb["name"])
        if cbdef is None:
            continue   # CB not bound by this program; irrelevant
        have = {m[0] for m in cbdef["members"]}
        for v in cb["vec"]:
            if v["name"] not in have:
                cbdef["members"].append((v["name"], v["offset"],
                                         SVC_SCALAR if v["dim"] == 1 else SVC_VECTOR,
                                         UNITY_TYPE_TO_SVT.get(v["type"], 3),
                                         1, v["dim"], v["arraySize"]))
        for v in cb["mat"]:
            if v["name"] not in have:
                cbdef["members"].append((v["name"], v["offset"], SVC_MATRIX_COLUMNS,
                                         UNITY_TYPE_TO_SVT.get(v["type"], 3),
                                         v["rows"] or 4, 4, v["arraySize"]))
        cbdef["size"] = max(cbdef["size"], cb["size"])
    for t in pentry["textures"]:
        names["textures"].setdefault(t["index"], t["name"])
        if t["sampler"] not in (None, 0xFFFFFFFF):
            names["samplers"].setdefault(t["sampler"], "sampler" + t["name"])
    # serialized offsets per CB *binding slot*: {slot: ({member: offset}, cb_size)}
    offsets = {}
    for slot, cbdef in names["cbs"].items():
        offsets[slot] = ({m[0]: m[1] for m in cbdef["members"]}, cbdef["size"])
    return names, offsets


# ── MSL struct re-layout ─────────────────────────────────────────────────────

PACKED_HITS = set()   # {"<shader>:<cb>.<member>@<type>"} - reported by main()

STRUCT_RE = re.compile(r"(struct\s+([\w$]+)\s*\{)(.*?)(\};)", re.S)
MEMBER_RE = re.compile(r"([\w$]+)\s+([\w$]+)\s*(?:\[(\d+)\])?\s*;")
BUF_RE = re.compile(r"constant\s+([\w$]+)\s*&\s*([\w$]+)\s*\[\[\s*buffer\((\d+)\)\s*\]\]")


def _msl_member_size(ty, arr):
    size, align = TYPE_INFO[ty]
    return (16 * arr if arr else size), align


def _emit_pads(lines, cur, target, tag, n):
    """Fill [cur, target) with pad declarations; returns new pad counter."""
    while cur < target:
        if cur % 16 == 0 and target - cur >= 16:
            k = (target - cur) // 16
            lines.append(f"    float4 pad_{tag}_{n}[{k}];" if k > 1 else
                         f"    float4 pad_{tag}_{n};")
            cur += 16 * k
        elif cur % 8 == 0 and target - cur >= 8:
            lines.append(f"    float2 pad_{tag}_{n};")
            cur += 8
        else:
            lines.append(f"    float pad_{tag}_{n};")
            cur += 4
        n += 1
    return n


def relayout_cb_structs(msl, offsets_by_slot, tag_for_log):
    """Rebuild every buffer-bound struct so each named member sits at its serialized
    byte offset. Unnamed-but-accessed pad members are packed into leftover gaps."""
    structs = {m.group(2): m for m in STRUCT_RE.finditer(msl)}
    for bm in BUF_RE.finditer(msl):
        sname, inst, slot = bm.group(1), bm.group(2), int(bm.group(3))
        if slot not in offsets_by_slot:
            raise RuntimeError(f"{tag_for_log}: buffer({slot}) {inst} has no serialized CB")
        serial, cbsize = offsets_by_slot[slot]
        sm = structs[sname]
        placed, pads = [], []
        orig_off = 0
        for m in MEMBER_RE.finditer(sm.group(3)):
            ty, nm, arr = m.group(1), m.group(2), int(m.group(3)) if m.group(3) else 0
            if ty not in TYPE_INFO:
                raise RuntimeError(f"{tag_for_log}: MSL type {ty} unsupported")
            size, align = _msl_member_size(ty, arr)
            orig_off = (orig_off + align - 1) & ~(align - 1)
            key = nm[len(MTX_PREFIX):] if nm.startswith(MTX_PREFIX) else nm
            if key in serial:
                placed.append((serial[key], ty, nm, arr))
            elif re.search(re.escape(inst) + r"\s*\.\s*" + re.escape(nm) + r"\b", msl):
                # accessed but not in the serialized tables. In engine-layout CBs
                # (UnityPerDraw) these are real engine-written slots -> keep the
                # original offset; in the repacked $Globals they are engine-unwritten
                # (true on D3D11 too, they read zeros) -> any collision-free spot.
                pads.append((orig_off, ty, nm, arr))
            orig_off += size
        placed.sort()
        spans = []
        repacked = []           # (member, aligned type) -> reads need float2(...) back-conversion
        for i, (off, ty, nm, arr) in enumerate(placed):
            size, align = _msl_member_size(ty, arr)
            if off % align:
                pty = None if arr else PACKED.get(ty)
                if pty is None or off % 4:
                    raise RuntimeError(f"{tag_for_log}: {nm}@{off} violates align {align}")
                size, align = TYPE_INFO[pty]        # same bytes, align 4 -> offset expressible
                repacked.append((nm, ty))
                ty = pty
                placed[i] = (off, ty, nm, arr)      # emit body reads `placed`
            spans.append((off, off + size, ty, nm, arr))
        for a, b in zip(spans, spans[1:]):
            if a[1] > b[0]:
                raise RuntimeError(f"{tag_for_log}: {a[3]} [{a[0]},{a[1]}) overlaps "
                                   f"{b[3]}@{b[0]}")
        cbsize = max(cbsize, max((s[1] for s in spans), default=0))
        gaps = []
        cur = 0
        for s in spans:
            if s[0] > cur:
                gaps.append((cur, s[0]))
            cur = max(cur, s[1])
        if cur < cbsize:
            gaps.append((cur, cbsize))

        def take(gi, o, size):
            g0, g1 = gaps[gi]
            gaps[gi] = (o + size, g1)
            if o > g0:
                gaps.insert(gi, (g0, o))

        for want, ty, nm, arr in pads:
            size, align = _msl_member_size(ty, arr)
            spot = None
            for gi, (g0, g1) in enumerate(gaps):     # original position if still free
                if g0 <= want and want + size <= g1:
                    spot = want
                    take(gi, want, size)
                    break
            if spot is None:
                for gi, (g0, g1) in enumerate(gaps):
                    o = (g0 + align - 1) & ~(align - 1)
                    if o + size <= g1:
                        spot = o
                        take(gi, o, size)
                        break
            if spot is None:
                raise RuntimeError(f"{tag_for_log}: no room for accessed pad {nm} "
                                   f"({size}B) within CB size {cbsize}")
            placed.append((spot, ty, nm, arr))
        placed.sort()
        # emit body
        lines = []
        cur = 0
        n = 0
        for off, ty, nm, arr in placed:
            n = _emit_pads(lines, cur, off, "fill", n) if off > cur else n
            lines.append(f"    {ty} {nm}[{arr}];" if arr else f"    {ty} {nm};")
            cur = off + _msl_member_size(ty, arr)[0]
        body = "\n" + "\n".join(lines) + "\n"
        msl = msl.replace(sm.group(0), sm.group(1) + body + sm.group(4), 1)
        # packed_* members are storage-only: convert reads back to the aligned vector type so
        # every downstream use (swizzles, arithmetic) stays exactly what HLSLcc generated.
        # `inst.` anchors the match, so the struct declaration itself is never rewritten.
        for nm, aty in repacked:
            msl = re.sub(r"\b" + re.escape(inst) + r"\s*\.\s*" + re.escape(nm) + r"\b",
                         f"{aty}({inst}.{nm})", msl)
            PACKED_HITS.add(f"{tag_for_log}:{inst}.{nm}@{aty}")
    return msl


def msl_texture_indices(msl):
    return {m.group(1): int(m.group(2)) for m in
            re.finditer(r">\s*([\w$]+)\s*\[\[\s*texture\s*\((\d+)\)\s*\]\]", msl)}


def rewrite_vs_trailing_msl(trailing, msl, tag):
    """Rebuild the vertex-channel table from the GENERATED MSL's [[attribute(n)]]
    declarations: (channel, attr+13) per stage_in member. v1 used the D3D ISGN
    register instead - wrong whenever the D3D signature carries UNUSED inputs
    (Limb: 5 in ISGN, 3 in MSL, compacted numbering), which cross-wired the mesh
    channels (normals->uv, tangents->color => alpha<=0 => invisible sprite)."""
    attrs = re.findall(r"[\w$]+\s+([A-Z][A-Z_]*?)(\d*)\s*\[\[\s*attribute\((\d+)\)\s*\]\]", msl)
    if not attrs:
        return trailing            # VS without stage_in (procedural) - keep as-is
    pad = 0
    while pad < len(trailing) and (len(trailing) - pad) % 4:
        pad += 1
    if len(trailing) - pad < 8:
        return trailing
    mask = struct.unpack_from("<I", trailing, pad)[0]
    pairs = []
    for sem, semidx, attr in sorted(attrs, key=lambda a: int(a[2])):
        chan = SEM_CHAN.get((sem, int(semidx or 0)))
        if chan is None:
            if sem.startswith("SV_"):
                continue
            raise RuntimeError(f"{tag}: VS input {sem}{semidx}: no Unity channel mapping")
        pairs.append((chan, int(attr) + 13))
        mask |= 1 << chan
    body = struct.pack("<II", mask, len(pairs))
    for chan, val in pairs:
        body += struct.pack("<II", chan, val)
    return trailing[:pad] + body


# ── per-shader conversion ────────────────────────────────────────────────────

def rewrap_shader_v2(d, name, do_compile):
    if list(d.get("platforms", [])) != [4]:
        raise RuntimeError(f"{name}: platforms={list(d.get('platforms', []))}, expected [4]")
    blob = decompress_blob(d, 0)
    entries = parse_blob(blob)
    pf = d["m_ParsedForm"]
    n_vs = n_fs = 0
    converted = set()      # multi-pass shaders share blob entries across passes
    for ss in pf.get("m_SubShaders", []):
        for ps in ss.get("m_Passes", []):
            for key in ("progVertex", "progFragment"):
                prog = ps.get(key)
                if not prog:
                    continue
                pbi = prog.get("m_ParameterBlobIndices", [])
                for sp, t, i in flat_subs(prog):
                    bi = sp["m_BlobIndex"]
                    if bi in converted:
                        continue
                    converted.add(bi)
                    e = entries[bi]
                    if e["type"] not in D3D_TO_METAL_ALL:
                        raise RuntimeError(f"{name}: entry[{bi}] type {e['type']}")
                    pentry = parse_params_entry(entries[pbi[t][i]]["raw"])
                    pe = parse_code_entry(e["raw"])
                    names, offsets = enrich_names(ps, prog, pentry)
                    msl, _ = dxbc_to_msl(pe["payload"], names, flags=HLSLCC_FLAGS)
                    if e["type"] in FS_TYPES:
                        msl = postprocess_fs(msl)
                        trailing = pe["trailing"]
                        n_fs += 1
                    else:
                        msl = postprocess_vs(msl)
                        trailing = rewrite_vs_trailing_msl(pe["trailing"], msl,
                                                           f"{name} e[{bi}]")
                        n_vs += 1
                    msl = relayout_cb_structs(msl, offsets, f"{name} e[{bi}]")
                    for tn, ti in msl_texture_indices(msl).items():
                        reg = {v: k for k, v in names["textures"].items()}.get(tn)
                        if reg is not None and reg != ti:
                            raise RuntimeError(f"{name} e[{bi}]: texture {tn} "
                                               f"reg {reg} != MSL {ti}")
                    if do_compile:
                        compile_check(msl, f"{name} entry[{bi}]")
                    payload = build_metal_payload(msl, len(pe["payload"]))
                    entries[bi] = {"raw": build_code_entry(D3D_TO_METAL_ALL[e["type"]],
                                                           pe["stats"], pe["keywords"],
                                                           payload, trailing),
                                   "seg": e["seg"],
                                   "type": D3D_TO_METAL_ALL[e["type"]]}
    new_blob = serialize_blob(entries)
    comp = lz4.block.compress(new_blob, mode="high_compression", store_size=False)
    d["platforms"] = [14]
    d["offsets"] = [[0]]
    d["compressedLengths"] = [[len(comp)]]
    d["decompressedLengths"] = [[len(new_blob)]]
    d["compressedBlob"] = list(comp)
    counts = {}
    remap_program_types(pf, counts)
    return f"{n_vs} VS + {n_fs} FS entries -> Metal (serialized tables untouched, " \
           f"MSL re-laid to serialized offsets); types {counts}; " \
           f"blob {len(blob)} -> {len(new_blob)}B raw / {len(comp)}B lz4"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src-data", required=True, help="Windows build data dir (DXBC source)")
    ap.add_argument("--dst-data", required=True, help="native app data dir to patch")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--compile-check", action="store_true")
    args = ap.parse_args()

    done = failed = 0
    for fname in sorted(os.path.basename(p) for p in
                        glob.glob(os.path.join(args.src_data, "*.assets"))):
        src_env = UnityPy.load(os.path.join(args.src_data, fname))
        rewrapped = {}
        for o in src_env.objects:
            if getattr(o.type, "name", None) != "Shader":
                continue
            d = o.read_typetree()
            name = d.get("m_ParsedForm", {}).get("m_Name", "")
            if not name.startswith(CUSTOM_PREFIX):
                continue
            short = name.split("/")[-1]
            if args.only and short not in args.only:
                continue
            try:
                report = rewrap_shader_v2(d, short, args.compile_check)
                print(f"== {short} ({fname}): {report}")
                rewrapped[name] = d
                done += 1
            except Exception as ex:
                print(f"!! {short}: {type(ex).__name__}: {ex}", file=sys.stderr)
                failed += 1
        if not rewrapped or args.dry_run:
            continue
        dst_path = os.path.join(args.dst_data, fname)
        dst_env = UnityPy.load(dst_path)
        applied = 0
        for o in dst_env.objects:
            if getattr(o.type, "name", None) != "Shader":
                continue
            if o.read_typetree().get("m_ParsedForm", {}).get("m_Name", "") in rewrapped:
                o.save_typetree(rewrapped[o.read_typetree().get("m_ParsedForm", {}).get("m_Name", "")])
                applied += 1
        if applied:
            data = dst_env.file.save()   # materialize BEFORE truncating (lazy reads)
            with open(dst_path, "wb") as fh:
                fh.write(data)
            print(f"wrote {applied} shader(s) into {dst_path}")
    if PACKED_HITS:
        print(f"\npacked_* re-layout used for {len(PACKED_HITS)} member(s) "
              f"(D3D-packed vectors at MSL-unalignable offsets):")
        for h in sorted(PACKED_HITS):
            print(f"  {h}")
    print(f"\n{done} shader(s) re-wrapped, {failed} failed"
          + (" [dry-run]" if args.dry_run else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
