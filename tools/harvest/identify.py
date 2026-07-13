#!/usr/bin/env python3
"""
identify.py - map the harvested D3DMetal metallibs to the game's 4 custom Shader Graphs.

Pipeline (ROADMAP Path 3-lite, step 1 → identification):
  1. Disassemble every harvested libs/*.metallib (via `metal-objdump`) and fingerprint each
     translated shader: stage + number of texture-sample calls (air.sample*).
  2. Read the 4 custom Shader Graphs (BonusPass, DamageScreen, ScreenPass, AberrationShader)
     from the Unity build's globalgamemanagers.assets (via UnityPy), decompress their D3D11
     subprograms, and fingerprint each pixel shader's DXBC: number of `sample` opcodes.
  3. D3DMetal preserves sample calls 1:1 when translating DXBC→AIR, so the pixel-shader sample
     count is a stable invariant. Match each custom shader to the harvested metallib with the
     same fragment sample count and save a named copy + its AIR disassembly to identified/.

The 4 shaders' fragment sample counts happen to be distinct (20/13/8/5 for
BonusPass/ScreenPass/DamageScreen/AberrationShader on this build), giving an unambiguous map.

Usage:  identify.py [--libs DIR] [--data UNITY_DATA_DIR] [--out DIR]
Requires: Xcode Metal Toolchain (metal-objdump) and a venv with UnityPy + lz4.
"""
import subprocess, glob, os, re, struct, sys, json, argparse

CUSTOM = ["BonusPass", "DamageScreen", "ScreenPass", "AberrationShader"]
SAMPLE_OPS = {0x45,0x46,0x47,0x48,0x49,0x4a,0x60,0x6e,0x7e,0x7f,0x62}  # DXBC sample family

def air_sample_count(objdump, path):
    txt = subprocess.run([objdump,"--disassemble",path],capture_output=True,text=True,timeout=90).stdout
    is_frag = bool(re.search(r'%ret_main_ty = type \{[^}]*<4 x float>',txt)) and 'air.sample' in txt
    n = len(re.findall(r'@air\.sample(?:_compare)?_texture_',txt))
    entry = re.findall(r'^0x[0-9a-f]+ -- (\w+):',txt,re.M)
    internal = any(k in txt for k in ("convertDrawPrimitivesToDrawMeshes","fragColorClear","vertPassthrough"))
    return dict(frag=is_frag, samples=n, entry=",".join(sorted(set(entry))), internal=internal)

def scan_dxbc(blob):
    if blob[:4]!=b"DXBC": return None
    try:
        nc=struct.unpack_from("<I",blob,0x1c)[0]; offs=struct.unpack_from(f"<{nc}I",blob,0x20)
    except Exception: return None
    r=dict(samples=0,dcl_resource=0,stage="?",instr=0,size=len(blob))
    for o in offs:
        if blob[o:o+4] in (b"SHEX",b"SHDR"):
            p=o+8; ver=struct.unpack_from("<I",blob,p)[0]; p+=4
            r["stage"]={0:"pixel",1:"vertex"}.get((ver>>16)&0xffff,str((ver>>16)&0xffff))
            length=struct.unpack_from("<I",blob,p)[0]; p+=4; end=min(o+8+length*4,len(blob))
            while p+4<=end:
                tok=struct.unpack_from("<I",blob,p)[0]; op=tok&0x7ff; ol=(tok>>24)&0x7f
                if ol==0: break
                r["instr"]+=1
                if op in SAMPLE_OPS: r["samples"]+=1
                if op==0x58: r["dcl_resource"]+=1
                p+=ol*4
    return r

def custom_fingerprints(data_dir):
    import UnityPy, lz4.block as lz4b
    env=UnityPy.load(os.path.join(data_dir,"globalgamemanagers.assets"))
    out={}
    def flat(x):
        r=[]
        for e in (x or []):
            r += flat(e) if isinstance(e,(list,tuple)) else [e]
        return r
    for obj in env.objects:
        if obj.type.name!="Shader": continue
        d=obj.read()
        try: name=d.m_ParsedForm.m_Name
        except Exception: continue
        short=name.split("/")[-1]
        if short not in CUSTOM: continue
        t=obj.read_typetree(); raw=bytes(t.get("compressedBlob") or b"")
        offs=flat(t.get("offsets")); clen=flat(t.get("compressedLengths")); dlen=flat(t.get("decompressedLengths"))
        best=None
        for off,cl,dl in zip(offs,clen,dlen):
            try: dec=lz4b.decompress(raw[off:off+cl],uncompressed_size=dl)
            except Exception: continue
            for m in re.finditer(b"DXBC",dec):
                s=m.start(); sz=struct.unpack_from("<I",dec,s+24)[0] if s+28<=len(dec) else 0
                if 0<sz<=len(dec)-s:
                    fp=scan_dxbc(dec[s:s+sz])
                    if fp and fp["stage"]=="pixel":
                        if best is None or fp["samples"]>best["samples"]: best=fp
        out[short]=best
    return out

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--libs",default=os.path.expanduser("~/Games/d3dm-harvest/libs"))
    ap.add_argument("--data",default=os.path.expanduser("~/Documents/casualtiesunknowncostam/CasualtiesUnknownDemo/CasualtiesUnknown_Data"))
    ap.add_argument("--out",default=os.path.expanduser("~/Games/d3dm-harvest/identified"))
    a=ap.parse_args()
    objdump=subprocess.check_output(["xcrun","-f","metal-objdump"]).decode().strip()
    os.makedirs(a.out,exist_ok=True)

    print("== fingerprinting harvested metallibs ==")
    air={}
    for p in sorted(glob.glob(os.path.join(a.libs,"*.metallib"))):
        fp=air_sample_count(objdump,p)
        if fp["internal"]: continue
        air[os.path.basename(p)]=fp
    frags={k:v for k,v in air.items() if v["frag"]}
    by_samples={}
    for k,v in frags.items(): by_samples.setdefault(v["samples"],[]).append(k)

    print("== fingerprinting the 4 custom shaders' DXBC ==")
    cust=custom_fingerprints(a.data)
    for name in CUSTOM:
        print(f"  {name:<18} pixel DXBC samples = {cust.get(name,{}).get('samples','?')}")

    # runtime pipeline correlation (from harvest-shaders.sh dump mode w/ HARVEST_HOOK_PSO):
    # each renderPSO event ties a fragment metallib to the pipeline that uses it (+ its vertex).
    pso={}   # fragment metallib -> vertex metallib
    manifest=os.path.join(os.path.dirname(a.libs.rstrip("/")),"manifest.jsonl")
    if os.path.exists(manifest):
        for line in open(manifest):
            try: e=json.loads(line)
            except Exception: continue
            if e.get("event")=="renderPSO" and e.get("fragmentLib","?")!="?":
                pso[e["fragmentLib"]]=e.get("vertexLib","?")

    print("\n== MATCH (fragment sample count preserved DXBC→AIR; pipeline from runtime PSO log) ==")
    mapping={}
    for name in CUSTOM:
        want=cust.get(name,{}).get("samples")
        cands=by_samples.get(want,[])
        lib=cands[0] if len(cands)==1 else None
        tag = lib if lib else (f"AMBIGUOUS{cands}" if cands else "NOT-HARVESTED (needs gameplay trigger)")
        vlib=pso.get(lib) if lib else None
        pipe=f"  pipeline: vertex={vlib} fragment={lib}" if vlib else ""
        mapping[name]=dict(samples=want,fragment_metallib=lib,vertex_metallib=vlib,candidates=cands)
        print(f"  {name:<18} samples={want:<3} -> {tag}{('   [PSO vertex='+vlib+']') if vlib else ''}")
        if lib:
            src=os.path.join(a.libs,lib)
            import shutil; shutil.copy(src,os.path.join(a.out,f"{name}.metallib"))
            with open(os.path.join(a.out,f"{name}.air"),"w") as f:
                f.write(subprocess.run([objdump,"--disassemble",src],capture_output=True,text=True).stdout)
    json.dump(mapping,open(os.path.join(a.out,"mapping.json"),"w"),indent=1)
    print(f"\nnamed metallibs + .air disassembly + mapping.json -> {a.out}")

if __name__=="__main__":
    main()
