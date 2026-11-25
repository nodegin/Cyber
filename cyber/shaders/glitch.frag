#version 440
// Cyber's glitch (amount 0 = clean, 1 = full). Layers, all driven by `seed`, which changes every
// frame while it plays:
//   - the picture torn into bands that slide sideways, smeared rows, R/G/B pulled apart
//   - red interference bands: the picture goes red, with dotted scan rows
//   - neon light streaks: thin horizontal trails, bright head, fading tail; a few vertical hairlines
//   - pixel clusters: runs of little rainbow blocks
//   - tiny grid noise: dense dither / zigzag texture in teal and red over a dark teal veil
//   - RGB static, interlaced scanlines, flicker
// Compile: /usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o glitch.frag.qsb glitch.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float amount;
    float seed;
    vec2 pxSize;    // item size in pixels
};

layout(binding = 1) uniform sampler2D source;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
float hash1(float x) { return hash(vec2(x, x * 0.7 + 1.3)); }

// saturated neon: cyan, hot pink, red, green, blue, amber
vec3 neon(float h) {
    h = fract(h) * 6.0;
    if (h < 1.0) return vec3(0.24, 0.94, 1.0);
    if (h < 2.0) return vec3(1.0, 0.17, 0.62);
    if (h < 3.0) return vec3(1.0, 0.22, 0.24);
    if (h < 4.0) return vec3(0.25, 1.0, 0.55);
    if (h < 5.0) return vec3(0.35, 0.45, 1.0);
    return vec3(1.0, 0.85, 0.3);
}
vec3 rainbow(float h) { return clamp(abs(fract(h + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0); }

vec4 tap(vec2 uv) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return vec4(0.0);
    return texture(source, uv);
}

void main() {
    vec2 uv0 = qt_TexCoord0;
    float a = clamp(amount, 0.0, 1.0);
    if (a < 0.001) { fragColor = texture(source, uv0) * qt_Opacity; return; }
    vec2 px = uv0 * pxSize;

    // ---- the picture: torn bands sliding sideways, smeared rows, RGB split
    vec2 uv = uv0;
    float bandH = 4.0 + floor(hash1(seed) * 40.0);
    float band = floor(px.y / bandH);
    float torn = step(1.0 - 0.55 * a, hash(vec2(band, seed)));
    uv.x += (hash(vec2(band, seed + 7.0)) - 0.5) * 0.18 * a * torn;
    float smear = step(1.0 - 0.3 * a, hash(vec2(band, seed + 8.0)));
    float run = 8.0 + 90.0 * hash(vec2(band, seed + 9.0));
    uv.x = mix(uv.x, floor(uv.x * pxSize.x / run) * run / pxSize.x, smear);
    float ca = (0.0008 + 0.009 * a) * (0.6 + 0.9 * torn);
    vec4 cr = tap(uv + vec2(ca, 0.0));
    vec4 cg = tap(uv + vec2(0.0, ca * 0.15));
    vec4 cb = tap(uv - vec2(ca, 0.0));
    vec4 col = vec4(cr.r, cg.g, cb.b, max(max(cr.a, cg.a), cb.a));

    // ---- red interference bands
    float rb = floor(px.y / 18.0);
    float red = step(1.0 - 0.12 * a, hash(vec2(rb, floor(seed * 0.5))));
    if (red > 0.5) {
        float l = dot(col.rgb, vec3(0.3, 0.59, 0.11));
        col.rgb = mix(col.rgb, vec3(1.0, 0.18, 0.15) * (0.25 + 1.4 * l) * col.a, 0.75);
        float dots = step(0.5, fract(px.y / 3.0)) * step(0.45, hash(vec2(floor(px.x / 3.0), floor(px.y / 3.0) + seed)));
        dots *= 0.25 + 0.75 * col.a;
        col.rgb += vec3(1.0, 0.2, 0.15) * dots * 0.3 * a;
        col.a = max(col.a, dots * 0.3 * a);
    }

    // ---- neon light streaks
    float rowH = 2.0 + floor(hash1(seed + 3.0) * 3.0);
    float row = floor(px.y / rowH);
    float hasStreak = step(1.0 - 0.2 * a, hash(vec2(row, seed + 21.0)));
    float start = hash(vec2(row, seed + 22.0)) * 1.2 - 0.2;
    float len = 0.05 + 0.6 * pow(hash(vec2(row, seed + 23.0)), 2.0);
    float t = (uv0.x - start) / len;
    if (hash(vec2(row, seed + 24.0)) > 0.5) t = 1.0 - t;        // trails point left or right
    float glow = hasStreak * step(0.0, t) * step(t, 1.0) * mix(0.2, 1.0, t * t);
    vec3 sc = neon(hash(vec2(row, seed + 25.0)));
    col.rgb = col.rgb * (1.0 - glow * 0.6) + sc * glow * 0.95 * a;
    col.a = max(col.a, glow * 0.9 * a);
    // vertical hairlines, broken up
    float vline = step(0.9985, hash(vec2(floor(px.x / 2.0), seed + 41.0))) * step(0.4, hash(vec2(floor(px.y / 14.0), floor(px.x / 2.0) + seed)));
    col.rgb += neon(hash(vec2(floor(px.x / 2.0), 42.0))) * vline * 0.3 * a;
    col.a = max(col.a, vline * 0.25 * a);

    // ---- pixel clusters: runs of little rainbow blocks
    vec2 cellSize = vec2(4.0 + 10.0 * hash1(floor(px.y / 4.0) + seed), 4.0);
    vec2 cell = floor(px / cellSize);
    float cluster = torn * step(1.0 - 0.18 * a, hash(floor(px / vec2(150.0, 24.0)) + seed));
    float bit = cluster * step(0.55, hash(cell + seed + 31.0));
    col.rgb = mix(col.rgb, rainbow(hash(cell + seed + 32.0)) * 0.9, bit * 0.55 * a);
    col.a = max(col.a, bit * 0.5 * a);

    // ---- tiny grid noise: dense dither / zigzag texture in teal and red, in horizontal runs,
    //      over a dark teal veil
    float mrow = floor(px.y / 2.0);
    float region = max(torn, smear) * step(1.0 - 0.35 * a, hash(vec2(floor(px.y / 22.0), floor(px.x / 260.0) + seed + 51.0)));
    float rowShift = floor(hash(vec2(mrow, seed + 52.0)) * 6.0);
    float zig = step(0.5, fract((px.x + rowShift + abs(fract(px.y / 6.0) - 0.5) * 6.0) / 3.0));
    float dith = step(0.5, hash(vec2(floor(px.x / 2.0), mrow) + seed + 53.0));
    float dense = step(0.35, hash(vec2(mrow, floor(px.x / 40.0) + seed + 54.0)));
    float g = region * zig * dith * dense;
    vec3 gc = hash(vec2(floor(px.x / 90.0), mrow + seed + 55.0)) > 0.8 ? vec3(1.0, 0.22, 0.2) : vec3(0.18, 0.62, 0.66);
    col.rgb = mix(col.rgb, vec3(0.02, 0.09, 0.11) * col.a, region * 0.2 * a);
    col.rgb = mix(col.rgb, gc * col.a, g * 0.35 * a);
    col.a = max(col.a, g * 0.18 * a);

    // ---- static, interlaced scanlines, flicker
    vec2 p = floor(px);
    vec3 grain = vec3(hash(p + seed), hash(p + seed + 0.37), hash(p + seed + 0.71)) - 0.5;
    col.rgb += grain * 0.07 * a * col.a;
    col.rgb *= 1.0 - 0.15 * a * step(0.5, fract(px.y / 2.0));
    col.rgb *= 1.0 - 0.2 * a * step(0.8, hash(vec2(seed, 9.0)));

    col = clamp(col, 0.0, 1.0);
    col.rgb = min(col.rgb, vec3(col.a));   // keep it premultiplied
    fragColor = col * qt_Opacity;
}
