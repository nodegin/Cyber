#version 440
// "Damaged screen" edge effect, drawn over everything (no source texture):
//   - a smooth glow hugging the screen edges, brightest in the corners, faint scanlines
//   - tearing: short bright bands that shoot in from the left/right edge and flicker
//   - dead blocks: a rare little chunk of the tint right at the edge
//   - veil: an even tint over the whole screen (eliminate mode darkens everything red)
// tint = the colour; strength fades it all; damage = how much tearing/blocks; time animates.
// Compile: /usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o damage.frag.qsb damage.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 tint;
    float strength;
    float time;
    float veil;
    float damage;
    float edgeWidth;   // how far the glow reaches in, as a fraction of the screen's short side
    vec2 pxSize;
};

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = uv * pxSize;
    float shortSide = min(pxSize.x, pxSize.y);

    // distance to the nearest edge, as a fraction of the short side (0 at the edge)
    float d = min(min(px.x, pxSize.x - px.x), min(px.y, pxSize.y - px.y)) / shortSide;
    float glow = pow(clamp(1.0 - d / edgeWidth, 0.0, 1.0), 2.2);
    // corners: both edges close
    vec2 c = abs(uv - 0.5) * 2.0;
    float corner = pow(c.x * c.y, 3.0);
    glow = clamp(glow + corner * 0.6, 0.0, 1.0);

    // interlaced scanlines and grain inside the glow
    float scan = 0.86 + 0.14 * step(1.5, mod(px.y, 3.0));
    float tick = floor(time * 24.0);
    float grain = (hash(px + tick) - 0.5) * 0.07;   // faint, per pixel: no visible grid
    float a = glow * (0.42 * scan + grain * glow);

    // tearing bands from the left / right edge
    float row = floor(px.y / 5.0);
    float t = floor(time * 13.0);
    float r = hash(vec2(row, t));
    if (r > 1.0 - 0.012 * damage) {
        float len = hash(vec2(row + 3.1, t)) * 0.18 + 0.03;
        bool fromLeft = hash(vec2(row, t + 7.7)) > 0.5;
        float x = fromLeft ? uv.x : 1.0 - uv.x;
        if (x < len) a += (1.0 - x / len) * 0.55 * (0.6 + 0.4 * hash(vec2(row, t + 2.0)));
    }
    // dead blocks near the edges
    vec2 cell = floor(px / vec2(26.0, 14.0));
    float b = hash(cell + floor(time * 9.0) * 0.37);
    if (b > 1.0 - 0.0015 * damage * glow * glow) a += 0.22;

    // a thin bright rim at the very edge
    float rim = smoothstep(0.004, 0.0, d);
    vec3 col = mix(tint.rgb, vec3(1.0), rim * 0.35);

    // the veil: the same colour, darkened, everywhere
    vec3 dark = tint.rgb * 0.1;
    float alpha = clamp(veil + a, 0.0, 1.0);
    vec3 outCol = mix(dark, col, clamp(a / max(alpha, 0.0001), 0.0, 1.0));

    alpha *= strength;
    fragColor = vec4(outCol * alpha, alpha) * qt_Opacity;
}
