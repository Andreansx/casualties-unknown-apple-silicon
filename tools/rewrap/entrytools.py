"""Generic Unity shader code-entry parser (wrapper + keywords + payload + trailing)."""
import struct

def parse_code_entry(raw):
    magic, gtype = struct.unpack_from("<II", raw, 0)
    assert magic == 0x0C0A75BA, hex(magic)
    stats = struct.unpack_from("<4I", raw, 8)
    kwc = struct.unpack_from("<I", raw, 24)[0]
    off = 28
    kws = []
    for _ in range(kwc):
        l = struct.unpack_from("<I", raw, off)[0]; off += 4
        kws.append(raw[off:off + l].decode())
        off += (l + 3) & ~3   # string padded to 4-byte alignment (no forced NUL)
    plen = struct.unpack_from("<I", raw, off)[0]; off += 4
    payload = raw[off:off + plen]
    trailing = raw[off + plen:]
    return {"type": gtype, "stats": stats, "keywords": kws,
            "payload": payload, "trailing": trailing}

def build_code_entry(gtype, stats, keywords, payload, trailing):
    out = struct.pack("<II", 0x0C0A75BA, gtype) + struct.pack("<4I", *stats)
    out += struct.pack("<I", len(keywords))
    for k in keywords:
        kb = k.encode()
        out += struct.pack("<I", len(kb)) + kb
        while len(out) % 4:
            out += b"\0"
    out += struct.pack("<I", len(payload)) + payload + trailing
    return out

def parse_blob(blob):
    n = struct.unpack_from("<I", blob, 0)[0]
    entries = []
    for i in range(n):
        o, l, s = struct.unpack_from("<III", blob, 4 + 12 * i)
        entries.append({"raw": blob[o:o + l], "seg": s,
                        "type": struct.unpack_from("<i", blob, o + 4)[0]})
    return entries

def serialize_blob(entries):
    n = len(entries)
    table = struct.pack("<I", n)
    off = 4 + 12 * n
    payloads = b""
    for e in entries:
        table += struct.pack("<III", off, len(e["raw"]), e["seg"])
        payloads += e["raw"]
        off += len(e["raw"])
    return table + payloads
