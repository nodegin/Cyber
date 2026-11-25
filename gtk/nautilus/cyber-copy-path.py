"""Copy Path, directly in the right-click menu of GNOME Files.

A Files extension. Files only loads it when the package nautilus-python is installed:

    sudo pacman -S nautilus-python      then      nautilus -q      (and open Files again)

setup.sh links this file into ~/.local/share/nautilus-python/extensions/ either way. Until that
package is there, the same thing is in the menu one level down, under Scripts > Copy path (the
script next to this file): Files has no other way to add a menu entry without a system package.
Once this extension runs it takes that Scripts entry away again, so there is only one.

On one or more files or folders: their full paths, one per line. On the empty part of a folder:
that folder's path. Things without a local path (network places, the trash) get their address.
"""
import os

import gi

gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GObject, Nautilus  # noqa: E402

# the Scripts entry this replaces: only if it is the link setup.sh made, never a file of the user's
_script = os.path.expanduser("~/.local/share/nautilus/scripts/Copy path")
try:
    if os.path.islink(_script) and os.readlink(_script).endswith("/gtk/nautilus/Copy path"):
        os.unlink(_script)
except OSError:
    pass


def _where(file):
    location = file.get_location()
    return location.get_path() or file.get_uri()


class CyberCopyPath(GObject.GObject, Nautilus.MenuProvider):
    def _copy(self, _item, text):
        Gdk.Display.get_default().get_clipboard().set(text)

    def _item(self, name, label, text):
        item = Nautilus.MenuItem(name=name, label=label, tip="Copy the full path to the clipboard")
        item.connect("activate", self._copy, text)
        return [item]

    def get_file_items(self, files):
        paths = [_where(f) for f in files]
        if not paths:
            return []
        return self._item("CyberCopyPath::files", "Copy Path" if len(paths) == 1 else "Copy Paths", "\n".join(paths))

    def get_background_items(self, folder):
        return self._item("CyberCopyPath::folder", "Copy Path", _where(folder))
