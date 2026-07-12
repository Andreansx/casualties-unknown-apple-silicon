"""Parser/serializer for Unity shader parameter-blob entries (wrapper type 3=VS/4=FS
on D3D11; 3=VS/2=FS in Metal builds).

Layout (all u32 LE, strings = u32 len + bytes padded to 4, no NUL):
  0x00 magic 0x0C0A75BA
  0x04 wrapper type (2/3/4)
  0x08 4 x u32 (always 0 in every observed entry; preserved)
  0x18 CB records:  name, size, nVec, nVec x vecRec, nMat, nMat x matRec
       vec/matRec = name + 6 u32 fields [type, rowCount, dim, arraySize, ?, byteOffset]
  ...  u32 nTex + nTex x (name + 4 u32 [multisampled?, index, samplerIndex, dim])
End of CB list is not delimited: a CB record is recognized by its name; the texture
section is recognized by parsing to exact end-of-entry. We disambiguate by trying the
texture section first at each boundary and requiring exact consumption."""
import struct

MAGIC = 0x0C0A75BA


def _rd_str(b, off):
    n = struct.unpack_from("<I", b, off)[0]
    if n == 0 or n > 96:
        raise ValueError(f"bad strlen {n} @{off:#x}")
    s = b[off + 4:off + 4 + n]
    if not all(32 <= c < 127 for c in s):
        raise ValueError(f"non-printable name @{off:#x}")
    off += 4 + ((n + 3) & ~3)
    return s.decode(), off


def _wr_str(s):
    sb = s.encode()
    out = struct.pack("<I", len(sb)) + sb
    while len(out) % 4:
        out += b"\0"
    return out


def _try_tex_section(b, off):
    """Parse u32 count + count texture records; must consume to exact end."""
    ntex = struct.unpack_from("<I", b, off)[0]
    off += 4
    if ntex > 64:
        raise ValueError("tex count implausible")
    texs = []
    for _ in range(ntex):
        name, off = _rd_str(b, off)
        ms, idx, sidx, dim = struct.unpack_from("<4I", b, off)
        off += 16
        texs.append({"name": name, "ms": ms, "index": idx, "sampler": sidx, "dim": dim})
    if off != len(b):
        raise ValueError("tex section does not reach end")
    return texs


def parse_params_entry(raw):
    magic, wtype = struct.unpack_from("<II", raw, 0)
    assert magic == MAGIC
    head = raw[8:24]
    off = 24
    cbs = []
    texs = None
    while off < len(raw):
        try:
            texs = _try_tex_section(raw, off)
            break
        except (ValueError, struct.error):
            pass
        name, off = _rd_str(raw, off)
        size = struct.unpack_from("<I", raw, off)[0]; off += 4
        cb = {"name": name, "size": size, "vec": [], "mat": []}
        for kind in ("vec", "mat"):
            n = struct.unpack_from("<I", raw, off)[0]; off += 4
            if n > 256:
                raise ValueError(f"{kind} count {n} implausible in CB {name}")
            for _ in range(n):
                pname, off = _rd_str(raw, off)
                f = struct.unpack_from("<6I", raw, off); off += 24
                cb[kind].append({"name": pname, "type": f[0], "rows": f[1],
                                 "dim": f[2], "arraySize": f[3], "f4": f[4],
                                 "offset": f[5]})
        cbs.append(cb)
    if texs is None:
        if off != len(raw):
            raise ValueError("no texture section and CBs did not consume entry")
        texs = []
    return {"wtype": wtype, "head": head, "cbs": cbs, "textures": texs}


def build_params_entry(p):
    out = struct.pack("<II", MAGIC, p["wtype"]) + p["head"]
    for cb in p["cbs"]:
        out += _wr_str(cb["name"]) + struct.pack("<I", cb["size"])
        for kind in ("vec", "mat"):
            out += struct.pack("<I", len(cb[kind]))
            for v in cb[kind]:
                out += _wr_str(v["name"]) + struct.pack(
                    "<6I", v["type"], v["rows"], v["dim"], v["arraySize"],
                    v["f4"], v["offset"])
    out += struct.pack("<I", len(p["textures"]))
    for t in p["textures"]:
        out += _wr_str(t["name"]) + struct.pack("<4I", t["ms"], t["index"], t["sampler"], t["dim"])
    return out
