#!/usr/bin/env bash
#
# build.sh - build the Apple Silicon BepInEx detour fix into ./dist/
#
#   dist/libas_jit.dylib      universal native JIT-write helper (arm64 + x86_64, ad-hoc signed)
#   dist/AppleSiliconShim.dll  the Doorstop entrypoint shim (netstandard2.0, AnyCPU)
#
# Both go into the game's BepInEx/core/ at install time (see install.sh, TODO).
#
# Requirements:
#   - clang (Xcode command line tools)
#   - dotnet SDK (brew install dotnet)  + a BepInEx 5.4.23.x install to reference
#
# Usage:
#   ./build.sh --core <path-to/BepInEx/core>
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --core) CORE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CORE" ] || { echo "usage: $0 --core <path-to/BepInEx/core>" >&2; exit 2; }
[ -f "$CORE/MonoMod.RuntimeDetour.dll" ] || { echo "no MonoMod.RuntimeDetour.dll in $CORE" >&2; exit 2; }

DIST="$HERE/dist"
mkdir -p "$DIST"

echo "==> native helper (universal)"
clang -arch arm64 -arch x86_64 -dynamiclib -O2 \
      -o "$DIST/libas_jit.dylib" "$HERE/native/as_jit.c"
codesign -f -s - "$DIST/libas_jit.dylib"
echo "    $(lipo -archs "$DIST/libas_jit.dylib") - $(basename "$DIST/libas_jit.dylib")"

echo "==> managed shim"
dotnet build -c Release -p:CoreDir="$CORE" -o "$DIST" "$HERE/src/AppleSiliconShim.csproj" \
  | tail -1
echo "    -> $DIST/AppleSiliconShim.dll"

echo "done. artifacts in $DIST/"
