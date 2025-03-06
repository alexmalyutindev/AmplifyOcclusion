#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "BlurFunctions.hlsl"

struct Attributes
{
    float2 texcoord : TEXCOORD0;
    float4 positionOS : POSITION;
};

struct Varyings
{
    float2 uv : TEXCOORD0;
    float4 positionCS : SV_POSITION;
};

Varyings Vertex(Attributes input)
{
    Varyings output;
    output.uv = input.texcoord;
    output.positionCS = float4(input.positionOS.xy * 2.0f - 1.0f, 0.0f, 1.0f);

    #if UNITY_UV_STARTS_AT_TOP
    output.uv.y = 1.0f - output.uv.y;
    #endif

    return output;
}

half2 InitOcclusionDepth(Varyings input)
{
    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

    const half2 occlusionDepth = FetchOcclusionDepth(input.uv);
    return occlusionDepth.xy;
}

#if !defined(BLUR_FUNCTION)
#define BLUR_FUNCTION blur1D_1x
#endif

half4 Fragment(Varyings input) : SV_Target
{
    const half2 occlusionDepth = InitOcclusionDepth(input);
    #if defined(BLUR_DIRECTION_V)
    const half2 deltaUV = half2(0, _OcclusionDepth_TexelSize.y);
    #else
    const half2 deltaUV = half2(_OcclusionDepth_TexelSize.x, 0);
    #endif
    return BLUR_FUNCTION(input.uv, deltaUV, occlusionDepth);
}