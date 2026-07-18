using System;
using System.IO;
using System.Reflection;
using MonoMod.Utils;
using MonoMod.RuntimeDetour;
using MonoMod.RuntimeDetour.Platforms;

namespace Doorstop
{
    /// <summary>
    /// Doorstop invokes Doorstop.Entrypoint.Start(). We shim in FRONT of BepInEx's own
    /// entrypoint: install an arm64-correct MonoMod detour platform, then hand off to the real
    /// BepInEx preloader.
    ///
    /// This MUST run before BepInEx.Preloader: HarmonyInteropFix (Preloader.Run, ~line 57)
    /// applies the first Harmony/MonoMod detour, long before any patcher/plugin Initialize().
    /// A BepInEx preloader *patcher* would therefore be too late — hence the Doorstop entrypoint
    /// override (set DOORSTOP_TARGET_ASSEMBLY to this assembly; see ../install.sh).
    /// </summary>
    internal static class Entrypoint
    {
        private static string _coreDir;

        public static void Start()
        {
            // core dir = directory this shim lives in (BepInEx/core)
            _coreDir = Path.GetDirectoryName(new Uri(typeof(Entrypoint).Assembly.CodeBase).LocalPath);
            AppDomain.CurrentDomain.AssemblyResolve += ResolveFromCore;

            string log = Path.Combine(_coreDir, "silicon_shim.log");
            try
            {
                ApplySiliconFix(log);
            }
            catch (Exception ex)
            {
                File.AppendAllText(log, "[shim] FIX FAILED:\n" + ex + "\n");
            }

            // Hand off to the real BepInEx preloader entrypoint (BepInEx.Preloader.dll also
            // exposes Doorstop.Entrypoint.Start()).
            var pre = Assembly.LoadFrom(Path.Combine(_coreDir, "BepInEx.Preloader.dll"));
            var t = pre.GetType("Doorstop.Entrypoint");
            var m = t.GetMethod("Start", BindingFlags.Public | BindingFlags.Static);
            m.Invoke(null, null);
        }

        private static void ApplySiliconFix(string log)
        {
            void W(string s) => File.AppendAllText(log, s + "\n");

            // ---- B1: bypassed, not "fixed" ----
            // We do NOT touch PlatformHelper.Current. BepInEx.Preloader.PlatformUtils.SetPlatform()
            // sets it itself, and it THROWS if we've locked it first. We override DetourHelper.Native
            // directly below, which bypasses the ARM-bit-based platform selection entirely — so the
            // (empirically observed) missing/late ARM bit no longer matters.
            // Read the private field, NOT the public getter — the getter locks on first access.
            var fCur = typeof(PlatformHelper).GetField("_current", BindingFlags.NonPublic | BindingFlags.Static);
            W("[shim] PlatformHelper._current (peeked, not locked): " + fCur.GetValue(null));

            // ---- B2: install an arm64 native platform with Apple W^X memory protection ----
            var arm = new DetourNativeARMPlatform();
            arm.ShouldFlushICache = false;                  // our wrapper flushes icache instead
            string helper = Path.Combine(_coreDir, "libas_jit.dylib");
            DetourHelper.Native = new AppleSiliconBepInEx.AppleSiliconMonoPlatform(arm, helper, log);
            W("[shim] DetourHelper.Native = " + DetourHelper.Native.GetType().Name);

            // ---- self-test: apply a real native detour and observe redirection ----
            try
            {
                bool ok = SelfTest.Run();
                W("[shim] SELF-TEST native detour: " + (ok ? "PASS (redirected)" : "FAIL (not redirected)"));
            }
            catch (Exception ex)
            {
                W("[shim] SELF-TEST threw: " + ex.GetType().Name + ": " + ex.Message);
            }

            // The self-test (or any MonoMod path) may have read PlatformHelper.Current and locked
            // it. BepInEx.Preloader.PlatformUtils.SetPlatform() sets Current later and throws if it
            // is locked — so release the lock. Safe: DetourHelper.Native is already installed and is
            // never re-consulted against PlatformHelper once non-null.
            var fLock = typeof(PlatformHelper).GetField("_currentLocked", BindingFlags.NonPublic | BindingFlags.Static);
            if (fLock != null)
            {
                fLock.SetValue(null, false);
                W("[shim] PlatformHelper lock released for BepInEx SetPlatform()");
            }
        }

        private static Assembly ResolveFromCore(object sender, ResolveEventArgs args)
        {
            try
            {
                var name = new AssemblyName(args.Name).Name;
                var p = Path.Combine(_coreDir, name + ".dll");
                return File.Exists(p) ? Assembly.LoadFrom(p) : null;
            }
            catch { return null; }
        }
    }
}
