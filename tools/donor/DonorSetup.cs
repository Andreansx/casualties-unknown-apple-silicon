// Donor-project automation for the Casualties: Unknown native Metal port.
// Run with: Unity -batchmode -quit -projectPath . -executeMethod DonorSetup.Setup
// then:     Unity -batchmode -quit -projectPath . -executeMethod DonorSetup.Build
using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public static class DonorSetup
{
    // The game's 40 stock shaders (from the UnityPy inventory sweep).
    static readonly string[] StockShaders = {
        "Hidden/Core/FallbackError",
        "Hidden/Light2D-Point",
        "Hidden/Light2D-Shape",
        "Hidden/Light2D-Shape-Volumetric",
        "Hidden/Light2d-Point-Volumetric",
        "Hidden/Shader Graph/FallbackError",
        "Hidden/Shadow2DShadowSprite",
        "Hidden/Shadow2DUnshadowGeometry",
        "Hidden/Shadow2DUnshadowSprite",
        "Hidden/ShadowProjected2D",
        "Hidden/Universal Render Pipeline/Bloom",
        "Hidden/Universal Render Pipeline/BokehDepthOfField",
        "Hidden/Universal Render Pipeline/CameraMotionBlur",
        "Hidden/Universal Render Pipeline/Debug/DebugReplacement",
        "Hidden/Universal Render Pipeline/Edge Adaptive Spatial Upsampling",
        "Hidden/Universal Render Pipeline/FallbackError",
        "Hidden/Universal Render Pipeline/FinalPost",
        "Hidden/Universal Render Pipeline/GaussianDepthOfField",
        "Hidden/Universal Render Pipeline/LensFlareDataDriven",
        "Hidden/Universal Render Pipeline/LutBuilderHdr",
        "Hidden/Universal Render Pipeline/LutBuilderLdr",
        "Hidden/Universal Render Pipeline/PaniniProjection",
        "Hidden/Universal Render Pipeline/Sampling",
        "Hidden/Universal Render Pipeline/Scaling Setup",
        "Hidden/Universal Render Pipeline/Stop NaN",
        "Hidden/Universal Render Pipeline/SubpixelMorphologicalAntialiasing",
        "Hidden/Universal Render Pipeline/TemporalAA",
        "Hidden/Universal Render Pipeline/UberPost",
        "Hidden/Universal/BlitHDROverlay",
        "Hidden/Universal/CoreBlit",
        "Hidden/Universal/CoreBlitColorAndDepth",
        "Hidden/Universal/HDRDebugView",
        "TextMeshPro/Bitmap",
        "TextMeshPro/Distance Field",
        "TextMeshPro/Mobile/Distance Field",
        "TextMeshPro/Sprite",
        "Universal Render Pipeline/2D/Sprite-Lit-Default",
        "Universal Render Pipeline/2D/Sprite-Unlit-Default",
        "Universal Render Pipeline/Particles/Unlit",
        "Universal Render Pipeline/Unlit",
    };

    public static void Setup()
    {
        // 1. TMP essential resources (brings the TextMeshPro/* shaders into Assets/)
        var tmpPkg = "Packages/com.unity.textmeshpro/Package Resources/TMP Essential Resources.unitypackage";
        if (File.Exists(tmpPkg) && !Directory.Exists("Assets/TextMesh Pro"))
        {
            AssetDatabase.ImportPackage(tmpPkg, false);
            Debug.Log("[DonorSetup] imported TMP Essential Resources");
        }

        // 2. URP pipeline asset with a 2D renderer (matches the game: URP-2D)
        if (AssetDatabase.LoadAssetAtPath<UniversalRenderPipelineAsset>("Assets/URP2D.asset") == null)
        {
            var rendererData = ScriptableObject.CreateInstance<Renderer2DData>();
            AssetDatabase.CreateAsset(rendererData, "Assets/Renderer2D.asset");
            var rp = UniversalRenderPipelineAsset.Create(rendererData);
            AssetDatabase.CreateAsset(rp, "Assets/URP2D.asset");
            Debug.Log("[DonorSetup] created URP2D pipeline asset");
        }
        var pipeline = AssetDatabase.LoadAssetAtPath<UniversalRenderPipelineAsset>("Assets/URP2D.asset");
        GraphicsSettings.defaultRenderPipeline = pipeline;
        QualitySettings.renderPipeline = pipeline;
        AssetDatabase.SaveAssets();

        // 3. Always Included Shaders = the 40 stock shaders (forces ALL keyword variants
        //    into the build, unstripped)
        var gsObj = AssetDatabase.LoadAllAssetsAtPath("ProjectSettings/GraphicsSettings.asset")[0];
        var so = new SerializedObject(gsObj);
        var arr = so.FindProperty("m_AlwaysIncludedShaders");
        int missing = 0;
        arr.ClearArray();
        for (int i = 0; i < StockShaders.Length; i++)
        {
            var sh = Shader.Find(StockShaders[i]);
            if (sh == null) { Debug.LogError("[DonorSetup] MISSING shader: " + StockShaders[i]); missing++; continue; }
            arr.InsertArrayElementAtIndex(arr.arraySize);
            arr.GetArrayElementAtIndex(arr.arraySize - 1).objectReferenceValue = sh;
        }
        so.ApplyModifiedProperties();
        AssetDatabase.SaveAssets();
        Debug.Log($"[DonorSetup] always-included: {arr.arraySize} shaders, {missing} missing");
        if (missing > 0) EditorApplication.Exit(2);
    }

    public static void Build()
    {
        var report = UnityEditor.BuildPipeline.BuildPlayer(new BuildPlayerOptions
        {
            scenes = new[] { "Assets/Scenes/SampleScene.unity" },
            locationPathName = "Build/Donor.app",
            target = BuildTarget.StandaloneOSX,
            options = BuildOptions.None,
        });
        Debug.Log($"[DonorSetup] build result: {report.summary.result}, " +
                  $"{report.summary.totalErrors} errors, {report.summary.outputPath}");
        if (report.summary.result != UnityEditor.Build.Reporting.BuildResult.Succeeded)
            EditorApplication.Exit(3);
    }
}
