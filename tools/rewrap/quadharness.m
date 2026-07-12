// quadharness.m — standalone Metal test of the converted "Shader Graphs/Limb" sprite shader.
// Draws a quad with POSITION/TEXCOORD0/COLOR0 exactly like Unity's Metal ABI would, with
// identity matrices, white textures, and vertex color (1,1,1,1). If the converted shader is
// healthy the readback is opaque non-zero pixels; a discard/zero-alpha readback reproduces
// the invisible-Expie bug in isolation.
// build: xcrun clang -fobjc-arc -framework Metal -framework Foundation quadharness.m -o quadharness
// run:   ./quadharness <vs.metal> <fs.metal>
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

static NSString *readFile(const char *p) {
    return [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:p]
                                     encoding:NSUTF8StringEncoding error:nil];
}

int main(int argc, const char **argv) {
@autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: quadharness vs.metal fs.metal\n"); return 2; }
    const int W = 64, H = 64;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *err = nil;
    MTLCompileOptions *opt = [MTLCompileOptions new];
    id<MTLLibrary> vlib = [dev newLibraryWithSource:readFile(argv[1]) options:opt error:&err];
    if (!vlib) { fprintf(stderr, "VS compile FAILED: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLLibrary> flib = [dev newLibraryWithSource:readFile(argv[2]) options:opt error:&err];
    if (!flib) { fprintf(stderr, "FS compile FAILED: %s\n", err.localizedDescription.UTF8String); return 1; }

    id<MTLFunction> vfn = [vlib newFunctionWithName:@"xlatMtlMain"];
    MTLFunctionConstantValues *fc = [MTLFunctionConstantValues new];
    uint32_t mask = 0; [fc setConstantValue:&mask type:MTLDataTypeUInt atIndex:1];
    id<MTLFunction> ffn = [flib newFunctionWithName:@"xlatMtlMain" constantValues:fc error:&err];
    if (!vfn || !ffn) { fprintf(stderr, "fn resolve failed: %s\n", err.localizedDescription.UTF8String); return 1; }

    // vertex layout: attribute(0) POSITION float3, attribute(1) TEXCOORD0 float4, attribute(2) COLOR0 float4
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat3; vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 30;
    vd.attributes[1].format = MTLVertexFormatFloat4; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 30;
    vd.attributes[2].format = MTLVertexFormatFloat4; vd.attributes[2].offset = 28; vd.attributes[2].bufferIndex = 30;
    vd.layouts[30].stride = 44;

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = vfn; pd.fragmentFunction = ffn; pd.vertexDescriptor = vd;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!pso) { fprintf(stderr, "pipeline FAILED: %s\n", err.localizedDescription.UTF8String); return 1; }
    printf("pipeline OK\n");

    // quad in clip space (identity matrices), uv 0..1, color 1
    float quad[6][11];
    float pos[6][2] = {{-0.8f,-0.8f},{0.8f,-0.8f},{-0.8f,0.8f},{0.8f,-0.8f},{0.8f,0.8f},{-0.8f,0.8f}};
    float uv[6][2]  = {{0,0},{1,0},{0,1},{1,0},{1,1},{0,1}};
    for (int i = 0; i < 6; i++) {
        quad[i][0]=pos[i][0]; quad[i][1]=pos[i][1]; quad[i][2]=0;                 // POSITION
        quad[i][3]=uv[i][0]; quad[i][4]=uv[i][1]; quad[i][5]=0; quad[i][6]=0;     // TEXCOORD0
        quad[i][7]=1; quad[i][8]=1; quad[i][9]=1; quad[i][10]=1;                  // COLOR0
    }
    id<MTLBuffer> vb = [dev newBufferWithBytes:quad length:sizeof quad options:0];

    // constant buffers: generous 4KB each, zero-filled, then identity matrices + select 1.0 fields
    float vg[1024]; for (int i = 0; i < 1024; i++) vg[i] = 1.0f;        // VGlobals: _ProjectionParams @0, MatrixVP @16(f), pad[52] @ (4+64+52*4? no: floats)
    // VGlobals layout (floats): _ProjectionParams[4] @0, MatrixVP 16f @4, pad_$Globals_80[53] @20
    vg[0]=1; vg[1]=1; vg[2]=0; vg[3]=1;                       // ProjectionParams
    int vpo = getenv("VP_OFF") ? atoi(getenv("VP_OFF")) : 4;   // float offset of MatrixVP
    for (int i = 0; i < 16; i++) vg[vpo+i] = 0;
    vg[vpo+0]=1; vg[vpo+5]=1; vg[vpo+10]=1; vg[vpo+15]=1;      // MatrixVP = I
    for (int i = 0; i < 4; i++) vg[20 + 52*4 + i] = 1.0f;     // pad[52] = white (_RendererColor)
    id<MTLBuffer> vgb = [dev newBufferWithBytes:vg length:sizeof vg options:0];

    float upd[1024]; for (int i = 0; i < 1024; i++) upd[i] = 0;
    // VS UnityPerDraw: ObjectToWorld @0 (16f). FS variant reads WorldToObject @16f after pad[4] (16f).
    upd[0]=1; upd[5]=1; upd[10]=1; upd[15]=1;                 // ObjectToWorld = I
    upd[16+0]=1; upd[16+5]=1; upd[16+10]=1; upd[16+15]=1;     // WorldToObject = I (FS layout)
    id<MTLBuffer> updb = [dev newBufferWithBytes:upd length:sizeof upd options:0];

    float fg[1024]; for (int i = 0; i < 1024; i++) fg[i] = 1.0f;
    // FGlobals: _ScaledScreenParams @0, _GlobalMipBias @4, _TimeParameters @8(approx), _ProjectionParams @12...
    fg[0]=W; fg[1]=H; fg[2]=1.0f/W+1; fg[3]=1.0f/H+1;
    fg[12]=1; fg[13]=1; fg[15]=1;
    id<MTLBuffer> fgb = [dev newBufferWithBytes:fg length:sizeof fg options:0];

    float upm[1024] = {0};
    upm[20]=0.25f; upm[21]=0.25f; upm[22]=4; upm[23]=4;   // _MainTex_TexelSize        // UnityPerMaterial: damage/pain factors all 0 -> pure _MainTex
    id<MTLBuffer> upmb = [dev newBufferWithBytes:upm length:sizeof upm options:0];

    // white textures everywhere
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> white = [dev newTextureWithDescriptor:td];
    uint8_t wpx[4*4*4]; memset(wpx, 0xFF, sizeof wpx);
    [white replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:wpx bytesPerRow:16];

    id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];

    // render target
    MTLTextureDescriptor *rtd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
    rtd.usage = MTLTextureUsageRenderTarget; rtd.storageMode = MTLStorageModeShared;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:rtd];

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = rt;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:pso];
    [enc setVertexBuffer:vb offset:0 atIndex:30];
    [enc setVertexBuffer:vgb offset:0 atIndex:0];
    [enc setVertexBuffer:updb offset:0 atIndex:1];
    [enc setFragmentBuffer:fgb offset:0 atIndex:0];
    [enc setFragmentBuffer:updb offset:0 atIndex:1];
    [enc setFragmentBuffer:upmb offset:0 atIndex:2];
    for (int t = 0; t < 8; t++) { [enc setFragmentTexture:white atIndex:t]; [enc setFragmentSamplerState:smp atIndex:t]; }
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.error) { fprintf(stderr, "GPU error: %s\n", cb.error.localizedDescription.UTF8String); return 1; }

    uint8_t *out = malloc(W*H*4);
    [rt getBytes:out bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    // stats
    long sum[4] = {0,0,0,0}; int nonzero = 0;
    for (int i = 0; i < W*H; i++) {
        for (int c = 0; c < 4; c++) sum[c] += out[i*4+c];
        if (out[i*4+3]) nonzero++;
    }
    int ci = (H/2*W + W/2)*4;
    printf("center px RGBA = %d %d %d %d\n", out[ci], out[ci+1], out[ci+2], out[ci+3]);
    printf("mean RGBA = %.1f %.1f %.1f %.1f, alpha>0 pixels: %d/%d\n",
           sum[0]/(float)(W*H), sum[1]/(float)(W*H), sum[2]/(float)(W*H), sum[3]/(float)(W*H), nonzero, W*H);
    return 0;
}
}
