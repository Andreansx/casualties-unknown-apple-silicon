#!/bin/bash
# Fetch + build Unity's HLSLcc (DXBC -> Metal MSL translator, the same code path Unity's
# editor uses for Metal) and a tiny CLI around it. Produces ./hlslcc-cli.
set -euo pipefail
cd "$(dirname "$0")"

[ -d HLSLcc ] || git clone --depth 1 https://github.com/Unity-Technologies/HLSLcc.git HLSLcc
cp offline_main.cpp HLSLcc/
cd HLSLcc
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 . >/dev/null
cmake --build build -j8 >/dev/null
c++ -std=c++11 -O2 -Iinclude -Isrc/internal_includes -Isrc/cbstring -Isrc \
    offline_main.cpp -Lbuild -lhlslcc -Wl,-rpath,"$PWD/build" -o ../hlslcc-cli
cd ..
echo "built: $PWD/hlslcc-cli"
./hlslcc-cli 2>&1 | head -1 || true
