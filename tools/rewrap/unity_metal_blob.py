#!/usr/bin/env python3
"""
unity_metal_blob.py - build & parse Unity 2022.3 Metal shader sub-program blobs.

This is the byte-exact core of the Path 3-lite "hard tail": serialise a Metal Shading
Language (MSL) source string into the container Unity's engine parses at load time, so a
native ARM64 Unity player can compile it via `[MTLDevice newLibraryWithSource:]`.

Format was reverse-engineered from
  * real native macOS Unity 2022.3.62f3 Metal shaders (unity_builtin_extra), and
  * UnityPlayer.dylib's loader (sub_10E3AA0 / sub_10E1D30 / sub_10E2460), which:
      - expects each program payload to begin with magic 0xF00DCAFE,
      - reads the entry-point name at nameOffset and the MSL source at sourceOffset,
      - feeds the source to newLibraryWithSource: (source path) unless a 0x100 flag
        selects newLibraryWithData: (precompiled-metallib path).

A single-variant Metal program sub-program entry (what these post-fx use - no keywords):

  outer wrapper (32 bytes):
     u32  0x0C0A75BA          # ShaderGpuProgram tag
     u32  gpuProgramType      # 23 = Metal vertex (kShaderGpuProgramMetalVS)
                              # 24 = Metal fragment (kShaderGpuProgramMetalFS)
     u32  stats[5] = 0        # (hash/stats slot, zero for these)
     u32  payloadLen          # = srcOffset(60) + len(source)   [excludes NUL/padding]
  payload (the 0xF00DCAFE blob, `payloadLen` bytes + NUL + 4-byte pad):
     u32  0xF00DCAFE
     u32  nameOffset  = 48    # relative to blob start
     u32  count       = 6
     u32  srcOffset   = 60
     u32  x4          = 0
     u32  x5          = 0
     u32  x6          = 0
     u32  x7          = 0
     u32  x8          = 0
     u32  x9          = 0x25       # constant across all stock Metal shaders
     u32  x10         = 0xFFFFFFFF # constant
     u32  x11         = 0
     bytes  "xlatMtlMain\0"        # at nameOffset 48 .. 60
     bytes  <MSL source>           # at srcOffset 60
     u8   0x00                     # source terminator
     pad to 4 bytes

Type IDs (Unity ShaderGpuProgramType):
   15 = kShaderGpuProgramDX11VertexSM40   -> Metal vertex   23
   17 = kShaderGpuProgramDX11PixelSM40    -> Metal fragment 24
"""
import struct

WRAPPER_MAGIC   = 0x0C0A75BA
PAYLOAD_MAGIC   = 0xF00DCAFE
ENTRY_NAME      = b"xlatMtlMain"
NAME_OFFSET     = 48
SRC_OFFSET      = 60
BLOB_COUNT      = 6

METAL_VS = 23
METAL_FS = 24
D3D_VS   = 15
D3D_FS   = 17

D3D_TO_METAL = {D3D_VS: METAL_VS, D3D_FS: METAL_FS}


def build_metal_program(msl_source: str, gpu_program_type: int, trailing: bytes = b"") -> bytes:
    """Serialise MSL source into one Unity Metal sub-program entry (outer wrapper + payload).

    `trailing` is the input-binding / vertex-channel structure that follows the program payload
    in a real Unity code entry. It is platform-independent (it describes the ShaderLab pass'
    vertex channels), so when swapping a D3D entry for a Metal one we MUST carry the original
    entry's trailing bytes across - the engine's GpuProgram loader reads it after the source, and
    a missing/short one makes it reject the program ("Failed to load GpuProgram from binary shader
    data"). For a fullscreen post-fx VS (no vertex attributes) it is 10 zero-ish bytes; a VS with
    N attributes carries an N-entry channel map.
    """
    src = msl_source.encode("utf-8")
    # payload: 48-byte header (12 dwords), then name (12 bytes), then source
    header = struct.pack(
        "<12I",
        PAYLOAD_MAGIC, NAME_OFFSET, BLOB_COUNT, SRC_OFFSET,
        0, 0, 0, 0, 0, 0x25, 0xFFFFFFFF, 0,
    )
    assert len(header) == NAME_OFFSET, len(header)
    name = ENTRY_NAME + b"\0"                    # 12 bytes -> ends exactly at SRC_OFFSET
    assert NAME_OFFSET + len(name) == SRC_OFFSET, (NAME_OFFSET, len(name), SRC_OFFSET)
    payload_core = header + name + src           # length == SRC_OFFSET + len(src)
    payload_len = len(payload_core)              # bounds the f00dcafe payload (source ends here)

    wrapper = struct.pack("<II", WRAPPER_MAGIC, gpu_program_type)
    wrapper += struct.pack("<5I", 0, 0, 0, 0, 0)  # stats
    wrapper += struct.pack("<I", payload_len)
    return wrapper + payload_core + trailing


def parse_metal_program(entry: bytes) -> dict:
    """Mirror of the engine loader: recover (type, entryName, source) from an entry.

    Used to round-trip-validate build_metal_program and to sanity-read stock shaders."""
    magic, gtype = struct.unpack_from("<II", entry, 0)
    if magic != WRAPPER_MAGIC:
        raise ValueError(f"bad wrapper magic {magic:#010x}")
    payload_len = struct.unpack_from("<I", entry, 28)[0]
    base = 32
    pmagic, name_off, count, src_off = struct.unpack_from("<4I", entry, base)
    if pmagic != PAYLOAD_MAGIC:
        raise ValueError(f"bad payload magic {pmagic:#010x}")
    name_abs = base + name_off
    name = entry[name_abs:entry.index(b"\0", name_abs)]
    src_abs = base + src_off
    src_len = payload_len - src_off          # engine computes exactly this
    source = entry[src_abs:src_abs + src_len]
    return {
        "gpu_program_type": gtype,
        "payload_len": payload_len,
        "name_offset": name_off,
        "count": count,
        "src_offset": src_off,
        "entry_name": name.decode("ascii", "replace"),
        "source": source.decode("utf-8", "replace"),
    }


if __name__ == "__main__":
    # self-test: round-trip a tiny shader
    msl = "#include <metal_stdlib>\nusing namespace metal;\nfragment float4 xlatMtlMain(){return 0;}\n"
    for t in (METAL_VS, METAL_FS):
        e = build_metal_program(msl, t)
        r = parse_metal_program(e)
        assert r["gpu_program_type"] == t
        assert r["entry_name"] == "xlatMtlMain"
        assert r["source"] == msl, (len(r["source"]), len(msl))
        print(f"round-trip OK type={t} entrylen={len(e)} srclen={len(r['source'])}")
