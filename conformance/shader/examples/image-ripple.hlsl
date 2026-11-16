// image-ripple - example
// GENERATED from glslangValidator 16.6.0 + SPIRV-Cross 2026-07-06T12:43:32 (HLSL SM 5.0).
// Author GLSL in visuals/*.glsl; do not hand-edit generated HLSL.

struct VisualUniforms
{
    float2 resolution;
    float time;
    float dt;
    float amplitude;
    float bass;
    float mid;
    float treble;
    float beat;
    float beatPhase;
    float onset;
    float sensitivity;
    float param0;
    float param1;
    float param2;
    float level;
    float bassImpact;
    float spectralCentroid;
    float flux;
    float beatCount;
    float trailDecay;
    float barPhase;
    float downbeat;
    float4 accent;
    float4 motion;
    float4 palette;
    float4 presentation0;
    float4 presentation1;
    float4 safeRect;
    float4 spectrum[16];
};

cbuffer VisualUniformBlock : register(b0)
{
    float2 ub_resolution : packoffset(c0);
    float ub_time : packoffset(c0.z);
    float ub_dt : packoffset(c0.w);
    float ub_amplitude : packoffset(c1);
    float ub_bass : packoffset(c1.y);
    float ub_mid : packoffset(c1.z);
    float ub_treble : packoffset(c1.w);
    float ub_beat : packoffset(c2);
    float ub_beatPhase : packoffset(c2.y);
    float ub_onset : packoffset(c2.z);
    float ub_sensitivity : packoffset(c2.w);
    float ub_param0 : packoffset(c3);
    float ub_param1 : packoffset(c3.y);
    float ub_param2 : packoffset(c3.z);
    float ub_level : packoffset(c3.w);
    float ub_bassImpact : packoffset(c4);
    float ub_spectralCentroid : packoffset(c4.y);
    float ub_flux : packoffset(c4.z);
    float ub_beatCount : packoffset(c4.w);
    float ub_trailDecay : packoffset(c5);
    float ub_barPhase : packoffset(c5.y);
    float ub_downbeat : packoffset(c5.z);
    float4 ub_accent : packoffset(c6);
    float4 ub_motion : packoffset(c7);
    float4 ub_palette : packoffset(c8);
    float4 ub_presentation0 : packoffset(c9);
    float4 ub_presentation1 : packoffset(c10);
    float4 ub_safeRect : packoffset(c11);
    float4 ub_spectrum[16] : packoffset(c12);
};

Texture2D<float4> uPrevTex : register(t1);
SamplerState uSamp : register(s0);
Texture2D<float4> uImageTex : register(t0);

static float4 outColor;
static float2 vUV;

struct SPIRV_Cross_Input
{
    float2 vUV : TEXCOORD0;
};

struct SPIRV_Cross_Output
{
    float4 outColor : SV_Target0;
};

VisualUniforms loadUniforms()
{
    VisualUniforms u;
    u.resolution = ub_resolution;
    u.time = ub_time;
    u.dt = ub_dt;
    u.amplitude = ub_amplitude;
    u.bass = ub_bass;
    u.mid = ub_mid;
    u.treble = ub_treble;
    u.beat = ub_beat;
    u.beatPhase = ub_beatPhase;
    u.onset = ub_onset;
    u.sensitivity = ub_sensitivity;
    u.param0 = ub_param0;
    u.param1 = ub_param1;
    u.param2 = ub_param2;
    u.level = ub_level;
    u.bassImpact = ub_bassImpact;
    u.spectralCentroid = ub_spectralCentroid;
    u.flux = ub_flux;
    u.beatCount = ub_beatCount;
    u.trailDecay = ub_trailDecay;
    u.barPhase = ub_barPhase;
    u.downbeat = ub_downbeat;
    u.accent = ub_accent;
    u.motion = ub_motion;
    u.palette = ub_palette;
    u.presentation0 = ub_presentation0;
    u.presentation1 = ub_presentation1;
    u.safeRect = ub_safeRect;
    for (int i = 0; i < 16; i++)
    {
        u.spectrum[i] = ub_spectrum[i];
    }
    return u;
}

float2x2 rot2(float a)
{
    float c = cos(a);
    float s = sin(a);
    return float2x2(float2(c, -s), float2(s, c));
}

float3 sanitizeColor(inout float3 c)
{
    for (int i = 0; i < 3; i++)
    {
        bool _215 = isnan(c[i]);
        bool _223;
        if (!_215)
        {
            _223 = isinf(c[i]);
        }
        else
        {
            _223 = _215;
        }
        if (_223)
        {
            c[i] = 0.0f;
        }
    }
    return clamp(c, 0.0f.xxx, 16.0f.xxx);
}

float3 feedbackTrail(float3 col, float2 uv, float decay, float zoom, float rotAmt)
{
    float2 q = uv - 0.5f.xx;
    float param = rotAmt;
    q = mul(q, rot2(param));
    q *= (1.0f - zoom);
    float3 param_1 = uPrevTex.Sample(uSamp, q + 0.5f.xx).xyz;
    float3 _268 = sanitizeColor(param_1);
    float3 p = _268;
    float _276;
    if (ub_dt > 0.0f)
    {
        _276 = ub_dt * 60.0f;
    }
    else
    {
        _276 = 1.0f;
    }
    float k = pow(clamp(decay, 0.0f, 0.89999997615814208984375f), _276);
    float3 param_2 = col;
    float3 _288 = sanitizeColor(param_2);
    float3 param_3 = max(_288, p * k);
    float3 _294 = sanitizeColor(param_3);
    return _294;
}

float3 visual(float2 uv, VisualUniforms u)
{
    float2 p = uv - 0.5f.xx;
    float r = length(p);
    float wave = (sin((r * 40.0f) - (u.time * 6.0f)) * (0.0040000001899898052215576171875f + (0.01200000010430812835693359375f * u.bassImpact))) * u.param1;
    float3 col = uImageTex.Sample(uSamp, uv + ((p / max(r, 9.9999997473787516355514526367188e-05f).xx) * wave)).xyz;
    col *= (0.85000002384185791015625f + (0.300000011920928955078125f * u.level));
    float3 param = col;
    float2 param_1 = uv;
    float param_2 = u.trailDecay * 0.5f;
    float param_3 = 0.0f;
    float param_4 = 0.0f;
    return feedbackTrail(param, param_1, param_2, param_3, param_4);
}

void frag_image_ripple_inner()
{
    VisualUniforms u = loadUniforms();
    float2 param = vUV;
    VisualUniforms param_1 = u;
    float3 param_2 = visual(param, param_1);
    float3 _374 = sanitizeColor(param_2);
    outColor = float4(_374, 1.0f);
    if (u.time < (-100000002004087734272.0f))
    {
        outColor += (uImageTex.Sample(uSamp, 0.0f.xx) + uPrevTex.Sample(uSamp, 0.0f.xx));
    }
}

SPIRV_Cross_Output frag_image_ripple(SPIRV_Cross_Input stage_input)
{
    vUV = stage_input.vUV;
    frag_image_ripple_inner();
    SPIRV_Cross_Output stage_output;
    stage_output.outColor = outColor;
    return stage_output;
}
