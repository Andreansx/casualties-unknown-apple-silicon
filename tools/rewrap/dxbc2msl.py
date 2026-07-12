#!/usr/bin/env python3
"""dxbc2msl.py — turn a Unity-stripped DXBC (ISGN/OSGN/SHDR only) back into a full DXBC
with a synthesized RDEF chunk (from Unity's serialized param tables), then feed it to the
HLSLcc CLI to obtain Unity-ABI Metal MSL.

Unity strips D3D reflection from builds (it keeps its own param tables); HLSLcc needs RDEF.
We rebuild it: resource slots/dims come from the SHDR dcl_* instructions (authoritative per
variant), names/CB layouts from the shader's m_ParsedForm (passed in as a 'names' dict).
"""
import struct, subprocess, os

HLSLCC = os.environ.get("HLSLCC_CLI") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hlslcc", "hlslcc-cli")

# ---------- SHDR dcl parsing ----------

def parse_container(dxbc):
    assert dxbc[:4] == b"DXBC", dxbc[:4]
    nch = struct.unpack_from("<I", dxbc, 28)[0]
    offs = struct.unpack_from(f"<{nch}I", dxbc, 32)
    chunks = {}
    for o in offs:
        four = dxbc[o:o+4]
        size = struct.unpack_from("<I", dxbc, o+4)[0]
        chunks[four] = dxbc[o+8:o+8+size]
    return chunks

# D3D10_SB resource dimension (dcl token bits 15:11) -> D3D_SRV_DIMENSION for RDEF
DCLDIM_TO_SRVDIM = {2: 1, 3: 4, 4: 6, 5: 8, 6: 9, 7: 3, 8: 5, 9: 7, 10: 10}
# (buffer=1->BUFFER(1), tex1d=2?..) mapping: dcl 2=texture1d? Actually:
# 0 unknown 1 buffer 2 texture1d 3 texture2d 4 texture2dms 5 texture3d 6 texturecube
# 7 texture1darray 8 texture2darray 9 texture2dmsarray 10 texturecubearray
DCLDIM_TO_SRVDIM = {1: 1, 2: 2, 3: 4, 4: 6, 5: 8, 6: 9, 7: 3, 8: 5, 9: 7, 10: 10}

def parse_dcls(shdr):
    """-> dict(version, stage, cbs={slot: vec4count}, textures={slot: srvdim}, samplers=[slots])"""
    ver = struct.unpack_from("<I", shdr, 0)[0]
    stage = (ver >> 16) & 0xFFFF          # 0 pixel, 1 vertex
    major = (ver >> 4) & 0xF
    length = struct.unpack_from("<I", shdr, 4)[0]   # in dwords, incl. 2 hdr
    out = {"stage": stage, "major": major, "cbs": {}, "textures": {}, "samplers": []}
    p = 8
    end = min(length * 4, len(shdr))
    while p + 4 <= end:
        tok = struct.unpack_from("<I", shdr, p)[0]
        op = tok & 0x7FF
        olen = (tok >> 24) & 0x7F
        if olen == 0:
            break
        if op == 0x59:    # dcl_constantbuffer cbN[size]
            slot = struct.unpack_from("<I", shdr, p+8)[0]
            size = struct.unpack_from("<I", shdr, p+12)[0]
            out["cbs"][slot] = max(out["cbs"].get(slot, 0), size)
        elif op == 0x58:  # dcl_resource
            dim = (tok >> 11) & 0x1F
            slot = struct.unpack_from("<I", shdr, p+8)[0]
            out["textures"][slot] = DCLDIM_TO_SRVDIM.get(dim, 4)
        elif op == 0x5A:  # dcl_sampler
            slot = struct.unpack_from("<I", shdr, p+8)[0]
            out["samplers"].append(slot)
        p += olen * 4
    return out

# ---------- RDEF synthesis ----------

SVT_FLOAT, SVT_INT, SVT_BOOL, SVT_UINT = 3, 2, 1, 19
SVC_SCALAR, SVC_VECTOR, SVC_MATRIX_COLUMNS = 0, 1, 3

class _Buf:
    def __init__(self):
        self.b = bytearray()
    def add(self, data):
        off = len(self.b)
        self.b += data
        return off

def build_rdef(dcls, names, stage, major=4):
    var_dwords = 10 if major >= 5 else 6   # SM5 var records carry 4 extra dwords
    """names = {
         'cbs':      {slot: {'name': str, 'size': bytes,
                             'members': [(name, offset, class_, type_, rows, cols, elements)]}},
         'textures': {slot: str},
         'samplers': {slot: str},
       }  — any missing entry gets a generic fallback.
    """
    strings = _Buf()
    stroffs = {}
    def s(name):
        if name not in stroffs:
            stroffs[name] = None  # patched later (strings live after all records)
        return name

    # --- plan layout: header(24) | bindings | cbuffers | vars | types | strings
    bindings = []   # (nameKey, type, rettype, dim, numsamples, bindpoint)
    for slot in sorted(dcls["cbs"]):
        nm = names.get("cbs", {}).get(slot, {}).get("name", f"cb{slot}")
        bindings.append((nm, 0, 0, 0, 0, slot))
    for slot, dim in sorted(dcls["textures"].items()):
        nm = names.get("textures", {}).get(slot, f"tex{slot}")
        bindings.append((nm, 2, 5, dim, 0xFFFFFFFF, slot))
    for slot in sorted(dcls["samplers"]):
        nm = names.get("samplers", {}).get(slot, f"sampler{slot}")
        bindings.append((nm, 3, 0, 0, 0, slot))

    cbs = []
    for slot in sorted(dcls["cbs"]):
        info = names.get("cbs", {}).get(slot, {})
        nm = info.get("name", f"cb{slot}")
        size = info.get("size", dcls["cbs"][slot] * 16)
        size = max(size, dcls["cbs"][slot] * 16)
        members = list(info.get("members", []))
        # fill uncovered 16-byte ranges with pad float4s so every SHDR load resolves
        covered = [False] * ((size + 15) // 16)
        for (_, off, _, _, rows, cols, elems) in members:
            bytecount = max(1, elems) * (rows * 16 if rows > 1 else 16 if cols > 2 else 8 if cols == 2 else 4)
            for i in range(off // 16, min(len(covered), (off + bytecount + 15) // 16)):
                covered[i] = True
        run = None
        for i, c in enumerate(covered + [True]):
            if not c and run is None:
                run = i
            elif c and run is not None:
                members.append((f"pad_{nm}_{run}", run * 16, SVC_VECTOR, SVT_FLOAT, 1, 4, i - run if i - run > 1 else 0))
                run = None
        members.sort(key=lambda m: m[1])
        cbs.append((nm, size, members))

    hdr_size = 6 * 4
    bind_off = hdr_size
    bind_size = len(bindings) * 8 * 4
    cb_off = bind_off + bind_size
    cb_size = len(cbs) * 6 * 4
    var_off = cb_off + cb_size
    nvars = sum(len(m) for _, _, m in cbs)
    var_size = nvars * var_dwords * 4
    type_off = var_off + var_size
    type_size = nvars * 16
    str_off = type_off + type_size

    # strings
    strblob = bytearray()
    def intern(name):
        nonlocal strblob
        if name not in stroffs or stroffs[name] is None:
            stroffs[name] = str_off + len(strblob)
            strblob += name.encode() + b"\0"
        return stroffs[name]

    out = bytearray()
    out += struct.pack("<6I", len(cbs), cb_off, len(bindings), bind_off, 0x0400 if stage else 0xFFFF, 0)
    for nm, t, rt, dim, ns, bp in bindings:
        out += struct.pack("<8I", intern(nm), t, rt, dim, ns, bp, 1, 0)
    vi = 0
    for nm, size, members in cbs:
        out += struct.pack("<6I", intern(nm), len(members), var_off + vi * var_dwords * 4, size, 0, 0)
        vi += len(members)
    ti = 0
    for nm, size, members in cbs:
        for (mn, off, cls, typ, rows, cols, elems) in members:
            bytecount = max(1, elems) * (rows * 16 if rows > 1 else cols * 4)
            out += struct.pack("<6I", intern(mn), off, bytecount, 2, type_off + ti * 16, 0)
            if var_dwords == 10:
                out += struct.pack("<4I", 0xFFFFFFFF, 0, 0xFFFFFFFF, 0)
            ti += 1
    for nm, size, members in cbs:
        for (mn, off, cls, typ, rows, cols, elems) in members:
            out += struct.pack("<6HI", cls, typ, rows, cols, elems, 0, 0)
    assert len(out) == str_off, (len(out), str_off)
    out += strblob
    return bytes(out)

def assemble_dxbc(chunks_in_order):
    """chunks_in_order = [(fourcc bytes, data bytes)] -> container"""
    n = len(chunks_in_order)
    hdr_len = 32 + 4 * n
    offs, blob = [], b""
    for four, data in chunks_in_order:
        offs.append(hdr_len + len(blob))
        blob += four + struct.pack("<I", len(data)) + data
    total = hdr_len + len(blob)
    out = b"DXBC" + b"\0" * 16 + struct.pack("<III", 1, total, n)
    out += struct.pack(f"<{n}I", *offs)
    out += blob
    return out

def dxbc_to_msl(payload, names, flags=None):
    """payload = Unity code-entry payload (prefix + stripped DXBC). -> (msl, stderr)"""
    idx = payload.find(b"DXBC")
    assert idx >= 0, "no DXBC in payload"
    chunks = parse_container(payload[idx:])
    code_four = b"SHDR" if b"SHDR" in chunks else b"SHEX"
    dcls = parse_dcls(chunks[code_four])
    rdef = build_rdef(dcls, names, dcls["stage"], dcls["major"])
    order = [(b"RDEF", rdef)]
    for f in (b"ISGN", b"OSGN", b"OSG5", b"PCSG", code_four):
        if f in chunks:
            order.append((f, chunks[f]))
    full = assemble_dxbc(order)
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".dxbc", delete=False) as tf:
        tf.write(full)
        path = tf.name
    args = [HLSLCC, path] + ([f"{flags:x}"] if flags else [])
    r = subprocess.run(args, capture_output=True, text=True, timeout=60)
    os.unlink(path)
    if r.returncode != 0:
        raise RuntimeError(f"hlslcc failed rc={r.returncode}: {r.stderr[:400]}")
    return r.stdout, r.stderr

if __name__ == "__main__":
    import sys
    payload = open(sys.argv[1], "rb").read()
    msl, err = dxbc_to_msl(payload, {})
    sys.stdout.write(msl)
