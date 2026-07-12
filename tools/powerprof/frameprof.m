// frameprof.m — Metal frame-structure profiler shim for the NATIVE arm64 build.
//
// Purpose: diagnose the ~37W GPU power at the menu (GPU ~90% duty pins max clocks;
// bisect showed it is NOT the converted shaders — even a black-screen build costs
// ~7.9 GPU-ms/frame vs wine's 4.1 for the whole game). This shim logs the actual
// per-frame encoder/pass breakdown as JSONL so the hot pass can be identified
// without eyeballing a 1.3 GB .gputrace in Xcode.
//
// Unlike tools/harvest/shim.m there is NO wine preloader here — the native player
// is a plain arm64 Mach-O — so linking Metal/Foundation directly is safe, and the
// app is ad-hoc signed without hardened runtime, so DYLD_INSERT_LIBRARIES works
// when the binary is exec'd directly (Contents/MacOS/EmptyMac, NOT via `open`).
//
// What it logs (JSONL, FRAMEPROF_LOG, default /tmp/frameprof.jsonl):
//  - "agg" every 120 presents: fps, cmdbufs/encoders/draws/verts/dispatches per
//    window, waitUntilCompleted count, and mean GPU-ms/frame (from per-command-
//    buffer GPUStartTime/GPUEndTime completed handlers).
//  - During short periodic DETAIL windows (frames dstart..dstart+n every period):
//    every render pass attachment (size/pixelformat/samplecount/load/store/
//    storagemode), every draw (vertex+instance counts), every pipeline bind
//    (label), encoder end summaries (label + draw/vert totals), per-cmdbuf GPU ms.
//
// Class discovery: we create a throwaway device/queue/cmdbuf/encoders in the
// constructor to learn the concrete AGX classes, then install safe swizzles
// (class_addMethod-first, so a shared superclass IMP is never mutated).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>
#import <unistd.h>
#import <execinfo.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

#define AGG_N 120

// ── logging ──────────────────────────────────────────────────────────────────

static FILE *g_f = NULL;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static void logline(const char *fmt, ...) {
    pthread_mutex_lock(&g_mu);
    if (!g_f) {
        const char *p = getenv("FRAMEPROF_LOG");
        g_f = fopen(p ? p : "/tmp/frameprof.jsonl", "a");
    }
    if (g_f) {
        fputc('{', g_f);
        va_list ap; va_start(ap, fmt); vfprintf(g_f, fmt, ap); va_end(ap);
        fputs("}\n", g_f);
        fflush(g_f);
    }
    pthread_mutex_unlock(&g_mu);
}

static void jesc(const char *in, char *out, size_t n) {
    size_t o = 0;
    if (!in) { if (n) out[0] = 0; return; }
    for (size_t i = 0; in[i] && o + 2 < n; i++) {
        unsigned char c = in[i];
        if (c == '"' || c == '\\') { out[o++] = '\\'; out[o++] = c; }
        else if (c < 0x20) { /* skip control */ }
        else out[o++] = c;
    }
    out[o < n ? o : n - 1] = 0;
}

static void obj_label(id obj, char *out, size_t n) {
    out[0] = 0;
    if (!obj) return;
    @try {
        id l = [obj respondsToSelector:@selector(label)] ? [obj performSelector:@selector(label)] : nil;
        if (l) jesc([l UTF8String], out, n);
    } @catch (...) {}
}

// ── detail-window gating ─────────────────────────────────────────────────────

static long g_dstart = 600, g_dperiod = 1200, g_dn = 4;
static _Atomic long g_present = 0;
static _Atomic long g_dlines = 0;          // per-window line cap, reset at agg

static int detail(void) {
    long p = atomic_load(&g_present);
    long m = g_dperiod > 0 ? (p % g_dperiod) : p;
    return m >= g_dstart && m < g_dstart + g_dn;
}
static int dgate(void) {                   // detail() + line budget
    if (!detail()) return 0;
    return atomic_fetch_add(&g_dlines, 1) < 6000;
}

// ── aggregate counters ───────────────────────────────────────────────────────

static _Atomic long g_cmdbufs = 0, g_encR = 0, g_encC = 0, g_encB = 0;
static _Atomic long g_draws = 0, g_verts = 0, g_disp = 0, g_waits = 0;
static _Atomic long g_presCalls = 0;   // presentDrawable: calls (diagnostic; Unity may present via [drawable present])
static _Atomic unsigned long long g_gpu_ns = 0;
static double g_wall0 = 0;

static double now_s(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void agg(long p) {
    double now = now_s();
    double dt = g_wall0 > 0 ? now - g_wall0 : 0; g_wall0 = now;
    unsigned long long ns = atomic_exchange(&g_gpu_ns, 0);
    long cbs = atomic_exchange(&g_cmdbufs, 0);
    long er = atomic_exchange(&g_encR, 0), ec = atomic_exchange(&g_encC, 0), eb = atomic_exchange(&g_encB, 0);
    long dr = atomic_exchange(&g_draws, 0); long vt = atomic_exchange(&g_verts, 0);
    long dp = atomic_exchange(&g_disp, 0);  long wt = atomic_exchange(&g_waits, 0);
    long pc = atomic_exchange(&g_presCalls, 0);
    atomic_store(&g_dlines, 0);
    logline("\"event\":\"agg\",\"frame\":%ld,\"dt_s\":%.3f,\"fps\":%.1f,"
            "\"cmdbufs\":%ld,\"encR\":%ld,\"encC\":%ld,\"encB\":%ld,"
            "\"draws\":%ld,\"verts\":%ld,\"disp\":%ld,\"waits\":%ld,\"presCalls\":%ld,\"gpu_ms_frame\":%.3f",
            p, dt, dt > 0 ? (double)AGG_N / dt : 0.0,
            cbs, er, ec, eb, dr, vt, dp, wt, pc, ns / 1e6 / (double)AGG_N);
}

// Heartbeat: if the frame tick never fires (present path not hooked / game paused),
// still report raw totals every 5s so activity is visible.
static void *heartbeat(void *arg) {
    (void)arg;
    long last = -1;
    for (;;) {
        sleep(5);
        long p = atomic_load(&g_present);
        if (p == last) {
            logline("\"event\":\"hb\",\"frame\":%ld,\"cmdbufs\":%ld,\"encR\":%ld,\"encC\":%ld,"
                    "\"encB\":%ld,\"draws\":%ld,\"gpu_ns\":%llu",
                    p, atomic_load(&g_cmdbufs), atomic_load(&g_encR), atomic_load(&g_encC),
                    atomic_load(&g_encB), atomic_load(&g_draws), atomic_load(&g_gpu_ns));
        }
        last = p;
    }
    return NULL;
}

// ── per-encoder draw stats ───────────────────────────────────────────────────

typedef struct { void *enc; long draws; long verts; } EncStat;
static EncStat g_es[256];
static pthread_mutex_t g_esmu = PTHREAD_MUTEX_INITIALIZER;

static void es_add(void *enc) {
    pthread_mutex_lock(&g_esmu);
    for (int i = 0; i < 256; i++) if (!g_es[i].enc) { g_es[i].enc = enc; g_es[i].draws = 0; g_es[i].verts = 0; break; }
    pthread_mutex_unlock(&g_esmu);
}
static void es_draw(void *enc, unsigned long verts, unsigned long inst) {
    atomic_fetch_add(&g_draws, 1);
    atomic_fetch_add(&g_verts, (long)(verts * (inst ? inst : 1)));
    pthread_mutex_lock(&g_esmu);
    for (int i = 0; i < 256; i++) if (g_es[i].enc == enc) { g_es[i].draws++; g_es[i].verts += (long)(verts * (inst ? inst : 1)); break; }
    pthread_mutex_unlock(&g_esmu);
    if (dgate()) logline("\"event\":\"draw\",\"enc\":\"%p\",\"v\":%lu,\"i\":%lu", enc, verts, inst);
}
static EncStat es_take(void *enc) {
    EncStat r = { NULL, 0, 0 };
    pthread_mutex_lock(&g_esmu);
    for (int i = 0; i < 256; i++) if (g_es[i].enc == enc) { r = g_es[i]; g_es[i].enc = NULL; break; }
    pthread_mutex_unlock(&g_esmu);
    return r;
}

// ── safe swizzle (never mutate a shared superclass IMP) ──────────────────────

static IMP swz(Class c, const char *sel, IMP hook) {
    SEL s = sel_registerName(sel);
    Method m = class_getInstanceMethod(c, s);
    if (!m) { logline("\"event\":\"swizzleMiss\",\"cls\":\"%s\",\"sel\":\"%s\"", class_getName(c), sel); return NULL; }
    IMP orig = method_getImplementation(m);
    if (class_addMethod(c, s, hook, method_getTypeEncoding(m))) return orig;   // was inherited
    return method_setImplementation(class_getInstanceMethod(c, s), hook);      // was concrete
}

// ── command-buffer hooks ─────────────────────────────────────────────────────

static IMP orig_rce, orig_cce, orig_cce_dt, orig_cce_desc, orig_bce;
static IMP orig_commit, orig_present, orig_present_at, orig_wait;

static void log_pass(MTLRenderPassDescriptor *d, void *enc) {
    for (int i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *ca = d.colorAttachments[i];
        id<MTLTexture> t = ca.texture;
        if (!t) continue;
        logline("\"event\":\"pass\",\"enc\":\"%p\",\"att\":\"c%d\",\"w\":%lu,\"h\":%lu,\"fmt\":%lu,"
                "\"samp\":%lu,\"load\":%lu,\"store\":%lu,\"storage\":%lu",
                enc, i, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat,
                (unsigned long)t.sampleCount, (unsigned long)ca.loadAction, (unsigned long)ca.storeAction,
                (unsigned long)t.storageMode);
    }
    id<MTLTexture> dt = d.depthAttachment.texture;
    if (dt) logline("\"event\":\"pass\",\"enc\":\"%p\",\"att\":\"d\",\"w\":%lu,\"h\":%lu,\"fmt\":%lu,"
                    "\"samp\":%lu,\"load\":%lu,\"store\":%lu,\"storage\":%lu",
                    enc, (unsigned long)dt.width, (unsigned long)dt.height, (unsigned long)dt.pixelFormat,
                    (unsigned long)dt.sampleCount, (unsigned long)d.depthAttachment.loadAction,
                    (unsigned long)d.depthAttachment.storeAction, (unsigned long)dt.storageMode);
}

static id hook_rce(id self, SEL _cmd, MTLRenderPassDescriptor *d) {
    atomic_fetch_add(&g_encR, 1);
    id enc = ((id(*)(id, SEL, id))orig_rce)(self, _cmd, d);
    if (enc) {
        es_add((void *)enc);
        if (d && dgate()) log_pass(d, (void *)enc);
    }
    return enc;
}
static id hook_cce(id self, SEL _cmd) {
    atomic_fetch_add(&g_encC, 1);
    return ((id(*)(id, SEL))orig_cce)(self, _cmd);
}
static id hook_cce_dt(id self, SEL _cmd, NSUInteger t) {
    atomic_fetch_add(&g_encC, 1);
    return ((id(*)(id, SEL, NSUInteger))orig_cce_dt)(self, _cmd, t);
}
static id hook_cce_desc(id self, SEL _cmd, id d) {
    atomic_fetch_add(&g_encC, 1);
    return ((id(*)(id, SEL, id))orig_cce_desc)(self, _cmd, d);
}
static id hook_bce(id self, SEL _cmd) {
    atomic_fetch_add(&g_encB, 1);
    return ((id(*)(id, SEL))orig_bce)(self, _cmd);
}

static void hook_commit(id self, SEL _cmd) {
    atomic_fetch_add(&g_cmdbufs, 1);
    int det = detail();
    long p = atomic_load(&g_present);
    @try {
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            double ms = ([cb GPUEndTime] - [cb GPUStartTime]) * 1000.0;
            if (ms > 0) atomic_fetch_add(&g_gpu_ns, (unsigned long long)(ms * 1e6));
            if (det && ms >= 0) {
                char lab[128]; obj_label((id)cb, lab, sizeof lab);
                logline("\"event\":\"cbgpu\",\"present\":%ld,\"label\":\"%s\",\"gpu_ms\":%.3f", p, lab, ms);
            }
        }];
    } @catch (...) {}
    ((void(*)(id, SEL))orig_commit)(self, _cmd);
}

// Frame boundary = CAMetalLayer.nextDrawable (one per frame; Unity's macOS player
// presents via a scheduled handler + [drawable present], NOT presentDrawable:, so
// the present hooks below are diagnostic counters only).
static void frame_tick(void) {
    long p = atomic_fetch_add(&g_present, 1) + 1;
    if (p % AGG_N == 0) agg(p);
}
static IMP orig_nextdrawable;
static id hook_nextdrawable(id self, SEL _cmd) {
    id d = ((id(*)(id, SEL))orig_nextdrawable)(self, _cmd);
    if (dgate()) {
        CAMetalLayer *l = (CAMetalLayer *)self;
        logline("\"event\":\"drawable\",\"w\":%.0f,\"h\":%.0f,\"fmt\":%lu,\"sync\":%d",
                l.drawableSize.width, l.drawableSize.height,
                (unsigned long)l.pixelFormat, l.displaySyncEnabled ? 1 : 0);
    }
    frame_tick();
    return d;
}
static void hook_present(id self, SEL _cmd, id dr) {
    atomic_fetch_add(&g_presCalls, 1);
    ((void(*)(id, SEL, id))orig_present)(self, _cmd, dr);
}
static void hook_present_at(id self, SEL _cmd, id dr, double t) {
    atomic_fetch_add(&g_presCalls, 1);
    ((void(*)(id, SEL, id, double))orig_present_at)(self, _cmd, dr, t);
}
static void hook_wait(id self, SEL _cmd) {
    atomic_fetch_add(&g_waits, 1);
    ((void(*)(id, SEL))orig_wait)(self, _cmd);
}

// ── render-encoder hooks ─────────────────────────────────────────────────────

static IMP orig_endR, orig_endC, orig_endB, orig_setrps, orig_setcps;
static IMP orig_dP, orig_dPi, orig_dPib, orig_dI, orig_dIi, orig_dIib;
static IMP orig_dtg, orig_dth;

static void hook_setrps(id self, SEL _cmd, id pso) {
    if (dgate()) {
        char lab[256]; obj_label(pso, lab, sizeof lab);
        logline("\"event\":\"pso\",\"enc\":\"%p\",\"label\":\"%s\"", (void *)self, lab);
    }
    ((void(*)(id, SEL, id))orig_setrps)(self, _cmd, pso);
}
static void hook_setcps(id self, SEL _cmd, id pso) {
    if (dgate()) {
        char lab[256]; obj_label(pso, lab, sizeof lab);
        logline("\"event\":\"cpso\",\"enc\":\"%p\",\"label\":\"%s\"", (void *)self, lab);
    }
    ((void(*)(id, SEL, id))orig_setcps)(self, _cmd, pso);
}

static void hook_dP(id self, SEL _cmd, NSUInteger prim, NSUInteger start, NSUInteger n) {
    es_draw((void *)self, n, 1);
    ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger))orig_dP)(self, _cmd, prim, start, n);
}
static void hook_dPi(id self, SEL _cmd, NSUInteger prim, NSUInteger start, NSUInteger n, NSUInteger inst) {
    es_draw((void *)self, n, inst);
    ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, NSUInteger))orig_dPi)(self, _cmd, prim, start, n, inst);
}
static void hook_dPib(id self, SEL _cmd, NSUInteger prim, NSUInteger start, NSUInteger n, NSUInteger inst, NSUInteger base) {
    es_draw((void *)self, n, inst);
    ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, NSUInteger, NSUInteger))orig_dPib)(self, _cmd, prim, start, n, inst, base);
}
static void hook_dI(id self, SEL _cmd, NSUInteger prim, NSUInteger n, NSUInteger it, id ib, NSUInteger off) {
    es_draw((void *)self, n, 1);
    ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, id, NSUInteger))orig_dI)(self, _cmd, prim, n, it, ib, off);
}
static void hook_dIi(id self, SEL _cmd, NSUInteger prim, NSUInteger n, NSUInteger it, id ib, NSUInteger off, NSUInteger inst) {
    es_draw((void *)self, n, inst);
    ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, id, NSUInteger, NSUInteger))orig_dIi)(self, _cmd, prim, n, it, ib, off, inst);
}
static void hook_dIib(id self, SEL _cmd, NSUInteger prim, NSUInteger n, NSUInteger it, id ib, NSUInteger off, NSUInteger inst, NSInteger bv, NSUInteger bi) {
    es_draw((void *)self, n, inst);
    ((void(*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, id, NSUInteger, NSUInteger, NSInteger, NSUInteger))orig_dIib)(self, _cmd, prim, n, it, ib, off, inst, bv, bi);
}

static void hook_dtg(id self, SEL _cmd, MTLSize a, MTLSize b) {
    atomic_fetch_add(&g_disp, 1);
    if (dgate()) logline("\"event\":\"dispatch\",\"enc\":\"%p\",\"tg\":[%lu,%lu,%lu]", (void *)self,
                         (unsigned long)a.width, (unsigned long)a.height, (unsigned long)a.depth);
    ((void(*)(id, SEL, MTLSize, MTLSize))orig_dtg)(self, _cmd, a, b);
}
static void hook_dth(id self, SEL _cmd, MTLSize a, MTLSize b) {
    atomic_fetch_add(&g_disp, 1);
    if (dgate()) logline("\"event\":\"dispatch\",\"enc\":\"%p\",\"th\":[%lu,%lu,%lu]", (void *)self,
                         (unsigned long)a.width, (unsigned long)a.height, (unsigned long)a.depth);
    ((void(*)(id, SEL, MTLSize, MTLSize))orig_dth)(self, _cmd, a, b);
}

static void end_common(id self, const char *type) {
    EncStat st = es_take((void *)self);
    if (dgate()) {
        char lab[256]; obj_label(self, lab, sizeof lab);
        logline("\"event\":\"encEnd\",\"type\":\"%s\",\"enc\":\"%p\",\"label\":\"%s\",\"draws\":%ld,\"verts\":%ld",
                type, (void *)self, lab, st.draws, st.verts);
    }
}
static void hook_endR(id self, SEL _cmd) { end_common(self, "R"); ((void(*)(id, SEL))orig_endR)(self, _cmd); }
static void hook_endC(id self, SEL _cmd) { end_common(self, "C"); ((void(*)(id, SEL))orig_endC)(self, _cmd); }
static void hook_endB(id self, SEL _cmd) { end_common(self, "B"); ((void(*)(id, SEL))orig_endB)(self, _cmd); }

// ── vsync probe: who calls CAMetalLayer setDisplaySyncEnabled:? ──────────────

static IMP orig_setsync;
static void hook_setsync(id self, SEL _cmd, BOOL v) {
    void *bt[12]; int n = backtrace(bt, 12);
    char **syms = backtrace_symbols(bt, n);
    char buf[2048]; buf[0] = 0;
    for (int i = 2; i < n && i < 8; i++) {
        char e[300]; jesc(syms ? syms[i] : "?", e, sizeof e);
        size_t l = strlen(buf);
        snprintf(buf + l, sizeof buf - l, "%s%s", l ? " | " : "", e);
    }
    if (syms) free(syms);
    logline("\"event\":\"setDisplaySync\",\"value\":%d,\"bt\":\"%s\"", v ? 1 : 0, buf);
    if (getenv("FRAMEPROF_FORCE_SYNC")) v = YES;
    ((void(*)(id, SEL, BOOL))orig_setsync)(self, _cmd, v);
}

// ── mono governor: read runtime vSyncCount, optionally set targetFrameRate ───
// Uses the embedded Mono runtime already in-process. All engine calls are made
// on the main queue (Unity's NSApplication run loop services it between frames).

typedef void *(*f_p)(void);
typedef void *(*f_pp)(void *);
typedef void *(*f_ppc)(void *, const char *);
typedef void *(*f_img_cls)(void *, const char *, const char *);
typedef void *(*f_meth)(void *, const char *, int);
typedef void *(*f_invoke)(void *, void *, void **, void **);

typedef void *(*f_pc)(const char *);

static void *mono_method(const char *asmname, const char *ns, const char *cls, const char *meth, int nargs) {
    f_pc image_loaded = (f_pc)dlsym(RTLD_DEFAULT, "mono_image_loaded");
    f_img_cls cls_from = (f_img_cls)dlsym(RTLD_DEFAULT, "mono_class_from_name");
    f_meth meth_from = (f_meth)dlsym(RTLD_DEFAULT, "mono_class_get_method_from_name");
    if (!image_loaded || !cls_from || !meth_from) { logline("\"event\":\"monoSymMiss\""); return NULL; }
    void *img = image_loaded(asmname);
    if (!img) { logline("\"event\":\"monoImgMiss\",\"asm\":\"%s\"", asmname); return NULL; }
    void *c = cls_from(img, ns, cls);
    if (!c) { logline("\"event\":\"monoClsMiss\",\"cls\":\"%s.%s\"", ns, cls); return NULL; }
    return meth_from(c, meth, nargs);
}

static int mono_call_int_getter(const char *asmname, const char *ns, const char *cls, const char *meth, int *out) {
    void *m = mono_method(asmname, ns, cls, meth, 0);
    f_invoke invoke = (f_invoke)dlsym(RTLD_DEFAULT, "mono_runtime_invoke");
    f_pp unbox = (f_pp)dlsym(RTLD_DEFAULT, "mono_object_unbox");
    if (!m || !invoke || !unbox) return 0;
    void *exc = NULL;
    void *r = invoke(m, NULL, NULL, &exc);
    if (exc || !r) return 0;
    *out = *(int *)unbox(r);
    return 1;
}

static int mono_call_int_setter(const char *asmname, const char *ns, const char *cls, const char *meth, int val) {
    void *m = mono_method(asmname, ns, cls, meth, 1);
    f_invoke invoke = (f_invoke)dlsym(RTLD_DEFAULT, "mono_runtime_invoke");
    if (!m || !invoke) return 0;
    void *exc = NULL;
    void *args[1] = { &val };
    invoke(m, NULL, args, &exc);
    return exc == NULL;
}

static void *governor(void *arg) {
    (void)arg;
    long tfr = 0;
    const char *e = getenv("FRAMEPROF_TFR");
    if (e) tfr = atol(e);
    // wait for mono + UnityEngine.CoreModule
    f_p rootdom = NULL;
    for (int i = 0; i < 240; i++) {
        rootdom = (f_p)dlsym(RTLD_DEFAULT, "mono_get_root_domain");
        if (rootdom && rootdom()) break;
        rootdom = NULL;
        usleep(500 * 1000);
    }
    if (!rootdom) { logline("\"event\":\"monoTimeout\""); return NULL; }
    sleep(8);   // let the first scene come up
    dispatch_async(dispatch_get_main_queue(), ^{
        f_pp attach = (f_pp)dlsym(RTLD_DEFAULT, "mono_thread_attach");
        f_p rd = (f_p)dlsym(RTLD_DEFAULT, "mono_get_root_domain");
        if (attach && rd) attach(rd());
        int vs = -999, tf = -999;
        int ok1 = mono_call_int_getter("UnityEngine.CoreModule", "UnityEngine", "QualitySettings", "get_vSyncCount", &vs);
        int ok2 = mono_call_int_getter("UnityEngine.CoreModule", "UnityEngine", "Application", "get_targetFrameRate", &tf);
        int ql = -999;
        mono_call_int_getter("UnityEngine.CoreModule", "UnityEngine", "QualitySettings", "GetQualityLevel", &ql);
        logline("\"event\":\"runtimeState\",\"vSyncCount\":%d,\"ok\":%d,\"targetFrameRate\":%d,\"ok2\":%d,\"qualityLevel\":%d",
                vs, ok1, tf, ok2, ql);
    });
    if (tfr > 0) {
        sleep(6);   // give a clean before-window in the same log
        long fps_val = tfr;
        dispatch_async(dispatch_get_main_queue(), ^{
            int ok = mono_call_int_setter("UnityEngine.CoreModule", "UnityEngine", "Application", "set_targetFrameRate", (int)fps_val);
            logline("\"event\":\"setTargetFrameRate\",\"value\":%ld,\"ok\":%d", fps_val, ok);
        });
    }
    const char *q = getenv("FRAMEPROF_QL");
    if (q) {
        long ql_val = atol(q);
        sleep(6);
        dispatch_async(dispatch_get_main_queue(), ^{
            int ok = mono_call_int_setter("UnityEngine.CoreModule", "UnityEngine", "QualitySettings", "SetQualityLevel", (int)ql_val);
            int now = -999, vs = -999;
            mono_call_int_getter("UnityEngine.CoreModule", "UnityEngine", "QualitySettings", "GetQualityLevel", &now);
            mono_call_int_getter("UnityEngine.CoreModule", "UnityEngine", "QualitySettings", "get_vSyncCount", &vs);
            logline("\"event\":\"setQualityLevel\",\"value\":%ld,\"ok\":%d,\"now\":%d,\"vSyncCount\":%d", ql_val, ok, now, vs);
        });
        // re-read a few seconds later to see if something reverts it
        sleep(8);
        dispatch_async(dispatch_get_main_queue(), ^{
            int now = -999, vs = -999;
            mono_call_int_getter("UnityEngine.CoreModule", "UnityEngine", "QualitySettings", "GetQualityLevel", &now);
            mono_call_int_getter("UnityEngine.CoreModule", "UnityEngine", "QualitySettings", "get_vSyncCount", &vs);
            logline("\"event\":\"qualityRecheck\",\"now\":%d,\"vSyncCount\":%d", now, vs);
        });
    }
    return NULL;
}

// ── install ──────────────────────────────────────────────────────────────────

static void install(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { logline("\"event\":\"noDevice\""); return; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tex;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        id re = [cb renderCommandEncoderWithDescriptor:rp];
        Class REC = object_getClass(re);
        [(id<MTLRenderCommandEncoder>)re endEncoding];

        id<MTLCommandBuffer> cb2 = [q commandBuffer];
        id ce = [cb2 computeCommandEncoder];
        Class CEC = object_getClass(ce);
        [(id<MTLComputeCommandEncoder>)ce endEncoding];

        id<MTLCommandBuffer> cb3 = [q commandBuffer];
        id be = [cb3 blitCommandEncoder];
        Class BEC = object_getClass(be);
        [(id<MTLBlitCommandEncoder>)be endEncoding];

        Class CBC = object_getClass(cb);

        orig_rce      = swz(CBC, "renderCommandEncoderWithDescriptor:", (IMP)hook_rce);
        orig_cce      = swz(CBC, "computeCommandEncoder", (IMP)hook_cce);
        orig_cce_dt   = swz(CBC, "computeCommandEncoderWithDispatchType:", (IMP)hook_cce_dt);
        orig_cce_desc = swz(CBC, "computeCommandEncoderWithDescriptor:", (IMP)hook_cce_desc);
        orig_bce      = swz(CBC, "blitCommandEncoder", (IMP)hook_bce);
        orig_commit   = swz(CBC, "commit", (IMP)hook_commit);
        orig_present  = swz(CBC, "presentDrawable:", (IMP)hook_present);
        orig_present_at = swz(CBC, "presentDrawable:atTime:", (IMP)hook_present_at);
        orig_wait     = swz(CBC, "waitUntilCompleted", (IMP)hook_wait);

        orig_setrps = swz(REC, "setRenderPipelineState:", (IMP)hook_setrps);
        orig_dP   = swz(REC, "drawPrimitives:vertexStart:vertexCount:", (IMP)hook_dP);
        orig_dPi  = swz(REC, "drawPrimitives:vertexStart:vertexCount:instanceCount:", (IMP)hook_dPi);
        orig_dPib = swz(REC, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", (IMP)hook_dPib);
        orig_dI   = swz(REC, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", (IMP)hook_dI);
        orig_dIi  = swz(REC, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:", (IMP)hook_dIi);
        orig_dIib = swz(REC, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:", (IMP)hook_dIib);
        orig_endR = swz(REC, "endEncoding", (IMP)hook_endR);

        orig_setcps = swz(CEC, "setComputePipelineState:", (IMP)hook_setcps);
        orig_dtg  = swz(CEC, "dispatchThreadgroups:threadsPerThreadgroup:", (IMP)hook_dtg);
        orig_dth  = swz(CEC, "dispatchThreads:threadsPerThreadgroup:", (IMP)hook_dth);
        orig_endC = swz(CEC, "endEncoding", (IMP)hook_endC);

        orig_endB = swz(BEC, "endEncoding", (IMP)hook_endB);

        Class LC = objc_getClass("CAMetalLayer");
        if (LC) {
            orig_nextdrawable = swz(LC, "nextDrawable", (IMP)hook_nextdrawable);
            orig_setsync = swz(LC, "setDisplaySyncEnabled:", (IMP)hook_setsync);
        }

        logline("\"event\":\"installed\",\"cb\":\"%s\",\"re\":\"%s\",\"ce\":\"%s\",\"be\":\"%s\",\"layer\":%d",
                class_getName(CBC), class_getName(REC), class_getName(CEC), class_getName(BEC),
                orig_nextdrawable != NULL);
    }
}

__attribute__((constructor)) static void init(void) {
    logline("\"event\":\"loaded\",\"pid\":%d,\"proc\":\"%s\"", getpid(), getprogname());
    const char *e;
    if ((e = getenv("FRAMEPROF_DETAIL_START")))  g_dstart  = atol(e);
    if ((e = getenv("FRAMEPROF_DETAIL_PERIOD"))) g_dperiod = atol(e);
    if ((e = getenv("FRAMEPROF_DETAIL_N")))      g_dn      = atol(e);
    @try { install(); } @catch (...) { logline("\"event\":\"installThrew\""); }
    pthread_t t; pthread_create(&t, NULL, heartbeat, NULL); pthread_detach(t);
    pthread_t g; pthread_create(&g, NULL, governor, NULL); pthread_detach(g);
}
