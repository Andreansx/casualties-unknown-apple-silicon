using System.Reflection;
using System.Runtime.CompilerServices;
using MonoMod.RuntimeDetour;

namespace Doorstop
{
    /// <summary>
    /// Applies one real method-&gt;method Detour through the full RuntimeDetour pipeline
    /// (the same path HarmonyInteropFix uses) and verifies the call is redirected. Exercises
    /// DetourHelper.Runtime's Mono self-test AND DetourHelper.Native's code-page writes end to end.
    /// A PASS in silicon_shim.log is the proof the arm64 W^X detour path works.
    /// </summary>
    internal static class SelfTest
    {
        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int Original() => 111;

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int Replacement() => 222;

        public static bool Run()
        {
            var from = typeof(SelfTest).GetMethod("Original", BindingFlags.NonPublic | BindingFlags.Static);
            var to = typeof(SelfTest).GetMethod("Replacement", BindingFlags.NonPublic | BindingFlags.Static);
            var d = new Detour(from, to);
            try
            {
                return Original() == 222;   // redirected -> Replacement()
            }
            finally
            {
                d.Dispose();
            }
        }
    }
}
