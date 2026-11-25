// dndfix.cpp : drag and drop that ends, on Hyprland 0.57.x. Part of cybercorners.so.
//
// What was wrong (found 2026-11-24 with COSMIC Files: drag a file onto the sidebar, let go, and the
// pointer was dead for every window afterwards):
//   1. Hyprland 0.57 does not answer wl_data_offer.set_actions. A drop target says with that request
//      what it can do with the data (copy, move), and the compositor has to reply with the action
//      that will happen (wl_data_offer.action, and wl_data_source.action for the other side).
//      Hyprland sends one action when the drag enters a window and never again. COSMIC's toolkit
//      forgets the action each time the drag passes over something that is not a drop target and
//      waits for the reply when it reaches the next one: by the time of the drop it has none, and
//      ignores the drop. It never reads the data and never says it is finished.
//   2. After a drop Hyprland 0.57 keeps the drag open until the target says "finished", and gives no
//      window the pointer meanwhile. With a target that never says so, that is for good.
// Hyprland's main branch has both fixed (it answers set_actions and ends the drag at the drop), but
// no release has that yet. Until one does, this file does the same from the plugin:
//   1. it answers set_actions on the offers of the running drag, choosing the action as Hyprland's
//      main branch does: the target's preferred one if the source allows it, else copy, move, ask;
//   2. a drop that the target has not started to read after 1.5 s (or not finished after 15 s) is
//      called off, the way Hyprland calls off a drag itself: the pointer is back.
// plugin:cybercorners:dnd_fix = 0 turns both off. Remove this file when Hyprland has the fix
// (src/protocols/core/DataDevice.cpp there has a setSetActions handler in CWLDataOfferResource).
#include <algorithm>
#include <bit>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#define WLR_USE_UNSTABLE
// The running drag and its offers are private in Hyprland; this file alone looks inside. (The
// classes are laid out the same either way: only who may name the members changes.) Everything
// that header includes is included first, untouched, so that the change reaches its own two
// classes and nothing else (the standard library does not compile with it).
#include <hyprland/src/protocols/WaylandProtocol.hpp>
#include <wayland-server-protocol.h>
#include <hyprland/protocols/wayland.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>
#include <hyprland/src/helpers/math/Math.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/protocols/types/DataDevice.hpp>
#include <hyprutils/os/FileDescriptor.hpp>
#define private public
#include <hyprland/src/protocols/core/DataDevice.hpp>
#undef private
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/config/values/types/IntValue.hpp>

namespace {
    using clk = std::chrono::steady_clock;
    constexpr uint32_t NONE    = WL_DATA_DEVICE_MANAGER_DND_ACTION_NONE;
    constexpr uint32_t COPY    = WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY;
    constexpr uint32_t MOVE    = WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE;
    constexpr uint32_t ASK     = WL_DATA_DEVICE_MANAGER_DND_ACTION_ASK;
    constexpr uint32_t ALL     = COPY | MOVE | ASK;
    constexpr uint32_t UNKNOWN = 0xffffffff;
    constexpr auto     UNREAD  = std::chrono::milliseconds(1500);   // dropped, and the target has not asked for the data
    constexpr auto     READING = std::chrono::seconds(15);          // dropped, the target is reading and has not finished
    constexpr auto     TICK    = std::chrono::milliseconds(200);

    SP<Config::Values::CIntValue>         g_on;
    SP<CEventLoopTimer>                   g_watch;
    std::vector<WP<CWLDataOfferResource>> g_hooked;        // offers that carry our set_actions handler
    WP<IDataSource>                       g_dropSource;    // the drag that was dropped and has not ended yet
    clk::time_point                       g_dropAt;
    CHyprSignalListener                   g_onFocus, g_onStart, g_onMove, g_onButton, g_onTouchUp, g_onTip;
    struct {
        int answered = 0, drops = 0, calledOff = 0;
    } g_n;

    bool on() {
        return g_on && g_on->value() != 0 && PROTO::data;
    }

    // as CWLDataOfferResource::updateAction in Hyprland's main branch
    uint32_t choose(uint32_t source, uint32_t target, uint32_t preferred) {
        const uint32_t both = source & target;
        for (const uint32_t a : {preferred, COPY, MOVE, ASK}) {
            if (a && (both & a))
                return a;
        }
        return NONE;
    }

    void hook() {
        if (!on() || !PROTO::data->dndActive())
            return;
        static const bool SILENT = getenv("CYBER_DND_TEST_SILENT");   // tests only: leave targets unanswered, to see the drop being called off
        if (SILENT)
            return;
        auto& P = *PROTO::data;
        std::erase_if(g_hooked, [](const auto& w) { return w.expired(); });
        for (auto const& o : P.m_offers) {
            if (!o || o->m_dead || !o->m_resource || !o->m_source || o->m_source != P.m_dnd.currentSource)
                continue;
            if (std::ranges::any_of(g_hooked, [&o](const auto& w) { return w.get() == o.get(); }))
                continue;
            g_hooked.emplace_back(o);
            WP<CWLDataOfferResource> weak = o;
            // Hyprland 0.57 announces an action together with the offer, before the drag has entered
            // the window. COSMIC's toolkit (and smithay's, under it) only takes an action that comes
            // after the enter, so the first request is always answered, whatever was announced.
            auto                     last = std::make_shared<uint32_t>(UNKNOWN);
            o->m_resource->setSetActions([weak, last](CWlDataOffer* r, uint32_t actions, uint32_t preferred) {
                const auto offer = weak.lock();
                if (!offer || offer->m_dead)
                    return;
                const auto src = offer->m_source.lock();
                if (!src || !src->hasDnd())
                    return;
                if (g_dropSource && g_dropSource == offer->m_source)
                    return;   // after the drop the action stands
                if ((actions & ~ALL) || (preferred && (!std::has_single_bit(preferred) || !(preferred & actions))))
                    return;   // not a valid request: left unanswered, as Hyprland 0.57 leaves every one
                const uint32_t a = choose(src->actions(), r->version() >= 3 ? actions : COPY, preferred);
                if (a == *last)
                    return;
                *last = a;
                if (r->version() >= 3)
                    r->sendAction(a);
                src->sendDndAction(sc<wl_data_device_manager_dnd_action>(a));
                g_n.answered++;
            });
        }
    }

    void watch(SP<CEventLoopTimer> self, void*) {
        if (!g_dropSource || !PROTO::data || !PROTO::data->dndActive() || PROTO::data->m_dnd.currentSource != g_dropSource) {
            g_dropSource.reset();   // it ended by itself: the normal case
            self->updateTimeout(std::nullopt);
            return;
        }
        bool reading = false;
        for (auto const& o : PROTO::data->m_offers) {
            if (o && !o->m_dead && o->m_source == g_dropSource && o->m_recvd)
                reading = true;
        }
        const auto waited = clk::now() - g_dropAt;
        if ((reading && waited >= READING) || (!reading && waited >= UNREAD)) {
            g_dropSource.reset();
            g_n.calledOff++;
            PROTO::data->abortDndIfPresent();   // tells both sides it is over and hands the pointer back
            self->updateTimeout(std::nullopt);
            return;
        }
        self->updateTimeout(TICK);
    }

    // hook() once this round of events is through. One at a time, and taken back when the plugin
    // is unloaded: Hyprland must not call into code that is gone.
    uint64_t g_later        = 0;
    bool     g_laterPending = false;
    void     later() {
        if (g_laterPending || !on() || !PROTO::data->dndActive())
            return;
        g_laterPending = true;
        g_later        = g_pEventLoopManager->doLater([] {
            g_laterPending = false;
            hook();
        });
    }

    // the button (finger, pen) is up while a drag runs: Hyprland drops it now
    void released() {
        if (!on() || !g_watch || !PROTO::data->dndActive())
            return;
        g_dropSource = PROTO::data->m_dnd.currentSource;
        g_dropAt     = clk::now();
        g_n.drops++;
        g_watch->updateTimeout(TICK);
    }
}

void dndFixInit(HANDLE handle) {
    g_on = makeShared<Config::Values::CIntValue>("plugin:cybercorners:dnd_fix", "Answer drop targets and end drags that never finish (works around Hyprland 0.57; 0 = off)", 1,
                                                 Config::Values::SIntValueOptions{.min = 0, .max = 1});
    HyprlandAPI::addConfigValueV2(handle, g_on);

    g_watch = makeShared<CEventLoopTimer>(std::nullopt, watch, nullptr);
    g_pEventLoopManager->addTimer(g_watch);

    // Our handler has to be on an offer before the window it goes to can answer. Hyprland makes the
    // offer when the drag enters a window: in its own listener of dndPointerFocusChange (ours runs
    // after it), and when a drag starts, right after it has taken the pointer from the window the
    // drag began in (pointerFocusChange; the offer is made a few lines later, so "later" here: after
    // this round of events, still before the window's answer can be read). Every pointer movement
    // looks again.
    g_onFocus = g_pSeatManager->m_events.dndPointerFocusChange.listen([] {
        hook();
        later();
    });
    g_onStart = g_pSeatManager->m_events.pointerFocusChange.listen([] { later(); });
    g_onMove    = Event::bus()->m_events.input.mouse.move.listen([](Vector2D, Event::SCallbackInfo&) { hook(); });
    g_onButton  = Event::bus()->m_events.input.mouse.button.listen([](IPointer::SButtonEvent e, Event::SCallbackInfo&) {
        if (e.state == WL_POINTER_BUTTON_STATE_RELEASED)
            released();
        else
            hook();
    });
    g_onTouchUp = Event::bus()->m_events.input.touch.up.listen([](ITouch::SUpEvent, Event::SCallbackInfo&) { released(); });
    g_onTip     = Event::bus()->m_events.input.tablet.tip.listen([](CTablet::STipEvent e, Event::SCallbackInfo&) {
        if (!e.in)
            released();
    });
}

void dndFixExit() {
    g_onFocus.reset();
    g_onStart.reset();
    g_onMove.reset();
    g_onButton.reset();
    g_onTouchUp.reset();
    g_onTip.reset();
    if (g_laterPending)
        g_pEventLoopManager->removeDoLater(g_later);
    g_laterPending = false;
    for (auto const& w : g_hooked) {   // our handler must not outlive the plugin
        if (const auto o = w.lock(); o && o->m_resource)
            o->m_resource->setSetActions({});
    }
    g_hooked.clear();
    g_dropSource.reset();
    if (g_watch) {
        g_watch->cancel();
        g_pEventLoopManager->removeTimer(g_watch);
        g_watch.reset();
    }
}

std::string dndFixInfo() {
    char line[200];
    snprintf(line, sizeof(line), "drag and drop fix: %s; target requests answered %d, drops seen %d, drops called off %d\n", on() ? "on" : "off", g_n.answered, g_n.drops,
             g_n.calledOff);
    return line;
}
