// Minimal CLI: DXBC file -> Metal MSL on stdout (Unity flavor).
//   hlslcc-cli <in.dxbc> [flagsHex]
#include "hlslcc.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>

class Refl : public HLSLccReflection
{
public:
    bool OnConstantBuffer(const std::string& name, size_t bufferSize, size_t memberCount) override
    {
        fprintf(stderr, "CB %s size=%zu members=%zu\n", name.c_str(), bufferSize, memberCount);
        return true;
    }
};

int main(int argc, char** argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <in.dxbc> [flagsHex]\n", argv[0]); return 2; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<char> buf(n);
    if (fread(buf.data(), 1, n, f) != (size_t)n) { fclose(f); return 2; }
    fclose(f);

    // Unity's Metal default flags (matched against 2022.3 donor output by diffing)
    unsigned int flags = HLSLCC_FLAG_TRANSLATE_MATRICES
                       | HLSLCC_FLAG_REMOVE_UNUSED_GLOBALS
                       | HLSLCC_FLAG_DISABLE_FASTMATH
                       | HLSLCC_FLAG_METAL_SHADOW_SAMPLER_LINEAR;
    if (argc > 2) flags = (unsigned int)strtoul(argv[2], nullptr, 16);

    GlExtensions ext = {0};
    GLSLCrossDependencyData deps;
    HLSLccSamplerPrecisionInfo prec;
    Refl refl;
    GLSLShader out;
    int ok = TranslateHLSLFromMem(buf.data(), flags, LANG_METAL, &ext, &deps, prec, refl, &out);
    if (!ok) { fprintf(stderr, "translate FAILED\n"); return 1; }
    fputs(out.sourceCode.c_str(), stdout);
    return 0;
}
