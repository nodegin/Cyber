pragma Singleton
// Quick look: what popups/QuickLook.qml shows. GNOME Files asks for a preview over D-Bus when Space
// is pressed on a file; scripts/previewer.py answers and writes what the file is, as JSON, to
// $XDG_RUNTIME_DIR/cyber-preview.$WAYLAND_DISPLAY. This watches that file. An empty object = nothing
// to show; close() writes one, and the service notices.
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string stateFile: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/cyber-preview.${Quickshell.env("WAYLAND_DISPLAY") || "wayland-1"}`
    property var item: ({})                       // { uri, path, name, mime, kind, size, mtime, what, items?, text?, lines?, truncated?, seq }
    readonly property bool open: !!item.uri
    readonly property string kind: item.kind ?? ""          // image | video | audio | pdf | text | folder | other
    readonly property string path: item.path ?? ""
    readonly property string fileUrl: path ? "file://" + path.split("/").map(encodeURIComponent).join("/") : ""

    function close() { if (open) shut.running = true }

    function sizeText(n) {
        if (n < 1000) return `${n} B`
        const units = ["KB", "MB", "GB", "TB"]
        let v = n, i = -1
        do { v /= 1000; i++ } while (v >= 1000 && i < units.length - 1)
        return `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`
    }
    function timeText(s) {
        if (!s) return "----"
        const d = new Date(s * 1000), p = v => String(v).padStart(2, "0")
        return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
    }

    // the state file must exist before it can be watched; a stale "open" from before a restart is cleared
    Process {
        id: make
        command: ["sh", "-c", 'printf "{}" > "$1"', "sh", root.stateFile]
        onExited: watch.path = root.stateFile
    }
    Process {
        id: shut
        command: ["sh", "-c", 'printf "{}" > "$1"', "sh", root.stateFile]
    }
    FileView {
        id: watch
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const t = text()
            if (!t) return                                  // caught while being rewritten: the next change has it
            try { root.item = JSON.parse(t) } catch (e) {}  // half a line: the same
        }
        onLoadFailed: root.item = ({})
    }
    Component.onCompleted: make.running = true
}
