#!/usr/bin/env python3
"""
patch_ggm_metal.py - flip a transplanted native build's `globalgamemanagers` to target Metal.

The native ARM64 transplant is grafted from the *Windows* build, so its serialized settings say
the build targets D3D11 only. Two fields must change for the player to bring up a Metal device
and accept Metal shaders:

  1. GraphicsSettings.m_ShaderDefinesPerShaderCompiler[0].shaderPlatform : 4 (D3D11) -> 14 (Metal)
     Without this: "Forced GfxDevice 'Metal' was not built from editor, shaders will not be
     available" -> InitializeEngineGraphics failed.
  2. BuildSettings.m_GraphicsAPIs[0] : 2 (kGraphicsDeviceD3D11) -> 16 (kGraphicsDeviceMetal)
     Without this: the player never selects Metal (falls back to NullGfxDevice) and every shader
     is "not supported on this GPU".

Both are patched as SURGICAL binary edits (4 bytes each) - UnityPy's full re-serialization of
`globalgamemanagers` corrupts it ("The file '...' is corrupted!"), so we never rewrite the whole
file, only the two ints, located by signature.

Verified: with these two patches + the Mac player's Metal builtin resources (kept by
transplant.sh) + tools/rewrap/inject_metal.py's Metal shaders, the native player boots on a real
Metal device (M2 Max) and loads the re-wrapped custom shaders with zero GpuProgram-load errors.

Usage:  python3 patch_ggm_metal.py <path/to/Data/globalgamemanagers>
"""
import struct
import sys


def patch(path):
    b = bytearray(open(path, "rb").read())
    changed = []

    # 1) shaderPlatform 4 -> 14, found by the unique tier-defines signature that follows it:
    #    int shaderPlatform(=4) | int len(=2) | [V,0] | int len(=2) | V ...   (V = 142984712)
    V = struct.pack("<I", 142984712)
    sig = struct.pack("<I", 4) + struct.pack("<I", 2) + V + b"\x00\x00\x00\x00" + struct.pack("<I", 2) + V
    i = b.find(sig)
    if i < 0:
        raise RuntimeError("shaderPlatform signature not found (already patched? wrong file?)")
    assert struct.unpack_from("<I", b, i)[0] == 4
    b[i:i + 4] = struct.pack("<I", 14)
    changed.append(("shaderPlatform@%d" % i, "4->14"))

    # 2) BuildSettings.m_GraphicsAPIs [2] -> [16]. m_GraphicsAPIs is the LAST field of the
    #    BuildSettings object, serialised as vector<int> = [len=1, value=2]. Locate the object's
    #    byte range with UnityPy (read-only - we do NOT let it re-serialise), then patch the value
    #    of the trailing [1,2] pair.
    import UnityPy
    env = UnityPy.load(path)
    bs = [o for o in env.objects if getattr(o.type, "name", None) == "BuildSettings"]
    if not bs:
        raise RuntimeError("no BuildSettings object in globalgamemanagers")
    o = bs[0]
    obj = bytes(b[o.byte_start:o.byte_start + o.byte_size])
    tail = struct.pack("<ii", 1, 2)
    rel = obj.rfind(tail)
    if rel < 0 or rel + 8 != o.byte_size:
        raise RuntimeError("m_GraphicsAPIs [1,2] not at BuildSettings tail (already patched? layout differs)")
    gp = o.byte_start + rel + 4          # the value int
    assert struct.unpack_from("<i", b, gp)[0] == 2
    b[gp:gp + 4] = struct.pack("<i", 16)
    changed.append(("m_GraphicsAPIs@%d" % gp, "2->16 (Metal)"))

    open(path, "wb").write(b)
    return changed


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    for name, how in patch(sys.argv[1]):
        print(f"patched {name}: {how}")
    print("done - the build now targets Metal.")
