// Amplify Occlusion 2 - Robust Ambient Occlusion for Unity
// Copyright (c) Amplify Creations, Lda <info@amplify.pt>

#ifndef AMPLIFY_AO_GTAO
#define AMPLIFY_AO_GTAO

#define PIXEL_RADIUS_LIMIT ( 512 )
#define DEPTH_EPSILON (1e-6)
#define INTENSITY_THRESHOLD (1e-4)

#if defined( SHADER_API_MOBILE )
#define DEPTH_SCALE 16376.0
#else
#define DEPTH_SCALE 65504.0
#endif

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"
#include "Common.hlsl"

half4x4 _AO_CameraViewLeft;
half4x4 _AO_CameraViewRight;

float4 _AO_Target_TexelSize;

half4 _AO_UVToView;
half _AO_Bias;
half _AO_ThicknessDecay;
half4 _AO_Source_TexelSize;

float2 _AO_FadeParams;
float4 _AO_FadeValues;
half4 _AO_Levels;
half4 _AO_FadeToTint;
half _AO_PowExponent;

inline half ComputeDistanceFade(const half distance)
{
    return saturate(max(0.0, distance - _AO_FadeParams.x) * _AO_FadeParams.y);
}

float _AO_TemporalMotionSensibility;
half _AO_TemporalDirections;
half _AO_TemporalOffsets;
half _AO_HalfProjScale;
half _AO_Radius;
float _AO_BufDepthToLinearEye;

#define NORMALS_NONE ( 0 )
#define NORMALS_CAMERA ( 1 )
#define NORMALS_GBUFFER ( 2 )
#define NORMALS_GBUFFER_OCTA_ENCODED ( 3 )

float SampleSceneDepth_LOD0(float2 uv)
{
    return SAMPLE_TEXTURE2D_LOD(_CameraDepthTexture, sampler_CameraDepthTexture, uv, 0).x;
}

// (LocalPosition, DeviceDepth01)
inline half4 ConvertDepth(const half2 uv, const half deviceDepth)
{
    half linearDepth = LinearEyeDepth(deviceDepth, _ZBufferParams);
    half3 localPosition = half3((uv * _AO_UVToView.xy + _AO_UVToView.zw) * linearDepth, linearDepth);

    #if defined(UNITY_REVERSED_Z)
    const half sampledDepth = 1.0 - deviceDepth;
    #else
    const half sampledDepth = aSampledDepth;
    #endif

    return half4(localPosition, sampledDepth);
}

inline half4 FetchPosition0(const half2 aUV)
{
    const half sampledDepth = SampleSceneDepth_LOD0(aUV);

    return ConvertDepth(aUV, sampledDepth);
}


inline half4 FetchPosition(const half2 aUV, half aLOD)
{
    // TODO: Use Depth mip chain.
    const half sampledDepth = SampleSceneDepth_LOD0(aUV);

    return ConvertDepth(aUV, sampledDepth);
}


inline half3 FetchNormalVS(const half2 uv, const uint normalSource)
{
    if (normalSource == NORMALS_CAMERA ||
        normalSource == NORMALS_GBUFFER ||
        normalSource == NORMALS_GBUFFER_OCTA_ENCODED
    )
    {
        // NOTE: ViewSpace normal
        half3 normalWS = SampleSceneNormals(uv);
        half3 normalVS = mul((half3x3)_AO_CameraViewLeft, normalWS);
        normalVS.z = -normalVS.z;
        return normalVS;
    }
    else
    {
        // NOTE: Reconstruct normals from Depth.
        const float3 c = FetchPosition0(uv).xyz;
        const float3 r = FetchPosition0(uv + half2(+1.0, 0.0) * _AO_Target_TexelSize.xy).xyz;
        const float3 l = FetchPosition0(uv + half2(-1.0, 0.0) * _AO_Target_TexelSize.xy).xyz;
        const float3 t = FetchPosition0(uv + half2(0.0, +1.0) * _AO_Target_TexelSize.xy).xyz;
        const float3 b = FetchPosition0(uv + half2(0.0, -1.0) * _AO_Target_TexelSize.xy).xyz;
        const float3 vr = (r - c), vl = (c - l), vt = (t - c), vb = (c - b);
        const float3 min_horiz = (dot(vr, vr) < dot(vl, vl)) ? vr : vl;
        const float3 min_vert = (dot(vt, vt) < dot(vb, vb)) ? vt : vb;
        const float3 normalScreenSpace = normalize(cross(min_horiz, min_vert));

        return half3(-normalScreenSpace.x, -normalScreenSpace.y, -normalScreenSpace.z);
    }
}


inline void GetFadeIntensity_Radius_Thickness(
    const half aLinearDepth,
    out half outIntensity,
    out half outRadius,
    out half outThicknessDecay
)
{
    // Calc distance fade parameters
    const half3 intensity_radius_thickness = lerp(
        half3(_AO_Levels.a, _AO_Radius, _AO_ThicknessDecay),
        _AO_FadeValues.xyw,
        ComputeDistanceFade(aLinearDepth).xxx
    );

    outIntensity = intensity_radius_thickness.x;
    outRadius = intensity_radius_thickness.y;
    outThicknessDecay = intensity_radius_thickness.z;
}


inline half2 SampleStepsDynamicDepthMips(
    const int aStepCount,
    const half2 aScreenPos,
    const half2 aSlideDir_x_TexelSize,
    const half aStepRadius,
    const half aInitialRayStep,
    const half aTwoOverSquaredRadius,
    const half aThicknessDecay,
    const half3 aVpos,
    const half3 aVdir
)
{
    half2 h = half2(-1.0, -1.0);

    UNITY_UNROLL
    for (int s = 0; s < aStepCount; s++)
    {
        const half2 uvOffset = aSlideDir_x_TexelSize * max(aStepRadius * ((half)s + aInitialRayStep), 1.0 + (half)s);

        const half4 uv = aScreenPos.xyxy + float4(+uvOffset.xy, -uvOffset.xy);

        // ds.v / ||ds||
        // dt.v / ||dt||
        half3 ds, dt;

        if (s == 0)
        {
            ds = FetchPosition0(uv.xy).xyz;
            dt = FetchPosition0(uv.zw).xyz;
        }
        else
        {
            const half2 offsetPixels = _AO_Source_TexelSize.zw * uvOffset.xy;
            const half distancePixels = max(offsetPixels.x, offsetPixels.y);
            const half mipLevel = max(log2(distancePixels) * 0.70 - 2.0, 0.0);

            ds = FetchPosition(uv.xy, mipLevel).xyz;
            dt = FetchPosition(uv.zw, mipLevel).xyz;
        }

        ds = ds - aVpos.xyz;
        dt = dt - aVpos.xyz;

        const half2 dsdt = half2(dot(ds, ds), dot(dt, dt));
        const half2 rLength = rsqrt(dsdt + (0.0001).xx);

        half2 H = half2(dot(ds, aVdir), dot(dt, aVdir)) * rLength.xy;

        // "Conservative attenuation" - s2016_pbs_activision_occlusion - Slide 103
        // "Our attenuation function is a linear blending from 1 to 0 from a given,
        //  large enough distance, to the maximum search radius." GTAO - Page 4
        const half2 attn = saturate(dsdt.xy * aTwoOverSquaredRadius.xx);

        H = lerp(H, h, attn);

        h.xy = (H.xy > h.xy) ? H.xy : lerp(H.xy, h.xy, aThicknessDecay.xx);
    }

    return h;
}


inline half2 SampleSteps(
    const int aStepCount,
    const half2 aScreenPos,
    const half2 aSlideDir_x_TexelSize,
    const half aStepRadius,
    const half aInitialRayStep,
    const half aTwoOverSquaredRadius,
    const half aThicknessDecay,
    const half3 aVpos,
    const half3 aVdir
)
{
    half2 h = half2(-1.0, -1.0);

    UNITY_UNROLL
    for (int s = 0; s < aStepCount; s++)
    {
        const half2 uvOffset = aSlideDir_x_TexelSize * max(aStepRadius * ((half)s + aInitialRayStep), 1.0 + (half)s);

        // s2016_pbs_activision_occlusion - Slide 54

        const half4 uv = aScreenPos.xyxy + float4(+uvOffset.xy, -uvOffset.xy);

        // ds.v / ||ds||
        half3 ds = FetchPosition0(uv.xy).xyz - aVpos.xyz;

        // dt.v / ||dt||
        half3 dt = FetchPosition0(uv.zw).xyz - aVpos.xyz;

        const half2 dsdt = half2(dot(ds, ds), dot(dt, dt));
        const half2 rLength = rsqrt(dsdt + (0.0001).xx);

        half2 H = half2(dot(ds, aVdir), dot(dt, aVdir)) * rLength.xy;

        // "Conservative attenuation" - s2016_pbs_activision_occlusion - Slide 103
        // "Our attenuation function is a linear blending from 1 to 0 from a given,
        //  large enough distance, to the maximum search radius." GTAO - Page 4
        const half2 attn = saturate(dsdt.xy * aTwoOverSquaredRadius.xx);

        H = lerp(H, h, attn);

        h.xy = (H.xy > h.xy) ? H.xy : lerp(H.xy, h.xy, aThicknessDecay.xx);
    }

    return h;
}


void GetGTAO(
    const float2 uv,
    const bool useDynamicDepthMips,
    const int directionCount,
    const int stepCount,
    const int normalSource,
    out half outDepth,
    out half4 outRGBA
)
{
    const half2 screenPos = uv;

    const half2 depthUVoffset = half2(0.25, 0.25) * _AO_Target_TexelSize.xy;
    // Avoids occluded horizontal and vertical bands when using half resolution depth sampling.

    const half2 sampleUVdepth = screenPos - depthUVoffset;

    const half sampledDepth = SampleSceneDepth_LOD0(sampleUVdepth);

    const half4 vpos = ConvertDepth(sampleUVdepth, sampledDepth);

    half intensity, radius, thicknessDecay;
    GetFadeIntensity_Radius_Thickness(vpos.z, intensity, radius, thicknessDecay);

    #if defined(UNITY_REVERSED_Z)
    if (sampledDepth <= DEPTH_EPSILON || intensity < INTENSITY_THRESHOLD)
    #else
    if((sampledDepth >= (1.0 - DEPTH_EPSILON)) || (intensity < INTENSITY_THRESHOLD))
    #endif
    {
        outDepth = HALF_MAX;
        outRGBA = half4((1.0).xxxx);

        return;
    }

    const half3 vnormal = FetchNormalVS(screenPos - depthUVoffset, normalSource);

    const half3 vdir = normalize((0).xxx - vpos.xyz);

    const half vdirXYDot = dot(vdir.xy, vdir.xy);

    const half radiusToScreen = radius * _AO_HalfProjScale;
    const half screenRadius = max(min(radiusToScreen / vpos.z, PIXEL_RADIUS_LIMIT), (half)stepCount);

    const half twoOverSquaredRadius = 2.0 / (radius * radius);

    const half stepRadius = screenRadius / ((half)stepCount + 1.0);

    half noiseSpatialOffsets, noiseSpatialDirections;
    GetSpatialDirections_Offsets_JimenezNoise(
        screenPos,
        _AO_Target_TexelSize.zw,
        noiseSpatialOffsets,
        noiseSpatialDirections
    );

    noiseSpatialDirections += _AO_TemporalDirections;

    const half initialRayStep = frac(noiseSpatialOffsets + _AO_TemporalOffsets);

    const half piOver_directionCount = PI / (half)directionCount;
    const half noiseSpatialDirections_x_piOver_directionCount = noiseSpatialDirections * piOver_directionCount;

    half occlusionAcc = 0.0;

    for (int dirCnt = 0; dirCnt < directionCount; dirCnt++)
    {
        const half angle = (half)dirCnt * piOver_directionCount + noiseSpatialDirections_x_piOver_directionCount;

        const half2 cos_sin = half2(cos(angle), sin(angle));

        const half3 sliceDir = half3(cos_sin.xy, 0.0);

        half wallDarkeningCorrection = dot(vnormal, cross(vdir, sliceDir)) * vdirXYDot;
        wallDarkeningCorrection = wallDarkeningCorrection * wallDarkeningCorrection;

        const half2 slideDir_x_TexelSize = sliceDir.xy * _AO_Target_TexelSize.xy;

        half2 h;

        if (useDynamicDepthMips == true)
        {
            h = SampleStepsDynamicDepthMips(
                stepCount,
                screenPos,
                slideDir_x_TexelSize,
                stepRadius,
                initialRayStep,
                twoOverSquaredRadius,
                thicknessDecay,
                vpos.xyz,
                vdir
            );
        }
        else
        {
            h = SampleSteps(
                stepCount,
                screenPos,
                slideDir_x_TexelSize,
                stepRadius,
                initialRayStep,
                twoOverSquaredRadius,
                thicknessDecay,
                vpos.xyz,
                vdir
            );
        }

        // "Project (and normalize) the normal to the slice plane for the integration" - s2016_pbs_activision_occlusion - Slide 62
        const half3 normalSlicePlane = normalize(cross(sliceDir, vdir));
        const half3 tangent = cross(vdir, normalSlicePlane);

        // Gram-Schmidt process
        // https://en.wikipedia.org/wiki/Gram-Schmidt_process
        const half3 normalProjected = vnormal - normalSlicePlane * dot(vnormal, normalSlicePlane);
        // There is no need to divide by ||np|| as np is normalized

        const half projLength = length(normalProjected) + 0.0001;
        const half cos_gamma = clamp(dot(normalProjected, vdir /*w0*/) / projLength, -1.0, 1.0);
        // cos() = a.b / ( ||a|| * ||b|| )
        const half gamma = -sign(dot(normalProjected, tangent)) * acos(cos_gamma);

        h = acos(clamp(h, -1.0, 1.0));

        // "We have to clamp them with the normal hemisphere" - s2016_pbs_activision_occlusion - Slide 58
        h.x = gamma + max(-h.x - gamma, -HALF_PI);
        h.y = gamma + min(+h.y - gamma, +HALF_PI);

        const half sin_gamma = sin(gamma);
        const half2 h2 = 2.0 * h;

        const half2 innerIntegral = (-cos(h2 - gamma) + cos_gamma + h2 * sin_gamma);

        // "Multiply each slice contribution by the length of the projected normal" - s2016_pbs_activision_occlusion - Slide 62
        occlusionAcc += (projLength + wallDarkeningCorrection) * 0.25 * (innerIntegral.x + innerIntegral.y + _AO_Bias);
    }

    occlusionAcc /= (half)directionCount;

    const half outAO = saturate(occlusionAcc);

    outRGBA = half4((1).xxx, outAO);

    outDepth = DEPTH_SCALE * Linear01Depth(sampledDepth, _ZBufferParams);
}

#endif
