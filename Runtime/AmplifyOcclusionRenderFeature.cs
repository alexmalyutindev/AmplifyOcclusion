using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace AmplifyOcclusion
{
    public class AmplifyOcclusionRenderFeature : ScriptableRendererFeature
    {
        [Serializable]
        public class Settings
        {
            [Tooltip("Number of samples per pass.")]
            public SampleCountLevel SampleCount = SampleCountLevel.Medium;
            [Tooltip("Final applied intensity of the occlusion effect in shadows sides.")]
            [Range(0, 1)]
            public float Intensity = 1.0f;
            [Tooltip("Final applied intensity of the occlusion effect in light sides.")]
            [Range(0, 1)]
            public float DirectLightIntensity = 1.0f;
            [Tooltip("Color tint for occlusion.")]
            public Color Tint = Color.black;
            [Tooltip("Radius spread of the occlusion.")]
            public float Radius = 2.0f;
            [Tooltip("Power exponent attenuation of the occlusion.")]
            [Range(0, 16)]
            public float PowerExponent = 1.8f;
            [Tooltip("Controls the initial occlusion contribution offset.")]
            [Range(0, 0.99f)]
            public float Bias = 0.05f;
            [Tooltip("Controls the thickness occlusion contribution.")]
            [Range(0, 1.0f)]
            public float Thickness = 1.0f;
            [Tooltip("Compute the Occlusion and Blur at half of the resolution.")]
            public bool Downsample = true;
            [Tooltip("Cache optimization for best performance / quality tradeoff.")]
            public bool CacheAware = true;

            [Header("Distance Fade")]
            [Tooltip("Control parameters at faraway.")]
            public bool FadeEnabled = false;
            [Tooltip("Distance in Unity unities that start to fade.")]
            public float FadeStart = 100.0f;
            [Tooltip("Length distance to performe the transition.")]
            public float FadeLength = 50.0f;
            [Tooltip("Final Intensity parameter.")]
            [Range(0, 1)]
            public float FadeToIntensity = 0.0f;
            public Color FadeToTint = Color.black;
            [Tooltip("Final Radius parameter.")]
            public float FadeToRadius = 2.0f;
            [Tooltip("Final PowerExponent parameter.")]
            [Range(0, 16)]
            public float FadeToPowerExponent = 1.0f;
            [Tooltip("Final Thickness parameter.")]
            [Range(0, 1.0f)]
            public float FadeToThickness = 1.0f;

            [Header("Bilateral Blur")]
            public bool BlurEnabled = true;
            [Tooltip("Radius in screen pixels.")]
            [Range(1, 4)]
            public int BlurRadius = 3;
            [Tooltip("Number of times that the Blur will repeat.")]
            [Range(1, 4)]
            public int BlurPasses = 1;
            [Tooltip("Sharpness of blur edge-detection: 0 = Softer Edges, 20 = Sharper Edges.")]
            [Range(0, 20)]
            public float BlurSharpness = 15.0f;
        }

        [SerializeField]
        private Settings _settings = new();

        public Shader OcclusionShader;
        public Shader BlurShader;

        private Material _occlusion;
        private Material _blur;
        private AmplifyOcclusionRenderPass _pass;

        public override void Create()
        {
            _pass = new AmplifyOcclusionRenderPass(_settings)
            {
                renderPassEvent = RenderPassEvent.AfterRenderingPrePasses + 2
            };
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (renderingData.cameraData.isPreviewCamera)
            {
                return;
            }

            if (!GetMaterials())
            {
                // NOTE: Materials setup error!
                return;
            }

            _pass.Setup(_occlusion, _blur);
            renderer.EnqueuePass(_pass);
        }

        protected override void Dispose(bool disposing)
        {
            _pass.Dispose();
            CoreUtils.Destroy(_occlusion);
            CoreUtils.Destroy(_blur);
        }

        private bool GetMaterials()
        {
            if (_occlusion == null && OcclusionShader != null)
            {
                _occlusion = CoreUtils.CreateEngineMaterial(OcclusionShader);
            }

            if (_blur == null && BlurShader != null)
            {
                _blur = CoreUtils.CreateEngineMaterial(BlurShader);
            }

            return _occlusion != null && _blur != null;
        }
    }
}
