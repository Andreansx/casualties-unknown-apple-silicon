// as_jit.c — Apple Silicon JIT-write helper for arm64 macOS.
//
// Why this exists:
//   Mono's JIT code lives in MAP_JIT pages under hardware W^X. Two consequences:
//     • mprotect() on those pages returns EACCES — you cannot add write permission.
//     • pthread_jit_write_protect_np() toggles a PER-THREAD switch that makes ALL of the
//       thread's JIT pages non-executable while writable. It therefore cannot be driven from
//       managed (JIT-compiled) code: the moment writing is enabled, the managed caller's own
//       code page stops executing.
//
//   So the whole unprotect -> copy -> reprotect -> icache-flush must happen inside ONE native
//   call that never returns to managed code mid-toggle. That is this function. It is the arm64
//   macOS equivalent of what MonoMod v25 (PR #241) added for CoreCLR; BepInEx 5 ships MonoMod
//   22.x, which predates it.

#include <pthread.h>
#include <libkern/OSCacheControl.h>
#include <string.h>
#include <stddef.h>

// Copy `len` bytes from src to dst, where dst may be a MAP_JIT code page.
// Safe for non-JIT dst too — the write-protect toggle only affects JIT pages.
__attribute__((visibility("default")))
void as_jit_write(void *dst, const void *src, size_t len)
{
    pthread_jit_write_protect_np(0);   // JIT pages: writable (this thread)
    memcpy(dst, src, len);
    pthread_jit_write_protect_np(1);   // JIT pages: executable again
    sys_icache_invalidate(dst, len);
}
