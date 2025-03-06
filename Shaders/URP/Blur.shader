Shader "Hidden/Amplify Occlusion/URP/Blur"
{
    HLSLINCLUDE
    #include "BlurFunctions.hlsl"
    #pragma vertex Vertex
    #pragma fragment Fragment
    #pragma target 3.0
    // #pragma exclude_renderers gles d3d11_9x n3ds

    #pragma multi_compile _BLUR_RADIUS_1 _BLUR_RADIUS_2 _BLUR_RADIUS_3 _BLUR_RADIUS_4

    #if defined(_BLUR_RADIUS_1)
    #define BLUR_FUNCTION blur1D_1x
    #elif defined(_BLUR_RADIUS_2)
    #define BLUR_FUNCTION blur1D_2x
    #elif defined(_BLUR_RADIUS_3)
    #define BLUR_FUNCTION blur1D_3x
    #elif defined(_BLUR_RADIUS_4)
    #define BLUR_FUNCTION blur1D_4x
    #endif
    
    ENDHLSL

    SubShader
    {
        ZTest Always
        Cull Off
        ZWrite Off

        Pass
        {
            Name "BilateralBlurHorizontal"

            HLSLPROGRAM
            #include "BlurPasses.hlsl"
            ENDHLSL
        }
        Pass
        {
            Name "BilateralBlurVertical"

            HLSLPROGRAM
            #define BLUR_DIRECTION_V
            #include "BlurPasses.hlsl"
            ENDHLSL
        }
    }
}