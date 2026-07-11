import sys
import idapro, ida_hexrays, ida_funcs, ida_name, idc, idautils

idapro.open_database(sys.argv[1], True)
ida_hexrays.init_hexrays_plugin()

targets = sys.argv[2:]
for t in targets:
    ea = int(t, 16) if t.startswith("0x") else ida_name.get_name_ea(0, t)
    f = ida_funcs.get_func(ea)
    print(f"\n===== {ida_name.get_name(ea)} @ {ea:#x}  size={f.end_ea-f.start_ea} =====")
    try:
        cf = ida_hexrays.decompile(ea)
        txt = str(cf)
        lines = txt.splitlines()
        print(f"[decompiled: {len(lines)} lines]")
        # keyword scan for math character
        import re
        kws = ['sqrt','rsqrt','sinf','cosf','sin(','cos(','atan','floor','ceil','fmod',
               'expf','logf','pow','noise','perlin','/ ','* ','fabs','round']
        hits = {}
        low = txt.lower()
        for k in kws:
            c = low.count(k.lower())
            if c: hits[k] = c
        print("math-ops:", ", ".join(f"{k}×{v}" for k,v in sorted(hits.items(), key=lambda x:-x[1])))
        # count float constants
        floats = len(re.findall(r'\b\d+\.\d+', txt))
        print(f"float-literals: {floats}")
        print("---- first 55 lines ----")
        for ln in lines[:55]:
            print(ln)
    except Exception as e:
        print("decompile failed:", e)

idapro.close_database(False)
