// frameprof.m - Metal frame-structure profiler shim for the NATIVE arm64 build.
//
// Purpose: diagnose the ~37W GPU power at the menu (GPU ~90% duty pins max clocks;
// bisect showed it is NOT the converted shaders - even a black-screen build costs
// ~7.9 GPU-ms/frame vs wine's 4.1 for the whole game). This shim logs the actual
// per-frame encoder/pass breakdown as JSONL so the hot pass can be identified
// without eyeballing a 1.3 GB .gputrace in Xcode.
//
// Unlike tools/harvest/shim.m there is NO wine preloader here - the native player
// is a plain arm64 Mach-O - so linking Metal/Foundation directly is safe, and the
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

// PEEK: when the bound render PSO's label contains FRAMEPROF_PEEK (default off),
// every draw dumps the live contents of the bound constant/vertex buffers so
// "engine wrote constants where the shader reads them?" and "is the deformed
// vertex data sane?" are answerable without a .gputrace.
#define PEEK_VB 31
typedef struct {
    void *enc; long draws; long verts;
    int psoMatch; void *pso;
    char pass[160];
    double vpx, vpy, vpw, vph;
    unsigned long stencilRef;
    void *vb[PEEK_VB]; unsigned long vboff[PEEK_VB];      // vertex MTLBuffers
    void *fb[4]; unsigned long fboff[4];                  // fragment MTLBuffers 0..3
    unsigned char vstash[2][4096]; unsigned long vstashlen[2];   // setVertexBytes 0..1
    unsigned char fstash[2][4096]; unsigned long fstashlen[2];   // setFragmentBytes 0..1
} EncStat;
static EncStat g_es[256];
static pthread_mutex_t g_esmu = PTHREAD_MUTEX_INITIALIZER;
static const char *g_peek = NULL;
static _Atomic long g_peeks = 0;

static EncStat *es_find(void *enc) {   // caller holds g_esmu
    for (int i = 0; i < 256; i++) if (g_es[i].enc == enc) return &g_es[i];
    return NULL;
}

static void es_add(void *enc) {
    pthread_mutex_lock(&g_esmu);
    for (int i = 0; i < 256; i++) if (!g_es[i].enc) { memset(&g_es[i], 0, sizeof(EncStat)); g_es[i].enc = enc; break; }
    pthread_mutex_unlock(&g_esmu);
}
static void fdump(char *out, size_t n, const unsigned char *base, unsigned long avail,
                  unsigned long off, int nfloats) {
    size_t o = 0;
    out[0] = 0;
    if (!base || off + 4 > avail) { snprintf(out, n, "\"oob\""); return; }
    if (off + nfloats * 4 > avail) nfloats = (int)((avail - off) / 4);
    o += snprintf(out + o, n - o, "[");
    const float *f = (const float *)(base + off);
    for (int i = 0; i < nfloats && o + 16 < n; i++)
        o += snprintf(out + o, n - o, "%s%.5g", i ? "," : "", f[i]);
    snprintf(out + o, n - o, "]");
}

static void peek_buf(id mtlbuf, unsigned long bindoff, const unsigned char **base,
                     unsigned long *avail) {
    *base = NULL; *avail = 0;
    if (!mtlbuf) return;
    @try {
        if ([(id<MTLBuffer>)mtlbuf storageMode] == MTLStorageModePrivate) return;
        const unsigned char *p = (const unsigned char *)[(id<MTLBuffer>)mtlbuf contents];
        unsigned long len = [(id<MTLBuffer>)mtlbuf length];
        if (p && bindoff < len) { *base = p + bindoff; *avail = len - bindoff; }
    } @catch (...) {}
}

static void es_peek(EncStat *st, unsigned long verts) {
    if (atomic_fetch_add(&g_peeks, 1) > 2000) return;
    char head[512], vp[256], tail[640], pp[128], otw[256], fs_head[512], fs_tail[640], vbs[1400];
    const unsigned char *base; unsigned long avail;
    // VS buffer 0 = $Globals (limb: pp@336, VP@1216, tail 2048..; stock: 0..128)
    if (st->vstashlen[0]) { base = st->vstash[0]; avail = st->vstashlen[0]; }
    else peek_buf((id)st->vb[0], st->vboff[0], &base, &avail);
    unsigned long vs0len = avail;
    fdump(head, sizeof head, base, avail, 0, 16);
    fdump(vp, sizeof vp, base, avail, 1216, 16);
    fdump(pp, sizeof pp, base, avail, 336, 4);
    fdump(tail, sizeof tail, base, avail, 2048, 32);
    // VS buffer 1 = UnityPerDraw (ObjectToWorld rows 0..3)
    if (st->vstashlen[1]) { base = st->vstash[1]; avail = st->vstashlen[1]; }
    else peek_buf((id)st->vb[1], st->vboff[1], &base, &avail);
    fdump(otw, sizeof otw, base, avail, 0, 16);
    // FS buffer 0 = $Globals fragment view
    if (st->fstashlen[0]) { base = st->fstash[0]; avail = st->fstashlen[0]; }
    else peek_buf((id)st->fb[0], st->fboff[0], &base, &avail);
    unsigned long fs0len = avail;
    fdump(fs_head, sizeof fs_head, base, avail, 0, 8);
    fdump(fs_tail, sizeof fs_tail, base, avail, 2048, 32);
    // vertex streams (indices 2..30): first 8 floats each
    size_t o = 0; vbs[0] = 0;
    for (int i = 2; i < PEEK_VB && o + 200 < sizeof vbs; i++) {
        if (!st->vb[i]) continue;
        peek_buf((id)st->vb[i], st->vboff[i], &base, &avail);
        char tmp[220];
        fdump(tmp, sizeof tmp, base, avail, 0, 8);
        o += snprintf(vbs + o, sizeof vbs - o, "%s\"b%d\":%s", o ? "," : "", i, tmp);
    }
    logline("\"event\":\"peek\",\"enc\":\"%p\",\"pso\":\"%p\",\"v\":%lu,\"vs0len\":%lu,\"fs0len\":%lu,"
            "\"pass\":\"%s\",\"vpXYWH\":[%.0f,%.0f,%.0f,%.0f],\"sref\":%lu,"
            "\"vs_head\":%s,\"vs_pp336\":%s,\"vs_vp1216\":%s,\"vs_tail2048\":%s,\"updraw\":%s,"
            "\"fs_head\":%s,\"fs_tail2048\":%s,\"vstream\":{%s}",
            st->enc, st->pso, verts, vs0len, fs0len,
            st->pass, st->vpx, st->vpy, st->vpw, st->vph, st->stencilRef,
            head, pp, vp, tail, otw, fs_head, fs_tail, vbs);
}

static void es_draw(void *enc, unsigned long verts, unsigned long inst) {
    atomic_fetch_add(&g_draws, 1);
    atomic_fetch_add(&g_verts, (long)(verts * (inst ? inst : 1)));
    int peek = 0;
    EncStat snap;
    pthread_mutex_lock(&g_esmu);
    EncStat *st = es_find(enc);
    if (st) {
        st->draws++; st->verts += (long)(verts * (inst ? inst : 1));
        if (st->psoMatch) { peek = 1; snap = *st; }
    }
    pthread_mutex_unlock(&g_esmu);
    if (peek) es_peek(&snap, verts);
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

// Unity's jobified renderer records the main pass through a
// MTLParallelRenderCommandEncoder; its sub-encoders must be tracked too or
// their PSO binds/draws are invisible to the peek machinery.
static IMP orig_prce, orig_prce_sub;
static char g_lastppass[160];   // parent pass summary for sub-encoders (racy is fine)

static id hook_prce_sub(id self, SEL _cmd) {
    id enc = ((id(*)(id, SEL))orig_prce_sub)(self, _cmd);
    if (enc) {
        atomic_fetch_add(&g_encR, 1);
        es_add((void *)enc);
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)enc);
        if (st) strlcpy(st->pass, g_lastppass, sizeof st->pass);
        pthread_mutex_unlock(&g_esmu);
    }
    return enc;
}
static id hook_prce(id self, SEL _cmd, MTLRenderPassDescriptor *d) {
    id penc = ((id(*)(id, SEL, id))orig_prce)(self, _cmd, d);
    if (d) @try {
        id<MTLTexture> t = d.colorAttachments[0].texture;
        char lab[64]; lab[0] = 0;
        if (t) obj_label((id)t, lab, sizeof lab);
        snprintf(g_lastppass, sizeof g_lastppass, "c0 %lux%lu fmt%lu '%s'",
                 t ? (unsigned long)t.width : 0, t ? (unsigned long)t.height : 0,
                 t ? (unsigned long)t.pixelFormat : 0, lab);
    } @catch (...) {}
    if (penc && d && dgate()) log_pass(d, (void *)penc);
    return penc;
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

typedef struct { void *p; int flags; } RegEnt;   // PSO registry (defined below)
static RegEnt g_rpso[2048];
static int reg_get(RegEnt *tab, int n, void *p);
static _Atomic long g_traces;

static void hook_setrps(id self, SEL _cmd, id pso) {
    char lab[256]; obj_label(pso, lab, sizeof lab);
    if (g_peek) {
        // peek only pipelines built from the Limb FS (_SkinDamage) - the stock sprite
        // shaders also contain _RendererColor and would exhaust the peek budget
        int match = (lab[0] && strstr(lab, g_peek) != NULL) ||
                    (reg_get(g_rpso, 2048, (void *)pso) & 1) != 0;
        int was = 0;
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)self);
        if (st) { was = st->psoMatch; st->psoMatch = match; st->pso = (void *)pso; }
        pthread_mutex_unlock(&g_esmu);
        if (match && atomic_load(&g_traces) < 3000)
            logline("\"event\":\"limbBind\",\"enc\":\"%p\",\"pso\":\"%p\"",
                    (void *)self, (void *)pso);
        else if (was && !match && atomic_load(&g_traces) < 3000)
            logline("\"event\":\"limbUnbind\",\"enc\":\"%p\",\"next\":\"%s\"", (void *)self, lab);
    }
    if (dgate()) logline("\"event\":\"pso\",\"enc\":\"%p\",\"label\":\"%s\"", (void *)self, lab);
    ((void(*)(id, SEL, id))orig_setrps)(self, _cmd, pso);
}

// ── buffer-binding tracking (for peek) ───────────────────────────────────────

static IMP orig_setvb, orig_setvboff, orig_setvbytes, orig_setfb, orig_setfboff, orig_setfbytes;

static int trace_on(void *enc) {   // log state calls on encoders with the Limb PSO bound
    if (!g_peek) return 0;
    int m = 0;
    pthread_mutex_lock(&g_esmu);
    EncStat *st = es_find(enc);
    if (st) m = st->psoMatch;
    pthread_mutex_unlock(&g_esmu);
    return m && atomic_fetch_add(&g_traces, 1) < 3000;
}

static void hook_setvb(id self, SEL _cmd, id buf, NSUInteger off, NSUInteger idx) {
    if (g_peek && idx < PEEK_VB) {
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)self);
        if (st) { st->vb[idx] = (void *)buf; st->vboff[idx] = off;
                  if (idx < 2) st->vstashlen[idx] = 0; }
        pthread_mutex_unlock(&g_esmu);
    }
    if (trace_on((void *)self))
        logline("\"event\":\"tr\",\"enc\":\"%p\",\"c\":\"vb\",\"i\":%lu,\"nil\":%d,\"off\":%lu,\"len\":%lu",
                (void *)self, (unsigned long)idx, buf == nil,
                (unsigned long)off, buf ? (unsigned long)[(id<MTLBuffer>)buf length] : 0);
    ((void(*)(id, SEL, id, NSUInteger, NSUInteger))orig_setvb)(self, _cmd, buf, off, idx);
}
static void hook_setvboff(id self, SEL _cmd, NSUInteger off, NSUInteger idx) {
    if (g_peek && idx < PEEK_VB) {
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)self);
        if (st) st->vboff[idx] = off;
        pthread_mutex_unlock(&g_esmu);
    }
    ((void(*)(id, SEL, NSUInteger, NSUInteger))orig_setvboff)(self, _cmd, off, idx);
}
static void hook_setvbytes(id self, SEL _cmd, const void *p, NSUInteger len, NSUInteger idx) {
    if (g_peek && idx < 2 && p) {
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)self);
        if (st) { unsigned long n = len > 4096 ? 4096 : len;
                  memcpy(st->vstash[idx], p, n); st->vstashlen[idx] = n; st->vb[idx] = NULL; }
        pthread_mutex_unlock(&g_esmu);
    }
    if (trace_on((void *)self))
        logline("\"event\":\"tr\",\"enc\":\"%p\",\"c\":\"vbytes\",\"i\":%lu,\"len\":%lu",
                (void *)self, (unsigned long)idx, (unsigned long)len);
    ((void(*)(id, SEL, const void *, NSUInteger, NSUInteger))orig_setvbytes)(self, _cmd, p, len, idx);
}
static void hook_setfb(id self, SEL _cmd, id buf, NSUInteger off, NSUInteger idx) {
    if (g_peek && idx < 4) {
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)self);
        if (st) { st->fb[idx] = (void *)buf; st->fboff[idx] = off;
                  if (idx < 2) st->fstashlen[idx] = 0; }
        pthread_mutex_unlock(&g_esmu);
    }
    ((void(*)(id, SEL, id, NSUInteger, NSUInteger))orig_setfb)(self, _cmd, buf, off, idx);
}
static void hook_setfboff(id self, SEL _cmd, NSUInteger off, NSUInteger idx) {
    if (g_peek && idx < 4) {
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)self);
        if (st) st->fboff[idx] = off;
        pthread_mutex_unlock(&g_esmu);
    }
    ((void(*)(id, SEL, NSUInteger, NSUInteger))orig_setfboff)(self, _cmd, off, idx);
}
static IMP orig_setviewport, orig_setsref;
static void hook_setviewport(id self, SEL _cmd, MTLViewport v) {
    if (g_peek) {
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)self);
        if (st) { st->vpx = v.originX; st->vpy = v.originY; st->vpw = v.width; st->vph = v.height; }
        pthread_mutex_unlock(&g_esmu);
    }
    ((void(*)(id, SEL, MTLViewport))orig_setviewport)(self, _cmd, v);
}
static void hook_setsref(id self, SEL _cmd, uint32_t ref) {
    if (g_peek) {
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)self);
        if (st) st->stencilRef = ref;
        pthread_mutex_unlock(&g_esmu);
    }
    ((void(*)(id, SEL, uint32_t))orig_setsref)(self, _cmd, ref);
}

static IMP orig_setvbs, orig_setfbs;
static void hook_setvbs(id self, SEL _cmd, const id *bufs, const NSUInteger *offs, NSRange r) {
    if (g_peek && bufs && offs) {
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)self);
        if (st) for (NSUInteger k = 0; k < r.length; k++) {
            NSUInteger idx = r.location + k;
            if (idx < PEEK_VB) { st->vb[idx] = (void *)bufs[k]; st->vboff[idx] = offs[k];
                                 if (idx < 2) st->vstashlen[idx] = 0; }
        }
        pthread_mutex_unlock(&g_esmu);
    }
    ((void(*)(id, SEL, const id *, const NSUInteger *, NSRange))orig_setvbs)(self, _cmd, bufs, offs, r);
}
static void hook_setfbs(id self, SEL _cmd, const id *bufs, const NSUInteger *offs, NSRange r) {
    if (g_peek && bufs && offs) {
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)self);
        if (st) for (NSUInteger k = 0; k < r.length; k++) {
            NSUInteger idx = r.location + k;
            if (idx < 4) { st->fb[idx] = (void *)bufs[k]; st->fboff[idx] = offs[k];
                           if (idx < 2) st->fstashlen[idx] = 0; }
        }
        pthread_mutex_unlock(&g_esmu);
    }
    ((void(*)(id, SEL, const id *, const NSUInteger *, NSRange))orig_setfbs)(self, _cmd, bufs, offs, r);
}

static IMP orig_setftex;
static void hook_setftex(id self, SEL _cmd, id tex, NSUInteger idx) {
    if (trace_on((void *)self))
        logline("\"event\":\"tr\",\"enc\":\"%p\",\"c\":\"ftex\",\"i\":%lu,\"nil\":%d",
                (void *)self, (unsigned long)idx, tex == nil);
    ((void(*)(id, SEL, id, NSUInteger))orig_setftex)(self, _cmd, tex, idx);
}

static void hook_setfbytes(id self, SEL _cmd, const void *p, NSUInteger len, NSUInteger idx) {
    if (g_peek && idx < 2 && p) {
        pthread_mutex_lock(&g_esmu);
        EncStat *st = es_find((void *)self);
        if (st) { unsigned long n = len > 4096 ? 4096 : len;
                  memcpy(st->fstash[idx], p, n); st->fstashlen[idx] = n; st->fb[idx] = NULL; }
        pthread_mutex_unlock(&g_esmu);
    }
    ((void(*)(id, SEL, const void *, NSUInteger, NSUInteger))orig_setfbytes)(self, _cmd, p, len, idx);
}

// ── shader library / pipeline creation (are the converted shaders compiling?) ─
// Chain registry: library(source flags) -> function -> pipeline, so PSOs built from
// the converted Limb MSL are recognizable even when Unity leaves the PSO unlabeled.

#define FLAG_SKIN 1
#define FLAG_RCOL 2
static RegEnt g_rlib[256], g_rfn[1024];
static pthread_mutex_t g_regmu = PTHREAD_MUTEX_INITIALIZER;

static void reg_put(RegEnt *tab, int n, void *p, int flags) {
    if (!p || !flags) return;
    pthread_mutex_lock(&g_regmu);
    for (int i = 0; i < n; i++) if (tab[i].p == p || !tab[i].p) { tab[i].p = p; tab[i].flags = flags; break; }
    pthread_mutex_unlock(&g_regmu);
}
static int reg_get(RegEnt *tab, int n, void *p) {
    if (!p) return 0;
    int f = 0;
    pthread_mutex_lock(&g_regmu);
    for (int i = 0; i < n; i++) { if (!tab[i].p) break; if (tab[i].p == p) { f = tab[i].flags; break; } }
    pthread_mutex_unlock(&g_regmu);
    return f;
}

static IMP orig_newfn, orig_newfn_cv;
static id hook_newfn(id self, SEL _cmd, NSString *name) {
    id fn = ((id(*)(id, SEL, NSString *))orig_newfn)(self, _cmd, name);
    reg_put(g_rfn, 1024, (void *)fn, reg_get(g_rlib, 256, (void *)self));
    return fn;
}
static id hook_newfn_cv(id self, SEL _cmd, NSString *name, id cv, NSError **err) {
    id fn = ((id(*)(id, SEL, NSString *, id, NSError **))orig_newfn_cv)(self, _cmd, name, cv, err);
    reg_put(g_rfn, 1024, (void *)fn, reg_get(g_rlib, 256, (void *)self));
    return fn;
}
static pthread_once_t g_libswz_once = PTHREAD_ONCE_INIT;
static Class g_libcls;
static void libswz(void) {
    orig_newfn = swz(g_libcls, "newFunctionWithName:", (IMP)hook_newfn);
    orig_newfn_cv = swz(g_libcls, "newFunctionWithName:constantValues:error:", (IMP)hook_newfn_cv);
}

static void reg_pso(id pso, MTLRenderPipelineDescriptor *d) {
    @try {
        int f = reg_get(g_rfn, 1024, (void *)d.vertexFunction) |
                reg_get(g_rfn, 1024, (void *)d.fragmentFunction);
        if (f && pso) {
            reg_put(g_rpso, 2048, (void *)pso, f);
            char lab[256]; lab[0] = 0;
            if (d.label) jesc([d.label UTF8String], lab, sizeof lab);
            // dump the vertex descriptor: which buffer/offset/format feeds each attribute
            char vd[1024]; size_t o = 0; vd[0] = 0;
            MTLVertexDescriptor *v = d.vertexDescriptor;
            if (v) {
                for (int a = 0; a < 31 && o + 80 < sizeof vd; a++) {
                    MTLVertexAttributeDescriptor *ad = v.attributes[a];
                    if (!ad || ad.format == MTLVertexFormatInvalid) continue;
                    o += snprintf(vd + o, sizeof vd - o,
                                  "%s\"a%d\":{\"fmt\":%lu,\"off\":%lu,\"buf\":%lu}",
                                  o ? "," : "", a, (unsigned long)ad.format,
                                  (unsigned long)ad.offset, (unsigned long)ad.bufferIndex);
                }
                for (int b = 0; b < 31 && o + 80 < sizeof vd; b++) {
                    MTLVertexBufferLayoutDescriptor *ld = v.layouts[b];
                    if (!ld || ld.stride == 0) continue;
                    o += snprintf(vd + o, sizeof vd - o,
                                  "%s\"l%d\":{\"stride\":%lu,\"step\":%lu,\"rate\":%lu}",
                                  o ? "," : "", b, (unsigned long)ld.stride,
                                  (unsigned long)ld.stepFunction, (unsigned long)ld.stepRate);
                }
            }
            logline("\"event\":\"psoReg\",\"pso\":\"%p\",\"flags\":%d,\"label\":\"%s\",\"vdesc\":{%s}",
                    (void *)pso, f, lab, vd);
        }
    } @catch (...) {}
}

static IMP orig_newlib, orig_newpso, orig_newpso_refl;

static id hook_newlib(id self, SEL _cmd, NSString *src, id opts, NSError **err) {
    NSError *localErr = nil;
    if (!err) err = &localErr;
    id lib = ((id(*)(id, SEL, NSString *, id, NSError **))orig_newlib)(self, _cmd, src, opts, err);
    @try {
        const char *s = [src UTF8String];
        int skin = s && strstr(s, "_SkinDamage") != NULL;
        int rcol = s && strstr(s, "_RendererColor") != NULL;
        if (lib) {
            reg_put(g_rlib, 256, (void *)lib, (skin ? FLAG_SKIN : 0) | (rcol ? FLAG_RCOL : 0));
            g_libcls = object_getClass(lib);
            pthread_once(&g_libswz_once, libswz);
        }
        if (!lib || skin || rcol) {
            char e[512]; e[0] = 0;
            if (*err) jesc([[*err localizedDescription] UTF8String], e, sizeof e);
            logline("\"event\":\"newlib\",\"len\":%lu,\"skinDamage\":%d,\"rendColor\":%d,"
                    "\"ok\":%d,\"err\":\"%s\"", (unsigned long)[src length], skin, rcol,
                    lib != nil, e);
        }
    } @catch (...) {}
    return lib;
}
static id hook_newpso(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, NSError **err) {
    NSError *localErr = nil;
    if (!err) err = &localErr;
    id pso = ((id(*)(id, SEL, id, NSError **))orig_newpso)(self, _cmd, d, err);
    reg_pso(pso, d);
    if (!pso) @try {
        char lab[256], e[512]; lab[0] = e[0] = 0;
        if (d.label) jesc([d.label UTF8String], lab, sizeof lab);
        if (*err) jesc([[*err localizedDescription] UTF8String], e, sizeof e);
        logline("\"event\":\"psoFail\",\"label\":\"%s\",\"err\":\"%s\"", lab, e);
    } @catch (...) {}
    return pso;
}
static id hook_newpso_refl(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, NSUInteger opts,
                           void *refl, NSError **err) {
    NSError *localErr = nil;
    if (!err) err = &localErr;
    id pso = ((id(*)(id, SEL, id, NSUInteger, void *, NSError **))orig_newpso_refl)(
        self, _cmd, d, opts, refl, err);
    reg_pso(pso, d);
    if (!pso) @try {
        char lab[256], e[512]; lab[0] = e[0] = 0;
        if (d.label) jesc([d.label UTF8String], lab, sizeof lab);
        if (*err) jesc([[*err localizedDescription] UTF8String], e, sizeof e);
        logline("\"event\":\"psoFail\",\"label\":\"%s\",\"err\":\"%s\"", lab, e);
    } @catch (...) {}
    return pso;
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

        id<MTLCommandBuffer> cbp = [q commandBuffer];
        MTLRenderPassDescriptor *rp2 = [MTLRenderPassDescriptor renderPassDescriptor];
        rp2.colorAttachments[0].texture = tex;
        rp2.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp2.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        id pe = [cbp parallelRenderCommandEncoderWithDescriptor:rp2];
        Class PREC = object_getClass(pe);
        id sub = [(id<MTLParallelRenderCommandEncoder>)pe renderCommandEncoder];
        Class SUBC = object_getClass(sub);
        [(id<MTLRenderCommandEncoder>)sub endEncoding];
        [(id<MTLParallelRenderCommandEncoder>)pe endEncoding];

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
        orig_setvb     = swz(REC, "setVertexBuffer:offset:atIndex:", (IMP)hook_setvb);
        orig_setvboff  = swz(REC, "setVertexBufferOffset:atIndex:", (IMP)hook_setvboff);
        orig_setvbytes = swz(REC, "setVertexBytes:length:atIndex:", (IMP)hook_setvbytes);
        orig_setfb     = swz(REC, "setFragmentBuffer:offset:atIndex:", (IMP)hook_setfb);
        orig_setfboff  = swz(REC, "setFragmentBufferOffset:atIndex:", (IMP)hook_setfboff);
        orig_setfbytes = swz(REC, "setFragmentBytes:length:atIndex:", (IMP)hook_setfbytes);
        orig_setftex   = swz(REC, "setFragmentTexture:atIndex:", (IMP)hook_setftex);
        orig_setvbs    = swz(REC, "setVertexBuffers:offsets:withRange:", (IMP)hook_setvbs);
        orig_setfbs    = swz(REC, "setFragmentBuffers:offsets:withRange:", (IMP)hook_setfbs);
        orig_setviewport = swz(REC, "setViewport:", (IMP)hook_setviewport);
        orig_setsref     = swz(REC, "setStencilReferenceValue:", (IMP)hook_setsref);
        Class DEV = object_getClass((id)dev);
        orig_newlib = swz(DEV, "newLibraryWithSource:options:error:", (IMP)hook_newlib);
        orig_newpso = swz(DEV, "newRenderPipelineStateWithDescriptor:error:", (IMP)hook_newpso);
        orig_newpso_refl = swz(DEV, "newRenderPipelineStateWithDescriptor:options:reflection:error:", (IMP)hook_newpso_refl);
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

        Class CBC2 = CBC;
        orig_prce = swz(CBC2, "parallelRenderCommandEncoderWithDescriptor:", (IMP)hook_prce);
        orig_prce_sub = swz(PREC, "renderCommandEncoder", (IMP)hook_prce_sub);
        if (SUBC != REC)
            logline("\"event\":\"subclassDiffers\",\"sub\":\"%s\",\"rec\":\"%s\"",
                    class_getName(SUBC), class_getName(REC));

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
    if ((e = getenv("FRAMEPROF_PEEK")))          g_peek    = e;
    if ((e = getenv("FRAMEPROF_DETAIL_START")))  g_dstart  = atol(e);
    if ((e = getenv("FRAMEPROF_DETAIL_PERIOD"))) g_dperiod = atol(e);
    if ((e = getenv("FRAMEPROF_DETAIL_N")))      g_dn      = atol(e);
    @try { install(); } @catch (...) { logline("\"event\":\"installThrew\""); }
    pthread_t t; pthread_create(&t, NULL, heartbeat, NULL); pthread_detach(t);
    pthread_t g; pthread_create(&g, NULL, governor, NULL); pthread_detach(g);
}
