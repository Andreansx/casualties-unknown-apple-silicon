using System;
using System.IO;
using System.Runtime.InteropServices;
using MonoMod.RuntimeDetour;

namespace AppleSiliconBepInEx
{
    /// <summary>
    /// IDetourNativePlatform for Apple Silicon (arm64 macOS).
    ///
    /// Trampoline encoding + allocation are delegated to the inner DetourNativeARMPlatform,
    /// whose AArch64 encoding (LDR X15,#8 ; BR X15 ; &lt;target&gt;) is already correct. The only
    /// thing we replace is the WRITE to the target code page:
    ///
    ///   Mono's JIT pages are MAP_JIT (mprotect -&gt; EACCES), and the per-thread JIT write-protect
    ///   toggle cannot be driven from managed code (it stops this managed code from executing).
    ///   So every write into a code page is routed through the native helper `as_jit_write`,
    ///   which performs unprotect -&gt; memcpy -&gt; reprotect -&gt; icache-flush in a single native call.
    ///
    /// MakeWritable/MakeExecutable become no-ops (the helper does its own W^X toggle per write).
    /// </summary>
    public sealed class AppleSiliconMonoPlatform : IDetourNativePlatform
    {
        private readonly IDetourNativePlatform _inner;
        // Trampoline sizes by DetourType index: Thumb, ThumbBX, AArch32, AArch32BX, AArch64.
        // On arm64 only index 4 (AArch64 = 16 bytes) is used; the rest are kept for completeness.
        private static readonly uint[] DetourSizes = { 8u, 12u, 8u, 12u, 16u };

        [DllImport("libc")] private static extern IntPtr dlopen(string path, int mode);
        [DllImport("libc")] private static extern void sys_icache_invalidate(IntPtr start, UIntPtr len);
        // Resolved from the dylib we dlopen below (RTLD_DEFAULT via __Internal).
        [DllImport("__Internal")] private static extern void as_jit_write(IntPtr dst, IntPtr src, UIntPtr len);

        public AppleSiliconMonoPlatform(IDetourNativePlatform inner, string helperDylibPath, string log = null)
        {
            _inner = inner;
            const int RTLD_NOW = 2, RTLD_GLOBAL = 8;
            IntPtr h = dlopen(helperDylibPath, RTLD_NOW | RTLD_GLOBAL);
            if (log != null)
                File.AppendAllText(log, $"[wrapper] dlopen({Path.GetFileName(helperDylibPath)}) = 0x{h.ToInt64():X}\n");
            if (h == IntPtr.Zero)
                throw new DllNotFoundException("could not dlopen JIT-write helper: " + helperDylibPath);
        }

        // No-ops: the native helper does its own W^X toggle around each write.
        public void MakeWritable(IntPtr src, uint size) { }
        public void MakeExecutable(IntPtr src, uint size) { }
        public void MakeReadWriteExecutable(IntPtr src, uint size) { }
        public void FlushICache(IntPtr src, uint size) => sys_icache_invalidate(src, (UIntPtr)size);

        // Generate the trampoline into a normal heap buffer (writable), then blit it into the
        // code page natively.
        public unsafe void Apply(NativeDetourData detour)
        {
            byte[] tmp = new byte[detour.Size];
            fixed (byte* p = tmp)
            {
                var scratch = new NativeDetourData
                {
                    Method = (IntPtr)p,
                    Target = detour.Target,
                    Type = detour.Type,
                    Size = detour.Size,
                    Extra = detour.Extra
                };
                _inner.Apply(scratch);                       // writes trampoline bytes into tmp
                as_jit_write(detour.Method, (IntPtr)p, (UIntPtr)detour.Size);
            }
        }

        // Copy is used both to back up original bytes (dst = heap) and to restore them
        // (dst = code page). Routing through as_jit_write is correct for both.
        public void Copy(IntPtr src, IntPtr dst, byte type)
        {
            uint len = type < DetourSizes.Length ? DetourSizes[type] : 16u;
            as_jit_write(dst, src, (UIntPtr)len);
        }

        public NativeDetourData Create(IntPtr from, IntPtr to, byte? type = null) => _inner.Create(from, to, type);
        public void Free(NativeDetourData detour) => _inner.Free(detour);
        public IntPtr MemAlloc(uint size) => _inner.MemAlloc(size);
        public void MemFree(IntPtr ptr) => _inner.MemFree(ptr);
    }
}
