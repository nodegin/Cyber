// dragws.cpp : a window that is being dragged comes along to another workspace. Part of cybercorners.so.
//
// Hyprland 0.57 leaves a dragged window behind when the workspace changes (Super + left button,
// then Super + 2: the screen shows workspace 2, the window stays on 1 and the drag is dead). Asked
// for on 2026-11-26, two ways to take a window to another workspace while dragging it:
//   1. keep the pointer on the left or right edge of the screen for a second: the previous / next
//      workspace comes up and the window with it (again a second later while the pointer stays
//      there). Workspaces go in tens, like the shell's indicator: no step past the ends of the ten.
//   2. press a workspace key (Super + 1 .. 0), or change workspace any other way: the window is
//      moved to that workspace, under the pointer as it was, and the drag goes on.
// How: when the active workspace changes while the left button holds a window in a move drag, the
// window is moved to the new workspace. Hyprland ends the drag at the key press that changes the
// workspace and once more when that key is let go (seen with a logging build): from the first
// carry until the button is released, a drag that has ended is begun again (revive(): after every
// key event and at every pointer movement; never while the window is on a workspace that is not
// shown, which would bring that workspace back). The edge is watched on every pointer movement.
// For the picture at the edge this only posts events (the shell draws it: cyber/hud/EdgeSwitch.qml):
//   cyberdragedge>>left,<workspace>,<ms>,<y>   the pointer is on that edge, <y> from the top: that workspace in <ms>
//   cyberdragedge>>go,<left|right>,<workspace>   now
//   cyberdragedge>>off                       not any more
// plugin:cybercorners:drag_ws = 0 turns all of it off; drag_ws_delay is the wait in milliseconds.

#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>

#include <linux/input-event-codes.h>

#define WLR_USE_UNSTABLE
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/GlobalWindowController.hpp>
#include <hyprland/src/workspace/HLWorkspace.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/config/values/types/IntValue.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/ipc/s2/S2.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>

namespace {
    constexpr int                 TEN = 10;      // workspaces go in tens (the shell's indicator, Super + 1..0)

    SP<Config::Values::CIntValue> g_on, g_delay, g_log;
    SP<CEventLoopTimer>           g_timer;       // runs out: step to the workspace at the edge
    CHyprSignalListener           g_onMove, g_onButton, g_onKey, g_onWorkspace;
    PHLWINDOWREF                  g_held;        // the window the left button is dragging (as of the last pointer event)
    bool                          g_leftDown = false;
    bool                          g_carrying = false;
    bool                          g_keep     = false;  // a window was carried: its drag goes on until the button is released
    int                           g_side     = 0;      // -1 = on the left edge, 1 = on the right edge, with a workspace to go to
    int64_t                       g_target   = 0;      // that workspace
    struct {
        int carried = 0, steps = 0;
    } g_n;

    bool on() {
        return g_on && g_on->value() != 0;
    }

    // plugin:cybercorners:drag_ws_log = 1: what happens during a drag, one line each, in
    // $XDG_RUNTIME_DIR/cyber-dragws.log (for finding out why a window did not come along)
    void note(const char* fmt, ...) {
        if (!g_log || g_log->value() == 0)
            return;
        static FILE* f = nullptr;
        if (!f) {
            const char* dir = getenv("XDG_RUNTIME_DIR");
            f               = fopen((std::string(dir ? dir : "/tmp") + "/cyber-dragws.log").c_str(), "a");
            if (!f)
                return;
        }
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
        fprintf(f, "%lld.%03lld ", static_cast<long long>(ms / 1000 % 100000), static_cast<long long>(ms % 1000));
        va_list ap;
        va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fputc('\n', f);
        fflush(f);
    }
    long wsNumber(const PHLWORKSPACE& ws) {
        const auto id = ws ? ws->numberedID() : std::nullopt;
        return id ? static_cast<long>(*id) : -1;
    }

    void post(const std::string& data) {
        IPC::Socket2::sock()->postEvent({"cyberdragedge", data});
    }

    // the window in a move drag right now
    PHLWINDOW dragged() {
        if (!g_layoutManager)
            return nullptr;
        const auto& dc = g_layoutManager->dragController();
        if (!dc || dc->mode() != MBIND_MOVE)
            return nullptr;
        const auto t = dc->target();
        return t ? t->window() : nullptr;
    }

    // a carried window whose drag Hyprland has ended: pick it up again, where it is
    void revive() {
        const auto w = g_held.lock();
        if (!g_keep || !g_leftDown || !w || !on() || !g_layoutManager || dragged() == w)
            return;
        // Only on the workspace that is shown. Beginning a drag on a window of another workspace
        // brings that workspace back up: a workspace key pressed after the first carry showed the
        // new workspace for a moment and bounced back, and nothing moved (2026-11-26). carry()
        // moves the window first and calls this again.
        const auto mon = w->m_monitor.lock();
        if (!mon || mon->m_activeWorkspace != w->m_workspace)
            return;
        g_layoutManager->beginDragTarget(w->layoutTarget(), MBIND_MOVE);
        note("drag begun again: %s (window on workspace %ld)", dragged() == w ? "ok" : "REFUSED", wsNumber(w->m_workspace));
    }

    void leaveEdge() {
        if (g_side == 0)
            return;
        g_side = 0;
        g_timer->updateTimeout(std::nullopt);
        post("off");
    }

    // Where the pointer is on the dragged window's monitor: on an edge with a workspace behind it?
    void look() {
        revive();
        const auto w = on() ? dragged() : nullptr;
        if (w)
            g_held = w;
        const auto mon = w ? w->m_monitor.lock() : nullptr;
        const auto id  = mon && mon->m_activeWorkspace ? mon->m_activeWorkspace->numberedID() : std::nullopt;
        if (!w || !id) {
            leaveEdge();
            return;
        }
        const auto    p      = g_pInputManager->getMouseCoordsInternal();
        const int     side   = p.x <= mon->m_position.x + 1 ? -1 : p.x >= mon->m_position.x + mon->m_size.x - 2 ? 1 : 0;
        const int64_t first  = ((*id - 1) / TEN) * TEN + 1;
        const int64_t target = *id + side;
        if (side == 0 || *id < 1 || target < first || target > first + TEN - 1) {
            leaveEdge();
            return;
        }
        if (side == g_side && target == g_target)
            return;     // already counting down for it
        g_side   = side;
        g_target = target;
        const int ms = g_delay ? static_cast<int>(g_delay->value()) : 1000;
        g_timer->updateTimeout(std::chrono::milliseconds(ms));
        post(std::string(side < 0 ? "left," : "right,") + std::to_string(target) + "," + std::to_string(ms) + "," + std::to_string(static_cast<int>(p.y - mon->m_position.y)));
    }

    void step(SP<CEventLoopTimer>, void*) {
        const int  side   = g_side;
        const auto target = g_target;
        g_side            = 0;
        if (side == 0 || !on() || !dragged()) {
            post("off");
            return;
        }
        g_n.steps++;
        post(std::string("go,") + (side < 0 ? "left," : "right,") + std::to_string(target));
        (void)Config::Actions::changeWorkspace(std::to_string(target));     // the window follows: see carry()
        // still on the edge afterwards: count down for the next one
        g_pEventLoopManager->doLater([] { look(); });
    }

    // the active workspace changed: take the held window along
    void carry(PHLWORKSPACE ws) {
        const auto w = g_held.lock();
        if (g_carrying || !on() || !g_leftDown || !w || !ws || !ws->numberedID() || w->m_workspace == ws) {
            note("workspace %ld: nothing to carry (button %s, held window %s%s)", wsNumber(ws), g_leftDown ? "down" : "up", w ? "yes" : "no",
                 w && w->m_workspace == ws ? ", already there" : "");
            return;
        }
        const auto mon = w->m_monitor.lock();
        if (!mon || mon != ws->m_monitor.lock())
            return;     // another monitor's workspace: not this drag's business
        if (mon->m_activeWorkspace != ws) {
            note("workspace %ld is no longer the one shown (now %ld): not carrying", wsNumber(ws), wsNumber(mon->m_activeWorkspace));
            return;
        }
        g_carrying      = true;
        const long from = wsNumber(w->m_workspace);
        const auto r    = Config::Actions::moveToWorkspace(ws, true, w);
        if (w->m_workspace != ws)       // the action would not: the plain move
            Desktop::globalWindowController()->moveWindowToWorkspace(w, ws);
        if (w->m_workspace != ws) {
            // Still where it was. Do NOT focus it: that would bring its old workspace back up.
            note("carry %ld -> %ld REFUSED (%s)", from, wsNumber(ws), r ? "no error given" : r.error().message.c_str());
            g_carrying = false;
            return;
        }
        // (not the "focus" action: that one puts the pointer in the middle of the window)
        Desktop::focusState()->fullWindowFocus(w, Desktop::FOCUS_REASON_DESKTOP_STATE_CHANGE);
        g_keep = true;
        revive();
        g_carrying = false;
        g_n.carried++;
        note("carried %ld -> %ld, shown now %ld, dragging %s", from, wsNumber(ws), wsNumber(mon->m_activeWorkspace), dragged() == w ? "yes" : "no");
    }
}

void dragWsInit(HANDLE handle) {
    g_on = makeShared<Config::Values::CIntValue>("plugin:cybercorners:drag_ws", "A dragged window comes along to another workspace (screen edges, workspace keys; 0 = off)", 1,
                                                 Config::Values::SIntValueOptions{.min = 0, .max = 1});
    g_delay = makeShared<Config::Values::CIntValue>("plugin:cybercorners:drag_ws_delay", "How long the pointer stays on a screen edge before the workspace changes (ms)", 1000,
                                                    Config::Values::SIntValueOptions{.min = 200, .max = 5000});
    g_log = makeShared<Config::Values::CIntValue>("plugin:cybercorners:drag_ws_log", "Write what happens during a drag to $XDG_RUNTIME_DIR/cyber-dragws.log (1 = on)", 0,
                                                  Config::Values::SIntValueOptions{.min = 0, .max = 1});
    HyprlandAPI::addConfigValueV2(handle, g_on);
    HyprlandAPI::addConfigValueV2(handle, g_delay);
    HyprlandAPI::addConfigValueV2(handle, g_log);

    g_timer = makeShared<CEventLoopTimer>(std::nullopt, step, nullptr);
    g_pEventLoopManager->addTimer(g_timer);

    g_onMove   = Event::bus()->m_events.input.mouse.move.listen([](Vector2D, Event::SCallbackInfo&) { look(); });
    g_onButton = Event::bus()->m_events.input.mouse.button.listen([](IPointer::SButtonEvent e, Event::SCallbackInfo&) {
        if (e.button != BTN_LEFT)
            return;
        g_leftDown = e.state == WL_POINTER_BUTTON_STATE_PRESSED;
        note("left button %s (dragging %s)", g_leftDown ? "down" : "up", dragged() ? "yes" : "no");
        if (!g_leftDown) {
            g_held.reset();
            g_keep = false;
            leaveEdge();
        }
    });
    g_onKey = Event::bus()->m_events.input.keyboard.key.listen([](IKeyboard::SKeyEvent e, Event::SCallbackInfo&) {
        if (g_leftDown && g_held.lock())
            note("key %u %s (dragging %s)", e.keycode, e.state == WL_KEYBOARD_KEY_STATE_PRESSED ? "down" : "up", dragged() ? "yes" : "no");
        if (g_keep && g_leftDown)
            g_pEventLoopManager->doLater([] { revive(); });     // once Hyprland has dealt with the key
    });
    // after the change has been carried out, not in the middle of it
    g_onWorkspace = Event::bus()->m_events.workspace.active.listen([](PHLWORKSPACE ws) {
        if (!g_leftDown || g_carrying || !g_held.lock())
            return;
        note("workspace %ld shown (held window on %ld, dragging %s)", wsNumber(ws), wsNumber(g_held.lock()->m_workspace), dragged() ? "yes" : "no");
        g_pEventLoopManager->doLater([ref = PHLWORKSPACEREF(ws)] {
            if (const auto ws = ref.lock())
                carry(ws);
        });
    });
}

void dragWsExit() {
    g_onMove.reset();
    g_onButton.reset();
    g_onKey.reset();
    g_onWorkspace.reset();
    g_held.reset();
    if (g_timer) {
        g_timer->cancel();
        g_pEventLoopManager->removeTimer(g_timer);
        g_timer.reset();
    }
}

std::string dragWsInfo() {
    char line[200];
    snprintf(line, sizeof(line), "drag to workspace: %s; windows carried %d, edge steps %d\n", on() ? "on" : "off", g_n.carried, g_n.steps);
    return line;
}
