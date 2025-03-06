Shader "Hidden/Amplify Occlusion/URP/Occlusion"
{
    SubShader
    {
        ZTest Always
        Cull Off
        ZWrite Off

        Pass
        {
            Name "Occlusion"

            HLSLPROGRAM
            #pragma vertex Vertex
            #pragma fragment Fragment
            #pragma target 3.0

            #pragma multi_compile _LOW_QUALITY _MEDIUM_QUALITY _HIGH_QUALITY _VERYHIGH_QUALITY

            #include "GTAO.hlsl"

            #if defined(_LOW_QUALITY)
            #define DIRECTTION_COUNT 2
            #define SAMPLE_COUNT 4
            #elif defined(_MEDIUM_QUALITY)
            #define DIRECTTION_COUNT 2
            #define SAMPLE_COUNT 6
            #elif defined(_HIGH_QUALITY)
            #define DIRECTTION_COUNT 3
            #define SAMPLE_COUNT 8
            #elif defined(_VERYHIGH_QUALITY)
            #define DIRECTTION_COUNT 4
            #define SAMPLE_COUNT 10
            #endif

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

            half4 GTAO(
                const float2 uv,
                const bool useDynamicDepthMips,
                const int directionCount,
                const int sampleCount,
                const int normalSource
            )
            {
                half outDepth;
                half4 outRGBA;

                GetGTAO(
                    uv,
                    useDynamicDepthMips,
                    directionCount,
                    sampleCount / 2,
                    normalSource,
                    outDepth,
                    outRGBA
                );

                return half4(outRGBA.a, outDepth, 0, 0);
            }

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

            half4 Fragment(Varyings input) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                // TODO: Add Depths mips support!
                return GTAO(
                    input.uv,
                    false,
                    DIRECTTION_COUNT,
                    SAMPLE_COUNT,
                    NORMALS_CAMERA
                );
            }
            ENDHLSL
        }

        // TODO: Upsampling 
    }
}