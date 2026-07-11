import sys, re
import idapro, ida_funcs, ida_name, ida_bytes, idc, idautils, ida_gdl

DB = sys.argv[1]
idapro.open_database(DB, True)  # True = run auto-analysis

info = idc.get_inf_attr(idc.INF_PROCNAME) if hasattr(idc, "get_inf_attr") else "?"
print(f"### proc={info}")

# --- exports -------------------------------------------------------------
exports = list(idautils.Entries())  # (index, ordinal, ea, name)
hash_re = re.compile(r'^[0-9a-f]{32}$')
job_exports = [e for e in exports if e[3] and hash_re.match(e[3])]
print(f"### exports total={len(exports)}  hash-named-jobs={len(job_exports)}")

# --- per-function stats --------------------------------------------------
def fstats(ea):
    f = ida_funcs.get_func(ea)
    if not f: return None
    size = f.end_ea - f.start_ea
    ninsn = 0; avx = False; sse = False; calls = []
    for h in idautils.FuncItems(f.start_ea):
        ninsn += 1
        m = idc.print_insn_mnem(h).lower()
        if not m: continue
        if m.startswith('v') and any(x in m for x in ('ps','pd','ss','sd','mov','fma','perm','broad','blend')):
            avx = True
        if any(x in m for x in ('ps','pd')) and (m.startswith(('mov','mul','add','sub','div','rcp','rsqrt','sqrt','min','max','and','or','xor','shuf','unpck'))):
            sse = True
        for xr in idautils.XrefsFrom(h, 0):
            if xr.type in (16, 17):
                nm = ida_name.get_name(xr.to)
                if nm: calls.append(nm)
    # loop detection: any back-edge in flowchart
    loop = False
    fc = ida_gdl.FlowChart(f)
    for b in fc:
        for s in b.succs():
            if s.start_ea <= b.start_ea:
                loop = True; break
        if loop: break
    return dict(ea=f.start_ea, size=size, ninsn=ninsn, avx=avx, sse=sse, loop=loop, calls=calls)

funcs = []
for ea in idautils.Functions():
    s = fstats(ea)
    if s: funcs.append(s)

funcs.sort(key=lambda d: d['size'], reverse=True)

tot_bytes = sum(d['size'] for d in funcs)
avx_n = sum(1 for d in funcs if d['avx'])
sse_n = sum(1 for d in funcs if d['sse'])
loop_n = sum(1 for d in funcs if d['loop'])
print(f"### functions={len(funcs)}  code_bytes={tot_bytes}  avx_funcs={avx_n}  sse_funcs={sse_n}  loop_funcs={loop_n}")

print("\n### TOP 15 functions by size (name | bytes | insns | simd | loop | #calls)")
for d in funcs[:15]:
    nm = ida_name.get_name(d['ea']) or ''
    simd = ('avx2' if d['avx'] else 'sse' if d['sse'] else '-')
    print(f"  {nm[:40]:40} {d['size']:6} {d['ninsn']:5} {simd:5} {'loop' if d['loop'] else '   -':4} {len(d['calls']):3}")

# distinct external callees across all funcs (what engine ops jobs use)
allcalls = {}
for d in funcs:
    for c in d['calls']:
        allcalls[c] = allcalls.get(c, 0) + 1
print("\n### distinct call targets (callee | times), excluding intra sub_ ")
for c, n in sorted(allcalls.items(), key=lambda kv: -kv[1]):
    if c.startswith('sub_') or c.startswith('loc_'): continue
    print(f"  {n:4}  {c}")

idapro.close_database(False)
