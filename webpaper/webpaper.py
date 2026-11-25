#!/usr/bin/env python3
"""webpaper: a web page as the desktop wallpaper (Wayland layer shell, background layer).

    webpaper.py FOLDER_OR_HTML [--fps 30] [--scale 1.0] [--allow-network] [--window]

Made for Wallpaper Engine "web" wallpapers (a folder with project.json + index.html), but any
local page works. Started by Cyber (cyber/hud/Wallpaper.qml) when cyber/config.json has
wallpaper.web; one process covers every monitor, and a second start replaces the first.

  --fps N          cap the page's animation (requestAnimationFrame) at N frames a second; 0 = no cap
  --scale S        render at S times the screen resolution (0.5 .. 1) and stretch: cheaper
  --allow-network  let the page load things from the internet (off: local files only)
  --window         a normal window instead of the wallpaper layer, to look at a page

A live page costs a lot of GPU (measured for a WebGL rain page at 3440x1440 on a Radeon 610M:
about 40% at 24 fps and half resolution). render-video.sh turns a page into a seamless loop
video instead (it uses --record, below), which mpvpaper plays for a few percent.

  --record FILE    do not show a wallpaper: step the page's clock frame by frame and write what
                   the screen shows to FILE (used by render-video.sh inside a hidden compositor;
                   with --seconds, --overlap, --rec-fps and --grim-output)

The page is served from the folder as wallpaper://local/, never from the internet, and it gets
no mouse or keyboard: clicks on the desktop go through it. It prints "ready" once the page has
loaded. Needs gtk4-layer-shell, webkitgtk-6.0, python-gobject, python-cairo (the lock screen's).
"""
import argparse
import ctypes
import json
import mimetypes
import os
import signal
import sys
import urllib.parse

NAMESPACE = "webpaper"
CSP = ("default-src wallpaper: data: blob: 'unsafe-inline' 'unsafe-eval'; "
       "img-src wallpaper: data: blob:; media-src wallpaper: data: blob:")


def find_page(target):
    """-> (folder, file inside it)"""
    target = os.path.realpath(os.path.expanduser(target))
    if os.path.isfile(target):
        return os.path.dirname(target), os.path.basename(target)
    page = "index.html"
    try:  # Wallpaper Engine names the page in project.json
        with open(os.path.join(target, "project.json"), encoding="utf-8") as f:
            page = json.load(f).get("file") or page
    except (OSError, ValueError):
        pass
    return target, page


def replace_running():
    """One wallpaper at a time: stop an earlier webpaper, remember this one."""
    pidfile = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "cyber-webpaper.pid")
    try:
        old = int(open(pidfile).read().strip())
        with open(f"/proc/{old}/cmdline", "rb") as f:
            if b"webpaper.py" in f.read() and old != os.getpid():
                os.kill(old, signal.SIGTERM)
    except (OSError, ValueError):
        pass
    try:
        with open(pidfile, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser(description="A web page as the desktop wallpaper.")
    ap.add_argument("target")
    ap.add_argument("--fps", type=float, default=30)
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--allow-network", action="store_true")
    ap.add_argument("--window", action="store_true")
    ap.add_argument("--record", metavar="FILE")
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--overlap", type=float, default=2)
    ap.add_argument("--rec-fps", type=float, default=24)
    ap.add_argument("--grim-output", default="")
    args = ap.parse_args()
    if args.record:
        args.fps, args.scale = 0, 1.0

    folder, page = find_page(args.target)
    if not os.path.isfile(os.path.join(folder, page)):
        print(f"webpaper: no page at {os.path.join(folder, page)}", file=sys.stderr)
        return 3
    scale = min(1.0, max(0.25, args.scale))

    if not args.window:
        try:  # must be loaded before GTK pulls in libwayland-client
            ctypes.CDLL("libgtk4-layer-shell.so")
        except OSError:
            print("webpaper: gtk4-layer-shell is not installed", file=sys.stderr)
            return 3
        if not args.record:
            replace_running()
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    gi.require_version("WebKit", "6.0")
    gi.require_version("Soup", "3.0")
    from gi.repository import Gdk, Gio, GLib, Gtk, Soup, WebKit
    LayerShell = None
    if not args.window:
        gi.require_version("Gtk4LayerShell", "1.0")
        from gi.repository import Gtk4LayerShell as LayerShell
    import cairo

    # ---- wallpaper://local/<file> = a file in the folder
    context = WebKit.WebContext.get_default()
    security = context.get_security_manager()
    security.register_uri_scheme_as_secure("wallpaper")
    security.register_uri_scheme_as_cors_enabled("wallpaper")
    root = os.path.realpath(folder)

    def serve(request):
        rel = urllib.parse.unquote(urllib.parse.urlsplit(request.get_uri()).path).lstrip("/") or page
        path = os.path.realpath(os.path.join(root, rel))
        if os.path.commonpath([root, path]) == root and os.path.isfile(path):
            try:
                with open(path, "rb") as f:
                    data = f.read()
                response = WebKit.URISchemeResponse.new(
                    Gio.MemoryInputStream.new_from_bytes(GLib.Bytes.new(data)), len(data))
                response.set_content_type(mimetypes.guess_type(path)[0] or "application/octet-stream")
                if not args.allow_network:
                    headers = Soup.MessageHeaders.new(Soup.MessageHeadersType.RESPONSE)
                    headers.append("Content-Security-Policy", CSP)
                    response.set_http_headers(headers)
                request.finish_with_response(response)
                return
            except OSError:
                pass
        request.finish_error(GLib.Error.new_literal(GLib.quark_from_string("webpaper"), "not found", 404))

    context.register_uri_scheme("wallpaper", serve)

    # ---- runs in the page before its own scripts
    setup = []
    if args.fps > 0:   # every callback of one display frame runs, or none: loops stay in step
        setup.append("""(() => {
  const raf = window.requestAnimationFrame.bind(window), min = 1000 / %g - 3;
  let shown = -1e9;
  window.requestAnimationFrame = cb => raf(function tick(t) {
    if (t === shown || t - shown >= min) { shown = t; cb(t); } else raf(tick);
  });
})();""" % args.fps)
    if scale < 1:      # the page is zoomed in below, so it lays out (and draws) fewer pixels
        setup.append("Object.defineProperty(window, 'devicePixelRatio', { get: () => 1 });")
    setup.append("document.addEventListener('contextmenu', e => e.preventDefault());")
    if args.record:    # the page's clock and timers only move when __webpaperStep(ms) is called
        setup.append("""(() => {
  let now = 0, id = 1;
  const start = Date.now(), rafs = new Map(), timers = new Map();
  window.requestAnimationFrame = cb => { rafs.set(id, cb); return id++; };
  window.cancelAnimationFrame = i => rafs.delete(i);
  Date.now = () => start + Math.round(now);
  performance.now = () => now;
  const add = (cb, ms, repeat, a) => { timers.set(id, { cb, at: now + Math.max(0, ms || 0), every: repeat ? Math.max(1, ms || 0) : 0, a }); return id++; };
  window.setTimeout = (cb, ms, ...a) => add(cb, ms, false, a);
  window.setInterval = (cb, ms, ...a) => add(cb, ms, true, a);
  window.clearTimeout = window.clearInterval = i => timers.delete(i);
  window.__webpaperStep = dt => {
    now += dt;
    for (const [i, t] of [...timers]) {
      if (t.at > now) continue;
      if (t.every) t.at += t.every; else timers.delete(i);
      try { if (typeof t.cb === 'function') t.cb(...t.a); } catch (e) {}
    }
    const run = [...rafs.values()];
    rafs.clear();
    for (const cb of run) { try { cb(now); } catch (e) {} }
    return now;
  };
})();""")

    app = Gtk.Application(application_id="dev.cyber.WebPaper", flags=Gio.ApplicationFlags.NON_UNIQUE)
    views = []
    said_ready = []

    def record(view):
        """Step the page frame by frame and pipe what the screen shows (grim) into ffmpeg."""
        import subprocess
        fps = args.rec_fps
        total, warm = round((args.seconds + args.overlap) * fps), round(5 * fps)   # 5 s for the scene to fill
        grim = ["grim", "-t", "ppm"] + (["-o", args.grim_output] if args.grim_output else []) + ["-"]
        ff = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "image2pipe", "-framerate", f"{fps:g}",
                               "-c:v", "ppm", "-i", "-", "-c:v", "libx264", "-preset", "veryfast", "-qp", "8",
                               "-pix_fmt", "yuv444p", args.record], stdin=subprocess.PIPE)
        state = {"i": -warm}

        def step():
            view.evaluate_javascript(f"window.__webpaperStep({1000 / fps})", -1, None, None, None, None, None)
            if state["i"] < 0:
                state["i"] += 1
                GLib.timeout_add(20, step)
            else:
                GLib.timeout_add(180, grab)      # time for the page to be drawn and shown
            return False

        def grab():
            shot = subprocess.run(grim, capture_output=True)
            if shot.returncode != 0 or not shot.stdout:
                print("webpaper: grim failed:", shot.stderr.decode(errors="replace")[:200], file=sys.stderr)
                ff.stdin.close()
                app.quit()
                return False
            ff.stdin.write(shot.stdout)
            state["i"] += 1
            if state["i"] % 48 == 0:
                print(f"frame {state['i']}/{total}", flush=True)
            if state["i"] >= total:
                ff.stdin.close()
                ff.wait()
                print("recorded", flush=True)
                app.quit()
            else:
                GLib.timeout_add(1, step)
            return False
        step()

    def make_window(monitor):
        window = Gtk.ApplicationWindow(application=app)
        window.set_decorated(False)
        if LayerShell:
            LayerShell.init_for_window(window)
            LayerShell.set_namespace(window, NAMESPACE)
            LayerShell.set_layer(window, LayerShell.Layer.BACKGROUND)
            for edge in (LayerShell.Edge.TOP, LayerShell.Edge.BOTTOM, LayerShell.Edge.LEFT, LayerShell.Edge.RIGHT):
                LayerShell.set_anchor(window, edge, True)
            LayerShell.set_exclusive_zone(window, -1)
            LayerShell.set_keyboard_mode(window, LayerShell.KeyboardMode.NONE)
            if monitor is not None:
                LayerShell.set_monitor(window, monitor)
        else:
            window.set_default_size(1280, 720)

        ucm = WebKit.UserContentManager()
        ucm.add_script(WebKit.UserScript.new("\n".join(setup), WebKit.UserContentInjectedFrames.ALL_FRAMES,
                                             WebKit.UserScriptInjectionTime.START, None, None))
        view = WebKit.WebView(user_content_manager=ucm)
        s = view.get_settings()
        s.set_enable_webgl(True)
        s.set_hardware_acceleration_policy(WebKit.HardwareAccelerationPolicy.ALWAYS)
        s.set_media_playback_requires_user_gesture(False)
        s.set_javascript_can_open_windows_automatically(False)
        s.set_enable_back_forward_navigation_gestures(False)
        s.set_enable_write_console_messages_to_stdout(False)
        view.set_background_color(Gdk.RGBA(0, 0, 0, 1))
        view.set_zoom_level(1 / scale)
        view.connect("context-menu", lambda *a: True)

        def policy(_view, decision, kind):   # the page stays the page: no navigating away
            if kind in (WebKit.PolicyDecisionType.NAVIGATION_ACTION, WebKit.PolicyDecisionType.NEW_WINDOW_ACTION):
                uri = decision.get_navigation_action().get_request().get_uri() or ""
                if not uri.startswith("wallpaper:") and not (args.allow_network and uri.startswith("about:")):
                    decision.ignore()
                    return True
            return False
        view.connect("decide-policy", policy)

        def loaded(_view, event):
            if event == WebKit.LoadEvent.FINISHED and not said_ready:
                said_ready.append(True)
                if args.record:
                    GLib.timeout_add(2500, lambda: record(view) or False)   # let the images arrive
                else:
                    GLib.timeout_add(700, lambda: print("ready", flush=True) or False)
        view.connect("load-changed", loaded)

        window.set_child(view)
        state = {"size": None}

        def on_map(_w):
            if LayerShell:   # clicks on the desktop go through the wallpaper
                surface = window.get_surface()
                if surface is not None:
                    surface.set_input_region(cairo.Region())

            def load_when_sized():
                size = (view.get_width(), view.get_height())
                if size[0] < 2 or size[1] < 2:
                    return True                     # not laid out yet: ask again
                if size != state["size"]:           # first size, or the monitor's mode changed
                    state["size"] = size
                    view.load_uri("wallpaper://local/" + urllib.parse.quote(page))
                return True
            GLib.timeout_add(400, load_when_sized)
        window.connect("map", on_map)
        window.present()
        views.append(view)

    def activate(_app):
        monitors = Gdk.Display.get_default().get_monitors()
        if args.window or monitors.get_n_items() == 0:
            make_window(None)
        else:
            for i in range(monitors.get_n_items()):
                make_window(monitors.get_item(i))

    app.connect("activate", activate)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, lambda: app.quit() or False)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, lambda: app.quit() or False)
    return app.run([])


if __name__ == "__main__":
    sys.exit(main())
