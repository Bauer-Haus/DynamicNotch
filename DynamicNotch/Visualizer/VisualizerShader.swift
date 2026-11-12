//
//  VisualizerShader.swift
//  DynamicNotch
//
//  The full-screen visualizer's Metal shader: slow liquid light in the cover's colours,
//  stirred by the live analysis (VisualizerRenderer fills the uniforms). Compiled when the
//  visualizer first opens, so building the app doesn't need Xcode's separately downloaded
//  Metal toolchain.
//

enum VisualizerShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct VizOut {
    float4 position [[position]];
};

vertex VizOut viz_vertex(uint vid [[vertex_id]]) {
    // One triangle covering the screen.
    float2 p = float2((vid << 1) & 2, vid & 2);
    VizOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// Must match VisualizerRenderer.Slot (all float4, so no padding surprises).
struct VizUniforms {
    float4 frame;     // resolution x, y, time, phase
    float4 energy;    // bass, mid, treble, loudness
    float4 beat;      // beat flash, -, -, -
    float4 art;       // half size (fraction of height), scale, alpha, playing
    float4 colors[5]; // background, accents 1-4
    float4 rippleAge;
    float4 rippleStrength;
};

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    const float2x2 rot = float2x2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < 5; i++) {
        v += a * noise(p);
        p = rot * p * 2.03 + 17.1;
        a *= 0.5;
    }
    return v;
}

/// Rings of the cover's light that travel outwards from it on each beat.
static float3 ripples(constant VizUniforms &u, float2 p) {
    float3 c = float3(0);
    float d = length(p);
    for (int i = 0; i < 4; i++) {
        float age = u.rippleAge[i];
        float s = u.rippleStrength[i];
        if (s <= 0.0) continue;
        float r = u.art.x * u.art.y + age * 1.1;
        float ring = exp(-pow((d - r) * 9.0, 2.0));
        c += u.colors[1 + (i & 1)].rgb * ring * s * exp(-age * 1.8);
    }
    return c;
}

static float3 flow(constant VizUniforms &u, float2 p) {
    float bass = u.energy.x, mid = u.energy.y, treble = u.energy.z, loud = u.energy.w;
    float beat = u.beat.x;
    float t = u.frame.w * 0.12;
    float2 q = p * (1.15 - 0.12 * bass);
    float2 w = float2(fbm(q * 1.2 + float2(0.0, t)), fbm(q * 1.2 + float2(5.2, -t)));
    float2 w2 = float2(fbm(q + 2.2 * w + float2(1.7, 9.2) + 0.5 * t),
                       fbm(q + 2.2 * w + float2(8.3, 2.8) - 0.35 * t));
    float n = fbm(q + (2.4 + 0.8 * mid) * w2);

    // Light added onto the cover's dark backdrop, so its colours stay pure.
    float3 bg = u.colors[0].rgb;
    float drive = 0.45 + 0.55 * loud + 0.45 * bass + 0.35 * beat;
    float3 c = bg * (0.7 + 0.9 * n);
    c += u.colors[1].rgb * pow(smoothstep(0.3, 0.85, n), 1.4) * 1.4 * drive;
    c += u.colors[2].rgb * smoothstep(0.2, 0.8, length(w2) - 0.2) * (0.35 + 0.7 * mid) * drive;
    c += u.colors[3].rgb * smoothstep(0.55, 0.95, w.x * w2.y * 2.2) * (0.2 + 0.7 * treble);
    // Bright filaments where the flow folds.
    float fold = smoothstep(0.018, 0.0, abs(n - 0.55 - 0.05 * sin(t * 3.0)));
    c += mix(u.colors[1].rgb, float3(1.0), 0.3) * fold * (0.2 + 0.9 * treble) * drive;
    c += ripples(u, p) * 0.6;
    return c;
}

static float roundedBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

fragment float4 viz_fragment(VizOut in [[stage_in]],
                             constant VizUniforms &u [[buffer(0)]],
                             texture2d<float> art [[texture(0)]],
                             sampler artSampler [[sampler(0)]]) {
    float2 res = u.frame.xy;
    float2 frag = in.position.xy;
    // Centred, y up, 1 unit = screen height.
    float2 p = float2(frag.x - 0.5 * res.x, 0.5 * res.y - frag.y) / res.y;

    float3 c = flow(u, p);

    // Vignette, then a soft shoulder so bright passages never clip harshly.
    c *= 1.0 - 0.35 * smoothstep(0.4, 1.1, length(p * float2(0.8, 1.0)));
    c = 1.0 - exp(-c * 1.35);

    // The cover, floating in the middle with a shadow and a glow that breathes with the bass.
    float alpha = u.art.z;
    if (alpha > 0.001) {
        float h = u.art.x * u.art.y;
        float radius = h * 0.06;
        float sd = roundedBox(p, float2(h), radius);
        float beat = u.beat.x;
        c += u.colors[1].rgb * exp(-max(sd, 0.0) * 9.0) * (0.10 + 0.25 * u.energy.x + 0.25 * beat) * alpha;
        float shadow = exp(-max(roundedBox(p + float2(0.0, 0.018), float2(h), radius), 0.0) * 22.0);
        c *= 1.0 - 0.55 * shadow * alpha * step(0.0, sd);
        float2 uv = float2(p.x, -p.y) / (2.0 * h) + 0.5;
        float3 cover = art.sample(artSampler, uv).rgb;
        float inside = clamp(-sd * res.y + 0.5, 0.0, 1.0);
        c = mix(c, cover, inside * alpha);
    }

    // Dither away banding in the dark gradients.
    c += (hash21(frag + fract(u.frame.z)) - 0.5) / 255.0;
    return float4(c, 1.0);
}
"""#
}
