#!/usr/bin/env python3
"""
inject_custom_metal.py — Path 3 (Bucket B): give the remaining custom Shader Graphs native
Metal variants by translating their D3D11 DXBC to Unity-ABI MSL with Unity's own HLSLcc
(tools/hlslcc/build.sh), then re-wrapping every keyword variant in place.

Per shader (all "Shader Graphs/*" still on platforms=[4]):
  * per pass, build a reflection 'names' dict from Unity's serialized param tables
    (m_NameIndices + progXXX.m_CommonParameters) — used to synthesize the RDEF chunk that
    Unity strips from builds (dxbc2msl.py), so HLSLcc sees real names/CB layouts;
  * for every code entry (type 15/16 VS, 17/18 FS): DXBC -> MSL, post-process to Unity's
    2022.3 Metal flavor (rp_output_remap function-constant preamble for FS,
    `position, invariant` for VS), rebuild the entry with the SAME stats/keywords/trailing;
  * the trailing input-channel table is NOT platform-independent when the VS has vertex
    attributes: each (channel, value) pair's value must become the ISGN register + 13
    (verified empirically on 56 game/donor stock-shader entry pairs, 0 contradictions);
  * the MSL source is padded with trailing newlines so payloadLen keeps the ORIGINAL
    payload's length mod 4 — the engine reads the trailing table after the payload with
    the original's alignment phase (this reproduces the exact validated configuration);
  * platforms -> [14], every m_GpuProgramType 15/16 -> 23, 17/18 -> 24, blob LZ4'd.

Usage:
  python3 inject_custom_metal.py --game-data <CU.app>/Contents/Resources/Data \
        [--only WaterShader RainShader] [--dry-run] [--compile-check]
"""
import argparse
import glob
import os
import re
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from entrytools import parse_code_entry, build_code_entry, parse_blob, serialize_blob
from dxbc2msl import dxbc_to_msl, parse_container
from inject_metal import decompress_blob

import UnityPy
import lz4.block

CUSTOM_PREFIX = "Shader Graphs/"
VS_TYPES = {15: 23, 16: 23}
FS_TYPES = {17: 24, 18: 24}
D3D_TO_METAL_ALL = {**VS_TYPES, **FS_TYPES}
# Unity HLSLcc flags: TRANSLATE_MATRICES | REMOVE_UNUSED_GLOBALS | METAL_SHADOW_SAMPLER_LINEAR
HLSLCC_FLAGS = 0x20000 | 0x10000 | 0x80000

PAYLOAD_MAGIC = 0xF00DCAFE
ENTRY_NAME = b"xlatMtlMain"

CHAN_SEM = {0: ("POSITION", 0), 1: ("NORMAL", 0), 2: ("TANGENT", 0), 3: ("COLOR", 0),
            4: ("TEXCOORD", 0), 5: ("TEXCOORD", 1), 6: ("TEXCOORD", 2), 7: ("TEXCOORD", 3),
            8: ("TEXCOORD", 4), 9: ("TEXCOORD", 5), 10: ("TEXCOORD", 6), 11: ("TEXCOORD", 7)}

SVC_SCALAR, SVC_VECTOR, SVC_MATRIX_COLUMNS = 0, 1, 3
SVT_FLOAT, SVT_INT, SVT_BOOL = 3, 2, 1
UNITY_TYPE_TO_SVT = {0: SVT_FLOAT, 1: SVT_INT, 2: SVT_BOOL}


def build_names(pass_d, prog_d):
    """Reflection info for dxbc2msl.build_rdef from Unity's serialized param tables."""
    idx2name = {i: n for n, i in pass_d.get("m_NameIndices", [])}
    common = prog_d.get("m_CommonParameters", {})
    names = {"cbs": {}, "textures": {}, "samplers": {}}

    cbdefs = {}
    for cb in common.get("m_ConstantBuffers", []):
        members = []
        for vp in cb.get("m_VectorParams", []):
            dim = max(1, vp.get("m_Dim", 4))
            members.append((idx2name.get(vp["m_NameIndex"], f"v{vp['m_NameIndex']}"),
                            vp["m_Index"], SVC_SCALAR if dim == 1 else SVC_VECTOR,
                            UNITY_TYPE_TO_SVT.get(vp.get("m_Type", 0), SVT_FLOAT),
                            1, dim, vp.get("m_ArraySize", 0)))
        for mp in cb.get("m_MatrixParams", []):
            rows = mp.get("m_RowCount", 4) or 4
            members.append((idx2name.get(mp["m_NameIndex"], f"m{mp['m_NameIndex']}"),
                            mp["m_Index"], SVC_MATRIX_COLUMNS,
                            UNITY_TYPE_TO_SVT.get(mp.get("m_Type", 0), SVT_FLOAT),
                            rows, 4, mp.get("m_ArraySize", 0)))
        cbdefs[cb["m_NameIndex"]] = {
            "name": idx2name.get(cb["m_NameIndex"], f"cb_{cb['m_NameIndex']}"),
            "size": cb.get("m_Size", 0), "members": members}

    for b in common.get("m_ConstantBufferBindings", []):
        if b["m_NameIndex"] in cbdefs:
            names["cbs"][b["m_Index"]] = cbdefs[b["m_NameIndex"]]

    for tp in common.get("m_TextureParams", []):
        tex = idx2name.get(tp["m_NameIndex"], f"tex{tp['m_Index']}")
        names["textures"][tp["m_Index"]] = tex
        si = tp.get("m_SamplerIndex", -1)
        if si is not None and si >= 0 and si != 0xFFFFFFFF:
            names["samplers"].setdefault(si, "sampler" + tex)
    return names


def postprocess_fs(msl):
    """Public-HLSLcc XLT_REMAP macro -> Unity 2022.3's rp_output_remap function constant."""
    used = sorted({int(m) for m in re.findall(r"xlt_remap_o\[(\d+)\]", msl)})
    pre = "constant uint32_t rp_output_remap_mask [[ function_constant(1) ]];\n"
    for i in used:
        pre += f"constant const uint rp_output_remap_{i} = (rp_output_remap_mask >> {i * 4}) & 0xF;\n"
    msl = re.sub(r"#ifndef XLT_REMAP_O.*?constexpr constant uint xlt_remap_o\[\] = XLT_REMAP_O;\n",
                 pre, msl, flags=re.S)
    return re.sub(r"xlt_remap_o\[(\d+)\]", r"rp_output_remap_\1", msl)


def postprocess_vs(msl):
    return msl.replace("[[ position ]]", "[[ position, invariant ]]")


def parse_isgn(data):
    cnt = struct.unpack_from("<I", data, 0)[0]
    out = {}
    for i in range(cnt):
        noff, semidx, _, _, reg, _ = struct.unpack_from("<6I", data, 8 + i * 24)
        name = data[noff:data.index(b"\0", noff)].decode()
        out[(name.upper(), semidx)] = reg
    return out


SEM_CHAN = {v: k for k, v in CHAN_SEM.items()}

def rewrite_vs_trailing(trailing, payload):
    """Rebuild the vertex-channel table for Metal: one (channel, ISGN_register+13) pair for
    EVERY vertex input the shader declares. On D3D11 Unity implicitly zero-fills wanted
    channels absent from the pair list, but Unity's Metal vertex descriptor only declares
    attributes present here — a missing one gives 'Vertex attribute X is missing from the
    vertex descriptor' at pipeline-state creation. Leading alignment pad bytes are kept."""
    idx = payload.find(b"DXBC")
    isgn_chunk = parse_container(payload[idx:]).get(b"ISGN")
    if isgn_chunk is None:
        return trailing
    isgn = parse_isgn(isgn_chunk)
    pad = 0
    while pad < len(trailing) and (len(trailing) - pad) % 4:
        pad += 1
    if len(trailing) - pad < 8:
        return trailing
    mask = struct.unpack_from("<I", trailing, pad)[0]
    pairs = []
    for (sem, semidx), reg in sorted(isgn.items(), key=lambda kv: kv[1]):
        chan = SEM_CHAN.get((sem, semidx))
        if chan is None:
            if sem.startswith("SV_"):   # system values aren't vertex-buffer attributes
                continue
            raise RuntimeError(f"VS input {sem}{semidx}: no Unity vertex channel mapping")
        pairs.append((chan, reg + 13))
        mask |= 1 << chan
    body = struct.pack("<II", mask, len(pairs))
    for chan, val in pairs:
        body += struct.pack("<II", chan, val)
    return trailing[:pad] + body


def build_metal_payload(msl, orig_payload_len):
    """0xF00DCAFE payload; source newline-padded so len % 4 matches the original payload."""
    src = msl.encode()
    while (60 + len(src)) % 4 != orig_payload_len % 4:
        src += b"\n"
    header = struct.pack("<12I", PAYLOAD_MAGIC, 48, 6, 60, 0, 0, 0, 0, 0, 0x25, 0xFFFFFFFF, 0)
    return header + ENTRY_NAME + b"\0" + src


def remap_program_types(node, counts):
    if isinstance(node, dict):
        t = node.get("m_GpuProgramType")
        if t in D3D_TO_METAL_ALL:
            node["m_GpuProgramType"] = D3D_TO_METAL_ALL[t]
            counts[t] = counts.get(t, 0) + 1
        for v in node.values():
            remap_program_types(v, counts)
    elif isinstance(node, list):
        for v in node:
            remap_program_types(v, counts)


def blob_names_map(pf):
    """blob index -> names dict, walking every pass/program of the parsed form."""
    out = {}
    for ss in pf.get("m_SubShaders", []):
        for ps in ss.get("m_Passes", []):
            for key in ("progVertex", "progFragment"):
                prog = ps.get(key, {})
                names = build_names(ps, prog)
                subs = list(prog.get("m_SubPrograms", []) or [])
                for tier in prog.get("m_PlayerSubPrograms", []) or []:
                    subs += tier if isinstance(tier, list) else [tier]
                for sp in subs:
                    out[sp["m_BlobIndex"]] = names
    return out


def compile_check(msl, tag):
    with tempfile.NamedTemporaryFile(suffix=".metal", mode="w", delete=False) as tf:
        tf.write(msl)
        p = tf.name
    r = subprocess.run(["xcrun", "metal", "-c", p, "-o", "/dev/null",
                        "-std=macos-metal2.2", "-Wno-unused-variable"],
                       capture_output=True, text=True)
    os.unlink(p)
    if r.returncode != 0:
        raise RuntimeError(f"{tag}: metal compile failed:\n{r.stderr[:600]}")


def rewrap_shader(d, name, do_compile):
    if list(d.get("platforms", [])) != [4]:
        raise RuntimeError(f"{name}: platforms={list(d.get('platforms', []))}, expected [4]")
    offs = d["offsets"][0]
    if not isinstance(offs, int) and len(offs) != 1:
        raise RuntimeError(f"{name}: multi-segment blob ({len(offs)} segments) not supported")
    blob = decompress_blob(d, 0)
    entries = parse_blob(blob)
    names_by_blob = blob_names_map(d["m_ParsedForm"])

    n_vs = n_fs = 0
    new_entries = []
    for i, e in enumerate(entries):
        if e["type"] not in D3D_TO_METAL_ALL:
            new_entries.append(e)
            continue
        pe = parse_code_entry(e["raw"])
        names = names_by_blob.get(i, {})
        msl, _ = dxbc_to_msl(pe["payload"], names, flags=HLSLCC_FLAGS)
        if e["type"] in FS_TYPES:
            msl = postprocess_fs(msl)
            trailing = pe["trailing"]
            n_fs += 1
        else:
            msl = postprocess_vs(msl)
            trailing = rewrite_vs_trailing(pe["trailing"], pe["payload"])
            n_vs += 1
        if do_compile:
            compile_check(msl, f"{name} entry[{i}]")
        payload = build_metal_payload(msl, len(pe["payload"]))
        raw = build_code_entry(D3D_TO_METAL_ALL[e["type"]], pe["stats"], pe["keywords"],
                               payload, trailing)
        new_entries.append({"raw": raw, "seg": e["seg"], "type": D3D_TO_METAL_ALL[e["type"]]})

    new_blob = serialize_blob(new_entries)
    comp = lz4.block.compress(new_blob, mode="high_compression", store_size=False)
    d["platforms"] = [14]
    d["offsets"] = [[0]]
    d["compressedLengths"] = [[len(comp)]]
    d["decompressedLengths"] = [[len(new_blob)]]
    d["compressedBlob"] = list(comp)
    counts = {}
    remap_program_types(d["m_ParsedForm"], counts)
    return f"{n_vs} VS + {n_fs} FS entries -> Metal; types remapped {counts}; " \
           f"blob {len(blob)} -> {len(new_blob)}B raw / {len(comp)}B lz4"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game-data", required=True)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--compile-check", action="store_true")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.game_data, "*.assets")))
    touched = []
    done = failed = 0
    for f in files:
        env = UnityPy.load(f)
        changed = False
        for o in env.objects:
            if getattr(o.type, "name", None) != "Shader":
                continue
            d = o.read_typetree()
            name = d.get("m_ParsedForm", {}).get("m_Name", "")
            if not name.startswith(CUSTOM_PREFIX):
                continue
            short = name.split("/")[-1]
            if args.only and short not in args.only:
                continue
            if list(d.get("platforms", [])) != [4]:
                continue
            try:
                report = rewrap_shader(d, short, args.compile_check)
                print(f"== {short} ({os.path.basename(f)} pid={o.path_id}): {report}")
                if not args.dry_run:
                    o.save_typetree(d)
                    changed = True
                done += 1
            except Exception as ex:
                print(f"!! {short}: {type(ex).__name__}: {ex}", file=sys.stderr)
                failed += 1
        if changed:
            data = env.file.save()   # materialize BEFORE truncating (UnityPy lazy reads)
            with open(f, "wb") as fh:
                fh.write(data)
            touched.append(f)
            print(f"wrote {f}")
    print(f"\n{done} shader(s) re-wrapped, {failed} failed, {len(touched)} file(s) written"
          + (" [dry-run]" if args.dry_run else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
