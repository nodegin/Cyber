#!/usr/bin/env python3
"""Cyber's quick look: what GNOME Files talks to when Space is pressed on a file.

Files (Nautilus) does not preview anything itself. On Space it calls the D-Bus service
org.gnome.NautilusPreviewer (GNOME's own is "Sushi"): ShowFile(uri, window, close_if_shown). While
that service says it is visible, Files also sends every newly selected file, so the arrow keys
flip through a folder, and Space on the file being shown closes it again.
(Files 51 sends four arguments: the last is an activation token for the previewer's window. With
the method declared any other way the bus refuses the call and Space does nothing at all.)

This is that service for Cyber. It does not draw anything: it works out what the file is and
writes that as one line of JSON to $XDG_RUNTIME_DIR/cyber-preview.$WAYLAND_DISPLAY, which Cyber's
shell watches (services/Preview.qml) and shows as a HUD panel (popups/QuickLook.qml). An empty
object means "nothing shown"; the shell writes that itself when the panel is clicked away, and
this service notices. Text files are read here (the first 300 kB, JSON re-indented) into
<that file>.txt, so the shell never has to load a huge file.

It is started by D-Bus (~/.local/share/dbus-1/services/org.gnome.NautilusPreviewer.service,
written by setup.sh) and leaves again when nothing has been shown for a minute. Without Cyber's
shell running (on end-4/pC) Space simply does nothing.

When Files looks for it: once, as the Files process starts (it pings the name, which starts this).
If nothing answers then, Files switches to a second name, org.gnome.NautilusPreviewer.Devel, and
stays on it for as long as that process lives; it asks again whenever a file is selected. So a
Files that was already open when this was installed never asks for the first name again. That is
why there is a second service file for the .Devel name, starting this script with --devel: such a
Files finds it on the next click, without having to be closed first.
"""
import json
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

DEVEL = "--devel" in sys.argv[1:]      # the name Files falls back to (see above)
NAME = "org.gnome.NautilusPreviewer" + (".Devel" if DEVEL else "")
PATH = "/org/gnome/NautilusPreviewer" + ("/Devel" if DEVEL else "")
IFACE = "org.gnome.NautilusPreviewer2"
XML = f"""<node>
  <interface name="{IFACE}">
    <method name="ShowFile">
      <arg type="s" name="uri" direction="in"/>
      <arg type="s" name="window_handle" direction="in"/>
      <arg type="b" name="close_if_already_visible" direction="in"/>
      <arg type="s" name="activation_token" direction="in"/>
    </method>
    <method name="Close"/>
    <signal name="SelectionEvent"><arg type="u" name="direction"/></signal>
    <property name="Visible" type="b" access="read"/>
    <property name="Parent" type="s" access="read"/>
  </interface>
</node>"""

RUNTIME = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
STATE = os.path.join(RUNTIME, "cyber-preview." + (os.environ.get("WAYLAND_DISPLAY") or "wayland-1"))
TEXT = STATE + ".txt"
TEXT_LIMIT = 300_000          # bytes of a text file that are shown
JSON_LIMIT = 2_000_000        # a JSON file up to this size is re-indented
IDLE_SECONDS = 60

TEXTY = {
    "application/json", "application/xml", "application/javascript", "application/x-shellscript",
    "application/toml", "application/yaml", "application/x-yaml", "application/x-desktop",
    "application/sql", "application/x-php", "application/x-perl", "application/x-ruby",
    "application/x-wine-extension-ini", "application/x-subrip", "application/x-zerosize",
    "application/x-ndjson", "application/ld+json", "application/x-csh", "application/x-m4",
    "image/svg+xml",
}


def kind_of(mime, path, is_dir):
    if is_dir:
        return "folder"
    if mime == "image/svg+xml":
        return "image"
    if mime.startswith("image/"):
        return "image"
    if mime.startswith("video/"):
        return "video"
    if mime.startswith("audio/"):
        return "audio"
    if mime == "application/pdf":
        return "pdf"
    if mime.startswith("text/") or mime in TEXTY or Gio.content_type_is_a(mime, "text/plain"):
        return "text"
    if path:        # unknown type: text if it reads as text
        try:
            with open(path, "rb") as f:
                head = f.read(4096)
            if head and b"\0" not in head:
                head.decode("utf-8")
                return "text"
        except (OSError, UnicodeDecodeError):
            pass
    return "other"


def excerpt(path, mime, size):
    """-> (lines, truncated): the text to show is written to TEXT."""
    try:
        with open(path, "rb") as f:
            raw = f.read(JSON_LIMIT + 1 if "json" in mime else TEXT_LIMIT + 1)
    except OSError as e:
        raw = f"(cannot read: {e.strerror})".encode()
    text = raw.decode("utf-8", errors="replace")
    truncated = False
    if "json" in mime and len(raw) <= JSON_LIMIT:
        try:
            text = json.dumps(json.loads(text), indent=2, ensure_ascii=False)
        except ValueError:
            pass
    if len(text.encode("utf-8", errors="replace")) > TEXT_LIMIT:
        text = text.encode("utf-8", errors="replace")[:TEXT_LIMIT].decode("utf-8", errors="ignore")
        truncated = True
    truncated = truncated or size > max(len(raw), TEXT_LIMIT)
    text = text.replace("\r\n", "\n").replace("\t", "    ")
    with open(TEXT, "w", encoding="utf-8") as f:
        f.write(text)
    return text.count("\n") + 1, truncated


def describe(uri):
    gfile = Gio.File.new_for_uri(uri)
    info = None
    try:
        info = gfile.query_info(
            "standard::display-name,standard::content-type,standard::size,standard::type,"
            "standard::target-uri,time::modified", Gio.FileQueryInfoFlags.NONE, None)
    except GLib.Error:
        pass
    path = gfile.get_path()
    if not path and info is not None:      # recent://, trash://: where the file really is
        target = info.get_attribute_string("standard::target-uri")
        if target:
            path = Gio.File.new_for_uri(target).get_path()
    name = info.get_display_name() if info else (os.path.basename(path) if path else uri)
    mime = (info.get_content_type() if info else None) or "application/octet-stream"
    is_dir = bool(info and info.get_file_type() == Gio.FileType.DIRECTORY)
    size = int(info.get_size()) if info else 0
    mtime = int(info.get_attribute_uint64("time::modified")) if info else 0
    kind = kind_of(mime, path, is_dir) if path or is_dir else "other"
    out = {"uri": uri, "path": path or "", "name": name, "mime": mime, "kind": kind, "size": size,
           "mtime": mtime, "what": Gio.content_type_get_description(mime) or mime}
    if is_dir and path:
        try:
            out["items"] = len(os.listdir(path))
        except OSError:
            out["items"] = -1
    if kind == "text" and path:
        out["lines"], out["truncated"] = excerpt(path, mime, size)
        out["text"] = TEXT
    return out


class Previewer:
    def __init__(self, loop):
        self.loop = loop
        self.conn = None
        self.visible = False
        self.uri = ""
        self.parent = ""
        self.seq = 0
        self.idle = 0
        self.node = Gio.DBusNodeInfo.new_for_xml(XML)
        self.monitor = Gio.File.new_for_path(STATE).monitor_file(Gio.FileMonitorFlags.NONE, None)
        self.monitor.connect("changed", self.on_state_changed)
        GLib.timeout_add_seconds(5, self.tick)

    # ---- the state file
    def write(self, data):
        # in place (not write-and-rename): the shell watches this very file, and a watch does not
        # follow a file that was replaced. The shell ignores a half-written line.
        with open(STATE, "w", encoding="utf-8") as f:
            json.dump(data, f)

    def on_state_changed(self, *_):
        """The shell closed the panel (it wrote an empty object)."""
        try:
            with open(STATE, encoding="utf-8") as f:
                shown = bool(json.loads(f.read() or "{}").get("uri"))
        except (OSError, ValueError):
            shown = False
        if not shown and self.visible:
            self.set_visible(False)

    def set_visible(self, visible):
        if visible == self.visible:
            return
        self.visible = visible
        if not visible:
            self.uri = ""
        if self.conn:
            self.conn.emit_signal(None, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                  GLib.Variant("(sa{sv}as)", (IFACE, {"Visible": GLib.Variant("b", visible)}, [])))

    def tick(self):
        self.idle = 0 if self.visible else self.idle + 5
        if self.idle >= IDLE_SECONDS:
            self.loop.quit()
            return False
        return True

    # ---- D-Bus
    def show(self, uri, parent, close_if_shown, _activation_token=""):
        if self.visible and uri == self.uri and close_if_shown:
            self.close()
            return
        self.seq += 1
        data = describe(uri)
        data["seq"] = self.seq
        self.uri, self.parent = uri, parent
        self.write(data)
        self.set_visible(True)

    def close(self):
        self.write({})
        self.set_visible(False)

    def on_call(self, conn, sender, path, iface, method, params, invocation):
        try:
            if method == "ShowFile":
                self.show(*params.unpack())
            elif method == "Close":
                self.close()
        except Exception as e:  # never leave Files waiting for an answer
            print(f"cyber previewer: {method}: {e}", file=sys.stderr)
        invocation.return_value(None)

    def on_get(self, conn, sender, path, iface, prop):
        if prop == "Visible":
            return GLib.Variant("b", self.visible)
        if prop == "Parent":
            return GLib.Variant("s", self.parent)
        return None

    def on_bus(self, conn, name):
        self.conn = conn
        conn.register_object(PATH, self.node.interfaces[0], self.on_call, self.on_get, None)


def main():
    loop = GLib.MainLoop()
    p = Previewer(loop)
    Gio.bus_own_name(Gio.BusType.SESSION, NAME, Gio.BusNameOwnerFlags.NONE, p.on_bus, None, lambda *_: loop.quit())
    try:
        loop.run()
    finally:
        if p.visible:
            try:
                p.write({})
            except OSError:
                pass


if __name__ == "__main__":
    main()
