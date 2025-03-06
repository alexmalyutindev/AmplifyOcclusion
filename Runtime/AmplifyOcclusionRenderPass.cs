using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace AmplifyOcclusion
{
    public class AmplifyOcclusionRenderPass : ScriptableRenderPass, IDisposable
    {
        private const string ScreenSpaceOcclusionTexture = "_ScreenSpaceOcclusionTexture";
        private static readonly int ScreenSpaceOcclusionTextureId = Shader.PropertyToID(ScreenSpaceOcclusionTexture);

        private const string AmbientOcclusionParamName = "_AmbientOcclusionParam";
        private static readonly int AmbientOcclusionParamID = Shader.PropertyToID(AmbientOcclusionParamName);

        private readonly AmplifyOcclusionRenderFeature.Settings _settings;
        private Material _occlusion;
        private Material _blur;

        private RTHandle _gtaoBuffer;
        private RTHandle _gtoaTempBuffer0;
        private RTHandle _gtoaTempBuffer1;

        public AmplifyOcclusionRenderPass(AmplifyOcclusionRenderFeature.Settings settings)
        {
            _settings = settings;
            profilingSampler = new ProfilingSampler("AmplifyOcclusion");
            ConfigureInput(ScriptableRenderPassInput.Depth | ScriptableRenderPassInput.Normal);
        }

        public void Setup(Material occlusion, Material blur)
        {
            _occlusion = occlusion;
            _blur = blur;
        }

        public override void Configure(CommandBuffer cmd, RenderTextureDescriptor cameraTextureDescriptor)
        {
            var width = cameraTextureDescriptor.width;
            var height = cameraTextureDescriptor.height;

            var desc = new RenderTextureDescriptor(width, height)
            {
                sRGB = false,
                colorFormat = RenderTextureFormat.RGHalf,
            };
            RenderingUtils.ReAllocateIfNeeded(
                ref _gtaoBuffer,
                desc,
                name: ScreenSpaceOcclusionTexture,
                wrapMode: TextureWrapMode.Clamp
            );
            
            if (_settings.Downsample)
            {
                desc.width /= 2;
                desc.height /= 2;
                RenderingUtils.ReAllocateIfNeeded(
                    ref _gtoaTempBuffer0,
                    desc,
                    name: "_GTAO_Temp0",
                    wrapMode: TextureWrapMode.Clamp
                );
                RenderingUtils.ReAllocateIfNeeded(
                    ref _gtoaTempBuffer1,
                    desc,
                    name: "_GTAO_Temp1",
                    wrapMode: TextureWrapMode.Clamp
                );
            }
            else
            {
                RenderingUtils.ReAllocateIfNeeded(
                    ref _gtoaTempBuffer0,
                    desc,
                    name: "_GTAO_Temp0",
                    wrapMode: TextureWrapMode.Clamp
                );
                _gtoaTempBuffer1?.Release();
            }
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var quality = _settings.SampleCount;
            CoreUtils.SetKeyword(_occlusion, "_LOW_QUALITY", quality == SampleCountLevel.Low);
            CoreUtils.SetKeyword(_occlusion, "_MEDIUM_QUALITY", quality == SampleCountLevel.Medium);
            CoreUtils.SetKeyword(_occlusion, "_HIGH_QUALITY", quality == SampleCountLevel.High);
            CoreUtils.SetKeyword(_occlusion, "_VERYHIGH_QUALITY", quality == SampleCountLevel.VeryHigh);

            var blurRadius = _settings.BlurRadius;
            CoreUtils.SetKeyword(_blur, "_BLUR_RADIUS_1", blurRadius == 1);
            CoreUtils.SetKeyword(_blur, "_BLUR_RADIUS_2", blurRadius == 2);
            CoreUtils.SetKeyword(_blur, "_BLUR_RADIUS_3", blurRadius == 3);
            CoreUtils.SetKeyword(_blur, "_BLUR_RADIUS_4", blurRadius == 4);
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            // TODO: Downsample support!
            var cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, profilingSampler))
            {
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                var target = !_settings.Downsample ? _gtaoBuffer : _gtoaTempBuffer0;
                var blurTarget = !_settings.Downsample ? _gtoaTempBuffer0 : _gtoaTempBuffer1;
                
                var camera = renderingData.cameraData.camera;
                var targetRT = target.rt;

                cmd.SetGlobalFloat(PropertyID._AO_Radius, _settings.Radius);
                cmd.SetGlobalFloat(PropertyID._AO_PowExponent, _settings.PowerExponent);
                cmd.SetGlobalFloat(PropertyID._AO_Bias, _settings.Bias * _settings.Bias);
                cmd.SetGlobalFloat(PropertyID._AO_HalfProjScale, GetHalfProjScale(camera, targetRT));

                var tint = _settings.Tint;
                tint.a = _settings.Intensity;
                cmd.SetGlobalColor(PropertyID._AO_Levels, tint);

                float invThickness = (1.0f - _settings.Thickness);
                cmd.SetGlobalFloat(PropertyID._AO_ThicknessDecay, (1.0f - invThickness * invThickness) * 0.98f);
                cmd.SetGlobalVector(PropertyID._AO_UVToView, GetUVToView(camera, targetRT));

                cmd.SetGlobalMatrix(PropertyID._AO_CameraViewLeft, camera.worldToCameraMatrix);
                cmd.SetGlobalVector(PropertyID._AO_Target_TexelSize, GetTexelSize(targetRT));

                // Distance Fade
                if (_settings.FadeEnabled)
                {
                    var fadeStart = Mathf.Max(0.0f, _settings.FadeStart);
                    var fadeLength = Mathf.Max(0.01f, _settings.FadeLength);

                    float rcpFadeLength = 1.0f / fadeLength;

                    cmd.SetGlobalVector(PropertyID._AO_FadeParams, new Vector2(fadeStart, rcpFadeLength));
                    float invFadeThickness = 1.0f - _settings.FadeToThickness;
                    cmd.SetGlobalVector(
                        PropertyID._AO_FadeValues,
                        new Vector4(
                            _settings.FadeToIntensity,
                            _settings.FadeToRadius,
                            _settings.FadeToPowerExponent,
                            (1.0f - invFadeThickness * invFadeThickness) * 0.98f
                        )
                    );
                    var fadeToTint = _settings.FadeToTint;
                    fadeToTint.a = 0.0f;
                    cmd.SetGlobalColor(PropertyID._AO_FadeToTint, fadeToTint);
                }
                else
                {
                    cmd.SetGlobalVector(PropertyID._AO_FadeParams, new Vector2(0.0f, 0.0f));
                }

                cmd.BeginSample("Compute");
                {
                    cmd.Blit(null, target, _occlusion, 0);
                }
                cmd.EndSample("Compute");

                if (_settings.BlurEnabled)
                {
                    cmd.BeginSample("Blur");

                    float oneOverDepthScale = 1.0f / 65504.0f; // 65504.0f max half float
                    if (GraphicsSettings.HasShaderDefine(Graphics.activeTier, BuiltinShaderDefine.SHADER_API_MOBILE))
                    {
                        // using 16376.0 for DepthScale for mobile due to precision issues
                        oneOverDepthScale = 1.0f / 16376.0f;
                    }

                    float AO_BufDepthToLinearEye = camera.farClipPlane * oneOverDepthScale;
                    float AO_BlurSharpness = _settings.BlurSharpness * 100.0f * AO_BufDepthToLinearEye;
                    cmd.SetGlobalFloat(PropertyID._AO_BlurSharpness, AO_BlurSharpness);
                    cmd.SetGlobalFloat(PropertyID._AO_BufDepthToLinearEye, AO_BufDepthToLinearEye);

                    for (int i = 0; i < _settings.BlurPasses; i++)
                    {
                        cmd.SetGlobalTexture("_OcclusionDepth", target);
                        cmd.Blit(target, blurTarget, _blur, 0);
                        cmd.SetGlobalTexture("_OcclusionDepth", blurTarget);
                        cmd.Blit(blurTarget, target, _blur, 1);
                    }

                    cmd.EndSample("Blur");
                }

                if (_settings.Downsample)
                {
                    cmd.BeginSample("Upsample");
                    cmd.SetGlobalTexture("_AO_CurrOcclusionDepth", target);
                    cmd.Blit(target, _gtaoBuffer, _occlusion, 1);
                    cmd.EndSample("Upsample");
                }
                
                // Set the global SSAO Params
                cmd.SetGlobalTexture(ScreenSpaceOcclusionTextureId, _gtaoBuffer);
                cmd.SetGlobalVector(
                    AmbientOcclusionParamID,
                    new Vector4(_settings.Intensity, 0f, 0f, _settings.DirectLightIntensity)
                );
                CoreUtils.SetKeyword(cmd, ShaderKeywordStrings.ScreenSpaceOcclusion, true);
            }

            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            CommandBufferPool.Release(cmd);
        }

        private float GetHalfProjScale(Camera camera, RenderTexture target)
        {
            float projScale;
            if (camera.orthographic)
            {
                projScale = target.height / camera.orthographicSize;
            }
            else
            {
                float fovRad = camera.fieldOfView * Mathf.Deg2Rad;
                projScale = target.height / (Mathf.Tan(fovRad * 0.5f) * 2.0f);
            }

            projScale *= 0.5f;
            return projScale;
        }

        private Vector4 GetUVToView(Camera camera, RenderTexture target)
        {
            float fovRad = camera.fieldOfView * Mathf.Deg2Rad;
            float invHalfTanFov = 1.0f / Mathf.Tan(fovRad * 0.5f);
            Vector2 focalLen = new Vector2(invHalfTanFov * (target.height / (float) target.width), invHalfTanFov);
            Vector2 invFocalLen = new Vector2(1.0f / focalLen.x, 1.0f / focalLen.y);

            // Aspect Ratio
            return new Vector4(
                +2.0f * invFocalLen.x,
                +2.0f * invFocalLen.y,
                -1.0f * invFocalLen.x,
                -1.0f * invFocalLen.y
            );
        }

        private Vector4 GetTexelSize(RenderTexture rt)
        {
            return new Vector4(1.0f / rt.width, 1.0f / rt.height, rt.width, rt.height);
        }

        public void Dispose()
        {
            // TODO: Dispose smth.
        }
    }
}
