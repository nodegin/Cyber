#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
canvaslock: the canvasgreet theme as a real Wayland lock screen.

It runs inside your session (Hyprland, COSMIC, ...) and locks it with the
ext-session-lock protocol (via gtk4-layer-shell): while locked, the compositor
shows nothing but this program's windows and gives input to nothing else, and if
this program crashes the session stays locked. The theme is the same web page as
the login screen (served at greeter://theme/), shown with WebKitGTK. Your
password goes from the page to PAM in this process and is never logged or stored.

  canvaslock              lock now (if already locked, does nothing)
  canvaslock --demo       preview in a normal window: nothing is locked, password "demo"
  canvaslock --test N     really lock, but unlock by itself after N seconds (safe testing)
  canvaslock --daemon     COSMIC: wait for lock requests (runs in place of COSMIC's locker)

Layers that keep you from getting stuck:
  - Ctrl/Alt that Hyprland wrongly thinks are held (after Ctrl+Alt+F1) are ignored, so
    typing your password still works.
  - A theme that doesn't start within 12 s is replaced by a plain built-in password box.
  - If the lock program crashes it is restarted; if it keeps crashing, hyprlock takes over.
  - If it can't lock at all it exits 1 (`canvaslock || hyprlock`), and on COSMIC the real
    COSMIC locker is used.

Several desktops in one session (e.g. two Hyprland shells): if ~/.config/canvasgreet/lock-choices
is executable, the lock screen lists what `lock-choices list` returns, and after unlocking runs
`lock-choices apply <id>` for the one picked (see CHOICES_HOOK).

Emergency: Ctrl+Alt+Shift+F swaps the theme for a plain built-in password box.
If the lock program ever dies, Hyprland keeps the screen locked: switch to a text
console (Ctrl+Alt+F3), log in, and run  WAYLAND_DISPLAY=wayland-1 canvaslock
"""

import argparse
import ctypes
import ctypes.util
import json
import mimetypes
import os
import pwd
import queue
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse

LIB_DIR = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, LIB_DIR)
import canvasgreet as cg  # noqa: E402  (config, themes, shared backend helpers)

PAM_SERVICE = "canvaslock" if os.path.exists("/etc/pam.d/canvaslock") else "login"
EXIT_NO_LOCK = 3  # the lock screen could not be put up at all (callers fall back)
DEMO_PASSWORD = "demo"
APP_ID = "dev.canvasgreet.Lock"
# Optional: an executable of yours that offers desktops to pick on the lock screen (e.g. two
# shells inside one Hyprland session). `<hook> list` prints JSON
# [{"id", "name", "comment", "current": bool}, ...] ([] = just show the locked session);
# `<hook> apply <id>` is run after unlocking when another one was picked.
CHOICES_HOOK = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                            "canvasgreet", "lock-choices")
# No network and no file:// for the theme: everything must come from greeter://.
CSP = ("default-src greeter: data: blob:; script-src greeter: 'unsafe-inline' 'unsafe-eval'; "
       "style-src greeter: 'unsafe-inline'; img-src greeter: data: blob:; media-src greeter: data: blob:; "
       "font-src greeter: data:; connect-src greeter: data: blob:")


def log(*parts):
    print("[canvaslock]", *parts, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# PAM (libpam through ctypes)
# --------------------------------------------------------------------------

class _PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class _PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_void_p), ("resp_retcode", ctypes.c_int)]


_PAM_CONV_FUNC = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.POINTER(_PamMessage)),
                                  ctypes.POINTER(ctypes.POINTER(_PamResponse)), ctypes.c_void_p)


class _PamConv(ctypes.Structure):
    _fields_ = [("conv", _PAM_CONV_FUNC), ("appdata_ptr", ctypes.c_void_p)]


PAM_SUCCESS, PAM_AUTH_ERR, PAM_CONV_ERR = 0, 7, 19
PAM_PROMPT_ECHO_OFF, PAM_PROMPT_ECHO_ON, PAM_ERROR_MSG, PAM_TEXT_INFO = 1, 2, 3, 4
_CANCEL = object()


def pam_authenticate(user, password, on_message, ask):
    """Checks the password with PAM. on_message(kind, text) for info/errors; ask(kind, text)
    for any extra question (OTP, ...), returning the answer or _CANCEL. Returns (ok, message)."""
    libpam = ctypes.CDLL(ctypes.util.find_library("pam") or "libpam.so.0")
    libc = ctypes.CDLL(ctypes.util.find_library("c"))
    libc.calloc.restype, libc.calloc.argtypes = ctypes.c_void_p, [ctypes.c_size_t, ctypes.c_size_t]
    libc.strdup.restype, libc.strdup.argtypes = ctypes.c_void_p, [ctypes.c_char_p]
    libpam.pam_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(_PamConv),
                                 ctypes.POINTER(ctypes.c_void_p)]
    libpam.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
    libpam.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
    libpam.pam_strerror.argtypes, libpam.pam_strerror.restype = [ctypes.c_void_p, ctypes.c_int], ctypes.c_char_p

    used_password = [False]

    def conv(count, messages, responses, _appdata):
        replies = ctypes.cast(libc.calloc(count, ctypes.sizeof(_PamResponse)), ctypes.POINTER(_PamResponse))
        if not replies:
            return PAM_CONV_ERR
        for i in range(count):
            m = messages[i].contents
            style, text = m.msg_style, (m.msg or b"").decode("utf-8", "replace")
            if style == PAM_PROMPT_ECHO_OFF and not used_password[0]:
                answer, used_password[0] = password, True
            elif style in (PAM_ERROR_MSG, PAM_TEXT_INFO):
                on_message("error" if style == PAM_ERROR_MSG else "info", text)
                answer = None
            else:
                answer = ask("secret" if style == PAM_PROMPT_ECHO_OFF else "visible", text)
                if answer is _CANCEL:
                    return PAM_CONV_ERR
            if answer is not None:
                replies[i].resp = libc.strdup(answer.encode())
        responses[0] = replies
        return PAM_SUCCESS

    callback = _PAM_CONV_FUNC(conv)
    conversation = _PamConv(callback, None)
    handle = ctypes.c_void_p()
    rc = libpam.pam_start(PAM_SERVICE.encode(), user.encode(), ctypes.byref(conversation), ctypes.byref(handle))
    if rc != PAM_SUCCESS:
        return False, f"PAM start failed ({rc})"
    rc = libpam.pam_authenticate(handle, 0)
    message = (libpam.pam_strerror(handle, rc) or b"").decode()
    libpam.pam_end(handle, rc)
    return rc == PAM_SUCCESS, ("Incorrect password" if rc == PAM_AUTH_ERR else message)


# --------------------------------------------------------------------------
# What the page can ask for (same API as the login screen, see bridge.js)
# --------------------------------------------------------------------------

class LockBackend:
    def __init__(self, cfg, theme_name, theme_root, demo, emit_event, on_unlocked):
        self.cfg = cfg
        self.demo = demo
        self.emit_event = emit_event          # emit_event(name, payload), any thread
        self.on_unlocked = on_unlocked        # called on the main thread after a correct password
        self.helper = cg.Backend(cfg, theme_name, theme_root, demo=True, emit_event=emit_event)
        self.user = pwd.getpwuid(os.getuid())
        self.answers = queue.Queue()
        self.busy = threading.Lock()
        # Set when a letter arrives with Ctrl/Alt "held". Hyprland can believe they still are
        # after a Ctrl+Alt+F1 VT switch; the field then drops letters and a mangled password
        # reaches PAM, and three of those lock the account for 10 minutes (faillock).
        self.keyboard_suspect = False
        self._choices = None      # desktops offered by CHOICES_HOOK, loaded when the page asks
        self._choices_lock = threading.Lock()
        self.chosen = None        # the desktop picked when the password was accepted

    def choices(self):
        """Desktops to pick from (CHOICES_HOOK), [] if none. Loaded once, after the screen is
        already locked (never delays locking), with a short timeout."""
        with self._choices_lock:
            if self._choices is None:
                self._choices = self._load_choices()
            return self._choices

    def _load_choices(self):
        if not (os.path.isfile(CHOICES_HOOK) and os.access(CHOICES_HOOK, os.X_OK)):
            return []
        try:
            r = subprocess.run([CHOICES_HOOK, "list"], stdin=subprocess.DEVNULL, capture_output=True,
                               text=True, timeout=2)
            data = json.loads(r.stdout or "[]") if r.returncode == 0 else []
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            log(f"lock-choices hook failed: {e!r}")
            return []
        desktop = os.environ.get("XDG_CURRENT_DESKTOP", "")
        out = []
        for c in data if isinstance(data, list) else []:
            if not (isinstance(c, dict) and isinstance(c.get("id"), str) and c["id"]
                    and isinstance(c.get("name"), str) and c["name"]):
                continue
            current = c.get("current") is True
            out.append({"id": c["id"][:64], "name": c["name"][:64], "comment": str(c.get("comment") or "")[:120],
                        "type": "wayland", "desktopNames": desktop, "last": current, "verbatim": True})
        return out

    def apply_choice(self):
        """After unlocking: switch to the desktop picked on the lock screen, if it isn't the one
        running. Detached, so the lock can exit right away; problems are only logged."""
        chosen = self.chosen
        if self.demo or not chosen:
            return
        current = next((c["id"] for c in self.choices() if c["last"]), None)
        if chosen == current:
            return
        try:
            subprocess.Popen([CHOICES_HOOK, "apply", chosen], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            log(f"switching desktop: {current} -> {chosen}")
        except OSError as e:
            log(f"could not switch desktop: {e!r}")

    def _session(self):
        sid = os.environ.get("XDG_SESSION_DESKTOP", "") or os.environ.get("XDG_CURRENT_DESKTOP", "session").lower()
        desktop = os.environ.get("XDG_CURRENT_DESKTOP", sid)
        for s in self.helper._sessions:
            if s["id"] == sid or (desktop and desktop in s["desktopNames"].split(":")):
                return {"id": s["id"], "name": s["name"], "comment": s["comment"] or "Locked session",
                        "type": "wayland", "desktopNames": s["desktopNames"], "last": True}
        return {"id": sid, "name": desktop or sid, "comment": "Locked session", "type": "wayland",
                "desktopNames": desktop, "last": True}

    def info(self):
        base = self.helper.info()
        current = next((c["id"] for c in self.choices() if c["last"]), None)
        base.update(mode="lock", demo=self.demo, allowNetwork=False,
                    preferredUser=self.user.pw_name, preferredSession=current or self._session()["id"])
        return base

    def users(self):
        name = self.user.pw_name
        return [{"name": name, "realName": self.user.pw_gecos.split(",")[0] or name,
                 "avatar": self.helper._avatar(name), "last": True}]

    def sessions(self):
        return self.choices() or [self._session()]

    def login(self, _username, password, session):
        if not self.busy.acquire(blocking=False):
            return {"ok": False, "type": "busy", "error": "Already checking"}
        try:
            while not self.answers.empty():
                self.answers.get_nowait()
            if self.keyboard_suspect:
                self.keyboard_suspect = False
                log("attempt not checked: Ctrl/Alt looked stuck while typing (does not count as a failure)")
                return {"ok": False, "type": "keyboard",
                        "error": "Ctrl/Alt looked stuck while you typed: tap Ctrl and Alt once, then type your password again"}
            if self.demo:
                time.sleep(0.5)
                ok, message = password == DEMO_PASSWORD, f'Incorrect password (demo: the password is "{DEMO_PASSWORD}")'
            else:
                def ask(kind, text):
                    self.emit_event("prompt", {"type": kind, "message": text})
                    try:
                        return self.answers.get(timeout=300)
                    except queue.Empty:
                        return _CANCEL
                ok, message = pam_authenticate(self.user.pw_name, password,
                                               lambda kind, text: self.emit_event("message", {"type": kind, "message": text}),
                                               ask)
            log("password accepted" if ok else f"password rejected: {message}")  # never the password itself
            if ok:
                self.chosen = session if any(c["id"] == session for c in self.choices()) else None
                return {"ok": True, "demo": self.demo}
            return {"ok": False, "type": "auth_error" if message == "Incorrect password" else "error", "error": message}
        finally:
            self.busy.release()

    def respond(self, text):
        self.answers.put(text)
        return True

    def cancel(self):
        self.answers.put(_CANCEL)
        return True

    def power_capabilities(self):
        # Only sleep from a lock screen: someone at your desk must not be able to end your session.
        return {"suspend": self.helper.power_capabilities().get("suspend", False),
                "poweroff": False, "reboot": False, "hibernate": False}

    def power(self, action):
        if action != "suspend":
            return {"ok": False, "error": "Only sleep is available on the lock screen"}
        if self.demo:
            return {"ok": True, "demo": True}
        r = subprocess.run(["systemctl", "--no-ask-password", "suspend"], stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=60)
        return {"ok": True} if r.returncode == 0 else {"ok": False, "error": (r.stderr or "suspend failed").strip()}

    def dispatch(self, method, a):
        if method == "info":
            return self.info()
        if method == "users":
            return self.users()
        if method == "sessions":
            return self.sessions()
        if method == "login":
            return self.login(str(a.get("username", "")), str(a.get("password", "")), str(a.get("session", "")))
        if method == "respond":
            return self.respond(None if a.get("text") is None else str(a.get("text")))
        if method == "cancel":
            return self.cancel()
        if method == "power":
            return self.power(str(a.get("action", "")))
        if method == "powerCapabilities":
            return self.power_capabilities()
        if method == "themeFiles":
            return self.helper.theme_files(str(a.get("dir", "")))
        if method == "system":
            return self.helper.system()
        if method == "log":
            log("theme:", str(a.get("message", ""))[:2000])
            return True
        raise ValueError(f"unknown method {method!r}")


# --------------------------------------------------------------------------
# GTK / WebKit front end
# --------------------------------------------------------------------------

def run(args, cfg, theme_name, theme_root):
    if not args.demo:
        try:  # must be loaded before GTK pulls in libwayland-client
            ctypes.CDLL("libgtk4-layer-shell.so")
        except OSError:
            log("gtk4-layer-shell is not installed: sudo pacman -S gtk4-layer-shell")
            return 3
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    gi.require_version("WebKit", "6.0")
    gi.require_version("Soup", "3.0")
    if not args.demo:
        gi.require_version("Gtk4SessionLock", "1.0")
    from gi.repository import Gdk, Gio, GLib, Gtk, Soup, WebKit
    SessionLock = None
    if not args.demo:
        from gi.repository import Gtk4SessionLock as SessionLock

    with open(os.path.join(LIB_DIR, "bridge.js"), encoding="utf-8") as f:
        bridge_source = f.read()
    roots = {"theme": theme_root, "fallback": os.path.join(LIB_DIR, "fallback")}

    app = Gtk.Application(application_id=APP_ID + (".Demo" if args.demo else ""))
    state = {"lock": None, "views": [], "unlocking": False, "started": False,
             "failed": False, "entries": {}, "ready": set()}

    def add_css():
        css = Gtk.CssProvider()
        css.load_from_string(
            "window.canvaslock { background: #05040a; }"
            ".cl-fallback { color: #e8ebf3; font-family: monospace; font-size: 15px; }"
            ".cl-fallback entry { min-width: 320px; padding: 10px; }"
            ".cl-error { color: #ff6e8e; }")
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def emit_event(name, payload):  # any thread
        script = f"window.__canvasgreet && __canvasgreet.event({json.dumps(name)}, {json.dumps(json.dumps(payload))})"

        def send():
            for v in list(state["views"]):
                run_js(v, script)
            return False
        GLib.idle_add(send)

    def unlock_soon():
        if state["unlocking"]:
            return
        state["unlocking"] = True
        delay = int(cfg["exit_delay_ms"])
        if args.demo:
            GLib.timeout_add(delay + 1200, lambda: state.__setitem__("unlocking", False) or False)
            return
        GLib.timeout_add(delay, lambda: state["lock"].unlock() or False)

    backend = LockBackend(cfg, theme_name, theme_root, args.demo, emit_event, unlock_soon)

    # ---- greeter://theme/ ----
    context = WebKit.WebContext.get_default()
    security = context.get_security_manager()
    security.register_uri_scheme_as_secure("greeter")
    security.register_uri_scheme_as_cors_enabled("greeter")

    def serve(request):
        parts = urllib.parse.urlsplit(request.get_uri())
        root = roots.get(parts.hostname or "")
        error = None
        if root:
            root = os.path.realpath(root)
            rel = urllib.parse.unquote(parts.path).lstrip("/") or "index.html"
            path = os.path.realpath(os.path.join(root, rel))
            if os.path.isdir(path):
                path = os.path.join(path, "index.html")
            if os.path.commonpath([root, path]) == root and os.path.isfile(path):
                try:
                    with open(path, "rb") as f:
                        data = f.read()
                    stream = Gio.MemoryInputStream.new_from_bytes(GLib.Bytes.new(data))
                    response = WebKit.URISchemeResponse.new(stream, len(data))
                    response.set_content_type(mimetypes.guess_type(path)[0] or "application/octet-stream")
                    headers = Soup.MessageHeaders.new(Soup.MessageHeadersType.RESPONSE)
                    headers.append("Content-Security-Policy", CSP)
                    response.set_http_headers(headers)
                    request.finish_with_response(response)
                    return
                except OSError as e:
                    error = str(e)
        request.finish_error(GLib.Error.new_literal(GLib.quark_from_string("canvaslock"), error or "not found", 404))

    context.register_uri_scheme("greeter", serve)

    def run_js(view, script):
        try:
            view.evaluate_javascript(script, -1, None, None, None, None, None)
        except TypeError:
            view.evaluate_javascript(script, -1, None, None, None, None)

    # ---- one themed view per window ----
    def make_view(window):
        ucm = WebKit.UserContentManager()
        ucm.add_script(WebKit.UserScript.new(bridge_source, WebKit.UserContentInjectedFrames.TOP_FRAME,
                                             WebKit.UserScriptInjectionTime.START, None, None))
        ucm.register_script_message_handler("canvasgreet", None)
        view = WebKit.WebView(user_content_manager=ucm)
        s = view.get_settings()
        s.set_enable_webgl(True)
        s.set_hardware_acceleration_policy(WebKit.HardwareAccelerationPolicy.ALWAYS)
        s.set_media_playback_requires_user_gesture(False)
        s.set_enable_developer_extras(bool(args.demo))
        s.set_enable_write_console_messages_to_stdout(True)
        s.set_javascript_can_open_windows_automatically(False)
        s.set_enable_back_forward_navigation_gestures(False)
        view.set_background_color(Gdk.RGBA(0.02, 0.016, 0.04, 1))

        def on_message(_ucm, value):
            try:
                msg = json.loads(value.to_string())
                req_id, method = str(msg["id"]), str(msg["method"])
                margs = json.loads(msg.get("args") or "{}")
            except (ValueError, KeyError, TypeError):
                return
            state["ready"].add(view)  # the page is alive and talking to us

            def reply(payload):
                script = f"window.__canvasgreet && __canvasgreet.reply({json.dumps(req_id)}, {json.dumps(json.dumps(payload))})"
                GLib.idle_add(lambda: run_js(view, script) or False)

            def work():
                try:
                    result = backend.dispatch(method, margs)
                    payload = {"result": result}
                    if method == "login" and isinstance(result, dict) and result.get("ok"):
                        GLib.idle_add(lambda: unlock_soon() or False)
                except Exception as e:  # report to the page instead of crashing the lock
                    log(f"{method} failed: {e!r}")
                    payload = {"error": str(e)}
                reply(payload)

            if method in ("login", "power"):
                threading.Thread(target=work, daemon=True).start()
            else:
                work()

        ucm.connect("script-message-received::canvasgreet", on_message)
        view.connect("context-menu", lambda *a: True)

        def on_policy(_view, decision, kind):
            if kind in (WebKit.PolicyDecisionType.NAVIGATION_ACTION, WebKit.PolicyDecisionType.NEW_WINDOW_ACTION):
                uri = decision.get_navigation_action().get_request().get_uri()
                if not uri.startswith("greeter://") or kind == WebKit.PolicyDecisionType.NEW_WINDOW_ACTION:
                    decision.ignore()
                    return True
            return False

        view.connect("decide-policy", on_policy)

        def on_load_failed(_view, _event, uri, error):
            log(f"load failed: {uri}: {error.message}")
            if uri.startswith("greeter://theme/"):  # the theme itself, not a blocked navigation
                fallback(window, "theme failed to load")
            return True

        view.connect("load-failed", on_load_failed)
        view.connect("web-process-terminated", lambda _v, reason: fallback(window, f"web process ended ({reason.value_nick})"))
        state["views"].append(view)
        return view

    # ---- plain native password box (emergency / if the theme breaks) ----
    def fallback(window, reason):
        log(f"switching to the built-in password box: {reason}")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        box.add_css_class("cl-fallback")
        box.append(Gtk.Label(label=f"SESSION LOCKED  //  {backend.user.pw_name}"))
        entry = Gtk.PasswordEntry(show_peek_icon=False)
        status = Gtk.Label(label="Enter your password")
        box.append(entry)
        box.append(status)

        def submit(_entry):
            password = entry.get_text()
            entry.set_text("")
            entry.set_sensitive(False)
            status.set_text("Checking…")

            def work():
                r = backend.login(backend.user.pw_name, password, "")
                def done():
                    entry.set_sensitive(True)
                    entry.grab_focus()
                    if r.get("ok"):
                        status.set_text("Unlocked")
                        unlock_soon()
                    else:
                        status.set_text(r.get("error", "Failed"))
                        status.add_css_class("cl-error")
                    return False
                GLib.idle_add(done)
            threading.Thread(target=work, daemon=True).start()

        entry.connect("activate", submit)
        state["entries"][window] = entry
        old = window.get_child()
        if old in state["views"]:
            state["views"].remove(old)
        window.set_child(box)
        window.set_focus(entry)

    def make_window(window, monitor=None):
        window.add_css_class("canvaslock")
        view = make_view(window)
        window.set_child(view)
        scale = 1.0
        if monitor is not None:
            scale = monitor.get_scale() if hasattr(monitor, "get_scale") else monitor.get_scale_factor()
        view.set_zoom_level(float(cfg["zoom"]) / max(scale, 0.5))
        shortcut = Gtk.ShortcutController()
        shortcut.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        shortcut.add_shortcut(Gtk.Shortcut.new(Gtk.ShortcutTrigger.parse_string("<Control><Alt><Shift>f"),
                                               Gtk.CallbackAction.new(lambda *a: fallback(window, "emergency hotkey") or True)))
        if args.demo:
            shortcut.add_shortcut(Gtk.Shortcut.new(Gtk.ShortcutTrigger.parse_string("<Control>q"),
                                                   Gtk.CallbackAction.new(lambda *a: app.quit() or True)))
        window.add_controller(shortcut)

        # Keyboard focus: when the window becomes active again (e.g. after switching back from a
        # text console), make sure the page has the keyboard. --debug logs that keys arrive
        # (never which ones) and focus changes.
        def on_active(w, _pspec):
            if args.debug:
                log(f"window active={w.is_active()}")
            if w.is_active() and isinstance(w.get_child(), WebKit.WebView):
                w.set_focus(w.get_child())

        window.connect("notify::is-active", on_active)

        # Phantom Ctrl/Alt fix. After Ctrl+Alt+F1 Hyprland can believe Ctrl/Alt are still held, so
        # every letter arrives as Ctrl+letter and password fields drop it. A lock screen has no use
        # for Ctrl/Alt shortcuts, so such keys are delivered as plain keys instead. (Side effect:
        # Ctrl+V etc. don't work here.) Never logs which key.
        M = Gdk.ModifierType

        def on_key(_ctrl, keyval, _code, mods):
            uni = Gdk.keyval_to_unicode(keyval)
            ctrl, alt = bool(mods & M.CONTROL_MASK), bool(mods & M.ALT_MASK)
            if args.debug:
                log(f"key: printable={uni >= 0x20} ctrl={ctrl} alt={alt} shift={bool(mods & M.SHIFT_MASK)} "
                    f"super={bool(mods & M.SUPER_MASK)}")
            emergency = keyval in (Gdk.KEY_f, Gdk.KEY_F) and ctrl and alt and bool(mods & M.SHIFT_MASK)
            if emergency or not (ctrl or alt):
                return False
            child, entry = window.get_child(), state["entries"].get(window)
            is_view = isinstance(child, WebKit.WebView)
            enter = keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter)
            if uni >= 0x20:
                if is_view:
                    run_js(child, f"document.execCommand('insertText', false, {json.dumps(chr(uni))})")
                    return True
                if entry is not None:
                    entry.set_text(entry.get_text() + chr(uni))
                    entry.set_position(-1)
                    return True
                backend.keyboard_suspect = True  # couldn't repair it: don't let a mangled password reach PAM
            elif enter and is_view:
                run_js(child, "(e => e && e.form && e.form.requestSubmit())(document.activeElement)")
                return True
            elif enter and entry is not None:
                entry.emit("activate")
                return True
            elif keyval == Gdk.KEY_BackSpace and is_view:
                run_js(child, "document.execCommand('delete')")
                return True
            elif keyval == Gdk.KEY_BackSpace and entry is not None:
                entry.set_text(entry.get_text()[:-1])
                entry.set_position(-1)
                return True
            return False

        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", on_key)
        window.add_controller(keys)
        view.load_uri("greeter://theme/index.html")
        window.set_focus(view)

        # Watchdog: a theme that never starts (script error, renderer trouble) gets replaced by
        # the built-in password box, so there is always a way to type the password.
        def check_started():
            if view not in state["ready"] and window.get_child() is view:
                fallback(window, "the theme did not start within 12 s")
            return False

        GLib.timeout_add_seconds(12, check_started)
        return view

    def on_activate(_app):
        if state["started"]:
            return  # a second `canvaslock` while already locked: nothing to do
        state["started"] = True
        add_css()
        if args.demo:
            window = Gtk.ApplicationWindow(application=app, title="canvaslock preview")
            w, h = (int(x) for x in args.size.lower().split("x"))
            window.set_default_size(w, h)
            make_window(window)
            window.present()
            if args.fullscreen:  # after present(): some compositors ignore it on an unmapped window
                window.fullscreen()
            return
        if not SessionLock.is_supported():
            log("this compositor does not support ext-session-lock-v1")
            state["failed"] = True
            app.quit()
            return
        lock = state["lock"] = SessionLock.Instance.new()
        lock.connect("locked", lambda _l: log("locked"))

        def on_failed(_l):
            log("could not lock (is another lock screen active?)")
            state["failed"] = True
            app.quit()

        lock.connect("failed", on_failed)
        lock.connect("unlocked", lambda _l: (log("unlocked"), backend.apply_choice(), app.quit()))
        lock.connect("monitor", lambda _l, monitor: lock.assign_window_to_monitor(
            _window_for(monitor), monitor))
        lock.lock()
        if args.test:
            log(f"test mode: unlocking by itself in {args.test} s")
            GLib.timeout_add_seconds(args.test, lambda: lock.unlock() or False)

    def _window_for(monitor):
        window = Gtk.Window(application=app)
        make_window(window, monitor)
        return window

    app.connect("activate", on_activate)
    status = app.run([sys.argv[0]])
    if args.demo:
        return status
    # 0 = unlocked (or a lock was already up), EXIT_NO_LOCK = could not lock at all
    return EXIT_NO_LOCK if state["failed"] else 0


def child_command(args, child=True):
    cmd = [sys.executable, "-I", os.path.realpath(__file__), "--config", args.config]
    if child:
        cmd.append("--child")
    if args.theme:
        cmd += ["--theme", args.theme]
    if args.test:
        cmd += ["--test", str(args.test)]
    if args.debug:
        cmd.append("--debug")
    return cmd


def supervise(args):
    """`canvaslock` itself: runs the actual lock screen as a child process and keeps one running
    until the session is unlocked. A crash (the session stays locked) restarts it; if it keeps
    crashing, hyprlock takes over. Returns 1 if no lock could be put up at all, so callers can
    fall back (`canvaslock || hyprlock`)."""
    crashes = []
    while True:
        rc = subprocess.call(child_command(args))
        if rc == 0:
            return 0
        if rc in (2, EXIT_NO_LOCK):
            return 1
        now = time.monotonic()
        crashes = [t for t in crashes if now - t < 60] + [now]
        if len(crashes) > 3:
            if shutil.which("hyprlock"):
                log("the lock keeps crashing: handing over to hyprlock")
                return subprocess.call(["hyprlock"])
            log("the lock keeps crashing and hyprlock is not installed")
            return 1
        log(f"the lock screen exited unexpectedly ({rc}); restarting it ({len(crashes)}/3)")
        time.sleep(0.5)


def run_daemon(args):
    """COSMIC: stands in for COSMIC's in-session locker. cosmic-session starts `cosmic-greeter`
    by name and finds ~/.local/bin/cosmic-greeter first, which runs this. Locks on logind's Lock
    signal (Super+Escape, the panel, `loginctl lock-session`) and before sleep. If anything here
    fails, it hands over to COSMIC's real locker, so the session is never left without one."""
    real = "/usr/bin/cosmic-greeter"

    def hand_over(why):
        log(f"daemon: {why}; starting COSMIC's own locker instead")
        if os.path.exists(real):
            os.execv(real, [real])
        return 1

    try:
        from gi.repository import Gio, GLib
        bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        login1 = ("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager")

        def call(method, params, rtype):
            return bus.call_sync(*login1, method, params, GLib.VariantType(rtype),
                                 Gio.DBusCallFlags.NONE, -1, None).unpack()

        sid = os.environ.get("XDG_SESSION_ID")
        session = (call("GetSession", GLib.Variant("(s)", (sid,)), "(o)") if sid else
                   call("GetSessionByPID", GLib.Variant("(u)", (os.getpid(),)), "(o)"))[0]
    except Exception as e:
        return hand_over(f"cannot reach logind ({e})")

    state = {"proc": None, "inhibit": None, "buf": b""}

    def take_inhibitor():  # holds sleep back until we've locked
        if state["inhibit"] is not None:
            return
        try:
            res, fds = bus.call_with_unix_fd_list_sync(
                *login1, "Inhibit", GLib.Variant("(ssss)", ("sleep", "canvaslock", "Lock the screen before sleep", "delay")),
                GLib.VariantType("(h)"), Gio.DBusCallFlags.NONE, -1, None, None)
            state["inhibit"] = fds.get(res.unpack()[0])
        except Exception as e:
            log(f"daemon: no sleep inhibitor ({e})")

    def release_inhibitor():
        fd, state["inhibit"] = state["inhibit"], None
        if fd is not None:
            os.close(fd)

    def locked_now():
        p = state["proc"]
        return p is not None and p.poll() is None

    def lock(reason):
        if locked_now():
            return
        log(f"daemon: locking ({reason})")
        p = state["proc"] = subprocess.Popen(child_command(args, child=False), stderr=subprocess.PIPE)

        def on_output(fd, _cond):
            data = os.read(fd, 4096)
            if not data:  # the lock (supervisor) ended
                rc = p.wait()
                if rc != 0 and shutil.which("hyprlock"):
                    log("daemon: canvaslock could not lock; using hyprlock")
                    subprocess.Popen(["hyprlock"])
                take_inhibitor()
                return False
            sys.stderr.buffer.write(data)
            sys.stderr.flush()
            if b"[canvaslock] locked" in data:
                release_inhibitor()  # matters before sleep: now it may go ahead
            return True

        GLib.io_add_watch(p.stderr.fileno(), GLib.PRIORITY_DEFAULT, GLib.IOCondition.IN | GLib.IOCondition.HUP, on_output)

    def on_sleep(_conn, _sender, _path, _iface, _signal, params):
        if params.unpack()[0]:  # about to sleep
            if locked_now():
                release_inhibitor()
            else:
                lock("before sleep")
                GLib.timeout_add_seconds(5, lambda: release_inhibitor() or False)  # never block sleep forever
        else:  # woke up
            take_inhibitor()

    bus.signal_subscribe("org.freedesktop.login1", "org.freedesktop.login1.Session", "Lock", session, None,
                         Gio.DBusSignalFlags.NONE, lambda *_a: lock("lock request"))
    bus.signal_subscribe("org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep",
                         "/org/freedesktop/login1", None, Gio.DBusSignalFlags.NONE, on_sleep)
    take_inhibitor()
    log(f"daemon: ready, lock requests for {session} -> canvaslock")
    GLib.MainLoop().run()
    return 0


def main():
    ap = argparse.ArgumentParser(prog="canvaslock", description="canvasgreet theme as a Wayland lock screen.")
    ap.add_argument("--config", default=cg.DEFAULT_CONFIG)
    ap.add_argument("--theme", help="theme to use (default: lock_theme, else the login screen's theme)")
    ap.add_argument("--demo", action="store_true", help="preview in a window; nothing is locked (password: demo)")
    ap.add_argument("--test", type=int, metavar="SECONDS", help="lock for real, unlock by itself after SECONDS")
    ap.add_argument("--size", default="1720x720", help="--demo window size")
    ap.add_argument("--fullscreen", action="store_true", help="--demo full screen (Ctrl+Q quits)")
    ap.add_argument("--debug", action="store_true", help="log keyboard focus changes and that keys arrive (not which)")
    ap.add_argument("--daemon", action="store_true",
                    help="COSMIC: wait for lock requests (runs in place of COSMIC's own locker)")
    ap.add_argument("--child", action="store_true", help=argparse.SUPPRESS)  # the supervised lock itself
    args = ap.parse_args()

    if not os.environ.get("WAYLAND_DISPLAY"):
        print("canvaslock runs inside a Wayland session (WAYLAND_DISPLAY is not set).", file=sys.stderr)
        if args.daemon and os.path.exists("/usr/bin/cosmic-greeter"):
            os.execv("/usr/bin/cosmic-greeter", ["/usr/bin/cosmic-greeter"])
        return 2
    if args.daemon:
        try:
            return run_daemon(args)
        except Exception as e:  # never leave COSMIC without a locker
            log(f"daemon failed: {e!r}; starting COSMIC's own locker instead")
            if os.path.exists("/usr/bin/cosmic-greeter"):
                os.execv("/usr/bin/cosmic-greeter", ["/usr/bin/cosmic-greeter"])
            return 1
    if not (args.demo or args.child):
        return supervise(args)
    cfg = cg.load_config(args.config)
    theme_name = args.theme or cfg.get("lock_theme") or cg.selected_theme(cfg)
    theme_root = os.path.join(cfg["themes_dir"], theme_name)
    if not os.path.isfile(os.path.join(theme_root, "index.html")):
        log(f"theme {theme_name!r} not found; using the fallback page")
        theme_name, theme_root = "fallback", os.path.join(LIB_DIR, "fallback")
    log(f"theme {theme_name!r}, PAM service {PAM_SERVICE!r}{' (demo)' if args.demo else ''}")
    return run(args, cfg, theme_name, theme_root)


if __name__ == "__main__":
    sys.exit(main())
