#version 300 es
// Cyber's window glitch, run by Hyprland's own renderer (decoration:screen_shader).
// It is a template: cyber/hypr/glitch.lua fills in the @…@ values (which rectangles, how long,
// opening or closing) each time a window opens or closes, and switches it on for a moment.
// It works on the finished frame, so it distorts exactly what Hyprland drew in those rectangles,
// its own pop-in / fade animation included: it cannot lag behind the window.
// Same layers as the menus' glitch (glitch.frag): torn bands, smeared rows, RGB split, red
// interference, neon streaks, pixel runs, grid noise, static, scanlines, flicker.
precision highp float;

in vec2 v_texcoord;          // 0..1, origin top-left
uniform sampler2D tex;       // the finished frame
uniform float time;          // seconds, running; where it starts from is NOT relied on
out vec4 fragColor;

const vec2 SCREEN = vec2(@W@, @H@);   // monitor size in pixels
const float STRENGTH = @STRENGTH@;
const int MODE = @MODE@;              // 0 = opening (tears settle), 1 = closing (tears grow)
const float SALT = @SALT@;            // different tears every time

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
float hash1(float x) { return hash(vec2(x, x * 0.7 + 1.3)); }

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

// which rectangle (x0, y0, x1, y1 in pixels) is this pixel in?
bool rectAt(vec2 p, out vec4 r) {
@RECTS@
    return false;
}

// How torn, tick by tick (30 ticks a second): a stutter that repeats, not a fade. Hyprland
// switches the shader off when the effect is over (hypr/glitch.lua), so this never has to know
// when it started, and it is never blank while it is on.
const float OPENING[8] = float[8](0.9, 0.75, 0.15, 0.62, 0.25, 0.5, 0.12, 0.3);    // heavy, cutting out
const float CLOSING[8] = float[8](0.3, 0.6, 0.35, 0.85, 1.0, 0.7, 0.9, 1.0);       // worse and worse

void main() {
    vec4 base = texture(tex, v_texcoord);
    vec2 p = v_texcoord * SCREEN;
    float tick = floor(time * 30.0);
    int step8 = int(mod(tick, 8.0));
    float a = (MODE == 1 ? CLOSING[step8] : OPENING[step8]) * STRENGTH;
    vec4 r;
    if (!rectAt(p, r)) { fragColor = base; return; }

    vec2 size = r.zw - r.xy;
    vec2 px = p - r.xy;                       // pixel inside the rectangle
    vec2 uv0 = px / size;
    float seed = mod(tick, 4096.0) + SALT;    // new tears 30 times a second

    // ---- the picture: torn bands sliding sideways, smeared rows, RGB split
    vec2 uv = uv0;
    float bandH = 4.0 + floor(hash1(seed) * 40.0);
    float band = floor(px.y / bandH);
    float torn = step(1.0 - 0.55 * a, hash(vec2(band, seed)));
    uv.x += (hash(vec2(band, seed + 7.0)) - 0.5) * 0.18 * a * torn;
    float smear = step(1.0 - 0.3 * a, hash(vec2(band, seed + 8.0)));
    float run = 8.0 + 90.0 * hash(vec2(band, seed + 9.0));
    uv.x = mix(uv.x, floor(uv.x * size.x / run) * run / size.x, smear);
    float ca = (0.0008 + 0.009 * a) * (0.6 + 0.9 * torn);
    float inside = step(0.0, uv.x) * step(uv.x, 1.0);      // torn past the edge: dark
    vec2 cr = (r.xy + clamp(uv + vec2(ca, 0.0), 0.0, 1.0) * size) / SCREEN;
    vec2 cg = (r.xy + clamp(uv + vec2(0.0, ca * 0.15), 0.0, 1.0) * size) / SCREEN;
    vec2 cb = (r.xy + clamp(uv - vec2(ca, 0.0), 0.0, 1.0) * size) / SCREEN;
    vec3 col = vec3(texture(tex, cr).r, texture(tex, cg).g, texture(tex, cb).b);
    col = mix(vec3(0.02, 0.016, 0.04), col, inside);

    // ---- red interference bands
    float rb = floor(px.y / 18.0);
    if (hash(vec2(rb, floor(seed * 0.5))) > 1.0 - 0.12 * a) {
        float l = dot(col, vec3(0.3, 0.59, 0.11));
        col = mix(col, vec3(1.0, 0.18, 0.15) * (0.25 + 1.4 * l), 0.75);
        float dots = step(0.5, fract(px.y / 3.0)) * step(0.45, hash(vec2(floor(px.x / 3.0), floor(px.y / 3.0) + seed)));
        col += vec3(1.0, 0.2, 0.15) * dots * 0.3 * a;
    }

    // ---- neon light streaks, a few vertical hairlines
    float rowH = 2.0 + floor(hash1(seed + 3.0) * 3.0);
    float row = floor(px.y / rowH);
    float hasStreak = step(1.0 - 0.2 * a, hash(vec2(row, seed + 21.0)));
    float start = hash(vec2(row, seed + 22.0)) * 1.2 - 0.2;
    float len = 0.05 + 0.6 * pow(hash(vec2(row, seed + 23.0)), 2.0);
    float st = (uv0.x - start) / len;
    if (hash(vec2(row, seed + 24.0)) > 0.5) st = 1.0 - st;
    float glow = hasStreak * step(0.0, st) * step(st, 1.0) * mix(0.2, 1.0, st * st);
    col = col * (1.0 - glow * 0.6) + neon(hash(vec2(row, seed + 25.0))) * glow * 0.95 * a;
    float vline = step(0.9985, hash(vec2(floor(px.x / 2.0), seed + 41.0))) * step(0.4, hash(vec2(floor(px.y / 14.0), floor(px.x / 2.0) + seed)));
    col += neon(hash(vec2(floor(px.x / 2.0), 42.0))) * vline * 0.3 * a;

    // ---- pixel runs and tiny grid noise, only inside the bands that are tearing
    vec2 cellSize = vec2(4.0 + 10.0 * hash1(floor(px.y / 4.0) + seed), 4.0);
    vec2 cell = floor(px / cellSize);
    float cluster = torn * step(1.0 - 0.18 * a, hash(floor(px / vec2(150.0, 24.0)) + seed));
    float bit = cluster * step(0.55, hash(cell + seed + 31.0));
    col = mix(col, rainbow(hash(cell + seed + 32.0)) * 0.9, bit * 0.55 * a);

    float mrow = floor(px.y / 2.0);
    float region = max(torn, smear) * step(1.0 - 0.35 * a, hash(vec2(floor(px.y / 22.0), floor(px.x / 260.0) + seed + 51.0)));
    float rowShift = floor(hash(vec2(mrow, seed + 52.0)) * 6.0);
    float zig = step(0.5, fract((px.x + rowShift + abs(fract(px.y / 6.0) - 0.5) * 6.0) / 3.0));
    float dith = step(0.5, hash(vec2(floor(px.x / 2.0), mrow) + seed + 53.0));
    float dense = step(0.35, hash(vec2(mrow, floor(px.x / 40.0) + seed + 54.0)));
    float g = region * zig * dith * dense;
    vec3 gc = hash(vec2(floor(px.x / 90.0), mrow + seed + 55.0)) > 0.8 ? vec3(1.0, 0.22, 0.2) : vec3(0.18, 0.62, 0.66);
    col = mix(col, vec3(0.02, 0.09, 0.11), region * 0.2 * a);
    col = mix(col, gc, g * 0.35 * a);

    // ---- static, interlaced scanlines, flicker
    vec2 q = floor(px);
    col += (vec3(hash(q + seed), hash(q + seed + 0.37), hash(q + seed + 0.71)) - 0.5) * 0.07 * a;
    col *= 1.0 - 0.15 * a * step(0.5, fract(px.y / 2.0));
    col *= 1.0 - 0.2 * a * step(0.8, hash(vec2(seed, 9.0)));

    fragColor = vec4(clamp(col, 0.0, 1.0), base.a);
}
