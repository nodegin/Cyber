// Cyber's terminal look for Ghostty (custom-shader). Two things in one pass:
//
// 1. The window is a HUD panel, not a black rectangle: the same outline and glass as Cyber's HUD
//    dialogs (cyber/components/HudDialog.qml; keep the numbers in step): cut top-left corner, small
//    round top-right, the right edge stepping inwards part-way down, a long cut bottom-right; a
//    teal glow in the top-left falling off to dark navy; a cool grey-blue edge, heavier along the
//    top. Outside the outline the window is transparent. (ghostty/config sets background-opacity
//    to 0 so the shader paints the background.) The blur behind the glass and the cyan focus
//    markers outside the corners are drawn by Cyber's Hyprland plugin (cyber/hypr/corners), which
//    knows the same outline.
//
// 2. A CRT tube: the text is phosphor (it bleeds light and smears a little sideways), dark raster
//    lines run across everything (text, glass and what shows through it), lit text has a faint
//    shadow mask, the glass is lit from the middle and has static, and now and then a few rows
//    twitch sideways (JITTER). No screen curvature: the text stays where it is.
//    The band that drifts down the tube is not drawn here but by Cyber's Hyprland plugin
//    (plugin:cybercorners:scan_band): here it would need the whole terminal redrawn on every
//    refresh, which costs about a third of this PC's GPU; there only the band's rows are.
//
// It is a still picture by default: the static changes only when the terminal redraws (the cursor
// blinking is enough). The moving parts (flicker, the rolling band) are behind MOVING below plus
// `custom-shader-animation = true`: measured on this PC's integrated GPU, redrawing one focused
// 1728x1036 terminal every frame takes 47% of the GPU, the still version 1.4%.
// Tune the numbers below; Ghostty reloads the shader with its config (ctrl+shift+,).

// ---- the panel (pixels)
const float CUT      = 14.0;   // top-left cut
const float ROUND    = 5.0;    // top-right rounding
const float STEP_IN  = 10.0;   // how far the lower part of the right edge steps in
const float STEP_AT  = 0.43;   // where it steps, as a fraction of the height
const float BIG_CUT  = 38.0;   // bottom-right cut
const float EDGE     = 1.5;    // edge thickness; the top edge is drawn 1.7x heavier
// colours as you would pick them on screen (sRGB); the shader works in linear light, see lin()
const vec3  EDGE_COL = vec3(0.50, 0.60, 0.66);      // #8099a8
const vec3  TEAL     = vec3(0.114, 0.263, 0.294);   // #1d434b: the glow in the top-left corner
const vec3  NAVY     = vec3(0.020, 0.078, 0.118);   // #05141e: the rest of the glass
const float GLASS    = 0.20;   // how opaque the background gradient is while focused (0.2 = 80% see-through, blurred
                               // behind). Text and the edge stay solid. Unfocused, Hyprland fades the whole window
                               // like any other (inactive_opacity), text included.
const float DIM      = 0.60;   // how much the panel darkens what shows through it, so text stays readable over
                               // bright content (0 = not at all, 1 = black behind the text)

// ---- the tube
const float GLOW        = 0.6;    // phosphor bloom strength
const float GLOW_SPREAD = 1.6;    // bloom reach, in pixels
const float GLOW_FLOOR  = 0.20;   // darker than this doesn't glow
const float SMEAR       = 0.12;   // sideways phosphor smear of the text (more = fatter letters)
const float MOVING      = 0.0;    // 1.0 = flicker and the rolling band (needs custom-shader-animation = true)
const float RASTER_PX   = 3.0;    // one dark raster line every this many pixels (2 = finer, 4 = coarser)
const float RASTER      = 0.52;   // how dark that line is on text (0 = no lines)
const float RASTER_BG   = 0.60;   // ... on the glass's own tint
const float RASTER_SHADE = 0.20;  // ... and on what shows through the glass, so the lines are there over any background
const float RASTER_GAIN = 1.18;   // the text is brightened by this to make up for the lines
const float MASK        = 0.07;   // shadow mask: faint red, green and blue stripes on lit text (0 = none)
const float JITTER      = 1.2;    // now and then a thin band of rows slips sideways by about this many pixels (0 = never)
const float JITTER_ODDS = 0.085;  // ... on this share of the frames the terminal draws while it has the focus
const float AMBIENT     = 0.010;  // light in the middle of the glass
const float STATIC      = 0.0035; // static noise
const float FLICKER     = 0.018;  // brightness flicker
const float BAND        = 0.22;   // the rolling band's strength
const float CORNERS     = 0.30;   // corner darkening
const float FRINGE      = 0.8;    // colour fringing at the edges, in pixels

// Ghostty hands the shader linear-light colours and expects them back: convert picked colours
vec3 lin(vec3 c) { return pow(c, vec3(2.2)); }

// noise without sin(): no banding at large pixel coordinates
float hash(vec2 p) {
    vec3 q = fract(vec3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// distance (px) from p to the panel's outline: > 0 inside. p is measured from the top-left.
float panel(vec2 p, vec2 size) {
    float d = min(min(p.x, p.y), size.y - p.y);                          // left, top, bottom
    d = min(d, (p.x + p.y - CUT) * 0.7071);                              // top-left cut
    float stepY = size.y * STEP_AT;
    float right = size.x - STEP_IN * clamp((p.y - stepY) / STEP_IN, 0.0, 1.0);
    d = min(d, right - p.x);                                             // right edge, stepping in
    d = min(d, ((size.x - STEP_IN - p.x) + (size.y - p.y) - BIG_CUT) * 0.7071);   // bottom-right cut
    vec2 c = vec2(size.x - ROUND, ROUND);                                // top-right rounding
    if (p.x > c.x && p.y < c.y) d = min(d, ROUND - length(p - c));
    return d;
}

vec3 bright(vec3 c) {
    float l = max(c.r, max(c.g, c.b));
    return c * smoothstep(GLOW_FLOOR, 0.9, l);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 res = iResolution.xy;
    vec2 uv = fragCoord / res;
    vec2 px = 1.0 / res;
    vec2 p = vec2(fragCoord.x, res.y - fragCoord.y);     // pixels from the top-left
    vec2 fromCentre = uv - 0.5;
    float t = iTime;

    float d = panel(p, res);
    float inside = smoothstep(-0.5, 0.5, d);
    if (inside <= 0.0) { fragColor = vec4(0.0); return; }

    // ---- jitter: the picture is not quite steady. On some frames a thin band of rows sits a pixel
    // or so to the side. Only on frames the terminal draws anyway (typing, output, the cursor
    // blinking), so it costs nothing; while typing a twitch lasts one frame, on a still screen
    // until the cursor's next blink. Never without the focus: a terminal left alone is redrawn
    // once when the focus goes, which also straightens it.
    if (JITTER > 0.0 && iFocus > 0) {
        float tk = mod(floor(t * 60.0), 4099.0);
        if (hash(vec2(tk, 7.0)) < JITTER_ODDS) {
            float top = hash(vec2(tk, 13.0)), tall = 0.012 + 0.07 * hash(vec2(tk, 29.0));
            float in_band = step(top, uv.y) * step(uv.y, top + tall);
            float side = hash(vec2(tk, 41.0)) < 0.5 ? -1.0 : 1.0;
            uv.x += in_band * side * JITTER * (0.5 + hash(vec2(tk, 53.0))) * px.x;
        }
    }

    // ---- the text: red and blue pulled apart a touch towards the edges, smeared sideways
    vec2 shift = fromCentre * px * FRINGE * 2.0;
    vec4 base0 = texture(iChannel0, uv);
    vec4 base = base0;
    base.r = texture(iChannel0, uv + shift).r;
    base.b = texture(iChannel0, uv - shift).b;
    vec4 side = max(texture(iChannel0, uv - vec2(px.x, 0.0)), texture(iChannel0, uv + vec2(px.x, 0.0)));
    base = max(base, side * SMEAR);

    // ---- bloom: 9 taps instead of a 5x5 grid (25): the centre, 4 beside it and 4 diagonal further
    // out. Every tap sits between texels, so the sampler's own filtering averages 4 of them: about
    // the same soft halo for a third of the work (this shader runs for every pixel on every redraw).
    vec2 g1 = GLOW_SPREAD * 0.95 * px, g2 = GLOW_SPREAD * 1.75 * px;
    vec3 glow = bright(base0.rgb) * 0.16
        + (bright(texture(iChannel0, uv + vec2( g1.x, 0.0)).rgb) + bright(texture(iChannel0, uv + vec2(-g1.x, 0.0)).rgb)
         + bright(texture(iChannel0, uv + vec2(0.0,  g1.y)).rgb) + bright(texture(iChannel0, uv + vec2(0.0, -g1.y)).rgb)) * 0.135
        + (bright(texture(iChannel0, uv + vec2( g2.x,  g2.y)).rgb) + bright(texture(iChannel0, uv + vec2(-g2.x,  g2.y)).rgb)
         + bright(texture(iChannel0, uv + vec2( g2.x, -g2.y)).rgb) + bright(texture(iChannel0, uv + vec2(-g2.x, -g2.y)).rgb)) * 0.075;
    glow *= GLOW;

    // ---- the glass: teal in the top-left corner, navy elsewhere, lit from the middle, with static
    float reach = max(420.0, 0.42 * length(res));
    vec3 glass = mix(lin(TEAL), lin(NAVY), smoothstep(0.0, 1.0, length(p) / reach));
    glass += vec3(0.0, 0.7, 1.0) * AMBIENT * (1.0 - smoothstep(0.0, 0.75, length(fromCentre)));
    // The static's pattern changes 30 times a second. The time is wrapped before it moves the
    // pattern: added as it is, after some hours it is so large that a float can no longer hold the
    // pixel position next to it (steps of 8 at 20 hours), and the static turned into 8-pixel bars.
    float tick = floor(t * 30.0);
    float noise = hash(floor(fragCoord) + vec2(mod(tick, 289.0) * 37.0, mod(tick, 283.0) * 91.0)) - 0.5;
    glass = max(glass + noise * STATIC, vec3(0.0));

    // ---- raster lines, the rolling band, flicker
    // one whole pixel row in every RASTER_PX is dark, the rows between are lit: lines you can count,
    // like the gaps between a tube's scan lines (a cosine at this size only dimmed two rows in three)
    float line = mod(floor(p.y), RASTER_PX) < 1.0 ? 1.0 : 0.0;
    float bandPos = fract(t / 7.0) * 1.3 - 0.15;                         // top to bottom every 7 s
    float band = MOVING * smoothstep(0.10, 0.0, abs((1.0 - uv.y) - bandPos));
    float flick = 1.0 + MOVING * FLICKER * (sin(t * 97.0) * 0.6 + sin(t * 13.0) * 0.4);

    // the letters take the lines in full, their bloom only half (light spills across the gaps)
    float stripe = mod(floor(p.x), 3.0);
    vec3 grille = 1.0 - MASK + MASK * 2.0 * vec3(stripe < 1.0, stripe >= 1.0 && stripe < 2.0, stripe >= 2.0);
    vec3 lit = (base.rgb * (1.0 - RASTER * line) * grille + glow * (1.0 - 0.5 * RASTER * line))
        * RASTER_GAIN * (1.0 + BAND * band + noise * 0.25) * flick;
    glass = glass * (1.0 - RASTER_BG * line) * (1.0 + BAND * 0.6 * band) * flick;

    // the text over the glass (both premultiplied), then the light it gives off
    float textA = clamp(base.a, 0.0, 1.0);
    float glassA = GLASS + (1.0 - GLASS) * DIM;          // the tint, plus black for the dimming
    vec3 col = lit + glass * GLASS * (1.0 - textA);
    float alpha = clamp(textA + glassA * (1.0 - textA) + 0.3 * max(glow.r, max(glow.g, glow.b)), 0.0, 1.0);
    // a raster line also darkens what shows through the glass (black, added to the alpha only)
    alpha = clamp(alpha + RASTER_SHADE * line * (1.0 - textA) * (1.0 - alpha), 0.0, 1.0);

    // darker corners
    float corner = dot(fromCentre, fromCentre) * 2.0;
    col *= 1.0 - CORNERS * corner * corner;

    // ---- the edge: a line on the outline, heavier along the top
    float thick = EDGE * (p.y < 6.0 && p.x > CUT && p.x < res.x - ROUND ? 1.7 : 1.0);
    float edge = 1.0 - smoothstep(thick - 0.5, thick + 0.5, d);
    float focus = iFocus > 0 ? 1.0 : 0.6;
    col = mix(col, lin(EDGE_COL) * focus, edge * 0.9);
    alpha = max(alpha, edge * 0.9);

    fragColor = vec4(col, alpha) * inside;
}
