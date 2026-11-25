#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
canvasgreet: a greetd greeter whose UI is an ordinary web page.

greetd starts it (inside the `cage` kiosk compositor) as the unprivileged
`greeter` user. The selected theme folder is served at greeter://theme/ and
the page gets a small JavaScript API (see bridge.js) for users, sessions,
login and power actions.

Everything that touches your password is in this file: the page hands it to
the bridge, which passes it straight to greetd over $GREETD_SOCK. It is never
logged or stored.

  canvasgreet                    run as the real greeter (needs $GREETD_SOCK)
  canvasgreet --demo             preview a theme in a window: fake login
                                 (password "demo"), F5 reload, F12 devtools,
                                 auto-reload when theme files change, Ctrl+Q quit
                                 (add --fullscreen to see it as the login screen)
  canvasgreet --list             list installed themes
  canvasgreet --use NAME         choose the theme shown at the login screen
  canvasgreet --screenshot FILE  render the theme to a PNG and exit
"""

import argparse
import base64
import configparser
import json
import mimetypes
import os
import pwd
import queue
import re
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import tomllib

VERSION = "0.1.0"
LIB_DIR = os.path.dirname(os.path.realpath(__file__))
DEFAULT_CONFIG = "/etc/canvasgreet/config.toml"
SELECTED_FILE = ".selected"  # inside themes_dir, written by --use
THEME_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
DEMO_PASSWORD = "demo"

DEFAULTS = {
    "theme": "music",
    "lock_theme": "",  # canvaslock's theme; empty = same as the login screen
    "themes_dir": "/usr/local/share/canvasgreet/themes",
    "avatars_dir": "/usr/local/share/canvasgreet/avatars",
    "state_dir": "/var/cache/canvasgreet",
    "session_dirs": ["/usr/share/wayland-sessions"],
    "hide_sessions": ["hyprland-uwsm"],
    "default_session": "",
    "login_shell": True,
    "allow_network": False,
    "zoom": 1.0,
    "exit_delay_ms": 500,
    "chromium_flags": "--ignore-gpu-blocklist --enable-gpu-rasterization",
    "min_uid": 1000,
    "max_uid": 60000,
    "theme_options": {},
}

for ext, mime in {
    ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css",
    ".json": "application/json", ".wasm": "application/wasm", ".svg": "image/svg+xml",
    ".webp": "image/webp", ".avif": "image/avif", ".woff": "font/woff",
    ".woff2": "font/woff2", ".ttf": "font/ttf", ".otf": "font/otf",
    ".mp3": "audio/mpeg", ".ogg": "audio/ogg", ".oga": "audio/ogg",
    ".opus": "audio/ogg", ".flac": "audio/flac", ".wav": "audio/wav",
    ".m4a": "audio/mp4", ".aac": "audio/aac", ".webm": "video/webm",
    ".mp4": "video/mp4",
}.items():
    mimetypes.add_type(mime, ext)


def log(*parts):
    print("[canvasgreet]", *parts, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

def load_config(path):
    cfg = json.loads(json.dumps(DEFAULTS))  # deep copy
    if path and os.path.isfile(path):
        with open(path, "rb") as f:
            data = tomllib.load(f)
        for key, value in data.items():
            if key not in DEFAULTS:
                log(f"config: ignoring unknown key {key!r}")
                continue
            cfg[key] = value
    elif os.path.isdir(os.path.join(LIB_DIR, "themes")):
        # Running from a source checkout without an installed config.
        cfg["themes_dir"] = os.path.join(LIB_DIR, "themes")
        cfg["avatars_dir"] = os.path.join(LIB_DIR, "avatars")
    return cfg


def list_themes(cfg):
    root = cfg["themes_dir"]
    if not os.path.isdir(root):
        return []
    return sorted(
        name for name in os.listdir(root)
        if THEME_NAME_RE.match(name) and os.path.isfile(os.path.join(root, name, "index.html"))
    )


def selected_theme(cfg):
    try:
        with open(os.path.join(cfg["themes_dir"], SELECTED_FILE)) as f:
            name = f.read().strip()
        if THEME_NAME_RE.match(name):
            return name
    except OSError:
        pass
    return cfg["theme"]


# --------------------------------------------------------------------------
# greetd IPC  (https://man.sr.ht/~kennylevinsen/greetd/  -> greetd-ipc(7))
# Each message is a native-endian u32 length followed by that many bytes of JSON.
# --------------------------------------------------------------------------

class Greetd:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)

    def request(self, obj):
        data = json.dumps(obj).encode()
        self.sock.sendall(struct.pack("=I", len(data)) + data)
        (length,) = struct.unpack("=I", self._recv(4))
        return json.loads(self._recv(length))

    def _recv(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("greetd closed the connection")
            buf += chunk
        return buf

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# --------------------------------------------------------------------------
# Backend: everything the page can ask for. Pure Python, no Qt.
# --------------------------------------------------------------------------

_CANCEL = object()
FIELD_CODE_RE = re.compile(r"^%[fFuUdDnNickvm]$")
LOGIN_SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "mksh"}


class Backend:
    def __init__(self, cfg, theme_name, theme_root, demo, emit_event):
        self.cfg = cfg
        self.theme_name = theme_name
        self.theme_root = theme_root
        self.demo = demo
        self.emit_event = emit_event  # emit_event(name: str, payload: dict)
        self.greetd_sock = os.environ.get("GREETD_SOCK")
        self.answers = queue.Queue()
        self.login_lock = threading.Lock()
        self.state_path = os.path.join(cfg["state_dir"], "state.json")
        self.state = self._load_state()
        self._sessions = self._scan_sessions()

    # ---- state (last user / last session) ----

    def _load_state(self):
        try:
            with open(self.state_path) as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save_state(self, user, session):
        if self.demo:
            return
        self.state.update(lastUser=user, lastSession=session)
        tmp = self.state_path + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(self.state, f)
            os.replace(tmp, self.state_path)
        except OSError as e:
            log(f"could not save state: {e}")

    # ---- sessions ----

    def _scan_sessions(self):
        found = {}
        hidden = set(self.cfg["hide_sessions"])
        for directory in self.cfg["session_dirs"]:
            kind = "x11" if "xsessions" in directory else "wayland"
            if not os.path.isdir(directory):
                continue
            for fname in sorted(os.listdir(directory)):
                if not fname.endswith(".desktop"):
                    continue
                sid = fname[: -len(".desktop")]
                if sid in hidden or sid in found:
                    continue
                entry = self._parse_desktop(os.path.join(directory, fname))
                if entry:
                    entry.update(id=sid, type=kind)
                    found[sid] = entry
        return list(found.values())

    @staticmethod
    def _parse_desktop(path):
        cp = configparser.ConfigParser(interpolation=None, strict=False)
        cp.optionxform = str
        try:
            cp.read(path, encoding="utf-8")
            e = cp["Desktop Entry"]
        except (configparser.Error, KeyError, UnicodeDecodeError):
            return None
        if e.get("Hidden", "").lower() == "true" or e.get("NoDisplay", "").lower() == "true":
            return None
        try_exec = e.get("TryExec")
        if try_exec and not shutil.which(try_exec):
            return None
        try:
            argv = [a for a in shlex.split(e.get("Exec", "")) if not FIELD_CODE_RE.match(a)]
        except ValueError:
            return None
        if not argv or not shutil.which(argv[0]):
            return None
        return {
            "name": e.get("Name", os.path.basename(path)),
            "comment": e.get("Comment", ""),
            "desktopNames": e.get("DesktopNames", "").strip(";").replace(";", ":"),
            "cmd": argv,
        }

    def sessions(self):
        last = self.state.get("lastSession")
        return [
            {k: s[k] for k in ("id", "name", "comment", "type", "desktopNames")} | {"last": s["id"] == last}
            for s in self._sessions
        ]

    def _preferred_session(self):
        ids = [s["id"] for s in self._sessions]
        for candidate in (self.state.get("lastSession"), self.cfg["default_session"]):
            if candidate in ids:
                return candidate
        return ids[0] if ids else None

    # ---- users ----

    def _avatar(self, name):
        candidates = [os.path.join(self.cfg["avatars_dir"], name + ext)
                      for ext in (".png", ".jpg", ".jpeg", ".webp", ".svg")]
        candidates.append(f"/var/lib/AccountsService/icons/{name}")
        for path in candidates:
            try:
                if os.path.isfile(path) and os.path.getsize(path) < 4 * 1024 * 1024:
                    with open(path, "rb") as f:
                        data = f.read()
                    mime = mimetypes.guess_type(path)[0] or "image/png"
                    return f"data:{mime};base64,{base64.b64encode(data).decode()}"
            except OSError:
                continue
        return None

    def _real_users(self):
        users = []
        for p in pwd.getpwall():
            if not (self.cfg["min_uid"] <= p.pw_uid <= self.cfg["max_uid"]):
                continue
            if p.pw_shell.endswith(("nologin", "/false")):
                continue
            users.append(p)
        return sorted(users, key=lambda p: p.pw_uid)

    def users(self):
        last = self.state.get("lastUser")
        return [{
            "name": p.pw_name,
            "realName": p.pw_gecos.split(",")[0] or p.pw_name,
            "avatar": self._avatar(p.pw_name),
            "last": p.pw_name == last,
        } for p in self._real_users()]

    def _preferred_user(self):
        names = [p.pw_name for p in self._real_users()]
        last = self.state.get("lastUser")
        if last in names:
            return last
        return names[0] if names else None

    # ---- info ----

    @staticmethod
    def _read(path):
        try:
            with open(path) as f:
                return f.read().strip()
        except OSError:
            return ""

    def _os_name(self):
        for line in self._read("/etc/os-release").splitlines():
            if line.startswith("PRETTY_NAME="):
                return line.split("=", 1)[1].strip().strip('"')
        return "Linux"

    def system(self):
        """Live system facts for theme widgets (all from /proc and /sys, nothing sensitive)."""
        out = {"uptime": None, "load": None, "cpu": None, "mem": None, "net": None,
               "power": {"source": "ac", "battery": None, "charging": None}}
        try:
            out["uptime"] = float(self._read("/proc/uptime").split()[0])
            out["load"] = list(os.getloadavg())
        except (ValueError, IndexError, OSError):
            pass
        try:  # CPU busy fraction since the previous call
            fields = [int(x) for x in self._read("/proc/stat").splitlines()[0].split()[1:9]]
            idle, total = fields[3] + fields[4], sum(fields)
            prev = getattr(self, "_cpu_prev", None)
            if prev and total > prev[1]:
                out["cpu"] = round(1 - (idle - prev[0]) / (total - prev[1]), 4)
            self._cpu_prev = (idle, total)
        except (ValueError, IndexError):
            pass
        mem = {}
        for line in self._read("/proc/meminfo").splitlines():
            key, _, rest = line.partition(":")
            if key in ("MemTotal", "MemAvailable"):
                mem[key] = int(rest.split()[0]) * 1024
        if len(mem) == 2:
            out["mem"] = {"total": mem["MemTotal"], "used": mem["MemTotal"] - mem["MemAvailable"]}
        rx = tx = 0
        for line in self._read("/proc/net/dev").splitlines()[2:]:
            name, _, data = line.partition(":")
            if name.strip() != "lo" and data.split():
                cols = data.split()
                rx, tx = rx + int(cols[0]), tx + int(cols[8])
        out["net"] = {"rx": rx, "tx": tx}
        base = "/sys/class/power_supply"
        for name in (os.listdir(base) if os.path.isdir(base) else []):
            p = os.path.join(base, name)
            if self._read(p + "/type") == "Battery" and self._read(p + "/scope") != "Device":
                cap, status = self._read(p + "/capacity"), self._read(p + "/status")
                out["power"] = {"source": "battery" if status == "Discharging" else "ac",
                                "battery": int(cap) if cap.isdigit() else None,
                                "charging": status == "Charging"}
        return out

    def info(self):
        options = self.cfg["theme_options"].get(self.theme_name, {})
        return {
            "mode": "greeter",
            "version": VERSION,
            "hostname": socket.gethostname(),
            "kernel": os.uname().release,
            "os": self._os_name(),
            "demo": self.demo,
            "theme": self.theme_name,
            "preferredUser": self._preferred_user(),
            "preferredSession": self._preferred_session(),
            "allowNetwork": bool(self.cfg["allow_network"]),
            "options": options if isinstance(options, dict) else {},
        }

    # ---- login ----

    def _session_command(self, session, username):
        """greetd joins the cmd list with spaces and runs it with /bin/sh -c, so the whole
        command is sent as one correctly shell-quoted string."""
        cmd = list(session["cmd"])
        if self.cfg["login_shell"]:
            try:
                shell = pwd.getpwnam(username).pw_shell
            except KeyError:
                shell = ""
            if os.path.basename(shell) in LOGIN_SHELLS:
                # Run through the user's login shell so ~/.profile / ~/.zprofile apply.
                cmd = [shell, "-l", "-c", 'exec "$@"', "canvasgreet-session", *cmd]
        env = [f"XDG_SESSION_TYPE={session['type']}", f"XDG_SESSION_DESKTOP={session['id']}"]
        if session["desktopNames"]:
            env.append(f"XDG_CURRENT_DESKTOP={session['desktopNames']}")
        return [shlex.join(cmd)], env

    def login(self, username, password, session_id):
        session = next((s for s in self._sessions if s["id"] == session_id), None)
        if session is None:
            return {"ok": False, "type": "session", "error": f"Unknown session {session_id!r}"}
        if not username:
            return {"ok": False, "type": "user", "error": "No user selected"}
        if not self.login_lock.acquire(blocking=False):
            return {"ok": False, "type": "busy", "error": "A login is already in progress"}
        try:
            while not self.answers.empty():
                self.answers.get_nowait()
            if self.demo or not self.greetd_sock:
                return self._demo_login(password, session)
            return self._greetd_login(username, password, session)
        finally:
            self.login_lock.release()

    def _demo_login(self, password, session):
        time.sleep(0.6)
        if password == DEMO_PASSWORD:
            return {"ok": True, "demo": True, "session": session["name"]}
        return {"ok": False, "type": "auth_error",
                "error": f'Incorrect password (demo mode: the password is "{DEMO_PASSWORD}")'}

    def _greetd_login(self, username, password, session):
        try:
            g = Greetd(self.greetd_sock)
        except OSError as e:
            return {"ok": False, "type": "error", "error": f"Cannot reach greetd: {e}"}
        try:
            r = g.request({"type": "create_session", "username": username})
            used_password = False
            while r.get("type") == "auth_message":
                kind, text = r.get("auth_message_type"), r.get("auth_message", "")
                if kind == "secret" and not used_password:
                    answer, used_password = password, True
                elif kind in ("info", "error"):
                    self.emit_event("message", {"type": kind, "message": text})
                    answer = None
                else:  # an extra prompt (OTP, second factor, "visible" username prompt...)
                    self.emit_event("prompt", {"type": kind, "message": text})
                    try:
                        answer = self.answers.get(timeout=300)
                    except queue.Empty:
                        answer = _CANCEL
                    if answer is _CANCEL:
                        self._cancel(g)
                        return {"ok": False, "type": "cancelled", "error": "Login cancelled"}
                r = g.request({"type": "post_auth_message_response", "response": answer})

            if r.get("type") == "error":
                self._cancel(g)
                if r.get("error_type") == "auth_error":
                    return {"ok": False, "type": "auth_error", "error": "Incorrect password"}
                return {"ok": False, "type": "error", "error": r.get("description") or "Login failed"}
            if r.get("type") != "success":
                self._cancel(g)
                return {"ok": False, "type": "error", "error": f"Unexpected reply from greetd: {r}"}

            cmd, env = self._session_command(session, username)
            r = g.request({"type": "start_session", "cmd": cmd, "env": env})
            if r.get("type") != "success":
                self._cancel(g)
                return {"ok": False, "type": "error",
                        "error": r.get("description") or "greetd refused to start the session"}
            self._save_state(username, session["id"])
            log(f"starting session {session['id']!r} for {username!r}")
            return {"ok": True, "session": session["name"]}
        except (OSError, ConnectionError, ValueError) as e:
            self._cancel(g)
            return {"ok": False, "type": "error", "error": f"greetd error: {e}"}
        finally:
            g.close()

    @staticmethod
    def _cancel(g):
        try:
            g.request({"type": "cancel_session"})
        except Exception:
            pass

    def respond(self, text):
        self.answers.put(text)
        return True

    def cancel(self):
        self.answers.put(_CANCEL)
        return True

    # ---- power ----

    POWER_ACTIONS = {"poweroff": "PowerOff", "reboot": "Reboot", "suspend": "Suspend", "hibernate": "Hibernate"}

    def power_capabilities(self):
        caps = {}
        for action, method in self.POWER_ACTIONS.items():
            try:
                out = subprocess.run(
                    ["busctl", "call", "--system", "org.freedesktop.login1", "/org/freedesktop/login1",
                     "org.freedesktop.login1.Manager", f"Can{method}"],
                    capture_output=True, text=True, timeout=3).stdout
                caps[action] = out.split('"')[1] == "yes"
            except (OSError, IndexError, subprocess.SubprocessError):
                caps[action] = action in ("poweroff", "reboot")
        return caps

    def power(self, action):
        """Runs in a worker thread. Returns {"ok": False, "error"} if systemd/polkit refuses."""
        if action not in self.POWER_ACTIONS:
            raise ValueError(f"unknown power action {action!r}")
        if self.demo:
            log(f"demo mode: would run systemctl {action}")
            return {"ok": True, "demo": True}
        try:
            r = subprocess.run(["systemctl", "--no-ask-password", action], stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return {"ok": True}  # still in progress: the machine is going down or to sleep
        except OSError as e:
            return {"ok": False, "error": str(e)}
        if r.returncode != 0:
            lines = (r.stderr or r.stdout or "").strip().splitlines()
            error = lines[-1] if lines else f"systemctl {action} failed ({r.returncode})"
            log(f"power {action} failed: {error}")
            return {"ok": False, "error": error}
        return {"ok": True}

    # ---- theme files ----

    def theme_files(self, subdir):
        root = os.path.realpath(self.theme_root)
        target = os.path.realpath(os.path.join(root, subdir or ""))
        if os.path.commonpath([root, target]) != root or not os.path.isdir(target):
            return []
        rel = os.path.relpath(target, root)
        out = []
        for name in sorted(os.listdir(target)):
            path = os.path.join(target, name)
            if name.startswith(".") or not os.path.isfile(path):
                continue
            url_path = "/".join(p for p in (rel if rel != "." else "", name) if p)
            out.append({"name": name, "size": os.path.getsize(path),
                        "url": "greeter://theme/" + "/".join(map(_quote, url_path.split("/")))})
        return out


def _quote(part):
    from urllib.parse import quote
    return quote(part)


# --------------------------------------------------------------------------
# Qt front end
# --------------------------------------------------------------------------

def run_qt(args, cfg, theme_name, theme_root):
    greeter_mode = not (args.demo or args.screenshot)

    if greeter_mode:
        # The greeter user's home is "/"; give Chromium/Mesa a writable place
        # (the GPU shader cache there makes later starts faster).
        base = cfg["state_dir"]
        if not os.access(base, os.W_OK):
            base = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "canvasgreet")
        for var, sub in (("XDG_CACHE_HOME", "cache"), ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data")):
            os.environ[var] = os.path.join(base, sub)
            os.makedirs(os.environ[var], exist_ok=True)
        os.environ["HOME"] = base
        os.environ.setdefault("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")
    flags = " ".join(filter(None, [os.environ.get("QTWEBENGINE_CHROMIUM_FLAGS", ""), cfg["chromium_flags"]]))
    os.environ["QTWEBENGINE_CHROMIUM_FLAGS"] = flags

    from PyQt6.QtCore import (QBuffer, QFile, QFileSystemWatcher, QIODevice, QObject, Qt, QTimer, QUrl,
                              pyqtSignal, pyqtSlot)
    from PyQt6.QtGui import QColor, QKeySequence, QShortcut
    from PyQt6.QtWebChannel import QWebChannel
    from PyQt6.QtWebEngineCore import (QWebEnginePage, QWebEngineProfile, QWebEngineScript,
                                       QWebEngineSettings, QWebEngineUrlRequestInterceptor,
                                       QWebEngineUrlRequestJob, QWebEngineUrlScheme,
                                       QWebEngineUrlSchemeHandler)
    from PyQt6.QtWebEngineWidgets import QWebEngineView
    from PyQt6.QtWidgets import QApplication

    scheme = QWebEngineUrlScheme(b"greeter")
    scheme.setSyntax(QWebEngineUrlScheme.Syntax.Host)
    scheme_flags = (QWebEngineUrlScheme.Flag.SecureScheme | QWebEngineUrlScheme.Flag.CorsEnabled)
    if hasattr(QWebEngineUrlScheme.Flag, "FetchApiAllowed"):
        scheme_flags |= QWebEngineUrlScheme.Flag.FetchApiAllowed
    scheme.setFlags(scheme_flags)
    QWebEngineUrlScheme.registerScheme(scheme)

    app = QApplication(sys.argv[:1])
    app.setApplicationName("canvasgreet")
    app.setDesktopFileName("canvasgreet")

    roots = {"theme": theme_root, "fallback": os.path.join(LIB_DIR, "fallback")}

    class SchemeHandler(QWebEngineUrlSchemeHandler):
        """Serves greeter://theme/<path> from the theme folder (and nothing else)."""

        def requestStarted(self, job):
            url = job.requestUrl()
            root = roots.get(url.host())
            if root is None:
                job.fail(QWebEngineUrlRequestJob.Error.UrlNotFound)
                return
            root = os.path.realpath(root)
            rel = url.path(QUrl.ComponentFormattingOption.FullyDecoded).lstrip("/") or "index.html"
            path = os.path.realpath(os.path.join(root, rel))
            if os.path.isdir(path):
                path = os.path.join(path, "index.html")
            if os.path.commonpath([root, path]) != root or not os.path.isfile(path):
                job.fail(QWebEngineUrlRequestJob.Error.UrlNotFound)
                return
            try:
                with open(path, "rb") as f:
                    data = f.read()
            except OSError:
                job.fail(QWebEngineUrlRequestJob.Error.RequestFailed)
                return
            buf = QBuffer(job)
            buf.setData(data)
            buf.open(QIODevice.OpenModeFlag.ReadOnly)
            mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
            job.reply(mime.encode(), buf)

    class RequestGuard(QWebEngineUrlRequestInterceptor):
        """Blocks everything except the theme itself (and the network, if allowed)."""

        LOCAL = {"greeter", "data", "blob", "qrc"}
        DEV = {"devtools", "chrome-devtools", "chrome"}
        NET = {"http", "https", "ws", "wss"}

        def interceptRequest(self, info):
            s = info.requestUrl().scheme()
            if s in self.LOCAL or (s in self.DEV and not greeter_mode):
                return
            if s in self.NET and cfg["allow_network"]:
                return
            info.block(True)

    class Page(QWebEnginePage):
        def acceptNavigationRequest(self, url, nav_type, is_main_frame):
            return url.scheme() in ("greeter", "about", "data") or (not greeter_mode and url.scheme() == "chrome")

        def javaScriptConsoleMessage(self, level, message, line, source):
            log(f"js: {message}  ({source.rsplit('/', 1)[-1]}:{line})")

        def createWindow(self, _type):
            return None

    class Bridge(QObject):
        reply = pyqtSignal(str, str)   # (request id, JSON {"result"} | {"error"})
        event = pyqtSignal(str, str)   # (event name, JSON payload)
        _post = pyqtSignal(str, str, str)

        def __init__(self, on_login_ok):
            super().__init__()
            self.on_login_ok = on_login_ok
            self._post.connect(self._on_post)  # queued when emitted from the login thread
            self.backend = Backend(cfg, theme_name, theme_root, demo=not greeter_mode,
                                   emit_event=lambda n, p: self._post.emit("event", n, json.dumps(p)))

        def _on_post(self, kind, a, b):  # always runs on the Qt main thread
            if kind == "reply":
                self.reply.emit(a, b)
            elif kind == "event":
                self.event.emit(a, b)
            elif kind == "login-ok":
                self.on_login_ok()

        @pyqtSlot(str, str, str)
        def call(self, req_id, method, args_json):
            try:
                args = json.loads(args_json or "{}")
            except ValueError:
                args = {}
            if method in ("login", "power"):  # slow: keep the page animating meanwhile
                threading.Thread(target=self._run, args=(req_id, method, args), daemon=True).start()
            else:
                self._run(req_id, method, args)

        def _run(self, req_id, method, a):
            b = self.backend
            try:
                if method == "info":
                    result = b.info()
                elif method == "users":
                    result = b.users()
                elif method == "sessions":
                    result = b.sessions()
                elif method == "login":
                    result = b.login(str(a.get("username", "")), str(a.get("password", "")),
                                     str(a.get("session", "")))
                    if result.get("ok") and greeter_mode:
                        self._post.emit("login-ok", "", "")
                elif method == "respond":
                    result = b.respond(None if a.get("text") is None else str(a.get("text")))
                elif method == "cancel":
                    result = b.cancel()
                elif method == "power":
                    result = b.power(str(a.get("action", "")))
                elif method == "powerCapabilities":
                    result = b.power_capabilities()
                elif method == "themeFiles":
                    result = b.theme_files(str(a.get("dir", "")))
                elif method == "system":
                    result = b.system()
                elif method == "log":
                    log("theme:", str(a.get("message", ""))[:2000])
                    result = True
                else:
                    raise ValueError(f"unknown method {method!r}")
                payload = {"result": result}
            except Exception as e:  # report to the page instead of crashing the greeter
                log(f"{method} failed: {e!r}")
                payload = {"error": str(e)}
            self._post.emit("reply", req_id, json.dumps(payload))

    def quit_soon():
        # greetd starts the session once the greeter exits; the delay lets the theme fade out.
        QTimer.singleShot(int(cfg["exit_delay_ms"]), app.quit)

    bridge = Bridge(on_login_ok=quit_soon)

    profile = QWebEngineProfile(app)  # no storage name = off the record, nothing written to disk
    profile.setHttpCacheType(QWebEngineProfile.HttpCacheType.MemoryHttpCache)
    handler = SchemeHandler(app)
    guard = RequestGuard(app)
    profile.installUrlSchemeHandler(b"greeter", handler)
    profile.setUrlRequestInterceptor(guard)

    page = Page(profile, app)
    page.setBackgroundColor(QColor("#000000"))
    s = page.settings()
    WA = QWebEngineSettings.WebAttribute
    for attr, on in ((WA.PlaybackRequiresUserGesture, False), (WA.ShowScrollBars, False),
                     (WA.Accelerated2dCanvasEnabled, True), (WA.WebGLEnabled, True),
                     (WA.LocalStorageEnabled, True), (WA.JavascriptCanAccessClipboard, False),
                     (WA.JavascriptCanOpenWindows, False), (WA.ErrorPageEnabled, False),
                     (WA.FocusOnNavigationEnabled, True)):
        s.setAttribute(attr, on)

    qwc = QFile(":/qtwebchannel/qwebchannel.js")
    if not qwc.open(QIODevice.OpenModeFlag.ReadOnly):
        log("FATAL: qwebchannel.js not found in Qt resources")
        return 1
    with open(os.path.join(LIB_DIR, "bridge.js"), encoding="utf-8") as f:
        source = bytes(qwc.readAll()).decode() + "\n" + f.read()
    script = QWebEngineScript()
    script.setName("canvasgreet-bridge")
    script.setSourceCode(source)
    script.setInjectionPoint(QWebEngineScript.InjectionPoint.DocumentCreation)
    script.setWorldId(QWebEngineScript.ScriptWorldId.MainWorld)
    script.setRunsOnSubFrames(False)
    page.scripts().insert(script)

    channel = QWebChannel(page)
    channel.registerObject("bridge", bridge)
    page.setWebChannel(channel)
    page.setZoomFactor(float(cfg["zoom"]))

    view = QWebEngineView()
    view.setPage(page)
    view.setWindowTitle("canvasgreet")
    # No browser right-click menu (Back/Reload/Inspect...). The page still gets the DOM
    # "contextmenu" event, so a theme can draw its own. Devtools in --demo: F12.
    view.setContextMenuPolicy(Qt.ContextMenuPolicy.NoContextMenu)

    theme_url = QUrl("greeter://theme/index.html")
    fallback_url = QUrl("greeter://fallback/index.html")
    state = {"fallback": theme_root == roots["fallback"]}

    def load_fallback(reason):
        if state["fallback"]:
            return
        log(f"switching to the fallback theme: {reason}")
        state["fallback"] = True
        roots["theme"] = roots["fallback"]
        bridge.backend.theme_root = roots["fallback"]
        page.load(fallback_url)

    page.loadFinished.connect(lambda ok: None if ok else load_fallback("theme failed to load"))
    state["crashes"] = 0

    def on_render_crash(status, code):
        if status == QWebEnginePage.RenderProcessTerminationStatus.NormalTerminationStatus:
            return
        state["crashes"] += 1
        log(f"renderer exited ({status}, {code}), crash #{state['crashes']}")
        if state["fallback"]:
            QTimer.singleShot(300, lambda: page.load(fallback_url))
        elif state["crashes"] >= 2:
            QTimer.singleShot(300, lambda: load_fallback("theme keeps crashing"))
        else:
            QTimer.singleShot(300, lambda: page.load(theme_url))

    page.renderProcessTerminated.connect(on_render_crash)

    def reload():
        page.triggerAction(QWebEnginePage.WebAction.ReloadAndBypassCache)

    QShortcut(QKeySequence("Ctrl+Alt+Shift+F"), view, activated=lambda: load_fallback("emergency hotkey"))
    QShortcut(QKeySequence("Ctrl+Alt+Shift+R"), view, activated=reload)

    if not greeter_mode:
        QShortcut(QKeySequence("F5"), view, activated=reload)
        devtools = {}

        def open_devtools():
            if "view" not in devtools:
                dv = QWebEngineView()
                dv.setWindowTitle("canvasgreet devtools")
                dv.resize(1100, 800)
                page.setDevToolsPage(dv.page())
                devtools["view"] = dv
            devtools["view"].show()

        QShortcut(QKeySequence("F12"), view, activated=open_devtools)

        if args.demo and not args.screenshot:
            watcher = QFileSystemWatcher(app)
            debounce = QTimer(app, singleShot=True, interval=250)
            debounce.timeout.connect(lambda: (reload(), watch_all()))

            def watch_all():
                paths = [theme_root]
                for dirpath, dirnames, filenames in os.walk(theme_root):
                    dirnames[:] = [d for d in dirnames if not d.startswith(".") and d != "node_modules"]
                    paths.append(dirpath)
                    paths += [os.path.join(dirpath, f) for f in filenames]
                    if len(paths) > 800:
                        break
                old = watcher.files() + watcher.directories()
                if old:
                    watcher.removePaths(old)
                watcher.addPaths(paths)

            watcher.fileChanged.connect(lambda _p: debounce.start())
            watcher.directoryChanged.connect(lambda _p: debounce.start())
            watch_all()

    if args.screenshot:
        def shoot():
            view.grab().save(args.screenshot)
            log(f"saved {args.screenshot}")
            app.quit()
        page.loadFinished.connect(lambda ok: QTimer.singleShot(args.wait, shoot))

    if not greeter_mode:
        QShortcut(QKeySequence("Ctrl+Q"), view, activated=app.quit)

    page.load(fallback_url if state["fallback"] else theme_url)
    if greeter_mode or args.fullscreen:
        view.showFullScreen()
    else:
        w, h = (int(x) for x in args.size.lower().split("x"))
        view.resize(w, h)
        view.show()
    rc = app.exec()
    from PyQt6 import sip  # the page must go before its profile, or Chromium complains on exit
    sip.delete(view)
    sip.delete(page)
    return rc


def main():
    ap = argparse.ArgumentParser(prog="canvasgreet", description="HTML/CSS/JS login screen for greetd.")
    ap.add_argument("--config", default=DEFAULT_CONFIG, help=f"config file (default {DEFAULT_CONFIG})")
    ap.add_argument("--theme", help="theme to load (overrides the configured/selected one)")
    ap.add_argument("--demo", action="store_true", help="windowed preview with a fake login")
    ap.add_argument("--screenshot", metavar="FILE", help="render the theme to a PNG and exit (implies demo backend)")
    ap.add_argument("--wait", type=int, default=2500, help="ms to wait before --screenshot (default 2500)")
    ap.add_argument("--size", default="1720x720", help="window size for --demo/--screenshot (default 1720x720)")
    ap.add_argument("--fullscreen", action="store_true", help="--demo/--screenshot full screen (Ctrl+Q quits)")
    ap.add_argument("--list", action="store_true", help="list installed themes")
    ap.add_argument("--use", metavar="NAME", help="select the theme shown at the login screen")
    ap.add_argument("--version", action="version", version=f"canvasgreet {VERSION}")
    args = ap.parse_args()

    cfg = load_config(args.config)

    if args.list:
        current = selected_theme(cfg)
        for name in list_themes(cfg):
            print(("* " if name == current else "  ") + name)
        return 0

    if args.use:
        if args.use not in list_themes(cfg):
            print(f"no theme {args.use!r} in {cfg['themes_dir']} (try --list)", file=sys.stderr)
            return 1
        with open(os.path.join(cfg["themes_dir"], SELECTED_FILE), "w") as f:
            f.write(args.use + "\n")
        print(f"login screen theme set to {args.use!r}")
        return 0

    if not (args.demo or args.screenshot) and not os.environ.get("GREETD_SOCK"):
        print("GREETD_SOCK is not set: this is run by greetd. For a preview use --demo.", file=sys.stderr)
        return 2

    theme_name = args.theme or selected_theme(cfg)
    theme_root = os.path.join(cfg["themes_dir"], theme_name)
    if not (THEME_NAME_RE.match(theme_name) and os.path.isfile(os.path.join(theme_root, "index.html"))):
        log(f"theme {theme_name!r} not found in {cfg['themes_dir']}; using the fallback")
        theme_name, theme_root = "fallback", os.path.join(LIB_DIR, "fallback")

    log(f"version {VERSION}, theme {theme_name!r} ({theme_root})")
    return run_qt(args, cfg, theme_name, theme_root)


if __name__ == "__main__":
    sys.exit(main())
