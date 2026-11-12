//
//  VelaShaders.metal
//  Vela
//
//  Port of the WebGL prototype shaders (vela.html / gl.js) to Metal.
//  Three full-screen fragment visuals + one additive particle pass:
//    0 = Nebula, 1 = Schwarzes Loch klassisch (goldene Scheibe), 2 = Schwarzes Loch Nebula-Scheibe
//  All float literals carry an explicit `f` suffix (generated), MSL has no double.
//

#include <metal_stdlib>
using namespace metal;

// Must match `VelaUniforms` in VelaRenderer.swift (48 bytes, float2 first).
struct VelaUniforms {
    float2 res;      // drawable size in pixels
    float  time;
    float  phase;
    float  amp;      // audio level 0...1 (mic while listening, voice envelope while speaking)
    float  energy;   // 0...1, rises while thinking
    float  zoom;
    float  bright;
    float  design;   // 0, 1, 2
    float  k;        // disk flattening for particles
    float  rs;       // event horizon radius for particles
    float  px;       // point size scale in pixels
};

// ---------------------------------------------------------------- helpers

inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * .1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}

inline float hash13(float3 p3) {
    p3 = fract(p3 * .1031f);
    p3 += dot(p3, p3.zyx + 31.32f);
    return fract((p3.x + p3.y) * p3.z);
}

inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * f * (f * (f * 6.f - 15.f) + 10.f);
    return mix(mix(hash12(i), hash12(i + float2(1.f, 0.f)), u.x),
               mix(hash12(i + float2(0.f, 1.f)), hash12(i + float2(1.f, 1.f)), u.x), u.y);
}

inline float vnoise3(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    float3 u = f * f * (3.f - 2.f * f);
    float a = mix(mix(hash13(i), hash13(i + float3(1.f, 0.f, 0.f)), u.x),
                  mix(hash13(i + float3(0.f, 1.f, 0.f)), hash13(i + float3(1.f, 1.f, 0.f)), u.x), u.y);
    float b = mix(mix(hash13(i + float3(0.f, 0.f, 1.f)), hash13(i + float3(1.f, 0.f, 1.f)), u.x),
                  mix(hash13(i + float3(0.f, 1.f, 1.f)), hash13(i + float3(1.f, 1.f, 1.f)), u.x), u.y);
    return mix(a, b, u.z);
}

// GLSL: const mat2 M2 = mat2(1.6, 1.2, -1.2, 1.6);  M2 * p   (column-major)
inline float2 m2(float2 p) {
    return float2(1.6f * p.x - 1.2f * p.y, 1.2f * p.x + 1.6f * p.y);
}

// GLSL: rot(a) * p  with rot(a) = mat2(c, s, -s, c)
inline float2 rotp(float a, float2 p) {
    float c = cos(a);
    float s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

// pow() is undefined for negative bases in MSL; all callers are >= 0, clamp to be safe.
inline float spow(float x, float y) {
    return pow(max(x, 0.f), y);
}

inline float fbm(float2 p) {
    float s = 0.f;
    float a = .5f;
    for (int i = 0; i < 5; i++) { s += a * vnoise(p); p = m2(p) + float2(1.7f, 9.2f); a *= .5f; }
    return s / .97f;
}

inline float fbm3o(float2 p) {
    float s = 0.f;
    float a = .5f;
    for (int i = 0; i < 3; i++) { s += a * vnoise(p); p = m2(p) + float2(4.1f, 2.3f); a *= .5f; }
    return s / .875f;
}

inline float ridged(float2 p) {
    float s = 0.f;
    float a = .5f;
    for (int i = 0; i < 5; i++) {
        float n = 1.f - abs(vnoise(p) * 2.f - 1.f);
        s += a * n * n;
        p = m2(p) + float2(3.3f, 1.1f);
        a *= .5f;
    }
    return s;
}

inline float fbmV(float3 p) {
    float s = 0.f;
    float a = .5f;
    for (int i = 0; i < 4; i++) { s += a * vnoise3(p); p = p * 2.03f + float3(1.7f, 9.2f, 3.1f); a *= .5f; }
    return s / .9375f;
}

// fc = fragment coordinate with origin bottom-left (like gl_FragCoord)
inline float2 uvc(float2 fc, constant VelaUniforms &U) {
    float2 p = (fc - .5f * U.res) / (.5f * U.res.y);
    return p / U.zoom;
}

inline float starLayer(float2 p, float dens, float time) {
    float2 g = p * dens;
    float2 id = floor(g);
    float h = hash12(id);
    if (h < .93f) { return 0.f; }
    float2 o = float2(hash12(id + 7.3f), hash12(id + 3.1f)) * .7f + .15f;
    float d = length(fract(g) - o);
    float tw = .6f + .4f * sin(time * (1.f + 3.f * h) + h * 50.f);
    return (1.f - smoothstep(0.f, .12f, d)) * (h - .93f) * 14.f * tw;
}

inline float stars(float2 p, float dens, float time) {
    // Two depths drift at different speeds: a cheap parallax field.
    float near = starLayer(p + float2(time * 0.018f, time * 0.007f), dens, time);
    float far = starLayer(p + float2(-time * 0.006f, time * 0.004f), dens * 0.62f, time * 0.8f);
    return near + far * 0.55f;
}

// Tone mapping + premultiplied alpha, identical to the prototype's outc().
inline float4 outc(float3 c, float solid, constant VelaUniforms &U) {
    c *= U.bright;
    c = max(c, float3(0.f));
    // Leave a little headroom. The composite pass applies ACES and bloom.
    c = c / (1.f + 0.22f * c);
    float peak = max(c.r, max(c.g, c.b));
    float a = clamp(peak * 1.05f, 0.f, 1.f);
    a = max(a, solid);
    return float4(c, a);
}

// ---------------------------------------------------------------- full-screen triangle

struct QuadOut {
    float4 position [[position]];
};

vertex QuadOut vela_quad_vertex(uint vid [[vertex_id]]) {
    const float2 pts[3] = { float2(-1.f, -1.f), float2(3.f, -1.f), float2(-1.f, 3.f) };
    QuadOut o;
    o.position = float4(pts[vid], 0.f, 1.f);
    return o;
}

// Metal's [[position]] has its origin top-left; flip to GL convention.
inline float2 glFragCoord(float4 pos, constant VelaUniforms &U) {
    return float2(pos.x, U.res.y - pos.y);
}

// ---------------------------------------------------------------- 0: Nebula

fragment float4 vela_nebula_fragment(QuadOut in [[stage_in]], constant VelaUniforms &U [[buffer(0)]]) {
    float2 p = uvc(glFragCoord(in.position, U), U);
    float breath = 1.f + .03f * sin(U.time * .9f) + .05f * U.amp;
    p *= 1.16f / breath;
    float r = length(p);
    if (r > 1.05f) { return float4(0.f); }
    float ang = atan2(p.y, p.x);
    float tw = -2.4f * log(r + .06f);
    float2 q = rotp(tw * .62f + U.phase, p);
    float t = U.time * .035f;
    float2 w1 = float2(fbm(q * 1.4f + float2(t, 1.7f)), fbm(q * 1.4f + float2(5.2f, -t)));
    float2 qq = q * 2.4f + 2.1f * w1;
    float d = fbm(qq + float2(-t * .8f, t * .5f));
    float fil = ridged(qq * 1.9f + 2.6f * w1 + 11.f);
    float fil2 = ridged(qq * 4.4f + 1.3f * w1 + 27.f);
    float hueN = fbm3o(q * .85f + float2(3.1f, 7.7f) + w1 * .8f);
    float edgeN = fbm3o(p * 2.4f + float2(9.f, U.time * .02f));
    float edge = .60f + .36f * edgeN;
    float mask = 1.f - smoothstep(edge - .32f, edge + .05f, r);
    float dens = spow(clamp(d * 1.75f - .7f, 0.f, 1.f), 1.4f) * mix(.5f, 1.f, smoothstep(.12f, .42f, r));
    float fl = spow(fil, 5.5f);
    float fl2 = spow(fil2, 7.f) * smoothstep(.25f, .6f, d);
    float3 violet = float3(.52f, .18f, 1.f);
    float3 magenta = float3(.95f, .22f, .85f);
    float3 cyan = float3(.10f, .78f, 1.f);
    float3 teal = float3(.10f, .95f, .85f);
    float side = cos(ang - U.phase * .35f - .5f);
    float hmix = smoothstep(.42f, .82f, hueN * .55f + .34f * side + .22f);
    float3 gas = mix(violet, cyan, hmix);
    gas = mix(gas, magenta, smoothstep(.45f, .8f, d) * (1.f - hmix) * .8f);
    gas = mix(gas, teal, smoothstep(.70f, .98f, hueN) * hmix * .5f);
    float lanes = .22f + .78f * smoothstep(.32f, .64f, fbm3o(qq * 2.2f + 4.f));
    float3 col = gas * (dens * .7f + fl * 2.6f + fl2 * 2.f) * mask * lanes;
    col += gas * .05f * mask;
    float cr = r / (1.f + .35f * U.amp);
    float3 warm = float3(1.f, .66f, .80f);
    col += warm * (fl * 1.4f + fl2) * exp(-r * 3.f) * 1.2f * mask;
    col += float3(.92f, .42f, .88f) * exp(-cr * 6.f) * (.55f + .6f * U.amp);
    col += float3(1.f, .82f, .80f) * exp(-cr * 14.f) * (.8f + .6f * U.amp);
    col += float3(1.f, .97f, .95f) * exp(-cr * 38.f) * (1.2f + .8f * U.amp);
    float sd = stars(q * 1.3f + 3.f, 150.f, U.time) + stars(q * .9f + 11.f, 230.f, U.time) * .8f;
    col += mix(float3(.85f, .85f, 1.f), gas + .4f, .4f) * sd * mask * (.6f + dens * 2.f) * 1.3f;
    col += float3(.85f, .9f, 1.f) * stars(p, 70.f, U.time) * (mask * .6f + .1f);
    return outc(col * 1.2f, 0.f, U);
}

// ---------------------------------------------------------------- 1: Schwarzes Loch klassisch

inline float3 ramp(float temp) {
    float3 c = mix(float3(.70f, .16f, .02f), float3(1.f, .48f, .12f), smoothstep(0.f, .55f, temp));
    c = mix(c, float3(1.f, .74f, .42f), smoothstep(.5f, .85f, temp));
    return mix(c, float3(1.f, .94f, .84f), smoothstep(.88f, 1.f, temp));
}

inline float3 emis(float rd, float a, float rs, constant VelaUniforms &U) {
    float rin = rs * 1.38f;
    float rout = .95f;
    if (rd < rin * .9f || rd > rout) { return float3(0.f); }
    float x = (rd - rin) / (rout - rin);
    float prof = smoothstep(-.02f, .05f, x) * spow(clamp(1.f - x, 0.f, 1.f), 1.4f) / (.22f + x * 3.2f);
    float aa = a + U.phase * 1.6f / (.35f + x * 2.5f);
    float2 cs = float2(cos(aa), sin(aa));
    float n = fbmV(float3(cs * 1.3f, rd * 20.f + U.time * .05f));
    float n2 = vnoise3(float3(cs * 3.5f, rd * 70.f));
    float I = prof * (.45f + 1.5f * n * n) * (.7f + .6f * n2) * 1.5f;
    // Approaching side of the disk is brighter (Doppler beaming).
    float doppler = 0.42f + 0.95f * smoothstep(-1.f, 1.f, cos(a - 0.6f));
    return ramp(1.f - x) * I * doppler * (1.f + .45f * U.amp);
}

fragment float4 vela_blackhole_fragment(QuadOut in [[stage_in]], constant VelaUniforms &U [[buffer(0)]]) {
    float2 p = uvc(glFragCoord(in.position, U), U);
    float rs = .25f * (1.f + .02f * sin(U.time * .8f) + .035f * U.amp);
    float k = .19f;
    float r = length(p);
    if (r > 1.05f) { return float4(0.f); }
    float3 col = float3(0.f);
    float th = atan2(p.y, p.x);
    float up = p.y / max(r, 1e-4f);
    // lensed far side: arc over the top, thin arc beneath
    if (r > rs) {
        float thick = mix(.045f, .40f, smoothstep(-.9f, .95f, up));
        float rl = rs * 1.38f + (r - rs * 1.01f) / thick * .55f;
        float w = mix(.25f, 1.f, abs(up));
        w *= mix(.30f, 1.25f, smoothstep(-.3f, .7f, up));
        col += emis(rl, -th, rs, U) * w;
    }
    // primary disk
    float dy = p.y / k;
    float rd = length(float2(p.x, dy));
    float a = atan2(dy, p.x);
    float3 dcol = emis(rd, a, rs, U);
    if (dy > 0.f) {
        col += dcol * max(smoothstep(rs * 1.05f, rs * 1.9f, abs(p.x)), 1.f - smoothstep(0.f, .04f, p.y));
    }
    float shadow = 1.f - smoothstep(rs * .97f, rs * 1.005f, r);
    col *= 1.f - shadow;
    col += float3(1.f, .86f, .66f) * exp(-abs(r - rs * 1.012f) * 110.f) * mix(.35f, 1.1f, smoothstep(-.8f, .6f, up));
    col += float3(1.f, .94f, .82f) * exp(-abs(r - rs * 1.045f) * 180.f) * 0.55f;
    col += float3(1.f, .55f, .2f) * .10f * exp(-max(r - rs, 0.f) * 3.f) * (1.f - shadow);
    col += float3(1.f, .6f, .25f) * .35f * exp(-abs(p.y) * 14.f) * exp(-abs(p.x) * 2.6f) * (1.f - shadow) * (1.f + .5f * U.amp);
    if (dy <= 0.f) { col += dcol; }
    float vis = 1.f - smoothstep(.85f, 1.f, r);
    col += float3(1.f, .9f, .8f) * stars(p, 60.f, U.time) * .5f * (1.f - shadow);
    return outc(col * vis, shadow, U);
}

// ---------------------------------------------------------------- 2: Schwarzes Loch Nebula-Scheibe

fragment float4 vela_blackhole_nebula_fragment(QuadOut in [[stage_in]], constant VelaUniforms &U [[buffer(0)]]) {
    float2 p = uvc(glFragCoord(in.position, U), U);
    float k = .84f;
    float2 pd = float2(p.x, p.y / k);
    float rs = .22f * (1.f + .02f * sin(U.time * .8f) + .035f * U.amp);
    float r = length(pd);
    if (r > 1.25f) { return float4(0.f); }
    float ang = atan2(pd.y, pd.x);
    float lg = log(r + .02f);
    float2 q = rotp(-2.1f * lg + U.phase, pd);
    float t = U.time * .03f;
    float2 w = float2(fbm(q * 1.7f + float2(t, 2.f)), fbm(q * 1.7f + float2(6.f, -t)));
    float2 qq = q * 2.4f + 1.7f * w;
    float d = fbm(qq);
    float fil = spow(ridged(qq * 1.5f + 2.5f * w + 5.f), 4.f);
    float arms = .5f + .5f * cos(2.f * (ang + 2.1f * lg - U.phase) + 1.2f * (w.x - .5f));
    arms = spow(arms, 1.6f);
    float radial = smoothstep(rs * 1.3f, rs * 2.6f, r) * (1.f - smoothstep(.55f, 1.f, r + .25f * (w.y - .5f)));
    float gasD = (spow(clamp(d * 1.6f - .5f, 0.f, 1.f), 1.3f) * .9f + fil * 2.4f) * mix(.12f, 1.f, arms) * radial;
    float hue = smoothstep(.45f, .85f, r + .35f * (fbm3o(q * .8f + 9.f) - .5f)) * smoothstep(.2f, .8f, arms + .3f);
    float3 violet = float3(.58f, .24f, 1.f);
    float3 lilac = float3(.85f, .55f, 1.f);
    float3 cyan = float3(.15f, .85f, 1.f);
    float3 gas = mix(violet, cyan, hue);
    gas = mix(gas, lilac, fil * .5f);
    float3 col = gas * gasD * 1.45f + gas * .04f * radial;
    col += float3(.85f, .85f, 1.f) * stars(q * 1.2f + 5.f, 160.f, U.time) * radial * (.5f + gasD * 2.f);
    // inner accretion ring
    float x = (r - rs * 1.08f) / .30f;
    float2 cs = float2(cos(ang + U.phase * 2.2f), sin(ang + U.phase * 2.2f));
    float streak = fbmV(float3(cs * 1.4f, r * 26.f + U.time * .05f));
    float ring = smoothstep(-.02f, .04f, x) * exp(-max(x, 0.f) * 4.5f) * (.4f + 1.3f * streak * streak);
    col += mix(float3(.72f, .40f, 1.f), float3(1.f, .88f, 1.f), exp(-max(x, 0.f) * 9.f)) * ring * (2.f + 1.f * U.amp);
    col += float3(.55f, .3f, 1.f) * exp(-max(r - rs, 0.f) * 4.f) * .4f;
    float shadow = 1.f - smoothstep(rs * .97f, rs * 1.01f, r);
    col *= 1.f - shadow;
    col += float3(.9f, .8f, 1.f) * exp(-abs(r - rs * 1.03f) * 120.f) * 1.1f;
    col += float3(.25f, .85f, 1.f) * exp(-abs(r - rs * .995f) * 220.f) * .6f;
    col += float3(.85f, .9f, 1.f) * stars(p, 75.f, U.time) * (1.f - shadow) * .7f;
    float vis = 1.f - smoothstep(.9f, 1.05f, length(p));
    return outc(col * vis, shadow, U);
}

// ---------------------------------------------------------------- particles (additive points)

struct PointOut {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float3 col;
    float  alpha;
};

vertex PointOut vela_points_vertex(uint vid [[vertex_id]],
                                   const device float4 *rnd [[buffer(0)]],
                                   constant VelaUniforms &U [[buffer(1)]]) {
    float4 aR = rnd[vid];
    float2 pos;
    float3 col;
    float a = 1.f;
    float size;
    if (U.design < .5f) {
        float r = (spow(aR.x, .75f) * .82f + .02f) / 1.16f;
        float ang = aR.y * 6.2832f + U.phase * (1.f + .25f / (r + .3f)) - 2.3f * log(r + .06f) * .6f;
        pos = r * float2(cos(ang), sin(ang));
        float tw = sin(U.time * (.8f + aR.z * 3.f) + aR.w * 40.f);
        a = (.35f + .65f * tw * tw) * (1.f - smoothstep(.5f, .95f, r));
        col = mix(float3(.75f, .85f, 1.f), float3(1.f, .7f, .95f), aR.z);
        col = mix(col, float3(.5f, 1.f, .95f), step(.8f, aR.w) * .5f);
        size = .7f + spow(aR.w, 5.f) * 2.6f;
        pos *= 1.f + .03f * sin(U.time * .9f) + .05f * U.amp;
    } else {
        float life = fract(aR.x + U.time * (.035f + .05f * aR.z) * (1.f + 1.2f * U.energy));
        float r = mix(1.f, U.rs * 1.08f, spow(life, .55f));
        float ang = aR.y * 6.2832f + U.phase * .8f + 10.f * life * life;
        float2 dp = r * float2(cos(ang), sin(ang));
        pos = float2(dp.x, dp.y * U.k);
        float far = step(0.f, dp.y);
        if (far > .5f && length(pos) < U.rs * 1.05f) { a = 0.f; }
        a *= smoothstep(0.f, .18f, life) * (1.f - smoothstep(.86f, 1.f, life));
        if (U.design < 1.5f) {
            col = mix(float3(1.f, .5f, .15f), float3(1.f, .92f, .75f), life);
        } else {
            col = mix(mix(float3(.6f, .3f, 1.f), float3(.2f, .85f, 1.f), aR.w), float3(.95f, .85f, 1.f), life * life);
        }
        size = .6f + 1.3f * aR.w * aR.w;
        a *= U.design < 1.5f ? .35f : .55f;
    }
    PointOut o;
    o.position = float4(pos * U.zoom, 0.f, 1.f);
    o.pointSize = max(size * U.px * (1.f + .4f * U.amp), 1.f);
    o.col = col;
    o.alpha = a;
    return o;
}

// Fragment-side view of PointOut (without [[point_size]]); members match by name.
struct PointFragIn {
    float4 position [[position]];
    float3 col;
    float  alpha;
};

fragment float4 vela_points_fragment(PointFragIn in [[stage_in]], float2 pc [[point_coord]]) {
    float2 c = pc - .5f;
    float d = dot(c, c);
    float f = exp(-d * 18.f);
    return float4(in.col * in.alpha * f, in.alpha * f * .6f);
}

// ---------------------------------------------------------------- bloom + filmic composite

inline float3 acesFit(float3 x) {
    x = max(x, float3(0.f));
    const float a = 2.51f;
    const float b = 0.03f;
    const float c = 2.43f;
    const float d = 0.59f;
    const float e = 0.14f;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.f, 1.f);
}

fragment float4 vela_threshold_fragment(QuadOut in [[stage_in]],
                                        texture2d<float> src [[texture(0)]],
                                        constant float2 &target [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 uv = in.position.xy / max(target, float2(1.f));
    float3 c = max(src.sample(smp, uv).rgb, float3(0.f));
    float luma = max(c.r, max(c.g, c.b));
    float mask = smoothstep(0.55f, 1.15f, luma);
    return float4(c * mask, 1.f);
}

fragment float4 vela_blur_fragment(QuadOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   constant float2 &dir [[buffer(0)]],
                                   constant float2 &target [[buffer(1)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 uv = in.position.xy / max(target, float2(1.f));
    float2 texel = dir / float2(src.get_width(), src.get_height());
    float3 c = src.sample(smp, uv).rgb * 0.227027f;
    c += src.sample(smp, uv + texel * 1.384615f).rgb * 0.316216f;
    c += src.sample(smp, uv - texel * 1.384615f).rgb * 0.316216f;
    c += src.sample(smp, uv + texel * 3.230769f).rgb * 0.070270f;
    c += src.sample(smp, uv - texel * 3.230769f).rgb * 0.070270f;
    return float4(c, 1.f);
}

fragment float4 vela_composite_fragment(QuadOut in [[stage_in]],
                                        texture2d<float> scene [[texture(0)]],
                                        texture2d<float> bloom [[texture(1)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 size = float2(scene.get_width(), scene.get_height());
    float2 uv = in.position.xy / max(size, float2(1.f));
    float4 base = scene.sample(smp, uv);
    float3 glow = bloom.sample(smp, uv).rgb;
    float3 ldr = acesFit(base.rgb + glow * 0.62f);
    float noise = fract(sin(dot(in.position.xy, float2(12.9898f, 78.233f))) * 43758.5453f);
    ldr += (noise - 0.5f) / 255.f;
    return float4(clamp(ldr, 0.f, 1.f), base.a);
}
