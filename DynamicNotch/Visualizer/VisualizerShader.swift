//
//  VisualizerShader.swift
//  DynamicNotch
//
//  The full-screen visualizer's Metal shader: slow liquid light in the cover's colours,
//  stirred by the live analysis, with a pulse of light for each speaker of a 2.0, 2.1 or
//  5.1 system (VisualizerRenderer fills the uniforms). Compiled when the
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
    float4 beat;      // beat flash, speaker layout (0 off, 1 = 2.0, 2 = 2.1, 3 = 5.1), layout fade,
                      // the cover's own beat glow and ripples (0 in 2.0: no middle speaker)
    float4 art;       // half size (fraction of height), scale, alpha, playing
    float4 colors[5]; // background, accents 1-4
    float4 rippleAge;
    float4 rippleStrength;
    float4 speakerLevel[2];       // L, R, C, sub | SL, SR, left channel, right channel
    float4 speakerRingAge[3];     // two rings per speaker, in speaker order
    float4 speakerRingStrength[3];
    float4 speakerPunch[2];       // a flash on each hit, same order as speakerLevel
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

    // Light added onto the cover's dark backdrop, so its colours stay pure. Each side of the
    // screen follows its own channel: a sound on the left lights the left.
    float3 bg = u.colors[0].rgb;
    float aspect = u.frame.x / u.frame.y;
    float side = smoothstep(-0.35 * aspect, 0.35 * aspect, p.x);
    float2 lr = u.speakerLevel[1].zw;
    float tilt = mix(lr.x, lr.y, side) - 0.5 * (lr.x + lr.y);
    float drive = max(0.2, 0.45 + 0.55 * loud + 0.45 * bass + 0.35 * beat + 0.9 * tilt);
    float3 c = bg * (0.7 + 0.9 * n);
    c += u.colors[1].rgb * pow(smoothstep(0.3, 0.85, n), 1.4) * 1.4 * drive;
    c += u.colors[2].rgb * smoothstep(0.2, 0.8, length(w2) - 0.2) * (0.35 + 0.7 * mid) * drive;
    c += u.colors[3].rgb * smoothstep(0.55, 0.95, w.x * w2.y * 2.2) * (0.2 + 0.7 * treble);
    // Bright filaments where the flow folds.
    float fold = smoothstep(0.018, 0.0, abs(n - 0.55 - 0.05 * sin(t * 3.0)));
    c += mix(u.colors[1].rgb, float3(1.0), 0.3) * fold * (0.2 + 0.9 * treble) * drive;
    c += ripples(u, p) * 0.6 * u.beat.w;
    return c;
}

static float roundedBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float speakerLevel(constant VizUniforms &u, int i) {
    return u.speakerLevel[i >> 2][i & 3];
}

/// Where each speaker sits, seen from above with the screen's top as the front and the cover
/// as the listener. 2.0 and 2.1: left and right either side. 5.1: the usual layout (fronts
/// at +-30 degrees, centre ahead, surrounds behind at +-110), squeezed to fit the screen.
static float2 speakerPosition(int layout, int i, float aspect) {
    float side = min(0.33 * aspect, 0.5 * aspect - 0.1);
    if (layout < 3) {
        if (i == 0) return float2(-side, 0.0);
        if (i == 1) return float2(side, 0.0);
        return float2(0.0);
    }
    switch (i) {
        case 0: return float2(-0.75 * side, 0.27);  // front left
        case 1: return float2(0.75 * side, 0.27);   // front right
        case 2: return float2(0.0, 0.36);           // centre
        case 4: return float2(-side, -0.25);        // surround left
        case 5: return float2(side, -0.25);         // surround right
        default: return float2(0.0);                // sub: in the middle, behind the cover
    }
}

static bool speakerUsed(int layout, int i) {
    if (layout == 1) return i < 2;
    if (layout == 2) return i < 2 || i == 3;
    return layout == 3;
}

/// A pulse of light per speaker: a glow and bright core that swell with its level, rings
/// sent out on each hit, and a faint marker so the layout reads even when it's quiet.
static float3 speakers(constant VizUniforms &u, float2 p, float aspect) {
    int layout = int(u.beat.y);
    float fade = u.beat.z;
    if (layout == 0 || fade <= 0.001) return float3(0);
    float3 c = float3(0);
    for (int i = 0; i < 6; i++) {
        if (!speakerUsed(layout, i)) continue;
        float punch = u.speakerPunch[i >> 2][i & 3];
        float level = min(1.0, speakerLevel(u, i) + 0.45 * punch);
        float2 pos = speakerPosition(layout, i, aspect);
        float d = length(p - pos);
        float3 col = (i == 4 || i == 5) ? u.colors[2].rgb : u.colors[1].rgb;
        float3 hot = mix(col, float3(1.0), 0.55);

        if (i == 3) {
            // The sub: a glow that swells out from behind the cover, and wide slow rings.
            float edge = u.art.x * u.art.y;
            float sd = max(roundedBox(p, float2(edge), edge * 0.06), 0.0);
            c += col * exp(-sd / (0.03 + 0.12 * level)) * (0.1 + 1.1 * level + 0.6 * punch);
            for (int j = 0; j < 2; j++) {
                int r = 2 * i + j;
                float age = u.speakerRingAge[r >> 2][r & 3];
                float strength = u.speakerRingStrength[r >> 2][r & 3];
                float ring = exp(-pow((sd - age * 0.85) * 24.0, 2.0));
                c += col * ring * strength * exp(-age * 4.0) * 1.0;
            }
            continue;
        }

        float core = 0.012 + 0.03 * level;
        c += col * exp(-d / (0.035 + 0.09 * level)) * (0.06 + 0.9 * level);
        c += hot * smoothstep(core, core * 0.55, d) * (0.3 + 0.7 * level + 0.8 * punch);
        c += col * exp(-pow((d - 0.05) * 140.0, 2.0)) * 0.12;
        for (int j = 0; j < 2; j++) {
            int r = 2 * i + j;
            float age = u.speakerRingAge[r >> 2][r & 3];
            float strength = u.speakerRingStrength[r >> 2][r & 3];
            float ring = exp(-pow((d - core - age * 1.0) * 55.0, 2.0));
            c += hot * ring * strength * exp(-age * 5.0) * 0.9;
        }
    }
    return c * fade;
}

fragment float4 viz_fragment(VizOut in [[stage_in]],
                             constant VizUniforms &u [[buffer(0)]],
                             texture2d<float> art [[texture(0)]],
                             sampler artSampler [[sampler(0)]]) {
    float2 res = u.frame.xy;
    float2 frag = in.position.xy;
    // Centred, y up, 1 unit = screen height.
    float2 p = float2(frag.x - 0.5 * res.x, 0.5 * res.y - frag.y) / res.y;

    float3 c = flow(u, p) + speakers(u, p, res.x / res.y);

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
        c += u.colors[1].rgb * exp(-max(sd, 0.0) * 9.0) * (0.10 + (0.25 * u.energy.x + 0.25 * beat) * u.beat.w) * alpha;
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
