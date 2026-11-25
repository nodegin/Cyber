// cybercorners: a Hyprland plugin for the Cyber desktop.
// Windows have no border; the focused window gets four cyan corner brackets  ┌ ┐ └ ┘  just outside
// its corners. It is a window decoration, drawn by Hyprland in the same frame as the window, so the
// brackets move, fade and glitch with it and never trail behind.
//
// "Panel" windows (tagged "cyberpanel" by a window rule: Cyber's terminal, which draws itself as a
// HUD panel with cut corners, see ghostty/crt.glsl) get two things instead:
//   * markers that follow the outline: a "/" outside the two cut corners (top-left, bottom-right)
//     and brackets on the other two;
//   * the frosted-glass blur in the panel's shape. Hyprland blurs behind a window's whole rectangle,
//     also where the window is transparent, so the cut-away parts would show a blurred patch. This
//     plugin gives the window's surface a blur region in the panel's shape (the same field the
//     ext-background-effect protocol fills in), and Hyprland's own window blur is clipped to it:
//     one blur per window, like any other window. (Until v1.2 the plugin drew the blur itself as
//     ~24 strips, each a separate blur: measured at a quarter of the compositor's GPU time.)
// Every see-through window (panel or not, tiled or floating) also gets its blurred backdrop from
// this plugin since v3.0: blurred at a quarter of the size and kept until what is behind changes
// ("The stored backdrop" below). It also measures the FPS shown in the HUD (countFrame below).
// The outline's numbers (PANEL_* below) are the same as in ghostty/crt.glsl and
// cyber/components/HudDialog.qml: keep them in step.
//
// Loaded only on the Cyber desktop: setup.sh's "cyber desktop" block calls hl.plugin.load(), and
// Hyprland unloads it by itself when a reload no longer asks for it (switching to end-4/pC).
// Build:  ./build.sh   (also run automatically after a Hyprland update, see setup.sh)
//
// Tunable at runtime, e.g.  hyprctl eval 'hl.config({ plugin = { cybercorners = { length = 24 } } })'
//   color      0xAARRGGBB          default 0xff3cf0ff (Theme.cyan)
//   length     arm length, px      default 16
//   thickness  line width, px      default 2
//   gap        space from window   default 3
//   backdrop_fps     most redos a second of a see-through window's stored blur   default 60, 0 = off
//   backdrop_spread  its blur width, percent of blur size * 2^passes             default 52 (= Hyprland's look)
//   reuse_frames     copy unchanged areas from the previous frame (see reuseShown)  default 1, 0 = off

#define WLR_USE_UNSTABLE

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/WindowRenderPresentation.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/config/values/types/ColorValue.hpp>
#include <hyprland/src/config/values/types/IntValue.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/ipc/s2/S2.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/render/Framebuffer.hpp>
#include <hyprland/src/render/gl/GLFramebuffer.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/animation/WorkspaceAnimationController.hpp>
#include <hyprland/src/desktop/view/window/WindowFullscreenPolicy.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>
#include <hyprland/src/managers/screenshare/ScreenshareManager.hpp>   // only for the kinds of share (never call Screenshare::mgr() here)

#include <aquamarine/output/Output.hpp>

#include <algorithm>
#include <deque>
#include <cmath>
#include <chrono>
#include <string>
#include <unordered_map>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static HANDLE PHANDLE = nullptr;

// dndfix.cpp: drag and drop that ends (a workaround for Hyprland 0.57)
void        dndFixInit(HANDLE handle);
void        dndFixExit();
std::string dndFixInfo();
// dragws.cpp: a dragged window comes along to another workspace
void        dragWsInit(HANDLE handle);
void        dragWsExit();
std::string dragWsInfo();

#ifndef SPREAD_DEFAULT
#define SPREAD_DEFAULT 52
#endif

static struct {
    SP<Config::Values::CColorValue> color, pinColor;
    SP<Config::Values::CIntValue>   length, thickness, gap, backdropFps, backdropSpread, reuse, scan, scanPeriod;
} vars;

static constexpr uint32_t ALL_EDGES = DECORATION_EDGE_TOP | DECORATION_EDGE_BOTTOM | DECORATION_EDGE_LEFT | DECORATION_EDGE_RIGHT;

// ---- the HUD panel outline (pixels at scale 1)
static constexpr double PANEL_CUT     = 14;     // top-left cut
static constexpr double PANEL_STEP_IN = 10;     // how far the lower part of the right edge steps in
static constexpr double PANEL_STEP_AT = 0.43;   // where it steps, as a fraction of the height
static constexpr double PANEL_BIG_CUT = 38;     // bottom-right cut

// The last frames, for the diagnostic dump (cyber-corners-frames): when rendering started, how long
// the compositor's own work on it took (CPU side), when the screen showed it, and what had changed.
struct SFrameRec {
    uint64_t    id = 0;
    double      start = 0, cpu = -1, shown = -1;   // seconds
    int         late = 0;
    std::string what;
    double      mine[3] = {0, 0, 0};
    bool        real = false;                      // it drew something (Hyprland also runs frames that draw nothing)
};
static std::deque<SFrameRec> g_frameLog;
static double                g_mine[3] = {0, 0, 0};   // this frame: seconds in the blur update / backdrop draws / copying unchanged areas
struct STimed {
    double&                               slot;
    std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
    ~STimed() { slot += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(); }
};
static std::string           g_changedNow;        // filled by updateBuried: what changed since the frame before
static uint64_t              g_frameId = 0;
static double secondsOf(std::chrono::steady_clock::time_point t) {
    return std::chrono::duration<double>(t.time_since_epoch()).count();
}

// see "Reusing what the screen already shows" below
struct SReuse {
    WP<Render::IFramebuffer> last;               // the output buffer of the frame before
    bool                     valid     = false;  // ... which was rendered to the end
    CRegion                  fresh;              // what changed since that frame began (taken at render.pre)
    bool                     haveFresh = false, forced = false;
    // for the dump
    int    frames = 0, used = 0;
    double copiedPx = 0, drawnPx = 0;
};
static std::unordered_map<MONITORID, SReuse> g_reuse;

static bool isPanel(const PHLWINDOW& w) {
    return w && w->m_ruleApplicator->m_tagKeeper.isTagged("cyberpanel");
}
// GNOME Files in Cyber's look (gtk/cyber.css; keep these numbers in step with it): a folder outline.
// The focus markers follow it, as they follow the terminal's panel outline.
static constexpr double FOLDER_CUT  = 14;     // top-left cut
static constexpr double FOLDER_DROP = 14;     // the file pane's top edge is this much lower than the tab's
static constexpr double FOLDER_BIG  = 34;     // bottom-right cut
static bool isFolder(const PHLWINDOW& w) {
    return w && w->m_ruleApplicator->m_tagKeeper.isTagged("cyberfolder");
}
// a see-through window whose blur follows its own picture (see Fast::drawFrom)
static bool isShaped(const PHLWINDOW& w) {
    return w && w->m_ruleApplicator->m_tagKeeper.isTagged("cybershape");
}

// ---- the scan band: a faint lighter band drifting down Cyber's terminal, like the one that rolls
// down a filmed tube. It is drawn here, over the focused panel window, not in the terminal's own
// shader: there it would mean redrawing the whole terminal on every refresh (measured 2026-11-25:
// about a third of the GPU for one 1300x760 terminal, against 1% for the still shader). Here a
// step redraws only the rows the band covers. The band is a ramp: see-through at its top, brightest
// at its lower edge, where it ends (the user's reference, 2026-11-25).
// plugin:cybercorners:scan_band is the brightness at that edge in percent (0 = none), scan_period
// the seconds it takes from top to bottom.
static constexpr int SCAN_SLICES = 26;      // the band is drawn as this many strips: see-through at the top, brightest at its lower edge
struct SScanBand {
    double top = 0, height = 0;             // in the window's own pixels (top can be above or below the window)
};
static SScanBand scanBandAt(double windowHeight, std::chrono::steady_clock::time_point when) {
    const double period = std::max<Config::INTEGER>(2, vars.scanPeriod ? vars.scanPeriod->value() : 7);
    const double t      = std::chrono::duration<double>(when.time_since_epoch()).count();
    const double pos    = std::fmod(t, period) / period;
    const double h      = std::clamp(windowHeight * 0.24, 80.0, 420.0);
    return {-h + pos * (windowHeight + h), h};
}

class CCyberCorners : public IHyprWindowDecoration {
  public:
    CCyberCorners(PHLWINDOW w) : IHyprWindowDecoration(w), m_window(w) {}
    ~CCyberCorners() override = default;

    // reserve a thin ring around the window (it does not change the window's size or the layout)
    SDecorationPositioningInfo getPositioningInfo() override {
        m_extent = extent();
        SDecorationPositioningInfo info;
        info.policy         = DECORATION_POSITION_STICKY;
        info.edges          = ALL_EDGES;
        info.priority       = 9970;   // outside a border, if one is ever turned back on
        info.reserved       = false;
        info.desiredExtents = {{m_extent, m_extent}, {m_extent, m_extent}};
        return info;
    }
    void onPositioningReply(const SDecorationPositioningReply& reply) override {
        m_assigned = reply.assignedGeometry;
    }

    eDecorationType  getDecorationType() override { return DECORATION_CUSTOM; }
    eDecorationLayer getDecorationLayer() override { return DECORATION_LAYER_OVER; }
    uint64_t         getDecorationFlags() override { return 0; }   // not part of the window: blur / shadow ignore it
    std::string      getDisplayName() override { return "CyberCorners"; }

    void updateWindow(PHLWINDOW) override {
        if (extent() != m_extent)
            g_pDecorationPositioner->repositionDeco(this);
        damageEntire();
    }
    void updateState() override { damageEntire(); }      // focus moved: draw or erase
    void onWindowFocus() override { damageEntire(); }

    void damageEntire() override {
        const auto W = m_window.lock();
        if (!W || !W->mapped() || m_assigned.width <= 0 || m_assigned.height <= 0)
            return;
        CBox box = m_assigned;
        box.translate(g_pDecorationPositioner->getEdgeDefinedPoint(ALL_EDGES, W));
        box.translate(W->presentation().renderPresentation().workspaceOffset);
        CRegion ring(box);
        if (!isPanel(W) && !isFolder(W))   // "/" markers along cut corners are inside the rectangle: damage all of it
            ring.subtract(box.copy().expand(-(m_extent + 2)));
        ring.expand(2);
        g_pHyprRenderer->damageRegion(ring);
    }

    void draw(Render::CRenderContext& ctx, PHLMONITOR mon, float const& a, const Render::SWindowRenderPresentation& pres) override {
        const auto W = m_window.lock();
        if (!W || !W->mapped() || !wanted(W) || a <= 0.F)
            return;
        if (m_assigned.width < 2 * m_extent + 4 || m_assigned.height < 2 * m_extent + 4)
            return;

        CBox box = m_assigned;
        box.translate(g_pDecorationPositioner->getEdgeDefinedPoint(ALL_EDGES, W));
        box.translate(pres.workspaceOffset - mon->m_position + pres.floatingOffset);
        box.scale(mon->m_scale).round();

        const double T = std::max(1.0, (double)std::round(vars.thickness->value() * mon->m_scale));
        double       L = std::round((double)vars.length->value() * mon->m_scale);
        L              = std::clamp(L, T, std::floor(std::min(box.width, box.height) / 2.0));

        CHyprColor col{sc<uint64_t>((pinned(W) ? vars.pinColor : vars.color)->value())};
        col.a *= a;

        const double x0 = box.x, y0 = box.y, x1 = box.x + box.width, y1 = box.y + box.height;
        const auto   rect = [&](const CBox& r) {
            CRectPassElement::SRectData d;
            d.box   = r;
            d.color = col;
            g_pHyprRenderer->addPassElement(ctx, makeUnique<CRectPassElement>(d));
        };

        if (isFolder(W)) {   // └ as usual, ┐ at the lowered corner, "/" along the two cuts
            const double S = mon->m_scale, E = std::round(m_extent * S), off = (E - T / 2.0) * 0.7071, W2 = std::ceil(T * 1.4142);
            const double wx0 = x0 + E, wy0 = y0 + E, wx1 = x1 - E, wy1 = y1 - E;
            const double cut = FOLDER_CUT * S, drop = std::round(FOLDER_DROP * S), big = FOLDER_BIG * S;
            const auto   slash = [&](double ax, double ay, double len) {
                const int rows = std::max(1, (int)std::round(len));
                for (int i = 0; i < rows; ++i)
                    rect({std::round(ax - i - W2 / 2.0), std::round(ay + i), W2, 1.0});
            };
            rect({x1 - L, y0 + drop, L, T}); rect({x1 - T, y0 + drop, T, L});   // ┐
            rect({x0, y1 - T, L, T});        rect({x0, y1 - L, T, L});          // └
            slash(wx0 + cut - off, wy0 - off, cut);                             // top-left
            slash(wx1 + off, wy1 - big + off, big);                             // bottom-right
            return;
        }

        rect({x1 - L, y0, L, T});       rect({x1 - T, y0, T, L});        // ┐
        rect({x0, y1 - T, L, T});       rect({x0, y1 - L, T, L});        // └

        if (!isPanel(W)) {
            rect({x0, y0, L, T});           rect({x0, y0, T, L});            // ┌
            rect({x1 - L, y1 - T, L, T});   rect({x1 - T, y1 - L, T, L});    // ┘
            return;
        }

        // a panel: "/" along its two cut corners, the same distance outside the outline as the brackets
        const double S   = mon->m_scale;
        const double E   = std::round(m_extent * S);             // the window's own box is this far inside `box`
        const double off = (E - T / 2.0) * 0.7071;               // the line's centre, outwards from the cut
        const double wx0 = x0 + E, wy0 = y0 + E, wx1 = x1 - E, wy1 = y1 - E;
        const double W2  = std::ceil(T * 1.4142);                // a 45° line this wide looks T thick
        // rows from (ax, ay) down to (bx, by), x going left as y goes down
        const auto slash = [&](double ax, double ay, double len) {
            const int rows = std::max(1, (int)std::round(len));
            for (int i = 0; i < rows; ++i)
                rect({std::round(ax - i - W2 / 2.0), std::round(ay + i), W2, 1.0});
        };
        const double cut = PANEL_CUT * S, big = PANEL_BIG_CUT * S, stepIn = PANEL_STEP_IN * S;
        slash(wx0 + cut - off, wy0 - off, cut);                              // top-left
        slash(wx1 - stepIn + off, wy1 - big + off, big);                     // bottom-right

        // the scan band, inside the panel's outline (a strip is as wide as the outline is at its
        // narrowest row, so nothing shows in the cut-away corners)
        const double strength = vars.scan->value() / 100.0;
        const double wh = wy1 - wy0, ww = wx1 - wx0;
        if (strength <= 0 || wh < 80 || ww < 80)
            return;
        const auto   band  = scanBandAt(wh / S, std::chrono::steady_clock::now());
        const double stepY = std::round(wh * PANEL_STEP_AT);
        const auto   left  = [&](double y) { return std::max(0.0, cut - y); };
        const auto   right = [&](double y) {
            double r = ww - stepIn * std::clamp((y - stepY) / stepIn, 0.0, 1.0);
            return std::min(r, ww - stepIn - std::max(0.0, big - (wh - y)));
        };
        const double sh = band.height * S / SCAN_SLICES;
        for (int i = 0; i < SCAN_SLICES; ++i) {
            const double ya = std::round(band.top * S + i * sh), yb = std::round(band.top * S + (i + 1) * sh);
            const double y0c = std::max(0.0, ya), y1c = std::min(wh, yb);
            if (y1c - y0c < 1)
                continue;
            const double xl = std::max(left(y0c), left(y1c)), xr = std::min(right(y0c), right(y1c));
            if (xr - xl < 1)
                continue;
            const double w = (i + 1.0) / SCAN_SLICES;                         // a ramp: nothing at the top, full at the lower edge
            CRectPassElement::SRectData d;
            d.box   = CBox{wx0 + xl, wy0 + y0c, xr - xl, y1c - y0c};
            d.color = CHyprColor{0.62, 0.94, 1.0, (float)(strength * w * a)};
            g_pHyprRenderer->addPassElement(ctx, makeUnique<CRectPassElement>(d));
        }
    }

  private:
    PHLWINDOWREF m_window;
    CBox         m_assigned;
    double       m_extent = 0;

    static double extent() {
        return std::max<Config::INTEGER>(0, vars.gap->value()) + std::max<Config::INTEGER>(1, vars.thickness->value());
    }
    // pinned (Super+P): shown on every workspace. Such a window keeps its brackets, in another
    // colour, focused or not: the one lasting sign that it is pinned.
    static bool pinned(const PHLWINDOW& w) {
        return (sc<uint8_t>(w->m_state) & sc<uint8_t>(Desktop::View::eWindowState::WINDOW_STATE_PINNED)) != 0;
    }
    // only the focused window (and pinned ones), and not when it is fullscreen or asks for no decorations
    static bool wanted(const PHLWINDOW& w) {
        if (w != Desktop::focusState()->window() && !pinned(w))
            return false;
        if (w->m_workspace && Fullscreen::controller()->getFullscreenModes(w).internal == Fullscreen::FSMODE_FULLSCREEN)
            return false;
        if (!w->m_ruleApplicator->decorate().valueOrDefault())
            return false;
        return true;
    }
};

// ---------------------------------------------------------------------------------------------
// The stored backdrop, and a small blur to fill it.
//
// A see-through window is drawn as "blur what is behind it, then the window on top". Hyprland's
// blur works at full resolution and is redone whenever anything in the window's area is redrawn: a
// wallpaper frame, a video behind it, or just the window's own text changing. For tiled windows it
// blurs the whole screen once per wallpaper frame. Measured on the Radeon 610M at 3440x1440: about
// 3.7 ms per megapixel each time, plus about 2 ms per megapixel to redraw what is behind.
//
// Here, for every see-through window (tiled or floating):
//   * the blur is done the way phone compositors do it: what is behind the window is shrunk to a
//     quarter of its size (two halvings), blurred there (1/16 of the pixels) and stretched back
//     when it is drawn. Hyprland's contrast, vibrancy, brightness and grain are applied with its
//     own formulas, so it looks like Hyprland's blur at `decoration:blur:size` / `passes`;
//   * the blurred picture is kept (two small textures per window: before and after the blur) and
//     brought up to date only where something behind the window really changed (updateBuried
//     below compares, every frame, what each window and each background layer shows with the
//     frame before): a video in a corner behind a big window redoes that corner, not the window.
//     The window's own redraws never redo it. Where the picture is reused Hyprland is told the
//     backdrop is opaque, so nothing behind the window is redrawn there either.
// `plugin:cybercorners:backdrop_fps` caps how often it is redone (60 = whenever something
// changed); 0 turns all of this off (Hyprland's own blur, clipped to the panel's shape).
// `plugin:cybercorners:backdrop_spread` is the blur width, in percent of Hyprland's.
struct SBackdropState {
    GLuint                                 tex = 0, fbo = 0;         // the blurred backdrop, shrunk by `factor`
    GLuint                                 rawTex = 0, rawFbo = 0;   // the same picture before the blur: a change in one part is blurred into its surroundings from here
    int                                    qw = 0, qh = 0, factor = 4;
    CBox                                   src;                // what it shows: a rectangle of the screen (monitor pixels, multiples of factor)
    CBox                                   box;                // where the window was
    MONITORID                              monitor = MONITOR_INVALID;
    bool                                   have = false;       // the textures hold a picture
    CRegion                                stale;              // ... but here what is behind the window changed since (monitor pixels, on the grid, inside src)
    std::chrono::steady_clock::time_point  refreshed{}, checked{}, used{};
    int                                    attempts = 0;       // frames in a row that were asked to redraw what is behind and did not
    // for the diagnostic dump: what happened since the last dump
    int    nRefresh = 0, nReuse = 0, nCatchUp = 0, nMarked = 0;
    double blurredPx = 0, drawnPx = 0;
};

static double areaOf(const CRegion& rg) {
    double a = 0;
    for (auto& r : rg.getRects())
        a += (double)(r.x2 - r.x1) * (double)(r.y2 - r.y1);
    return a;
}

// ---- the small blur (plain OpenGL ES 3; every piece of GL state it touches is put back)
namespace Fast {
    struct STarget {
        GLuint fbo = 0, tex = 0;
        int    w = 0, h = 0;
    };
    static GLuint                                 g_vao = 0, g_blur = 0, g_draw = 0;
    static STarget                                g_level[4];   // scratch: 1/2, 1/4, 1/8, 1/16 of the largest window so far
    static STarget                                g_pass;       // scratch: after the first blur direction
    static bool                                   g_failed = false;
    static std::vector<std::pair<GLuint, GLuint>> g_trash;      // (framebuffer, texture) of windows that are gone
    static struct {
        GLint tex, texel, dir, lo, hi, w0, taps, stage, contrast, brightness, vibrancy, vibrancyDarkness, passes;
    } ub;
    static struct {
        GLint tex, origin, extent, screen, noise, brightness, alpha, mask, maskBox;
    } ud;

    static const char* VERT = R"(#version 300 es
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
})";

    // One direction of a Gaussian blur on the shrunk picture: 9 lookups stand for 17 pixels (each
    // lookup between two pixels reads both, weighted). stage 0, across: Hyprland's contrast and
    // brightness on what is read (its blurprepare). stage 1, down: its vibrancy on the result (blur1).
    static const char* BLUR = R"(#version 300 es
precision highp float;
uniform sampler2D tex;
uniform vec2  texel;       // 1 / size of tex
uniform vec2  dir;         // (1,0) or (0,1)
uniform vec2  lo, hi;      // pixel centres to stay inside (what was just copied)
uniform float w0;          // weight of the centre
uniform vec2  taps[4];     // (distance, weight) of the four pairs around it
uniform int   stage, passes;
uniform float contrast, brightness, vibrancy, vibrancyDarkness;
out vec4 fragColor;

const float Pr = 0.299, Pg = 0.587, Pb = 0.114;
const float A = 0.93, B = 0.11, C = 0.66;
vec3 gain(vec3 src, float k) {
    vec3 x = clamp(src, 0.0, 1.0);
    vec3 t = step(0.5, x);
    vec3 y = mix(x, 1.0 - x, t);
    vec3 a = 0.5 * pow(2.0 * y, vec3(k));
    return mix(a, 1.0 - a, t);
}
float doubleCircleSigmoid(float x, float a) {
    a = clamp(a, 0.0, 1.0);
    return x <= a ? a - sqrt(max(0.0, a * a - x * x)) : a + sqrt(max(0.0, pow(1.0 - a, 2.0) - pow(x - 1.0, 2.0)));
}
vec3 rgb2hsl(vec3 col) {
    float minc = min(col.r, min(col.g, col.b)), maxc = max(col.r, max(col.g, col.b));
    float delta = maxc - minc, lum = (minc + maxc) * 0.5, sat = 0.0, hue = 0.0;
    if (lum > 0.0 && lum < 1.0)
        sat = delta / (((lum < 0.5) ? lum : (1.0 - lum)) * 2.0);
    if (delta > 0.0) {
        vec3 maxcVec = vec3(maxc);
        vec3 masks   = vec3(equal(maxcVec, col)) * vec3(notEqual(maxcVec, vec3(col.g, col.b, col.r)));
        vec3 adds    = vec3(0.0, 2.0, 4.0) + vec3(col.g - col.b, col.b - col.r, col.r - col.g) / delta;
        hue = dot(adds, masks) / 6.0;
        if (hue < 0.0) hue += 1.0;
    }
    return vec3(hue, sat, lum);
}
vec3 hsl2rgb(vec3 col) {
    float hue = col.x, sat = col.y, lum = col.z;
    vec3  xt;
    if (hue < 1.0 / 3.0)      xt = vec3(6.0 * (1.0 / 3.0 - hue), 6.0 * hue, 0.0);
    else if (hue < 2.0 / 3.0) xt = vec3(0.0, 6.0 * (2.0 / 3.0 - hue), 6.0 * (hue - 1.0 / 3.0));
    else                      xt = vec3(6.0 * (hue - 2.0 / 3.0), 0.0, 6.0 * (1.0 - hue));
    xt = min(xt, 1.0);
    vec3 ct = (2.0 * sat * xt) + (1.0 - sat);
    return lum >= 0.5 ? ((1.0 - lum) * ct) + (2.0 * lum - 1.0) : lum * ct;
}
vec3 take(vec2 p) {
    vec3 c = texture(tex, clamp(p, lo, hi) * texel).rgb;
    if (stage == 0) {
        if (contrast != 1.0)
            c = gain(c, contrast);
        c *= max(1.0, brightness);
    }
    return c;
}
void main() {
    vec2 p = gl_FragCoord.xy;
    vec3 c = take(p) * w0;
    for (int i = 0; i < 4; i++) {
        vec2 o = dir * taps[i].x;
        c += (take(p + o) + take(p - o)) * taps[i].y;
    }
    if (stage == 1 && vibrancy != 0.0) {
        // Hyprland boosts the saturation once per pass, each time by vibrancy / passes
        float dark = 1.0 - vibrancyDarkness, b1 = B * dark;
        for (int k = 0; k < passes; k++) {
            vec3  hsl = rgb2hsl(c);
            float perceived = doubleCircleSigmoid(sqrt(c.r * c.r * Pr + c.g * c.g * Pg + c.b * c.b * Pb), 0.8 * dark);
            float boost = hsl.y > 0.0 ? smoothstep(b1 - C * 0.5, b1 + C * 0.5, 1.0 - (pow(1.0 - hsl.y * cos(A), 2.0) + pow(1.0 - perceived * sin(A), 2.0))) : 0.0;
            c = hsl2rgb(vec3(hsl.x, clamp(hsl.y + boost * vibrancy / float(passes), 0.0, 1.0), hsl.z));
        }
    }
    fragColor = vec4(c, 1.0);
})";

    // the stored picture, stretched back to full size, with Hyprland's grain (its blurfinish)
    static const char* DRAW = R"(#version 300 es
precision highp float;
uniform sampler2D tex;
uniform vec2  origin;      // screen pixel of the picture's corner
uniform vec2  extent;      // screen pixels the picture covers
uniform vec2  screen;
uniform float noise, brightness, alpha;
uniform sampler2D mask;    // the window's own picture: the backdrop shows only where that paints something
uniform vec4  maskBox;     // where that picture is on screen (x, y, w, h); w = 0: no mask
out vec4 fragColor;
float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 1689.1984);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
void main() {
    float m = 1.0;
    if (maskBox.z > 0.0) {
        m = smoothstep(0.004, 0.04, texture(mask, (gl_FragCoord.xy - maskBox.xy) / maskBox.zw).a);
        if (m <= 0.0)
            discard;
    }
    vec3 c = texture(tex, (gl_FragCoord.xy - origin) / extent).rgb;
    c += (hash(gl_FragCoord.xy / screen) - 0.5) * noise;
    c *= min(1.0, brightness);
    fragColor = vec4(c * alpha, alpha) * m;
})";

    static GLuint shader(GLenum type, const char* text) {
        const GLuint sh = glCreateShader(type);
        glShaderSource(sh, 1, &text, nullptr);
        glCompileShader(sh);
        GLint ok = 0;
        glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
        if (!ok) {
            char log[512] = {0};
            glGetShaderInfoLog(sh, sizeof(log) - 1, nullptr, log);
            fprintf(stderr, "[cybercorners] shader: %s\n", log);
            glDeleteShader(sh);
            return 0;
        }
        return sh;
    }
    static GLuint program(const char* frag) {
        const GLuint vs = shader(GL_VERTEX_SHADER, VERT), fs = shader(GL_FRAGMENT_SHADER, frag);
        if (!vs || !fs)
            return 0;
        const GLuint pr = glCreateProgram();
        glAttachShader(pr, vs);
        glAttachShader(pr, fs);
        glLinkProgram(pr);
        glDeleteShader(vs);
        glDeleteShader(fs);
        GLint ok = 0;
        glGetProgramiv(pr, GL_LINK_STATUS, &ok);
        if (!ok) {
            glDeleteProgram(pr);
            return 0;
        }
        return pr;
    }
    static bool ready() {
        if (g_failed)
            return false;
        if (g_blur && g_draw)
            return true;
        g_blur = program(BLUR);
        g_draw = program(DRAW);
        if (!g_blur || !g_draw) {
            g_failed = true;   // from now on wantsBackdrop() says no: Hyprland's own blur
            return false;
        }
        glGenVertexArrays(1, &g_vao);
        ub = {glGetUniformLocation(g_blur, "tex"),      glGetUniformLocation(g_blur, "texel"),      glGetUniformLocation(g_blur, "dir"),      glGetUniformLocation(g_blur, "lo"),
              glGetUniformLocation(g_blur, "hi"),       glGetUniformLocation(g_blur, "w0"),         glGetUniformLocation(g_blur, "taps"),     glGetUniformLocation(g_blur, "stage"),
              glGetUniformLocation(g_blur, "contrast"), glGetUniformLocation(g_blur, "brightness"), glGetUniformLocation(g_blur, "vibrancy"), glGetUniformLocation(g_blur, "vibrancyDarkness"),
              glGetUniformLocation(g_blur, "passes")};
        ud = {glGetUniformLocation(g_draw, "tex"),   glGetUniformLocation(g_draw, "origin"),     glGetUniformLocation(g_draw, "extent"), glGetUniformLocation(g_draw, "screen"),
              glGetUniformLocation(g_draw, "noise"), glGetUniformLocation(g_draw, "brightness"), glGetUniformLocation(g_draw, "alpha"),
              glGetUniformLocation(g_draw, "mask"),  glGetUniformLocation(g_draw, "maskBox")};
        return true;
    }

    // A texture with a framebuffer on it (made, or made again for another size). Leaves the
    // texture and framebuffer bindings changed: the callers put them back.
    static void make(GLuint& fbo, GLuint& tex, int w, int h) {
        const auto gl = Render::GL::g_pHyprOpenGL.get();
        if (fbo) {
            glDeleteFramebuffers(1, &fbo);
            gl->onFramebufferDeleted(fbo);
            glDeleteTextures(1, &tex);
        }
        glGenTextures(1, &tex);
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glGenFramebuffers(1, &fbo);
        gl->bindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    }
    static void atLeast(STarget& t, int w, int h) {   // scratch only grows
        if (t.fbo && t.w >= w && t.h >= h)
            return;
        t.w = std::max(t.w, w);
        t.h = std::max(t.h, h);
        make(t.fbo, t.tex, t.w, t.h);
    }
    static void emptyTrash() {
        if (g_trash.empty())
            return;
        const auto gl = Render::GL::g_pHyprOpenGL.get();
        for (auto& [fbo, tex] : g_trash) {
            glDeleteFramebuffers(1, &fbo);
            gl->onFramebufferDeleted(fbo);
            glDeleteTextures(1, &tex);
        }
        g_trash.clear();
    }
    static void freeAll() {   // plugin unload, with the GL context current
        emptyTrash();
        const auto gl = Render::GL::g_pHyprOpenGL.get();
        for (STarget* t : {&g_level[0], &g_level[1], &g_level[2], &g_level[3], &g_pass}) {
            if (!t->fbo)
                continue;
            glDeleteFramebuffers(1, &t->fbo);
            gl->onFramebufferDeleted(t->fbo);
            glDeleteTextures(1, &t->tex);
            *t = {};
        }
        if (g_blur)
            glDeleteProgram(g_blur);
        if (g_draw)
            glDeleteProgram(g_draw);
        if (g_vao)
            glDeleteVertexArrays(1, &g_vao);
        g_blur = g_draw = g_vao = 0;
    }

    struct SLook {
        int   levels;                // halvings: 2 = a quarter of the size
        int   passes;                // Hyprland's setting (how many times it boosts the saturation)
        float sigma;                 // of the Gaussian, in pixels of the shrunk picture
        float contrast, brightness, vibrancy, vibrancyDarkness, noise;
    };
    static SLook look() {
        static auto PSIZE = CConfigValue<Config::INTEGER>("decoration:blur:size");
        static auto PPASS = CConfigValue<Config::INTEGER>("decoration:blur:passes");
        static auto PNOIS = CConfigValue<Config::FLOAT>("decoration:blur:noise");
        static auto PCONT = CConfigValue<Config::FLOAT>("decoration:blur:contrast");
        static auto PBRIG = CConfigValue<Config::FLOAT>("decoration:blur:brightness");
        static auto PVIBR = CConfigValue<Config::FLOAT>("decoration:blur:vibrancy");
        static auto PVIBD = CConfigValue<Config::FLOAT>("decoration:blur:vibrancy_darkness");
        // Hyprland's blur at size s, p passes looks like a Gaussian of about 0.6 * s * 2^p screen pixels
        // (measured against it at 4 / 2); `backdrop_spread` is that 0.6, in percent
        const double px     = std::max<int64_t>(1, *PSIZE) * std::pow(2.0, std::clamp<int64_t>(*PPASS, 1, 8)) * (double)vars.backdropSpread->value() / 100.0;
        int          levels = 2;
        while (levels < 4 && px / (1 << levels) > 3.2)   // 17 pixels hold a Gaussian up to 3.2 wide: shrink further for more
            levels++;
        return {levels, (int)std::clamp<int64_t>(*PPASS, 1, 8), (float)std::clamp(px / (1 << levels), 0.5, 3.2), (float)*PCONT, (float)*PBRIG, (float)*PVIBR, (float)*PVIBD, (float)*PNOIS};
    }
    static int factor() {
        return 1 << look().levels;
    }

    static const int REACH = 9;   // pixels of the shrunk picture the blur spreads a change (the Gaussian's 8, and 1 for the lookups in between)

    // Bring the stored picture up to date in `part` (monitor pixels, on the grid, inside st.src):
    // shrink that piece of what Hyprland has drawn so far into st.rawTex, then blur it and its
    // surroundings (as far as the blur reaches) from st.rawTex into st.tex.
    // -> the piece of screen whose backdrop changed; nothing when it could not be done
    static std::optional<CBox> update(Render::CRenderContext& ctx, SBackdropState& st, const CBox& part) {
        STimed     timed{g_mine[0]};
        const auto gl  = Render::GL::g_pHyprOpenGL.get();
        const auto src = dynamicPointerCast<Render::GL::CGLFramebuffer>(ctx.m_data.currentFB);
        if (!gl || !src || !ready())
            return std::nullopt;
        const SLook lk = look();
        const int   F  = 1 << lk.levels;
        const int   qw = (int)st.src.w / F, qh = (int)st.src.h / F;
        const int   px = ((int)part.x - (int)st.src.x) / F, py = ((int)part.y - (int)st.src.y) / F, pw = (int)part.w / F, ph = (int)part.h / F;
        if (qw < 1 || qh < 1 || pw < 1 || ph < 1 || px < 0 || py < 0 || px + pw > qw || py + ph > qh)
            return std::nullopt;

        GLint vp[4], prog = 0, vao = 0, tex0 = 0;
        glGetIntegerv(GL_VIEWPORT, vp);
        glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
        gl->setActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex0);
        const bool blend = gl->blendEnabled();

        for (int l = 0; l + 1 < lk.levels; ++l)
            atLeast(g_level[l], (int)part.w >> (l + 1), (int)part.h >> (l + 1));
        atLeast(g_pass, qw, qh);
        if (!st.fbo || st.qw != qw || st.qh != qh) {
            make(st.fbo, st.tex, qw, qh);
            make(st.rawFbo, st.rawTex, qw, qh);
            st.qw = qw;
            st.qh = qh;
        }
        st.factor = F;
        gl->setCapStatus(GL_SCISSOR_TEST, false);
        gl->blend(false);

        // shrink: each step halves (averaging 2x2); the last one lands in the raw picture, at the part's place
        GLuint from = src->getFBID();
        int    fx = part.x, fy = part.y, fw = part.w, fh = part.h;
        for (int l = 0; l < lk.levels; ++l) {
            const bool last = l + 1 == lk.levels;
            const int  tw = (int)part.w >> (l + 1), th = (int)part.h >> (l + 1);
            gl->bindFramebuffer(GL_READ_FRAMEBUFFER, from);
            gl->bindFramebuffer(GL_DRAW_FRAMEBUFFER, last ? st.rawFbo : g_level[l].fbo);
            if (last)
                glBlitFramebuffer(fx, fy, fx + fw, fy + fh, px, py, px + pw, py + ph, GL_COLOR_BUFFER_BIT, GL_LINEAR);
            else {
                glBlitFramebuffer(fx, fy, fx + fw, fy + fh, 0, 0, tw, th, GL_COLOR_BUFFER_BIT, GL_LINEAR);
                from = g_level[l].fbo;
                fx = fy = 0;
                fw = tw;
                fh = th;
            }
        }

        // the Gaussian: centre + 4 pairs, each pair of pixels read with one lookup between them
        float g[9], total = 0;
        for (int k = 0; k <= 8; ++k)
            g[k] = std::exp(-(float)(k * k) / (2.F * lk.sigma * lk.sigma));
        total = g[0];
        for (int k = 1; k <= 8; ++k)
            total += 2.F * g[k];
        float taps[8];
        for (int k = 0; k < 4; ++k) {
            const float a = g[2 * k + 1], b = g[2 * k + 2];
            taps[2 * k]     = ((2 * k + 1) * a + (2 * k + 2) * b) / (a + b);
            taps[2 * k + 1] = (a + b) / total;
        }

        // what the blur must redo: the part and as far around it as the blur reaches. The first
        // direction (across) also has to cover the rows above and below that the second one reads.
        const int bx0 = std::max(0, px - REACH), by0 = std::max(0, py - REACH), bx1 = std::min(qw, px + pw + REACH), by1 = std::min(qh, py + ph + REACH);
        const int hy0 = std::max(0, by0 - REACH), hy1 = std::min(qh, by1 + REACH);

        glUseProgram(g_blur);
        glBindVertexArray(g_vao);
        glUniform1i(ub.tex, 0);
        glUniform2f(ub.lo, 0.5F, 0.5F);
        glUniform2f(ub.hi, qw - 0.5F, qh - 0.5F);
        glUniform1f(ub.w0, g[0] / total);
        glUniform2fv(ub.taps, 4, taps);
        glUniform1f(ub.contrast, lk.contrast);
        glUniform1f(ub.brightness, lk.brightness);
        glUniform1f(ub.vibrancy, lk.vibrancy);
        glUniform1f(ub.vibrancyDarkness, lk.vibrancyDarkness);
        glUniform1i(ub.passes, lk.passes);
        // across (the viewport limits what is drawn; gl_FragCoord stays the pixel in the picture)
        gl->bindFramebuffer(GL_FRAMEBUFFER, g_pass.fbo);
        gl->setViewport(bx0, hy0, bx1 - bx0, hy1 - hy0);
        glBindTexture(GL_TEXTURE_2D, st.rawTex);
        glUniform2f(ub.texel, 1.F / qw, 1.F / qh);
        glUniform2f(ub.dir, 1.F, 0.F);
        glUniform1i(ub.stage, 0);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        // down, into the blurred picture
        gl->bindFramebuffer(GL_FRAMEBUFFER, st.fbo);
        gl->setViewport(bx0, by0, bx1 - bx0, by1 - by0);
        glBindTexture(GL_TEXTURE_2D, g_pass.tex);
        glUniform2f(ub.texel, 1.F / g_pass.w, 1.F / g_pass.h);
        glUniform2f(ub.dir, 0.F, 1.F);
        glUniform1i(ub.stage, 1);
        glDrawArrays(GL_TRIANGLES, 0, 3);

        // everything back as Hyprland had it
        gl->bindFramebuffer(GL_FRAMEBUFFER, src->getFBID());
        g_pHyprRenderer->bindFB(ctx, ctx.m_data.currentFB);
        glUseProgram(prog);
        glBindVertexArray(vao);
        glBindTexture(GL_TEXTURE_2D, tex0);
        gl->setViewport(vp[0], vp[1], vp[2], vp[3]);
        gl->blend(blend);
        return CBox{st.src.x + bx0 * F, st.src.y + by0 * F, (double)(bx1 - bx0) * F, (double)(by1 - by0) * F};
    }

    // draw st.tex where `where` says (screen pixels), into what Hyprland is drawing
    // maskTex: the window's own picture (0 = none). The backdrop is then drawn only where that picture
    // is not see-through, so a window with cut corners or a stepped outline (GNOME Files in Cyber's
    // look, gtk/cyber.css) has the blur in exactly its own shape, whatever that is.
    static void drawFrom(Render::CRenderContext& ctx, const SBackdropState& st, const CRegion& where, float a, GLuint maskTex = 0, const CBox& maskBox = {}) {
        STimed     timed{g_mine[1]};
        const auto gl = Render::GL::g_pHyprOpenGL.get();
        if (!gl || !st.tex || !ready())
            return;
        GLint prog = 0, vao = 0, tex0 = 0;
        glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
        gl->setActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex0);
        const bool  blend = gl->blendEnabled();
        const SLook lk    = look();
        GLint       tex1  = 0;
        if (maskTex) {
            gl->setActiveTexture(GL_TEXTURE1);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex1);
            glBindTexture(GL_TEXTURE_2D, maskTex);
            gl->setActiveTexture(GL_TEXTURE0);
        }
        gl->blend(a < 1.F || maskTex);
        glUseProgram(g_draw);
        glBindVertexArray(g_vao);
        glBindTexture(GL_TEXTURE_2D, st.tex);
        glUniform1i(ud.tex, 0);
        glUniform1i(ud.mask, maskTex ? 1 : 0);
        glUniform4f(ud.maskBox, maskBox.x, maskBox.y, maskTex ? maskBox.w : 0.0, maskBox.h);
        glUniform2f(ud.origin, st.src.x, st.src.y);
        glUniform2f(ud.extent, st.qw * st.factor, st.qh * st.factor);
        glUniform2f(ud.screen, ctx.m_data.pMonitor->m_transformedSize.x, ctx.m_data.pMonitor->m_transformedSize.y);
        glUniform1f(ud.noise, lk.noise);
        glUniform1f(ud.brightness, lk.brightness);
        glUniform1f(ud.alpha, a);
        for (auto& r : where.getRects()) {
            gl->scissor(ctx, &r, ctx.m_data.transformDamage);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        gl->disableScissor();
        glUseProgram(prog);
        glBindVertexArray(vao);
        glBindTexture(GL_TEXTURE_2D, tex0);
        if (maskTex) {
            gl->setActiveTexture(GL_TEXTURE1);
            glBindTexture(GL_TEXTURE_2D, tex1);
            gl->setActiveTexture(GL_TEXTURE0);
        }
        gl->blend(blend);
    }
}

class CCyberBackdropElement : public IPassElement {
  public:
    struct SData {
        SP<SBackdropState> state;
        CBox               box;       // the window, monitor pixels
        CBox               part;      // refresh: the piece of screen to read again (on the grid, inside state->src)
        CRegion            shape;     // where the backdrop shows (panel outline, minus what is hidden), monitor pixels
        bool               refresh = false;   // bring the stored picture up to date in `part` first
        float              a       = 1.F;
        float              scale   = 1.F;
        Vector2D           monPos;
        SP<Render::ITexture> mask;      // the window's own picture, for windows tagged "cybershape"
        CBox               maskBox;
    };

    CCyberBackdropElement(const SData& d) : m_data(d) {}

    // On a frame that redoes part of the blur, tell Hyprland: it then draws everything behind that
    // part (also what an opaque window above would hide), which is what the blur must read, and
    // redraws a little more around it, where the blur carries the change.
    bool             needsLiveBlur(Render::CRenderContext&) override { return m_data.refresh; }
    bool             needsPrecomputeBlur(Render::CRenderContext&) override { return false; }
    const char*      passName() override { return "CCyberBackdropElement"; }
    ePassElementType type() override { return EK_CUSTOM; }

    std::optional<CBox> boundingBox(Render::CRenderContext&) override {
        if (!m_data.refresh)
            return m_data.box.copy().scale(1.F / m_data.scale);
        return m_data.part.copy().expand(Fast::REACH * m_data.state->factor).scale(1.F / m_data.scale);
    }

    // Where the stored picture is reused it covers everything behind it: Hyprland need not draw that.
    CRegion opaqueRegion(Render::CRenderContext&) override {
        if (m_data.a < 1.F || !m_data.state->have || m_data.mask)
            return {};      // (a masked backdrop has holes: what is behind them must be drawn)
        CRegion rg = m_data.shape.copy();
        if (m_data.refresh)
            rg.subtract(m_data.part);
        return rg.scale(1.F / m_data.scale);
    }

    std::vector<UP<IPassElement>> draw(Render::CRenderContext& ctx) override {
        auto&      d  = m_data;
        const auto st = d.state;
        if (!st || !ctx.m_data.pMonitor)
            return {};
        Fast::emptyTrash();
        const CRegion drawn = ctx.m_data.damage;                      // what this frame redraws here
        const auto    ask   = [&d](const CRegion& rg) {               // have Hyprland redraw this next frame
            if (!rg.empty())
                g_pHyprRenderer->damageRegion(rg.copy().scale(1.F / d.scale).translate(d.monPos));
        };
        if (d.refresh) {
            const bool first = !st->have;
            // the part was just redrawn, all of it: the screen shows what is behind the window there
            const bool fresh = CRegion{d.part}.subtract(drawn).empty() || st->attempts > 3;
            if (first || fresh) {
                const auto changed = Fast::update(ctx, *st, d.part);
                if (!changed)
                    return {};
                st->have      = true;
                st->refreshed = std::chrono::steady_clock::now();
                st->nRefresh++;
                st->blurredPx += d.part.w * d.part.h;
                if (fresh) {
                    st->stale.subtract(d.part);
                    st->attempts = 0;
                } else
                    st->stale = CRegion{st->src};     // made from a half-redrawn screen: again when all of it is redrawn
                ask(CRegion{*changed}.intersect(d.shape).subtract(drawn));   // the blur carried the change further than this frame redraws
            }
            if (!st->stale.empty()) {   // still out of date somewhere this frame did not redraw
                st->attempts++;
                ask(CRegion{st->stale.getExtents()});
            }
        } else
            st->nReuse++;
        CRegion need = drawn.copy().intersect(d.shape);
        if (need.empty())
            return {};
        st->drawnPx += areaOf(need);
        Fast::drawFrom(ctx, *st, need, d.a, d.mask ? d.mask->m_texID : 0, d.maskBox);
        return {};
    }

    SData m_data;
};

static CRegion  opaquePart(const PHLWINDOW& w);
static uint64_t pictureOf(SP<CWLSurfaceResource> res);
class CCyberPanelBlur;
static std::vector<CCyberPanelBlur*> g_backdrops;          // windows that have a stored backdrop
static SP<CEventLoopTimer>           g_catchUp;            // redraws what was drawn from an old picture

// Keeps a window's blur as it should be (see the top of the file), every frame, before the window
// is drawn: the panel's shape, nothing for buried windows, and the stored backdrop above.
class CCyberPanelBlur : public IHyprWindowDecoration {
  public:
    CCyberPanelBlur(PHLWINDOW w) : IHyprWindowDecoration(w), m_window(w) {}
    ~CCyberPanelBlur() override {
        dropPicture();
        std::erase(g_backdrops, this);
    }

    SDecorationPositioningInfo getPositioningInfo() override {
        SDecorationPositioningInfo info;
        info.policy         = DECORATION_POSITION_STICKY;
        info.edges          = ALL_EDGES;
        info.priority       = 9960;
        info.reserved       = false;
        info.desiredExtents = {{0, 0}, {0, 0}};
        return info;
    }
    void             onPositioningReply(const SDecorationPositioningReply&) override {}
    eDecorationType  getDecorationType() override { return DECORATION_CUSTOM; }
    eDecorationLayer getDecorationLayer() override { return DECORATION_LAYER_BOTTOM; }
    uint64_t         getDecorationFlags() override { return 0; }
    std::string      getDisplayName() override { return "CyberPanelBlur"; }
    void             updateWindow(PHLWINDOW) override { sync(); }
    void             damageEntire() override {}

    void draw(Render::CRenderContext& ctx, PHLMONITOR mon, float const&, const Render::SWindowRenderPresentation& pres) override {
        sync();
        backdrop(ctx, mon, pres);
    }

    // Should the plugin draw this window's backdrop itself? Yes for anything see-through that
    // Hyprland would blur: panels, unfocused (faded) windows, windows that are mostly not opaque.
    bool wantsBackdrop(const PHLWINDOW& W, bool panel) {
        static auto PBLUR = CConfigValue<Config::INTEGER>("decoration:blur:enabled");
        if (vars.backdropFps->value() <= 0 || Fast::g_failed || !*PBLUR || m_buried || W->m_ruleApplicator->noBlur().valueOrDefault())
            return false;
        if (Fullscreen::controller()->getFullscreenModes(W).internal == Fullscreen::FSMODE_FULLSCREEN)
            return false;
        if (W->presentation().rounding() > 0)
            return false;   // the stored picture is drawn square: with rounded corners leave it to Hyprland
        const auto mon = W->m_monitor.lock();
        if (!mon || mon->m_transform != WL_OUTPUT_TRANSFORM_NORMAL)
            return false;   // a rotated screen: the small blur works in plain screen pixels
        const auto pres = W->presentation().renderPresentation();
        if (pres.alpha * pres.fadeAlpha < 0.02F)
            return false;   // invisible (the parked Looking Glass window): nothing to blur for
        if (panel)
            return true;
        if (pres.alpha * pres.fadeAlpha < 1.F)
            return true;
        const CBox box = W->getWindowMainSurfaceBox();
        return areaOf(opaquePart(W)) < 0.5 * box.width * box.height;
    }

    // add the stored-backdrop element for this frame
    void backdrop(Render::CRenderContext& ctx, PHLMONITOR mon, const Render::SWindowRenderPresentation& pres) {
        const auto W = m_window.lock();
        if (!m_takeover || !W || !mon || ctx.m_renderingSnapshot || pres.workspaceScene || !ctx.m_data.currentFB)
            return;
        if (ctx.m_data.renderModif.enabled && !ctx.m_data.renderModif.modifs.empty())
            return;   // a zoomed or mirrored view: no stored picture fits it
        if (!m_bd) {
            m_bd = makeShared<SBackdropState>();
            g_backdrops.push_back(this);
        }
        CBox box = W->getWindowMainSurfaceBox();
        box.translate(pres.workspaceOffset - mon->m_position + pres.floatingOffset);
        box.scale(mon->m_scale).round();

        // where the backdrop shows: the panel's outline or the whole window, without the part behind opaque windows
        CRegion shape;
        if (isPanel(W) && !m_region.empty())
            shape = m_region.copy().scale(mon->m_scale).translate(box.pos());
        else
            shape.add(box);
        if (!m_visPart.empty())
            shape.intersect(m_visPart.copy().scale(mon->m_scale).translate(box.pos()));
        if (shape.empty())
            return;

        // the piece of screen the picture shows: the window and a margin, on the grid of the shrunk picture, inside the screen
        const int    F = Fast::factor(), MARGIN = 8 * F;
        const int    fw = ((int)ctx.m_data.currentFB->m_size.x / F) * F, fh = ((int)ctx.m_data.currentFB->m_size.y / F) * F;
        const double f  = F;
        const int    x0 = std::clamp((int)(std::floor((box.x - MARGIN) / f) * F), 0, fw), y0 = std::clamp((int)(std::floor((box.y - MARGIN) / f) * F), 0, fh);
        const int    x1 = std::clamp((int)(std::ceil((box.x + box.w + MARGIN) / f) * F), 0, fw), y1 = std::clamp((int)(std::ceil((box.y + box.h + MARGIN) / f) * F), 0, fh);
        if (x1 - x0 < 2 * F || y1 - y0 < 2 * F)
            return;
        const CBox src   = {(double)x0, (double)y0, (double)(x1 - x0), (double)(y1 - y0)};
        const auto now   = std::chrono::steady_clock::now();
        const bool moved = m_bd->monitor != mon->m_id || m_bd->factor != F || m_bd->src.x != src.x || m_bd->src.y != src.y || m_bd->src.w != src.w || m_bd->src.h != src.h;
        if (moved) {   // the stored picture belongs to another place
            m_bd->have     = false;
            m_bd->src      = src;
            m_bd->monitor  = mon->m_id;
            m_bd->factor   = F;
            m_bd->attempts = 0;
            m_bd->stale.clear();
        }
        m_bd->box  = box;
        m_bd->used = now;
        m_monPos   = mon->m_position;
        m_scale    = mon->m_scale;
        if (now - m_bd->checked >= std::chrono::seconds(1)) {   // the safety net: once a second, redo all of it anyway
            m_bd->checked = now;
            m_bd->stale   = CRegion{src};
        }

        const auto interval = std::chrono::microseconds(1000000 / std::max<Config::INTEGER>(1, vars.backdropFps->value()));
        const bool due      = now - m_bd->refreshed >= interval - std::chrono::milliseconds(3);

        CCyberBackdropElement::SData d;
        d.state  = m_bd;
        d.box    = box;
        d.shape  = shape;
        d.a      = pres.fadeAlpha;
        d.scale  = mon->m_scale;
        d.monPos = mon->m_position;
        d.part   = src;
        if (isShaped(W)) {   // blur in the window's own shape
            const auto res = W->wlSurface() ? W->wlSurface()->resource() : nullptr;
            const auto tex = res ? res->m_current.texture : nullptr;
            // (an "external" texture needs another kind of sampler: such a window keeps the plain rectangle)
            if (tex && tex->m_texID && (tex->m_type == Render::TEXTURE_RGBA || tex->m_type == Render::TEXTURE_RGBX)) {
                d.mask    = tex;
                d.maskBox = box;
            }
        }
        if (!m_bd->have)
            d.refresh = true;   // no picture at all: make one now, whatever this frame redraws
        else if (!m_bd->stale.empty() && due) {
            // Out of date somewhere. What this frame redraws of that is brought up to date now (the screen
            // shows what is behind the window only where it was just redrawn; Hyprland redraws some more
            // around a blur, which covers rounding the part out to our grid).
            CRegion fresh = m_bd->stale.copy().intersect(ctx.m_data.damage);
            if (m_bd->attempts > 3)
                fresh = m_bd->stale;   // asked for it several times: take the screen as it is
            if (!fresh.empty()) {
                const CBox e  = fresh.getExtents();
                const int  ex0 = std::max(x0, (int)(std::floor(e.x / f) * F)), ey0 = std::max(y0, (int)(std::floor(e.y / f) * F));
                const int  ex1 = std::min(x1, (int)(std::ceil((e.x + e.w) / f) * F)), ey1 = std::min(y1, (int)(std::ceil((e.y + e.h) / f) * F));
                if (ex1 > ex0 && ey1 > ey0) {
                    d.part    = {(double)ex0, (double)ey0, (double)(ex1 - ex0), (double)(ey1 - ey0)};
                    d.refresh = true;
                }
            }
            if (!d.refresh) {   // nothing of it is redrawn in this frame: ask for a frame that does
                m_bd->attempts++;
                g_pHyprRenderer->damageBox(m_bd->stale.getExtents().scale(1.F / m_scale).translate(m_monPos));
            }
        } else if (!m_bd->stale.empty())
            armCatchUp();       // out of date, but redone too recently: the timer asks when it is due
        g_pHyprRenderer->addPassElement(ctx, makeUnique<CCyberBackdropElement>(d));
    }

    static void armCatchUp() {
        if (g_catchUp && !g_catchUp->armed())
            g_catchUp->updateTimeout(std::chrono::milliseconds(8));
    }

    // Something behind this window changed there (global coordinates): the stored picture is out of date there.
    void markStale(const CBox& where) {
        if (!m_bd || !m_takeover || !m_bd->have)
            return;
        CBox local = where;
        local.translate(-m_monPos).scale(m_scale);
        const double f  = std::max(1, m_bd->factor);
        const CBox&  s  = m_bd->src;
        const double x0 = std::max(s.x, std::floor(local.x / f) * f), y0 = std::max(s.y, std::floor(local.y / f) * f);
        const double x1 = std::min(s.x + s.w, std::ceil((local.x + local.w) / f) * f), y1 = std::min(s.y + s.h, std::ceil((local.y + local.h) / f) * f);
        if (x1 <= x0 || y1 <= y0)
            return;
        m_bd->stale.add(CBox{x0, y0, x1 - x0, y1 - y0});
        if (m_bd->stale.getRects().size() > 6)
            m_bd->stale = CRegion{m_bd->stale.getExtents()};
        m_bd->nMarked++;
    }

    void forget() {   // blur settings changed: every stored picture is wrong
        if (m_bd)
            m_bd->stale = CRegion{m_bd->src};
    }

    std::string stats() {
        if (!m_takeover || !m_bd)
            return m_takeover ? "stored backdrop: not drawn yet" : "no stored backdrop";
        char buf[256];
        snprintf(buf, sizeof(buf), "stored backdrop %dx%d: brought up to date %d times (%.2f MP read), reused %d times, %.2f MP drawn, marked changed %d times, %d catch-up redraws",
                 m_bd->qw, m_bd->qh, m_bd->nRefresh, m_bd->blurredPx / 1e6, m_bd->nReuse, m_bd->drawnPx / 1e6, m_bd->nMarked, m_bd->nCatchUp);
        m_bd->nRefresh = m_bd->nReuse = m_bd->nCatchUp = m_bd->nMarked = 0;
        m_bd->blurredPx = m_bd->drawnPx = 0;
        return buf;
    }

    void dropPicture() {   // the textures are deleted at the next frame, when the GL context is ours
        if (m_bd && m_bd->fbo) {
            Fast::g_trash.emplace_back(m_bd->fbo, m_bd->tex);
            Fast::g_trash.emplace_back(m_bd->rawFbo, m_bd->rawTex);
            m_bd->fbo = m_bd->tex = m_bd->rawFbo = m_bd->rawTex = 0;
            m_bd->qw = m_bd->qh = 0;
            m_bd->have = false;
        }
    }

    void releaseIfUnused() {   // not drawn for a while (other workspace, minimised): give the textures back
        if (m_bd && std::chrono::steady_clock::now() - m_bd->used > std::chrono::seconds(10))
            dropPicture();
    }

    // Called by the timer: the stored picture is out of date and a redo is due: ask Hyprland to
    // redraw what is behind the window there (the redo happens in that frame).
    // -> true while there is something left to catch up with.
    bool catchUp() {
        if (!m_bd || !m_takeover || m_bd->stale.empty() || !m_bd->have)
            return false;
        const auto now = std::chrono::steady_clock::now();
        if (now - m_bd->used > std::chrono::milliseconds(500))
            return false;   // not being drawn (covered, another workspace): it is redone when it shows again
        const auto interval = std::chrono::microseconds(1000000 / std::max<Config::INTEGER>(1, vars.backdropFps->value()));
        if (now - m_bd->refreshed >= interval) {
            if (m_bd->attempts > 12)
                return false;
            m_bd->attempts++;
            g_pHyprRenderer->damageBox(m_bd->stale.getExtents().scale(1.F / m_scale).translate(m_monPos));
            m_bd->nCatchUp++;
        }
        return true;
    }

    // the panel's outline as a region, in the surface's own pixels
    static CRegion outline(double w, double h) {
        CRegion      rg;
        const double cut = PANEL_CUT, big = PANEL_BIG_CUT, stepIn = PANEL_STEP_IN, round = 5;
        const double stepY = std::round(h * PANEL_STEP_AT);
        if (w < cut + stepIn + big + 8 || h < stepY + stepIn + big + 8 || stepY < cut + 4) {
            rg.add(CBox{0, 0, w, h});   // too small for the outline
            return rg;
        }
        for (int y = 0; y < (int)cut; ++y) {                              // top: the cut on the left, the rounding on the right
            const double x0 = std::ceil(cut - y - 0.5);
            double       x1 = w;
            if (y < round) {
                const double dy = round - y - 0.5;
                x1 = w - std::floor(round - std::sqrt(std::max(0.0, round * round - dy * dy)));
            }
            rg.add(CBox{x0, (double)y, x1 - x0, 1});
        }
        rg.add(CBox{0, cut, w, stepY - cut});                              // down to the step
        for (int i = 0; i < (int)stepIn; ++i)                              // the right edge steps in
            rg.add(CBox{0, stepY + i, w - std::ceil(i + 0.5), 1});
        const double lowerTop = stepY + stepIn, lowerW = w - stepIn;
        rg.add(CBox{0, lowerTop, lowerW, h - big - lowerTop});             // down to the bottom-right cut
        for (int i = 0; i < (int)big; ++i)                                 // bottom-right cut
            rg.add(CBox{0, h - big + i, lowerW - std::ceil(i + 0.5), 1});
        return rg;
    }

    // A window Cyber shows a live copy of (the parked Looking Glass window, tagged "cybertilt" by
    // hud/LookingGlassPanel.qml): tell Cyber whenever it has drawn a new picture, as
    // "cybertiltframe>>ADDRESS" on Hyprland's event socket, so Cyber fetches a frame only then.
    // Fetching is not free: Hyprland redraws the whole screen once for every frame it hands out,
    // and hands them out whether or not the window changed (measured 2026-11-24: a still VM cost
    // 33 full redraws a second).
    void watchFrames(bool on) {
        if (!on) {
            m_frames.reset();
            return;
        }
        if (m_frames)
            return;
        const auto W   = m_window.lock();
        const auto res = W && W->wlSurface() ? W->wlSurface()->resource() : nullptr;
        if (!res)
            return;
        m_framePic = 0;
        m_frames   = res->m_events.commit.listen([this] {
            const auto W   = m_window.lock();
            const auto res = W && W->wlSurface() ? W->wlSurface()->resource() : nullptr;
            if (!res)
                return;
            const uint64_t pic = pictureOf(res);
            const auto     now = std::chrono::steady_clock::now();
            if (pic == m_framePic || now - m_framePosted < std::chrono::milliseconds(4))
                return;   // the same buffers as last time (a commit without a new picture), or told just now
            m_framePic    = pic;
            m_framePosted = now;
            char addr[32];
            snprintf(addr, sizeof(addr), "%lx", (unsigned long)(uintptr_t)W.get());
            IPC::Socket2::sock()->postEvent({"cybertiltframe", addr});
        });
    }

    // Cyber hides the real Looking Glass window by a rule on its tag ("cybertilt": opacity 0) while
    // its tilted copy stands in for it, and shows it again by taking the tag off. Hyprland fades
    // such a change over a fifth of a second. Here it has to be a cut: at that moment the copy is
    // exactly under the window, with the same picture, and starts to swing at once; a window still
    // fading on top of it shows as a flat ghost over the swinging copy (the user's recording,
    // 2026-11-24). So while a window carries the tag, and for a moment after it lost it, its
    // opacity jumps to where it is going.
    void cutFade(const PHLWINDOW& W, bool tilted) {
        if (tilted)
            m_cutFrames = 10;
        if (m_cutFrames <= 0)
            return;
        if (!tilted)
            m_cutFrames--;
        auto& alpha = W->alpha();
        if (!alpha.isBeingAnimated())
            return;
        alpha.warp();
        g_pHyprRenderer->damageWindow(W);
    }

    // Called every frame for every window: keep the surface's blur region as it should be.
    //   buried window        -> an empty region: no blur at all (see updateBuried below)
    //   opaque all over      -> an empty region too. There is nothing to blur behind it, but Hyprland
    //                           still counts some of them as "may blur" (seen with the browser: an
    //                           alpha picture that declares itself opaque), and then draws everything
    //                           hidden behind the window instead of skipping it
    //   stored backdrop      -> an empty region too: the plugin draws the blur (see above)
    //   panel, backdrop off  -> the panel's outline, for Hyprland's own blur
    //   anything else        -> untouched (or given back, if it was ours)
    // Ghostty speaks ext-background-effect itself and, with its own blur option off, hands
    // Hyprland an EMPTY blur region on every commit ("do not blur me"). So for panels the region is
    // put back right after each commit, by a listener that runs after the protocol's own.
    void sync(bool force = false) {
        const auto W = m_window.lock();
        if (!W || !W->mapped())
            return;
        const auto surf = W->wlSurface();
        if (!surf)
            return;
        const bool panel = isPanel(W);
        if (panel) {
            const CBox   box = W->getWindowMainSurfaceBox();
            const double w = std::round(box.width), h = std::round(box.height);
            if (w != m_w || h != m_h || m_region.empty()) {
                m_region = outline(w, h);
                m_w      = w;
                m_h      = h;
                force    = true;
            }
        }
        const bool takeover = wantsBackdrop(W, panel);
        if (takeover != m_takeover) {
            m_takeover = takeover;
            force      = true;
            if (!takeover && m_bd) {   // give the texture back
                dropPicture();
                std::erase(g_backdrops, this);
                m_bd.reset();
            }
        }
        bool solid = false;
        if (!panel && !takeover && !m_buried && W->presentation().rounding() <= 0) {
            const CBox box = W->getWindowMainSurfaceBox();
            solid          = box.width > 1 && box.height > 1 && areaOf(opaquePart(W)) >= box.width * box.height - 0.5;
        }
        if (solid != m_solid) {
            m_solid = solid;
            force   = true;
        }
        m_shape = panel && !m_buried && !m_takeover;      // Hyprland's own blur, clipped to the panel
        if (!panel && !m_buried && !m_takeover && !m_solid) {
            if (m_touched) {
                m_commit.reset();
                surf->m_hasBackgroundEffect = false;
                surf->m_blurRegion.clear();
                m_touched = false;
                g_pHyprRenderer->damageWindow(W);
            }
            return;
        }
        // not as wanted (first time, or the client made a new effect object whose listener now runs
        // after ours): put it right, and for panels move our listener to the end of the queue
        const size_t want = m_shape ? m_region.getRects().size() : 0;
        const bool   ours = surf->m_hasBackgroundEffect && surf->m_blurRegion.getRects().size() == want;
        if (ours && !force && (m_commit || !panel))
            return;
        if (panel && (!ours || !m_commit)) {
            if (const auto res = surf->resource())
                m_commit = res->m_events.commit.listen([this] { apply(); });
        }
        apply();
        g_pHyprRenderer->damageWindow(W);
    }

    void apply() {
        const auto W = m_window.lock();
        if (!W)
            return;
        if (const auto surf = W->wlSurface()) {
            if (m_shape)
                surf->m_blurRegion = m_region;
            else
                surf->m_blurRegion.clear();
            surf->m_hasBackgroundEffect = true;
            m_touched                   = true;
        }
    }

    // The part of the window that is not hidden behind an opaque window above it, in the window's
    // own pixels; an empty region = all of it. Hyprland then draws and blurs only that part (it is
    // the field the hyprland-surface protocol fills in for clients that say so themselves).
    void setVisiblePart(const CRegion& part) {
        const auto W = m_window.lock();
        if (!W)
            return;
        const auto surf = W->wlSurface();
        if (!surf)
            return;
        m_visPart = part;
        if (part.empty()) {
            if (m_visTouched) {
                surf->m_visibleRegion.clear();
                m_visTouched = false;
                m_visRects   = 0;
                g_pHyprRenderer->damageWindow(W);
            }
            return;
        }
        if (!m_visTouched && !surf->m_visibleRegion.empty())
            return;   // the client set one itself: leave it
        CRegion    copy = part;
        const auto ext  = copy.getExtents();
        const bool same = m_visTouched && m_visRects == part.getRects().size() && ext.x == m_visExt.x && ext.y == m_visExt.y && ext.w == m_visExt.w && ext.h == m_visExt.h;
        surf->m_visibleRegion = part;
        m_visTouched          = true;
        m_visRects            = part.getRects().size();
        if (!same) {
            m_visExt = ext;
            g_pHyprRenderer->damageWindow(W);
        }
    }

    // nothing of this window's backdrop can be seen: skip its blur
    void setBuried(bool buried) {
        const bool changed = buried != m_buried;
        m_buried           = buried;
        sync(changed);
    }

    void clear() {
        m_commit.reset();
        const auto W = m_window.lock();
        if (!W)
            return;
        if (const auto surf = W->wlSurface()) {
            if (m_touched) {
                surf->m_hasBackgroundEffect = false;
                surf->m_blurRegion.clear();
            }
            if (m_visTouched)
                surf->m_visibleRegion.clear();
        }
        m_touched = m_visTouched = false;
    }

  private:
    PHLWINDOWREF        m_window;
    bool                m_touched = false, m_buried = false, m_shape = false, m_visTouched = false, m_takeover = false, m_solid = false;
    SP<SBackdropState>  m_bd;
    CRegion             m_visPart;
    Vector2D            m_monPos;
    float               m_scale = 1.F;
    size_t              m_visRects = 0;
    CBox                m_visExt;
    double              m_w = 0, m_h = 0;
    CRegion             m_region;
    CHyprSignalListener m_commit;
    int                 m_cutFrames = 0;  // cutFade()
    CHyprSignalListener m_frames;         // watchFrames()
    uint64_t            m_framePic = 0;
    std::chrono::steady_clock::time_point m_framePosted{};
};

// Blur is the expensive part of every frame on this GPU, and each see-through window blurs what is
// behind it. Two things that cannot be seen are skipped, checked every frame from the real
// stacking order (the moment a window is uncovered, it is drawn and blurred in full again):
//   * a window that is (almost) completely covered by windows above it shows its backdrop only
//     through them, at a few percent and blurred again by them: its own blur is skipped;
//   * the part of a window that lies behind an OPAQUE window above it (your focused browser, a
//     video player) is neither drawn nor blurred. Hyprland has this shortcut itself, but turns it
//     off wherever a blurred window is, so a video playing in front made every see-through window
//     behind it blur again at the video's frame rate: measured at about 40% of the GPU.
static constexpr double BURIED_AT = 0.99;   // covered share of the window's area

// where a window is certainly opaque, in global coordinates (the same test Hyprland's own occlusion uses)
static CRegion opaquePart(const PHLWINDOW& w) {
    const auto pres = w->presentation().renderPresentation();
    const auto surf = w->wlSurface();
    if (!surf || pres.alpha * pres.fadeAlpha * surf->m_alphaModifier * surf->m_overallOpacity < 1.F)
        return {};
    const auto res = surf->resource();
    if (!res)
        return {};
    const CBox box = w->getWindowMainSurfaceBox();
    if (std::abs(res->m_current.size.x - box.width) > 1 || std::abs(res->m_current.size.y - box.height) > 1)
        return {};   // being resized: the picture and the box disagree
    CRegion rg;
    if (res->m_current.texture && res->m_current.texture->m_opaque)
        rg.add(CBox{0, 0, box.width, box.height});
    else
        rg = res->m_current.opaque.copy().intersect(CBox{0, 0, box.width, box.height});
    if (rg.empty())
        return rg;
    const int round = (int)std::ceil(w->presentation().rounding());
    if (round > 0)
        rg.expand(-round);
    return rg.translate(box.pos());
}

// ---- what changed since the last frame (for the stored backdrops)
static uint64_t mixIn(uint64_t h, uint64_t v) {
    return h ^ (v + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
}
// a number that changes when a surface, or one of its subsurfaces, shows a new picture
static uint64_t pictureOf(SP<CWLSurfaceResource> res) {
    uint64_t h = 1469598103934665603ULL;
    if (!res)
        return h;
    res->breadthfirst(
        [](SP<CWLSurfaceResource> s, const Vector2D& at, void* data) {
            auto& h = *sc<uint64_t*>(data);
            h       = mixIn(h, (uint64_t)(uintptr_t)s->m_current.buffer.m_buffer.get());
            h       = mixIn(h, ((uint64_t)(int64_t)at.x << 32) ^ (uint64_t)(int64_t)at.y);
            h       = mixIn(h, ((uint64_t)s->m_current.size.x << 32) ^ (uint64_t)s->m_current.size.y);
        },
        &h);
    return h;
}
struct SSeen {
    uint64_t  picture = 0;
    CBox      box;
    bool      now = false;
    MONITORID monitor = MONITOR_INVALID;
};
static std::unordered_map<void*, SSeen> g_seen;

// -> where this thing changed since the last frame (global coordinates, empty box = it did not)
static CBox changed(void* key, uint64_t picture, const CBox& box, MONITORID monitor) {
    auto&      e     = g_seen[key];
    const bool was   = e.picture != 0;
    const bool moved = was && (e.box.x != box.x || e.box.y != box.y || e.box.w != box.w || e.box.h != box.h);
    CBox       out;
    if (!was || e.picture != picture || moved) {   // a new picture, or the same one in another place or size
        out = box;
        if (moved) {   // where it was, too
            const double x0 = std::min(e.box.x, box.x), y0 = std::min(e.box.y, box.y);
            out = CBox{x0, y0, std::max(e.box.x + e.box.w, box.x + box.w) - x0, std::max(e.box.y + e.box.h, box.y + box.h) - y0};
        }
    }
    e.picture = picture ? picture : 1;
    e.box     = box;
    e.now     = true;
    e.monitor = monitor;
    return out;
}

// ---- windows whose picture goes somewhere else too
// The "visible part" below tells Hyprland not to draw what an opaque window above covers. Hyprland
// uses the same field when it draws a window for a capture (a window share, a recording of one
// window, Cyber's tilted Looking Glass copy), so the capture got a hole where another window lay
// over it. In the tilted copy the hole is shifted sideways by the perspective and showed next to
// the covering window (seen 2026-11-24: a strip of bare wallpaper beside a browser window dragged
// over Looking Glass). So a window that is being captured is always drawn whole:
//   * a window tagged "cybertilt" (Cyber's copy of it is on screen);
//   * a window Hyprland reports a window share for. Its event only gives the window's title, at
//     the time the share began or ended, and titles change: every window with that title is
//     marked when a share begins, and a mark goes when a share with the title it was marked
//     under ends, or when no window share is left at all. That errs on the side of drawing.
struct SSharedWindow {
    PHLWINDOWREF window;
    std::string  title;
    int          shares = 0;
};
static std::vector<SSharedWindow> g_shared;
static int                        g_windowShares = 0;

static bool isCaptured(const PHLWINDOW& w) {
    if (w->m_ruleApplicator->m_tagKeeper.isTagged("cybertilt"))
        return true;
    for (auto& e : g_shared) {
        if (e.window.lock() == w)
            return true;
    }
    return false;
}

static CCyberPanelBlur* blurDecoOf(const PHLWINDOW& w) {
    for (auto& d : w->presentation().decorations()) {
        if (d->getDisplayName() == "CyberPanelBlur")
            return static_cast<CCyberPanelBlur*>(d.get());
    }
    return nullptr;
}

static void updateBuried(PHLMONITOR mon) {
    if (!mon)
        return;
    std::vector<PHLWINDOW> ws;   // in stacking order, lowest first
    for (auto& w : Desktop::windowState()->windows()) {
        if (!w || !w->mapped() || w->isHidden() || !w->m_workspace)
            continue;
        if (w->m_workspace != mon->m_activeWorkspace && w->m_workspace != mon->m_activeSpecialWorkspace)
            continue;
        ws.push_back(w);
        if (const auto deco = blurDecoOf(w)) {
            const bool tilted = w->m_ruleApplicator->m_tagKeeper.isTagged("cybertilt");
            deco->watchFrames(tilted);
            deco->cutFade(w, tilted);
        }
    }

    // ---- stored backdrops: what is behind each window, and did it change?
    if (!g_backdrops.empty()) {
        static auto PSIZE = CConfigValue<Config::INTEGER>("decoration:blur:size");
        static auto PPASS = CConfigValue<Config::INTEGER>("decoration:blur:passes");
        static auto PNOIS = CConfigValue<Config::FLOAT>("decoration:blur:noise");
        static auto PCONT = CConfigValue<Config::FLOAT>("decoration:blur:contrast");
        static auto PBRIG = CConfigValue<Config::FLOAT>("decoration:blur:brightness");
        static auto PVIBR = CConfigValue<Config::FLOAT>("decoration:blur:vibrancy");
        static double lastLook = -1;
        const double  look     = *PSIZE * 1000.0 + *PPASS * 100.0 + *PNOIS * 7.0 + *PCONT * 13.0 + *PBRIG * 17.0 + *PVIBR * 19.0 + vars.backdropSpread->value() * 23.0 + vars.backdropFps->value() * 0.001;
        if (look != lastLook) {
            lastLook = look;
            for (auto* b : g_backdrops)
                b->forget();
        }

        for (auto& [k, e] : g_seen) {
            if (e.monitor == mon->m_id)
                e.now = false;
        }
        std::vector<CBox> below;                       // changes behind every window: the wallpaper and bottom layers
        for (size_t level = 0; level < 2 && level < mon->m_layerSurfaceLayers.size(); ++level) {
            for (auto& ref : mon->m_layerSurfaceLayers[level]) {
                const auto ls = ref.lock();
                if (!ls || !ls->mapped() || !ls->wlSurface())
                    continue;
                const CBox c = changed(ls.get(), pictureOf(ls->wlSurface()->resource()), ls->m_geometry, mon->m_id);
                if (c.width > 0 && c.height > 0)
                    g_changedNow += ls->m_namespace + " ";
                if (c.width > 0 && c.height > 0)
                    below.push_back(c);
            }
        }
        std::vector<CBox> moved(ws.size());            // per window: where it changed (with room for its shadow)
        std::vector<CBox> movedRaw(ws.size()), boxes(ws.size());
        static std::unordered_map<void*, bool> wasShown;   // an invisible window (the parked Looking Glass one) changes nothing for anyone
        for (size_t i = 0; i < ws.size(); ++i) {
            const auto pres = ws[i]->presentation().renderPresentation();
            const CBox box  = ws[i]->getWindowMainSurfaceBox().translate(pres.workspaceOffset + pres.floatingOffset);
            uint64_t   pic  = pictureOf(ws[i]->wlSurface() ? ws[i]->wlSurface()->resource() : nullptr);
            pic             = mixIn(pic, (uint64_t)std::lround(pres.alpha * pres.fadeAlpha * 1000));
            pic             = mixIn(pic, ws[i] == Desktop::focusState()->window() ? 2 : 1);
            const CBox c    = changed(ws[i].get(), pic, box, mon->m_id);
            if (c.width > 0 && c.height > 0)
                g_changedNow += ws[i]->metadata().appID() + " ";
            const bool shown = pres.alpha * pres.fadeAlpha >= 0.02F;
            const bool was   = wasShown.contains(ws[i].get()) ? wasShown[ws[i].get()] : true;
            wasShown[ws[i].get()] = shown;
            boxes[i]              = box;
            if (c.width > 0 && c.height > 0 && (shown || was)) {
                movedRaw[i] = c;
                moved[i]    = c.copy().expand(40);
            }
        }
        if (wasShown.size() > 256)
            wasShown.clear();
        // what was there the frame before and is gone (closed, hidden, on another workspace): what was behind it shows now
        std::erase_if(g_seen, [&](const auto& kv) {
            if (kv.second.now || kv.second.monitor != mon->m_id)
                return false;
            below.push_back(kv.second.box.copy().expand(40));
            return true;
        });

        for (size_t i = 0; i < ws.size(); ++i) {
            const auto deco = blurDecoOf(ws[i]);
            if (!deco)
                continue;
            for (auto& c : below)
                deco->markStale(c);
            for (size_t j = 0; j < ws.size(); ++j) {
                if (j == i || moved[j].width <= 0)
                    continue;
                const bool under = ws[i]->isFloating() ? (!ws[j]->isFloating() || j < i) : (!ws[j]->isFloating() && j < i);
                // ... and it really lies behind this window: a neighbour (tiled windows side by side) does not
                if (under && !movedRaw[j].intersection(boxes[i]).empty())
                    deco->markStale(moved[j]);
            }
        }
    }
    for (size_t i = 0; i < ws.size(); ++i) {
        const CBox   me   = ws[i]->getWindowMainSurfaceBox();
        const double area = me.width * me.height;
        bool         buried = false;
        CRegion      part;       // what is left of the window after the opaque windows above it
        if (area > 1) {
            CRegion cover, seen;
            seen.add(me);
            bool cut = false;
            for (size_t j = 0; j < ws.size(); ++j) {
                if (j == i || ws[j]->m_workspace != ws[i]->m_workspace || !ws[j]->isFloating())
                    continue;
                if (j < i && ws[i]->isFloating())
                    continue;                                   // below this window (tiled windows are below every floating one)
                const auto pres = ws[j]->presentation().renderPresentation();
                if (pres.alpha * pres.fadeAlpha < 0.5F)
                    continue;                                   // a nearly invisible window hides nothing
                const CBox o = ws[j]->getWindowMainSurfaceBox().intersection(me);
                if (o.width <= 0 || o.height <= 0)
                    continue;
                cover.add(o);
                const CRegion solid = opaquePart(ws[j]);
                if (!solid.empty()) {
                    seen.subtract(solid);
                    cut = true;
                }
            }
            double covered = 0;
            for (auto& r : cover.getRects())
                covered += (double)(r.x2 - r.x1) * (double)(r.y2 - r.y1);
            buried = covered >= BURIED_AT * area || seen.empty();
            if (cut && !seen.empty()) {
                double left = 0;
                for (auto& r : seen.getRects())
                    left += (double)(r.x2 - r.x1) * (double)(r.y2 - r.y1);
                if (left < area - 1) {
                    part = seen.translate(-me.pos());
                    if (const auto surf = ws[i]->wlSurface(); surf && surf->resource() && surf->resource()->m_current.scale != 1)
                        part.scale(surf->resource()->m_current.scale);
                }
            }
        }
        for (auto& d : ws[i]->presentation().decorations()) {
            if (d->getDisplayName() != "CyberPanelBlur")
                continue;
            const auto deco = static_cast<CCyberPanelBlur*>(d.get());
            deco->setBuried(buried);
            deco->setVisiblePart(isCaptured(ws[i]) ? CRegion{} : part);
        }
    }
}

// While a panel window has the focus: every second refresh, have the rows redrawn that the band
// leaves and enters. The step is taken a little after the refresh that follows a shown frame (see
// scanOnPresent), not from a free-running timer: a frame started right when another went out and
// then shown two refreshes later is what the FPS readout counts as late, and a free timer did
// that 25 times a second (the readout would say 35). A step on every refresh costs twice as much
// (measured: 10% of the GPU against 5.5%).
static SP<CEventLoopTimer>                   g_scanTimer;
static CBox                                  g_scanLast;
static bool                                  g_scanActive = false;
static std::chrono::steady_clock::time_point g_scanDue;
static void scanArm(std::chrono::milliseconds in) {
    if (!g_scanTimer)
        return;
    g_scanDue = std::chrono::steady_clock::now() + in;
    g_scanTimer->updateTimeout(in);
}
static void scanStep(SP<CEventLoopTimer> self, void*) {
    const auto W = Desktop::focusState()->window();
    g_scanActive = vars.scan && vars.scan->value() > 0 && W && W->mapped() && isPanel(W) && !W->isHidden() &&
        !(W->m_workspace && Fullscreen::controller()->getFullscreenModes(W).internal == Fullscreen::FSMODE_FULLSCREEN);
    CBox now;
    if (g_scanActive) {
        const CBox box  = W->getWindowMainSurfaceBox();
        const auto band = scanBandAt(box.height, std::chrono::steady_clock::now());
        const double y0 = std::max(0.0, band.top - 2), y1 = std::min(box.height, band.top + band.height + 2);
        if (y1 > y0)
            now = CBox{box.x, box.y + y0, box.width, y1 - y0};
    }
    if (g_scanLast.width > 0)
        g_pHyprRenderer->damageBox(g_scanLast);
    if (now.width > 0)
        g_pHyprRenderer->damageBox(now);
    g_scanLast = now;
    scanArm(std::chrono::milliseconds(g_scanActive ? 70 : 400));   // in case no frame is shown (the band is off screen, the monitor asleep)
}
// a frame was shown: the next step goes a refresh and a bit from now, unless one is due before that
static void scanOnPresent(double refreshSeconds) {
    if (!g_scanActive)
        return;
    // (a refresh and 3 ms: measured 0 "late" a second and 5.5% of the GPU; one and a half refreshes
    // cost a little less but the readout counted 32 late a second)
    const auto in = std::chrono::milliseconds((int)std::lround(refreshSeconds * 1000.0) + 3);
    if (g_scanDue - std::chrono::steady_clock::now() > in)
        scanArm(in);
}

static void onWindowShare(bool started, const std::string& title) {
    std::erase_if(g_shared, [](const auto& e) { return e.window.expired(); });
    if (started) {
        g_windowShares++;
        for (auto& w : Desktop::windowState()->windows()) {
            if (!w || !w->mapped() || w->metadata().title() != title)
                continue;
            auto it = std::ranges::find_if(g_shared, [&](const auto& e) { return e.window.lock() == w && e.title == title; });
            if (it == g_shared.end())
                g_shared.push_back({w, title, 1});
            else
                it->shares++;
            if (const auto deco = blurDecoOf(w))
                deco->setVisiblePart({});   // whole from the first captured frame on
        }
        return;
    }
    g_windowShares = std::max(0, g_windowShares - 1);
    if (g_windowShares == 0) {
        g_shared.clear();
        return;
    }
    for (auto& e : g_shared) {
        if (e.title == title)
            e.shares--;
    }
    std::erase_if(g_shared, [](const auto& e) { return e.shares <= 0; });
}

// Diagnostics: `touch $XDG_RUNTIME_DIR/cyber-corners-dump` and within a second the plugin writes how
// it sees every window to $XDG_RUNTIME_DIR/cyber-corners-info (what the app declares opaque, and
// what the plugin decided: buried, clipped, blur region).
static void dumpIfAsked() {
    const char* rt = getenv("XDG_RUNTIME_DIR");
    if (!rt)
        return;
    const char*       tag = getenv("CYBER_CORNERS_TAG");   // set for a test session, so the live one does not answer for it
    const std::string ask = std::string(rt) + "/cyber-corners-dump" + (tag ? tag : "");
    if (access(ask.c_str(), F_OK) != 0)
        return;
    unlink(ask.c_str());
    FILE* f = fopen((std::string(rt) + "/cyber-corners-info" + (tag ? tag : "")).c_str(), "w");
    if (!f)
        return;
    fputs(dndFixInfo().c_str(), f);
    fputs(dragWsInfo().c_str(), f);
    for (auto& w : Desktop::windowState()->windows()) {
        if (!w || !w->mapped())
            continue;
        const auto surf = w->wlSurface();
        const auto res  = surf ? surf->resource() : nullptr;
        if (!res)
            continue;
        const CBox   box  = w->getWindowMainSurfaceBox();
        const auto   pres = w->presentation().renderPresentation();
        CRegion      op   = res->m_current.opaque.copy().intersect(CBox{0, 0, box.width, box.height});
        double       area = 0;
        for (auto& r : op.getRects())
            area += (double)(r.x2 - r.x1) * (double)(r.y2 - r.y1);
        fprintf(f, "%-28s %4.0fx%-4.0f alpha %.2f  declares opaque: %3.0f%% of the window (%zu rects)  opaque buffer: %d  -> hyprland opaque: %d, blurs: %d | visible-part rects: %zu, blur-region set: %d (%zu rects)\n",
                w->metadata().appID().c_str(), box.width, box.height, pres.alpha * pres.fadeAlpha, 100.0 * area / std::max(1.0, box.width * box.height), op.getRects().size(),
                res->m_current.texture ? (int)res->m_current.texture->m_opaque : -1, (int)w->presentation().opaque(), (int)w->shouldBlur(), surf->m_visibleRegion.getRects().size(),
                (int)surf->m_hasBackgroundEffect, surf->m_blurRegion.getRects().size());
        for (auto& d : w->presentation().decorations()) {
            if (d->getDisplayName() == "CyberPanelBlur")
                fprintf(f, "    %s\n", static_cast<CCyberPanelBlur*>(d.get())->stats().c_str());
        }
    }
    for (auto& [id, r] : g_reuse) {
        fprintf(f, "frames: %d, of which %d copied unchanged areas from the frame before: %.1f MP copied, %.1f MP composited\n", r.frames, r.used, r.copiedPx / 1e6, r.drawnPx / 1e6);
        r.frames = r.used = 0;
        r.copiedPx = r.drawnPx = 0;
    }
    fclose(f);
    // the last frames: start (ms after the first one listed), the compositor's own work (ms), start -> on screen (ms), refreshes missed,
    // this plugin's share of that work (blur update + backdrop draws + copying unchanged areas, ms), what changed
    if (FILE* g = fopen((std::string(rt) + "/cyber-corners-frames" + (tag ? tag : "")).c_str(), "w")) {
        const double t0 = g_frameLog.empty() ? 0 : g_frameLog.front().start;
        for (auto& r : g_frameLog)
            fprintf(g, "%9.1f  cpu %5.1f  shown after %6.1f  late %d  mine %.1f+%.1f+%.1f  %s%s\n", (r.start - t0) * 1000, r.cpu < 0 ? -1.0 : r.cpu * 1000,
                    r.shown < 0 ? r.shown : (r.shown - r.start) * 1000, r.late, r.mine[0] * 1000, r.mine[1] * 1000, r.mine[2] * 1000, r.real ? "" : "(nothing to draw) ", r.what.c_str());
        fclose(g);
    }
}

// The HUD's FPS readout (cyber/services/Fps.qml), posted on Hyprland's event socket once a second as
//   cyberfps>>MONITOR,FPS,DRAWN,LATE,REFRESH
// A compositor only draws when something changed, so "frames drawn" says how much moved, not how
// smooth it is: a still desktop with a 15 fps wallpaper draws 15. What is wanted is: of the
// screen's refreshes, how many did a frame miss? So every frame that really draws something
// (Hyprland also runs its frame loop when nothing changed: those passes draw nothing and put
// nothing new on screen, and are left out) is timed from the start of its rendering to the moment
// the screen shows it. A frame that was started right when the previous one went out (continuous
// drawing) and is not on the next refresh came LATE, once per refresh it missed.
// FPS = REFRESH - LATE: 60 while nothing is late, however little is drawn. DRAWN = frames shown.
// (Renders and screen updates are not paired one to one: with render:new_render_scheduling Hyprland
// also renders ahead without showing, which shifted such a pairing by several frames.)
struct SPresentWatch {
    WP<Aquamarine::IOutput>                             output;
    CHyprSignalListener                                 listener;
    std::deque<std::pair<std::chrono::steady_clock::time_point, uint64_t>> started;   // when the last frames that drew something were started (start, id)
    std::chrono::steady_clock::time_point               lastShown{}, lastPre{};
    uint64_t                                            lastId = 0;
    int                                                 drawn = 0, late = 0;
};
static std::unordered_map<std::string, UP<SPresentWatch>> g_present;

// ---------------------------------------------------------------------------------------------
// Reusing what the screen already shows.
//
// The screen has a few buffers that take turns (three here). Each one only receives the frames
// drawn into it, so Hyprland redraws in every frame all that changed since THAT buffer was last
// used: every change is composited two or three times over. With a wallpaper moving 15 times a
// second that makes about 45 of 60 frames full-screen redraws (all windows, blur, HUD) whenever
// anything else is moving too.
// But the buffer of the frame before holds the finished picture, complete. So at the start of a
// frame: what this buffer is missing and did NOT change since the previous frame is copied
// straight from the previous buffer (a plain copy, the cheapest thing a GPU does), and Hyprland is
// left with only what really changed. The picture is the same, bit for bit.
// Not done when the copy would not be exact or safe: zoom, a screen shader, a rotated screen,
// forced full frames (after a mode change), a screen capture in progress (Hyprland builds its
// capture picture from what it draws), tearing, damage tracking off.
// `plugin:cybercorners:reuse_frames = 0` turns it off.

static void reusePre(PHLMONITOR mon) {   // at render.pre, after our own changes to the damage
    if (!mon)
        return;
    auto& r     = g_reuse[mon->m_id];
    r.fresh     = mon->m_damage.getBufferDamage(1);
    r.haveFresh = true;
    r.forced    = mon->m_forceFullFrames > 0;
}

// a test hook: `touch $XDG_RUNTIME_DIR/cyber-corners-snap<TAG>` writes the previous frame's output
// buffer to cyber-corners-out<TAG>.ppm (screenshots are taken from another picture and cannot show
// what the reuse step does)
static void snapIfAsked(const SP<Render::GL::CGLFramebuffer>& fb, int w, int h) {
    const char* rt = getenv("XDG_RUNTIME_DIR");
    if (!rt || !fb)
        return;
    const char*       tag = getenv("CYBER_CORNERS_TAG");
    const std::string ask = std::string(rt) + "/cyber-corners-snap" + (tag ? tag : "");
    if (access(ask.c_str(), F_OK) != 0)
        return;
    unlink(ask.c_str());
    if (w < 1 || h < 1)
        return;
    std::vector<unsigned char> px((size_t)w * h * 4);
    Render::GL::g_pHyprOpenGL->bindFramebuffer(GL_READ_FRAMEBUFFER, fb->getFBID());
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
    if (FILE* f = fopen((std::string(rt) + "/cyber-corners-out" + (tag ? tag : "") + ".ppm").c_str(), "wb")) {
        fprintf(f, "P6\n%d %d\n255\n", w, h);
        for (size_t i = 0; i < (size_t)w * h; ++i)
            fwrite(&px[i * 4], 1, 3, f);
        fclose(f);
    }
}

static void reuseShown(Render::CRenderContext& ctx, PHLMONITOR mon) {   // at RENDER_BEGIN
    if (!mon)
        return;
    static auto PTRACK  = CConfigValue<Config::INTEGER>("debug:damage_tracking");
    static auto PBLINK  = CConfigValue<Config::INTEGER>("debug:damage_blink");
    static auto PSHADER = CConfigValue<std::string>("decoration:screen_shader");

    auto&      r         = g_reuse[mon->m_id];
    const auto cur       = ctx.m_data.outFB;
    const auto prev      = r.last.lock();
    const bool prevValid = r.valid && prev && cur && prev != cur;   // (these are wrappers around the screen's buffers: no size of their own)
    const bool haveFresh = r.haveFresh, forced = r.forced;
    r.haveFresh = false;
    r.last      = cur;
    r.valid     = false;   // true again when this frame has been rendered to the end (RENDER_POST)
    r.frames++;
    if (!cur || ctx.m_mode != Render::RENDER_MODE_NORMAL)
        return;
    const auto gl  = Render::GL::g_pHyprOpenGL.get();
    const auto src = prevValid ? dynamicPointerCast<Render::GL::CGLFramebuffer>(prev) : nullptr;
    const auto out = dynamicPointerCast<Render::GL::CGLFramebuffer>(cur);
    const auto wrk = dynamicPointerCast<Render::GL::CGLFramebuffer>(ctx.m_data.currentFB);
    const int W = mon->m_pixelSize.x, H = mon->m_pixelSize.y;
    if (src && gl && wrk && src->getFBID()) {
        snapIfAsked(src, W, H);
        gl->bindFramebuffer(GL_FRAMEBUFFER, wrk->getFBID());
        g_pHyprRenderer->bindFB(ctx, ctx.m_data.currentFB);
    }
    r.drawnPx += areaOf(ctx.m_data.damage);
    if (!vars.reuse->value() || !haveFresh || forced || !src || !out || !gl || !wrk || !src->getFBID() || !out->getFBID() || W < 1 || H < 1)
        return;
    const std::string shader = *PSHADER;   // Hyprland writes an empty string setting as "[[EMPTY]]"
    if (*PTRACK != 2 || *PBLINK || !(shader.empty() || shader == "[[EMPTY]]") || ctx.m_data.mouseZoomFactor != 1.F || mon->m_transform != WL_OUTPUT_TRANSFORM_NORMAL || mon->needsACopyFB() ||
        mon->m_tearingState.activelyTearing || !mon->m_solitaryClient.expired())
        return;

    const CBox whole = {0, 0, (double)W, (double)H};
    CRegion    reuse = ctx.m_data.damage.copy().subtract(r.fresh).intersect(whole);
    if (reuse.empty())
        return;
    CRegion keep = ctx.m_data.damage.copy().intersect(r.fresh);
    if (keep.empty()) {   // nothing new at all: keep one pixel, so the pass still runs and tells the clients about the frame
        const CBox e = ctx.m_data.damage.getExtents();
        keep         = CRegion{CBox{e.x, e.y, 1, 1}};
        reuse.subtract(keep);
    }

    STimed timed{g_mine[2]};
    gl->setCapStatus(GL_SCISSOR_TEST, false);
    gl->bindFramebuffer(GL_READ_FRAMEBUFFER, src->getFBID());
    gl->bindFramebuffer(GL_DRAW_FRAMEBUFFER, out->getFBID());
    for (auto& b : reuse.getRects())
        glBlitFramebuffer(b.x1, b.y1, b.x2, b.y2, b.x1, b.y1, b.x2, b.y2, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    gl->bindFramebuffer(GL_FRAMEBUFFER, wrk->getFBID());
    g_pHyprRenderer->bindFB(ctx, ctx.m_data.currentFB);   // back to what Hyprland was drawing into

    r.used++;
    r.copiedPx += areaOf(reuse);
    r.drawnPx  += areaOf(keep) - areaOf(ctx.m_data.damage);
    ctx.m_data.damage      = keep;
    ctx.m_data.finalDamage = keep;
}

// At RENDER_BEGIN: this frame has something to draw, so the screen will show it.
static void frameDraws(PHLMONITOR mon) {
    if (!mon)
        return;
    const auto it = g_present.find(mon->m_name);
    if (it == g_present.end() || !it->second || it->second->lastId == 0)
        return;
    auto& pw = *it->second;
    if (!pw.started.empty() && pw.started.back().second == pw.lastId)
        return;
    pw.started.emplace_back(pw.lastPre, pw.lastId);
    if (pw.started.size() > 16)
        pw.started.pop_front();
    for (auto r = g_frameLog.rbegin(); r != g_frameLog.rend(); ++r) {
        if (r->id == pw.lastId) {
            r->real = true;
            break;
        }
    }
}

static void countFrame(PHLMONITOR mon) {
    using clock = std::chrono::steady_clock;
    static clock::time_point since = clock::now();
    if (!mon || !mon->m_output)
        return;
    const auto now = clock::now();
    auto&      pw  = g_present[mon->m_name];
    if (!pw || pw->output.lock() != mon->m_output) {
        pw         = makeUnique<SPresentWatch>();
        pw->output = mon->m_output;
        const auto   raw    = pw.get();
        const double period = 1.0 / std::max(1.F, mon->m_refreshRate);
        pw->listener        = mon->m_output->events.present.listen([raw, period](const Aquamarine::IOutput::SPresentEvent& e) {
            // the time the screen really showed it (the event can reach us a little later)
            auto shown = clock::now();
            if (e.when && (e.when->tv_sec || e.when->tv_nsec)) {
                const auto stamp = clock::time_point(std::chrono::seconds(e.when->tv_sec) + std::chrono::nanoseconds(e.when->tv_nsec));
                if (stamp <= shown && shown - stamp < std::chrono::milliseconds(100))
                    shown = stamp;
            }
            if (!e.presented)
                return;
            scanOnPresent(period);
            raw->drawn++;
            // Did a refresh go by without a new frame, although one was being drawn for it? "Being
            // drawn for it" = its rendering started right when the previous frame went out (that is
            // when Hyprland starts the next frame while things keep changing). A frame started later
            // (something changed after a quiet moment) was never meant for that refresh.
            int late = 0;
            if (raw->lastShown.time_since_epoch().count() != 0) {
                const int gaps = (int)std::lround(std::chrono::duration<double>(shown - raw->lastShown).count() / period);
                if (gaps >= 2) {
                    for (auto& [t, id] : raw->started) {
                        if (t >= raw->lastShown - std::chrono::milliseconds(2) && t <= raw->lastShown + std::chrono::milliseconds(4)) {
                            late = std::min(gaps - 1, 4);
                            break;
                        }
                    }
                }
            }
            raw->late += late;
            // for the frame log: the newest frame that was started before this moment and not shown yet
            const double shownS = secondsOf(shown);
            for (auto it = g_frameLog.rbegin(); it != g_frameLog.rend(); ++it) {
                if (!it->real || it->shown >= 0 || it->start > shownS - 0.001)
                    continue;
                it->shown = shownS;
                it->late  = late;
                break;
            }
            while (!raw->started.empty() && raw->started.front().first <= shown - std::chrono::milliseconds(1))
                raw->started.pop_front();   // shown now, or never: either way it is not waiting for a later refresh
            raw->lastShown = shown;
        });
    }
    pw->lastPre = now;
    pw->lastId  = ++g_frameId;       // whether it draws anything is known at RENDER_BEGIN (frameDraws below)
    g_frameLog.push_back({g_frameId, secondsOf(now), -1, -1, 0, g_changedNow});
    g_changedNow.clear();
    if (g_frameLog.size() > 400)
        g_frameLog.pop_front();

    const double dt = std::chrono::duration<double>(now - since).count();
    if (dt < 1.0)
        return;
    for (auto& [name, w] : g_present) {
        if (!w->drawn)
            continue;
        const int refresh = w->output ? (int)std::round(w->output->state->state().mode ? w->output->state->state().mode->refreshRate / 1000.0 : 60.0) : 60;
        const int late    = (int)std::round(w->late / dt);
        IPC::Socket2::sock()->postEvent({"cyberfps", name + "," + std::to_string(std::max(0, refresh - late)) + "," + std::to_string((int)std::round(w->drawn / dt)) + "," +
                                                         std::to_string(late) + "," + std::to_string(refresh)});
        w->drawn = w->late = 0;
    }
    since = now;
    dumpIfAsked();
    for (auto* b : g_backdrops)
        b->releaseIfUnused();
}

// A fullscreen window that gets the focus is in front again. Hyprland lets a floating window that
// is focused while another window is fullscreen show above it, and leaves it there after the
// fullscreen window has the focus back (seen with Looking Glass fullscreen and a terminal on top).
// Pinned windows stay; focusing a hidden window (Super+Tab) brings it over the fullscreen one again.
static void coverByFullscreen(PHLWINDOW w) {
    if (!w || !w->m_workspace)
        return;
    if (Fullscreen::controller()->getFullscreenWindow(w->m_workspace) != w ||
        Fullscreen::controller()->getFullscreenModes(w).internal != Fullscreen::FSMODE_FULLSCREEN)
        return;
    for (auto& o : Desktop::windowState()->windows()) {
        if (!o || o == w || !o->mapped() || o->m_workspace != w->m_workspace)
            continue;
        if (!o->fullscreenPolicy().allowedOverFullscreen() || (o->m_state & Desktop::View::WINDOW_STATE_PINNED))
            continue;
        o->fullscreenPolicy().setAllowedOverFullscreen(false);
        o->updateFullscreenInputState();
        Animation::Workspace::setFullscreenFloatingFade(o, 0.F);
        g_pHyprRenderer->damageWindow(o);
    }
}

static void addTo(PHLWINDOW w) {
    const auto has = [&w](const char* name) {
        return std::ranges::any_of(w->presentation().decorations(), [name](const auto& d) { return d->getDisplayName() == name; });
    };
    if (!has("CyberCorners"))
        HyprlandAPI::addWindowDecoration(PHANDLE, w, makeShared<CCyberCorners>(w));
    if (!has("CyberPanelBlur"))
        HyprlandAPI::addWindowDecoration(PHANDLE, w, makeShared<CCyberPanelBlur>(w));
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    if (std::string{__hyprland_api_get_hash()} != __hyprland_api_get_client_hash()) {
        HyprlandAPI::addNotification(PHANDLE, "[cybercorners] built for another Hyprland version: run ~/.local/share/cyber/cyber/hypr/corners/build.sh",
                                     CHyprColor{1.0, 0.2, 0.2, 1.0}, 6000);
        throw std::runtime_error("[cybercorners] version mismatch");
    }

    vars.color     = makeShared<Config::Values::CColorValue>("plugin:cybercorners:color", "Corner bracket colour", 0xff3cf0ff);
    vars.length    = makeShared<Config::Values::CIntValue>("plugin:cybercorners:length", "Arm length (px)", 16, Config::Values::SIntValueOptions{.min = 2, .max = 400});
    vars.thickness = makeShared<Config::Values::CIntValue>("plugin:cybercorners:thickness", "Line width (px)", 2, Config::Values::SIntValueOptions{.min = 1, .max = 20});
    vars.gap       = makeShared<Config::Values::CIntValue>("plugin:cybercorners:gap", "Space between window and bracket (px)", 3, Config::Values::SIntValueOptions{.min = 0, .max = 40});
    vars.pinColor  = makeShared<Config::Values::CColorValue>("plugin:cybercorners:pin_color", "Corner bracket colour of a pinned window", 0xffff2bd6);
    HyprlandAPI::addConfigValueV2(PHANDLE, vars.color);
    HyprlandAPI::addConfigValueV2(PHANDLE, vars.pinColor);
    HyprlandAPI::addConfigValueV2(PHANDLE, vars.length);
    HyprlandAPI::addConfigValueV2(PHANDLE, vars.thickness);
    HyprlandAPI::addConfigValueV2(PHANDLE, vars.gap);
    vars.backdropFps = makeShared<Config::Values::CIntValue>("plugin:cybercorners:backdrop_fps", "Most refreshes a second of the stored blurred backdrop of see-through windows (0 = off)", 60,
                                                             Config::Values::SIntValueOptions{.min = 0, .max = 240});
    HyprlandAPI::addConfigValueV2(PHANDLE, vars.backdropFps);
    vars.backdropSpread = makeShared<Config::Values::CIntValue>("plugin:cybercorners:backdrop_spread", "Blur width of the stored backdrop, percent of size * 2^passes", SPREAD_DEFAULT,
                                                                Config::Values::SIntValueOptions{.min = 5, .max = 300});
    HyprlandAPI::addConfigValueV2(PHANDLE, vars.backdropSpread);
    vars.reuse = makeShared<Config::Values::CIntValue>("plugin:cybercorners:reuse_frames", "Copy unchanged areas from the previous frame instead of drawing them again (0 = off)", 1,
                                                       Config::Values::SIntValueOptions{.min = 0, .max = 1});
    HyprlandAPI::addConfigValueV2(PHANDLE, vars.reuse);
    vars.scan = makeShared<Config::Values::CIntValue>("plugin:cybercorners:scan_band", "Brightness of the scan band drifting down the focused terminal at its lower edge, percent (0 = none)", 10,
                                                      Config::Values::SIntValueOptions{.min = 0, .max = 30});
    HyprlandAPI::addConfigValueV2(PHANDLE, vars.scan);
    vars.scanPeriod = makeShared<Config::Values::CIntValue>("plugin:cybercorners:scan_period", "Seconds the scan band takes from top to bottom", 7,
                                                            Config::Values::SIntValueOptions{.min = 2, .max = 120});
    HyprlandAPI::addConfigValueV2(PHANDLE, vars.scanPeriod);
    g_scanTimer = makeShared<CEventLoopTimer>(std::chrono::milliseconds(400), scanStep, nullptr);
    g_pEventLoopManager->addTimer(g_scanTimer);
    dndFixInit(PHANDLE);
    dragWsInit(PHANDLE);

    g_catchUp = makeShared<CEventLoopTimer>(
        std::nullopt,
        [](SP<CEventLoopTimer> self, void*) {
            bool more = false;
            for (auto* b : g_backdrops)
                more = b->catchUp() || more;
            self->updateTimeout(more ? std::optional<Time::steady_dur>{std::chrono::milliseconds(8)} : std::nullopt);
        },
        nullptr);
    g_pEventLoopManager->addTimer(g_catchUp);

    static auto onOpen = Event::bus()->m_events.window.open.listen([](PHLWINDOW w) { addTo(w); });
    static auto onShare = Event::bus()->m_events.screenshare.state.listen([](bool started, uint8_t type, const std::string& name) {
        if (type == Screenshare::SHARE_WINDOW)
            onWindowShare(started, name);
    });
    static auto onActive = Event::bus()->m_events.window.active.listen([](PHLWINDOW w, Desktop::eFocusReason) { coverByFullscreen(w); });
    // pinned or unpinned: its brackets appear, change colour or go (nothing else redraws them)
    static auto onPin = Event::bus()->m_events.window.pin.listen([](PHLWINDOW w) {
        if (const auto m = w ? w->m_monitor.lock() : nullptr)
            g_pHyprRenderer->damageMonitor(m);
    });
    static auto onFrame  = Event::bus()->m_events.render.pre.listen([](PHLMONITOR m) {
        updateBuried(m);
        countFrame(m);
        reusePre(m);
    });
    static auto onStage = Event::bus()->m_events.render.stage.listen([](const auto& ev) {
        if (ev.stage == RENDER_BEGIN && ev.context && !ev.context->get().m_data.damage.empty()) {
            frameDraws(ev.monitor);
            reuseShown(ev.context->get(), ev.monitor);
        }
        if (ev.stage == RENDER_POST && ev.monitor) {
            const auto it = g_reuse.find(ev.monitor->m_id);
            if (it != g_reuse.end())
                it->second.valid = true;
        }
        if (ev.stage == RENDER_POST && !g_frameLog.empty() && g_frameLog.back().cpu < 0) {
            g_frameLog.back().cpu = secondsOf(std::chrono::steady_clock::now()) - g_frameLog.back().start;
            for (int i = 0; i < 3; ++i) {
                g_frameLog.back().mine[i] = g_mine[i];
                g_mine[i]                 = 0;
            }
        }
    });

    for (auto& w : Desktop::windowState()->windows()) {
        if (w->isHidden() || !w->mapped())
            continue;
        addTo(w);
    }

    return {"cybercorners", "Cyber desktop: corner markers, stored blurred backdrops for see-through windows, FPS for the HUD, drag-and-drop fix, dragged windows follow to other workspaces", "hypr-setup", "4.7"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    dndFixExit();
    dragWsExit();
    if (g_scanTimer) {
        g_scanTimer->cancel();
        g_pEventLoopManager->removeTimer(g_scanTimer);
        g_scanTimer.reset();
    }
    if (g_catchUp) {
        g_catchUp->cancel();
        g_pEventLoopManager->removeTimer(g_catchUp);
        g_catchUp.reset();
    }
    g_shared.clear();
    g_windowShares = 0;
    g_reuse.clear();
    g_present.clear();   // the listeners on the outputs' present events
    for (auto* b : g_backdrops)
        b->dropPicture();
    g_backdrops.clear();
    if (Render::GL::g_pHyprOpenGL) {
        Render::GL::g_pHyprOpenGL->makeEGLCurrent();
        Fast::freeAll();
    }
    // Hyprland removes this plugin's decorations itself; give the panels' surfaces back as they were
    for (auto& w : Desktop::windowState()->windows()) {
        if (!w)
            continue;
        for (auto& d : w->presentation().decorations()) {
            if (d->getDisplayName() == "CyberPanelBlur")
                static_cast<CCyberPanelBlur*>(d.get())->clear();
        }
    }
}
