// shim.m — D3DMetal shader-harvest shim (ROADMAP Path 3-lite, step 1)  [LEAN build]
//
// Injected via DYLD_INSERT_LIBRARIES into the x86_64 wine/game process launched by
// tools/harvest-shaders.sh. It dumps every AIR metallib D3DMetal generates from the game's
// DXBC — the translated Metal shaders — plus a JSONL manifest of what fired.
//
// WHY PURE C / NO FRAMEWORK LINKAGE (this is load-bearing, do not "clean up"):
// An earlier version linked Metal.framework + Foundation.framework. DYLD_INSERT_LIBRARIES
// loads the shim (and thus those frameworks) VERY EARLY — during wine's preloader stage,
// before ntdll reserves the low Windows address space. That early framework load stole
// wine's low memory ("preloader: failed to reserve range 0x10000-0x110000") and the game
// crashed 3/3 (execute-fault at a fixed Windows address), EVEN with zero swizzling. Loading
// Metal LATE (when D3DMetal itself inits, after wine is set up) is fine — proven by running
// the game with MTL_CAPTURE_ENABLED=1 and no shim.
//
// So this shim links NOTHING heavy: just libSystem + libobjc + libdispatch + dl. It stays
// completely inert until a background poll sees Metal already loaded in-process
// (dlopen(Metal, RTLD_NOLOAD) != NULL == D3DMetal has initialized and wine is up). Only then
// does it touch Metal — via dlsym'd MTLCreateSystemDefaultDevice + ObjC-runtime swizzling —
// which is the safe, late window. No __interpose (that needs Metal symbols at link → early
// load). Everything is @try/guarded: a harvest failure must never take down the game.
//
// Build: tools/harvest/build-shim.sh (universal arm64+x86_64). Frame capture is intentionally
// NOT done here (MTL_CAPTURE_ENABLED + any shim destabilizes the game); capture the clean way
// with a no-shim run + Xcode attach (see harvest-shaders.sh notes).

#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdarg.h>
#import <string.h>
#import <unistd.h>
#import <sys/stat.h>

// ── minimal ObjC-runtime helpers (no Foundation) ─────────────────────────────

typedef id (*msg_t)(id, SEL);
static const char *cstr(id obj, const char *selname) {
    // [obj <selname>] where the result is a C string accessor (UTF8String / fileSystemRepresentation)
    if (!obj) return NULL;
    SEL s = sel_registerName(selname);
    if (!class_respondsToSelector(object_getClass(obj), s)) return NULL;
    typedef const char *(*f)(id, SEL);
    return ((f)objc_msgSend)(obj, s);
}

// ── config / plumbing ────────────────────────────────────────────────────────

static const char *harvest_dir(void) {
    static char dir[1024];
    static int init = 0;
    if (!init) {
        const char *d = getenv("HARVEST_DIR");
        snprintf(dir, sizeof dir, "%s", d ? d : "/tmp/d3dm-harvest");
        char libs[1100]; snprintf(libs, sizeof libs, "%s/libs", dir);
        char cmd[2300]; snprintf(cmd, sizeof cmd, "%s", dir);
        mkdir(dir, 0755); mkdir(libs, 0755);
        init = 1;
    }
    return dir;
}

static pthread_mutex_t g_log = PTHREAD_MUTEX_INITIALIZER;

// Append a raw JSON object line. `body` must be the inside of the braces (no braces).
static void logline(const char *fmt, ...) {
    char path[1200]; snprintf(path, sizeof path, "%s/manifest.jsonl", harvest_dir());
    pthread_mutex_lock(&g_log);
    FILE *f = fopen(path, "a");
    if (f) {
        fputc('{', f);
        va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
        fputs("}\n", f);
        fclose(f);
    }
    pthread_mutex_unlock(&g_log);
}

// JSON-escape a C string into out (best-effort; enough for shader/function names & paths).
static void jesc(const char *in, char *out, size_t n) {
    size_t o = 0;
    if (!in) { if (n) out[0] = 0; return; }
    for (size_t i = 0; in[i] && o + 2 < n; i++) {
        unsigned char c = in[i];
        if (c == '"' || c == '\\') { out[o++] = '\\'; out[o++] = c; }
        else if (c == '\n') { out[o++] = '\\'; if (o+1<n) out[o++]='n'; }
        else if (c < 0x20) { /* skip control */ }
        else out[o++] = c;
    }
    out[o < n ? o : n-1] = 0;
}

static _Atomic int g_idx = 0;

// Write `len` bytes to libs/<name>-NNNN.<ext>; return the leaf name via `leaf`.
static void dump_bytes(const char *stem, const char *ext, const void *buf, size_t len,
                       char *leaf, size_t leafn) {
    int idx = atomic_fetch_add(&g_idx, 1);
    snprintf(leaf, leafn, "%s-%04d.%s", stem, idx, ext);
    char path[1400]; snprintf(path, sizeof path, "%s/libs/%s", harvest_dir(), leaf);
    FILE *f = fopen(path, "wb");
    if (f) { if (buf && len) fwrite(buf, 1, len, f); fclose(f); }
}

// ── pipeline correlation tables (opt-in, HARVEST_HOOK_PSO) ───────────────────
// Map each translated shader from its dumped metallib → the MTLLibrary it became → the
// MTLFunctions taken from it → the MTLRenderPipelineStates built with them. That lets us name
// which render pipelines in a frame are the 4 custom post-fx (their fragment function is the
// 20/13/8/5-sample shader we identified). Small fixed tables; pointer identity is enough.
typedef struct { const void *ptr; char leaf[64]; } Ent;
static Ent g_lib[512]; static _Atomic int g_nlib = 0;   // library ptr -> metallib leaf
static Ent g_fn[1024]; static _Atomic int g_nfn  = 0;   // function ptr -> metallib leaf
static pthread_mutex_t g_tab = PTHREAD_MUTEX_INITIALIZER;
static void tab_put(Ent *t, _Atomic int *n, const void *p, const char *leaf) {
    pthread_mutex_lock(&g_tab);
    int i = atomic_load(n);
    if (i < 512) { t[i].ptr = p; snprintf(t[i].leaf, sizeof t[i].leaf, "%s", leaf); atomic_store(n, i+1); }
    pthread_mutex_unlock(&g_tab);
}
static const char *tab_get(Ent *t, _Atomic int *n, const void *p) {
    const char *r = NULL;
    pthread_mutex_lock(&g_tab);
    for (int i = atomic_load(n)-1; i >= 0; i--) if (t[i].ptr == p) { r = t[i].leaf; break; }
    pthread_mutex_unlock(&g_tab);
    return r;
}

static IMP orig_newfn, orig_newfn_ce;     // library newFunctionWithName: variants
static void install_on_library(Class libcls);   // fwd

// library.newFunctionWithName: -> record function ptr -> its library's metallib leaf
static id hook_newfn(id self, SEL _cmd, id name) {
    typedef id (*f)(id, SEL, id); id fn = ((f)orig_newfn)(self, _cmd, name);
    const char *leaf = tab_get(g_lib, &g_nlib, self);
    if (fn && leaf) tab_put(g_fn, &g_nfn, fn, leaf);
    return fn;
}
static id hook_newfn_ce(id self, SEL _cmd, id name, id cv, id *err) {
    typedef id (*f)(id, SEL, id, id, id*); id fn = ((f)orig_newfn_ce)(self, _cmd, name, cv, err);
    const char *leaf = tab_get(g_lib, &g_nlib, self);
    if (fn && leaf) tab_put(g_fn, &g_nfn, fn, leaf);
    return fn;
}

// device.newRenderPipelineStateWithDescriptor: -> log which metallib its fragment fn came from
static IMP orig_rps, orig_rps_opt;
static void log_pso(id desc) {
    id ff = ((id(*)(id,SEL))objc_msgSend)(desc, sel_registerName("fragmentFunction"));
    id vf = ((id(*)(id,SEL))objc_msgSend)(desc, sel_registerName("vertexFunction"));
    const char *fleaf = ff ? tab_get(g_fn, &g_nfn, ff) : NULL;
    const char *vleaf = vf ? tab_get(g_fn, &g_nfn, vf) : NULL;
    logline("\"event\":\"renderPSO\",\"fragmentLib\":\"%s\",\"vertexLib\":\"%s\"",
            fleaf ? fleaf : "?", vleaf ? vleaf : "?");
}
static id hook_rps(id self, SEL _cmd, id desc, id *err) {
    log_pso(desc); typedef id (*f)(id,SEL,id,id*); return ((f)orig_rps)(self,_cmd,desc,err);
}
static id hook_rps_opt(id self, SEL _cmd, id desc, unsigned long opt, id *refl, id *err) {
    log_pso(desc); typedef id (*f)(id,SEL,id,unsigned long,id*,id*);
    return ((f)orig_rps_opt)(self,_cmd,desc,opt,refl,err);
}

// ── the swizzled library-creation hooks (dump the translated shader, call through) ──

static _Atomic int g_reentry = 0;

// dispatch_data_create_map is in libSystem; declare it (dispatch/data.h has it, but be explicit).
extern dispatch_data_t dispatch_data_create_map(dispatch_data_t, const void **, size_t *);

static IMP orig_data, orig_file, orig_url, orig_source;
static int g_hook_pso = 0;   // set from HARVEST_HOOK_PSO in install_on_class

static id hook_data(id self, SEL _cmd, dispatch_data_t data, id *err) {
    char leaf[128]; leaf[0] = 0;
    if (atomic_fetch_add(&g_reentry, 1) == 0) {
        const void *buf = NULL; size_t len = 0;
        dispatch_data_t map = data ? dispatch_data_create_map(data, &buf, &len) : NULL;
        if (buf && len) {
            dump_bytes("data", "metallib", buf, len, leaf, sizeof leaf);
            logline("\"event\":\"newLibraryWithData\",\"file\":\"%s\",\"size\":%zu", leaf, len);
        }
        if (map) dispatch_release(map);
    }
    atomic_fetch_sub(&g_reentry, 1);
    typedef id (*f)(id, SEL, dispatch_data_t, id *);
    id lib = ((f)orig_data)(self, _cmd, data, err);
    // Correlate this library object with its dumped metallib, and make sure its class's
    // newFunctionWithName: is hooked so we can trace functions → pipelines.
    if (g_hook_pso && lib && leaf[0]) {
        tab_put(g_lib, &g_nlib, lib, leaf);
        install_on_library(object_getClass(lib));
    }
    return lib;
}

static void dump_file(const char *tag, const char *path) {
    if (!path) return;
    FILE *f = fopen(path, "rb");
    if (!f) { logline("\"event\":\"%s\",\"src\":\"?\",\"note\":\"unreadable\"", tag); return; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    void *buf = n > 0 ? malloc(n) : NULL;
    if (buf) { size_t got = fread(buf, 1, n, f); char leaf[128];
        dump_bytes("file", "metallib", buf, got, leaf, sizeof leaf);
        char e[1024]; jesc(path, e, sizeof e);
        logline("\"event\":\"%s\",\"src\":\"%s\",\"file\":\"%s\",\"size\":%zu", tag, e, leaf, got);
        free(buf); }
    fclose(f);
}

static id hook_file(id self, SEL _cmd, id path, id *err) {
    if (atomic_fetch_add(&g_reentry, 1) == 0) dump_file("newLibraryWithFile", cstr(path, "fileSystemRepresentation"));
    atomic_fetch_sub(&g_reentry, 1);
    typedef id (*f)(id, SEL, id, id *); return ((f)orig_file)(self, _cmd, path, err);
}

static id hook_url(id self, SEL _cmd, id url, id *err) {
    if (atomic_fetch_add(&g_reentry, 1) == 0) {
        id p = url ? ((msg_t)objc_msgSend)(url, sel_registerName("path")) : NULL;
        dump_file("newLibraryWithURL", cstr(p, "fileSystemRepresentation"));
    }
    atomic_fetch_sub(&g_reentry, 1);
    typedef id (*f)(id, SEL, id, id *); return ((f)orig_url)(self, _cmd, url, err);
}

// The jackpot if D3DMetal ever compiles MSL source (it normally emits AIR, but hook anyway).
static id hook_source(id self, SEL _cmd, id src, id opts, id *err) {
    if (atomic_fetch_add(&g_reentry, 1) == 0) {
        const char *s = cstr(src, "UTF8String");
        if (s) { char leaf[128]; dump_bytes("source", "metal", s, strlen(s), leaf, sizeof leaf);
            logline("\"event\":\"newLibraryWithSource\",\"file\":\"%s\",\"size\":%zu", leaf, strlen(s)); }
    }
    atomic_fetch_sub(&g_reentry, 1);
    typedef id (*f)(id, SEL, id, id, id *); return ((f)orig_source)(self, _cmd, src, opts, err);
}

// ── swizzle install ──────────────────────────────────────────────────────────

static IMP swz(Class c, const char *sel, IMP hook) {
    SEL s = sel_registerName(sel);
    Method m = class_getInstanceMethod(c, s);
    if (!m) { logline("\"event\":\"swizzleMiss\",\"sel\":\"%s\"", sel); return NULL; }
    return method_setImplementation(m, hook);
}

// Swizzle a concrete MTLLibrary class's newFunctionWithName: variants (once per class), so we
// can trace which functions came from which dumped metallib. Called lazily from hook_data.
static void install_on_library(Class libcls) {
    static Class done[16]; static int ndone = 0;
    for (int i = 0; i < ndone; i++) if (done[i] == libcls) return;
    if (ndone < 16) done[ndone++] = libcls;
    if (!orig_newfn)    orig_newfn    = swz(libcls, "newFunctionWithName:", (IMP)hook_newfn);
    if (!orig_newfn_ce) orig_newfn_ce = swz(libcls, "newFunctionWithName:constantValues:error:", (IMP)hook_newfn_ce);
    logline("\"event\":\"installedLibrary\",\"class\":\"%s\"", class_getName(libcls));
}

static void install_on_class(Class c) {
    static Class done = NULL;
    if (c == done) return;
    done = c;
    g_hook_pso = (getenv("HARVEST_HOOK_PSO") != NULL);
    logline("\"event\":\"device\",\"class\":\"%s\",\"pso\":%d", class_getName(c), g_hook_pso);
    orig_data = swz(c, "newLibraryWithData:error:", (IMP)hook_data);
    orig_file = swz(c, "newLibraryWithFile:error:", (IMP)hook_file);
    orig_url  = swz(c, "newLibraryWithURL:error:",  (IMP)hook_url);
    orig_source = swz(c, "newLibraryWithSource:options:error:", (IMP)hook_source);
    if (g_hook_pso) {
        orig_rps     = swz(c, "newRenderPipelineStateWithDescriptor:error:", (IMP)hook_rps);
        orig_rps_opt = swz(c, "newRenderPipelineStateWithDescriptor:options:reflection:error:", (IMP)hook_rps_opt);
    }
    logline("\"event\":\"installed\",\"data\":%d,\"file\":%d,\"url\":%d,\"source\":%d,\"rps\":%d",
            orig_data!=NULL, orig_file!=NULL, orig_url!=NULL, orig_source!=NULL, orig_rps!=NULL);
}

// ── optional: write a real Xcode `.gputrace` frame capture (HARVEST_CAPTURE=1) ──
// Pure ObjC-runtime calls — MTLCaptureManager / MTLCaptureDescriptor / NSString / NSURL are
// all loaded by the time Metal is up, so we reach them by class name without linking anything.
// Requires MTL_CAPTURE_ENABLED=1 in the environment (set by harvest-shaders.sh CAPTURE=1).
// Runs WITHOUT swizzling (capture-only mode) so it can't perturb D3DMetal's library creation.
#define MTLCaptureDestinationGPUTraceDocument 2

static void capture_once(id dev, const char *outpath) {
    Class MgrCls = objc_getClass("MTLCaptureManager");
    Class DescCls = objc_getClass("MTLCaptureDescriptor");
    Class NSStr = objc_getClass("NSString");
    Class NSURL = objc_getClass("NSURL");
    if (!MgrCls || !DescCls || !NSStr || !NSURL) { logline("\"event\":\"captureNoClasses\""); return; }
    SEL shared = sel_registerName("sharedCaptureManager");
    id mgr = ((id(*)(id,SEL))objc_msgSend)((id)MgrCls, shared);
    long sup = ((long(*)(id,SEL,long))objc_msgSend)(mgr, sel_registerName("supportsDestination:"),
                                                    MTLCaptureDestinationGPUTraceDocument);
    id desc = ((id(*)(id,SEL))objc_msgSend)(
                ((id(*)(id,SEL))objc_msgSend)((id)DescCls, sel_registerName("alloc")),
                sel_registerName("init"));
    ((void(*)(id,SEL,id))objc_msgSend)(desc, sel_registerName("setCaptureObject:"), dev);
    ((void(*)(id,SEL,long))objc_msgSend)(desc, sel_registerName("setDestination:"),
                                         MTLCaptureDestinationGPUTraceDocument);
    id nspath = ((id(*)(id,SEL,const char*))objc_msgSend)((id)NSStr,
                    sel_registerName("stringWithUTF8String:"), outpath);
    id url = ((id(*)(id,SEL,id))objc_msgSend)((id)NSURL, sel_registerName("fileURLWithPath:"), nspath);
    ((void(*)(id,SEL,id))objc_msgSend)(desc, sel_registerName("setOutputURL:"), url);
    id err = NULL;
    long ok = ((long(*)(id,SEL,id,id*))objc_msgSend)(mgr,
                    sel_registerName("startCaptureWithDescriptor:error:"), desc, &err);
    logline("\"event\":\"capture\",\"supported\":%ld,\"ok\":%ld,\"out\":\"%s\"", sup, ok, outpath);
    if (ok) {
        usleep(300 * 1000);   // ~36 frames at 120fps — spans several full frames
        ((void(*)(id,SEL))objc_msgSend)(mgr, sel_registerName("stopCapture"));
        logline("\"event\":\"captureDone\",\"out\":\"%s\"", outpath);
    }
}

// Auto-capture once ~12s after engage (gives the game time to reach steady-state rendering
// where the always-on post-fx — ScreenPass, AberrationShader — are bound), and also on demand
// whenever a `trigger` file appears in HARVEST_DIR.
static void capture_loop(id dev) {
    char trig[1200]; snprintf(trig, sizeof trig, "%s/trigger", harvest_dir());
    int n = 0;
    for (int i = 0; ; i++) {
        int fire = (i == 48);                                   // ~12s auto-shot
        if (access(trig, F_OK) == 0) { fire = 1; unlink(trig); }
        if (fire) {
            char out[1300]; snprintf(out, sizeof out, "%s/frame-%02d.gputrace", harvest_dir(), n++);
            capture_once(dev, out);
        }
        usleep(250 * 1000);
    }
}

// ── late engage: poll until Metal is loaded, then grab the device (swizzle and/or capture) ──

static void *engage(void *arg) {
    (void)arg;
    const char *METAL = "/System/Library/Frameworks/Metal.framework/Metal";
    for (int i = 0; i < 240; i++) {          // up to ~60s
        void *h = dlopen(METAL, RTLD_NOLOAD); // non-NULL only once Metal is already loaded
        if (h) {
            id (*create)(void) = (id(*)(void))dlsym(h, "MTLCreateSystemDefaultDevice");
            if (create) {
                id dev = create();            // safe now: Metal up, wine address space set
                if (dev) {
                    // Capture-only mode (HARVEST_CAPTURE + HARVEST_CAPTURE_ONLY): don't swizzle,
                    // just record a .gputrace — mirrors the stable "MTL_CAPTURE_ENABLED, no
                    // library hooks" configuration.
                    if (getenv("HARVEST_CAPTURE_ONLY") == NULL)
                        install_on_class(object_getClass(dev));
                    if (getenv("HARVEST_CAPTURE") != NULL) capture_loop(dev);   // never returns
                    return NULL;
                }
            }
        }
        usleep(250 * 1000);
    }
    logline("\"event\":\"engageTimeout\"");
    return NULL;
}

__attribute__((constructor)) static void init(void) {
    // Constructor must be FEATHERWEIGHT — it runs in every process in the launch chain,
    // including wine's preloader. Just note we loaded and spawn the late-engage poller.
    const char *pn = getprogname();
    logline("\"event\":\"shimLoaded\",\"proc\":\"%s\",\"pid\":%d", pn ? pn : "?", getpid());
    if (getenv("HARVEST_DISABLE") != NULL) return;
    pthread_t t; pthread_create(&t, NULL, engage, NULL); pthread_detach(t);
}
