#version 440
// The tilted Looking Glass panel (hud/LookingGlassPanel.qml) as a curved screen. The flat panel is
// bent like a wrap-around display (its middle lies behind its edges), then swung back on its left
// edge and tipped back a touch, in perspective: the same two rotations the panel had as a flat
// sheet (21 degrees about the vertical axis, -3 about the horizontal one, both seen from
// 1.6 x its width away). With curve = 0 it is that flat sheet again, pixel for pixel.
// Drawn over a row of narrow strips (GridMesh), so its top and bottom edges really are curves.
// flip = 1 is the mirror image: swung back on its RIGHT edge, for a panel on the right of the
// screen (the capture HUD, popups/Capture.qml, which also has this projection's inverse in JS for
// the pointer: change both together).
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 qt_TexCoord0;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float tilt;      // 0 flat .. 1 tilted
    float curve;     // how far the middle lies behind the edges, as a fraction of the width
    float margin;    // the picture has this much room around the panel (for the outline's soft edge)
    vec2 size;       // the panel, without that room
    float flip;      // 0: hinged on its left edge; 1: mirrored, hinged on its right edge
};
void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    float W = size.x, H = size.y, d = W * 1.6;
    // where this point is on the flat panel: x from its left edge, y from its middle
    float x = qt_MultiTexCoord0.x * (W + 2.0 * margin) - margin;
    float y = qt_MultiTexCoord0.y * (H + 2.0 * margin) - margin - H * 0.5;
    x = mix(x, W - x, flip);                                 // from here on: measured from the hinge edge
    float u = clamp(x / W, 0.0, 1.0);
    float z = -curve * W * 4.0 * u * (1.0 - u) * tilt;      // the bend: a shallow arc, deepest in the middle

    float a = radians(21.0) * tilt, b = radians(-3.0) * tilt;
    float x1 = x * cos(a) + z * sin(a);
    float z1 = -x * sin(a) + z * cos(a);
    float w1 = 1.0 - z1 / d;                                 // further away = smaller
    float y1 = y / w1;
    float w2 = 1.0 - y1 * sin(b) / d;

    float px = x1 / (w1 * w2);
    vec4 p = qt_Matrix * vec4(mix(px, W - px, flip), y1 * cos(b) / w2 + H * 0.5, 0.0, 1.0);
    // the same place on screen, and the picture keeps its perspective inside each strip
    gl_Position = p * (w1 * w2);
}
