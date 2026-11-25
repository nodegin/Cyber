pragma Singleton
// Looking Glass: the Windows VM's screen in a window (looking-glass-client).
//   The bottom-bar button starts it as a user service (systemd-run, unit "cyber-looking-glass", so it
//   survives Cyber reloading) and stops it; the button is lit while a client runs, so a crash or
//   closing the window turns it off. Hyprland places the window and decides when it is engaged
//   (hypr/lookingglass.lua); hud/LookingGlassPanel.qml tilts it while it is idle.
// config.json: "lookingGlass": { "vm": "win11" }  (the libvirt domain; only watched, never started)
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs

Singleton {
    id: root

    readonly property string appId: "looking-glass-client"
    readonly property string unit: "cyber-looking-glass"
    readonly property string vm: Config.data.lookingGlass?.vm ?? "win11"

    property bool running: false          // a looking-glass-client process exists
    property bool vmRunning: true         // the VM is up (assumed until checked)
    property var window: null             // its window as hyprctl sees it (address, at, size, tags, ...)
    property real covered: 0              // how much of its spot lies under other windows (0..1); idle, they are all above it
    // the same window as a capture source (matched by address, in case there is ever a second one)
    readonly property var toplevel: window === null ? null
        : ToplevelManager.toplevels.values.find(t => "0x" + (t.HyprlandToplevel?.address ?? "") === window.address) ?? null
    // "focused" = engaged: it is the active window and the pointer is on it. Hyprland decides that
    // (hypr/lookingglass.lua watches the pointer) and tells us; until it has, fall back to
    // "it is the active window".
    property int engaged: -1              // -1 not told yet, 0 idle, 1 engaged
    property string activeAddress: "?"
    readonly property bool focused: window !== null && (engaged !== -1 ? engaged === 1
        : activeAddress === "?" ? window.focusHistoryID === 0 : activeAddress === window.address)
    GlobalShortcut { name: "lgEngaged"; onPressed: root.engaged = 1 }
    GlobalShortcut { name: "lgIdle"; onPressed: root.engaged = 0 }
    // The corners plugin (3.2 and later) says when the parked window has drawn a new picture
    // ("cybertiltframe" on Hyprland's event socket); the panel then fetches a frame only for that.
    // Without it the panel falls back to a timer.
    property bool frameSignal: false
    Process {
        id: pluginProbe
        command: ["hyprctl", "plugin", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = /Plugin cybercorners[\s\S]*?Version:\s*(\d+)\.(\d+)/.exec(text)
                root.frameSignal = m !== null && (Number(m[1]) > 3 || (Number(m[1]) === 3 && Number(m[2]) >= 2))
            }
        }
    }
    function probePlugin() { if (!pluginProbe.running) pluginProbe.running = true }

    // the pointer is on the tilted copy (hud/LookingGlassPanel.qml): Hyprland brings the window forward
    function engage() { Quickshell.execDetached(["hyprctl", "eval", "if CyberLookingGlass then CyberLookingGlass.engage() end"]) }
    function askState() { Quickshell.execDetached(["hyprctl", "eval", "if CyberLookingGlass then CyberLookingGlass.report() end"]) }
    property bool wasNull: true
    onWindowChanged: if ((window === null) !== wasNull) { wasNull = window === null; if (window) { askState(); probePlugin() } else engaged = -1 }
    // the process, matched on its command line: its name is longer than the 15 characters that
    // `pgrep -x` / `pkill -x` can see, so those never match it
    readonly property string pattern: "^(/usr/bin/)?looking-glass-client( |$)"

    function toggle() {
        if (root.running) {
            Quickshell.execDetached(["sh", "-c",
                `systemctl --user stop ${root.unit} 2>/dev/null; pkill -f '${root.pattern}'; true`])
            root.running = false
        } else {
            // win:fullScreen=no: the client's own config opens it fullscreen; Hyprland places it instead
            Quickshell.execDetached(["sh", "-c",
                `systemctl --user reset-failed ${root.unit} 2>/dev/null; `
                + `systemd-run --user --quiet --collect --unit=${root.unit} looking-glass-client win:fullScreen=no`])
            root.running = true
        }
        recheck.restart()
    }

    // ---- is it running? (the button follows the process, however it was started)
    Process {
        id: probe
        command: ["pgrep", "-f", root.pattern]
        onExited: code => root.running = code === 0
    }
    Timer { id: recheck; interval: 1500; onTriggered: probe.running = true }
    Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true; onTriggered: if (!probe.running) probe.running = true }

    // ---- is the VM up?
    Process {
        id: domstate
        command: ["virsh", "-c", "qemu:///system", "domstate", root.vm]
        stdout: StdioCollector { onStreamFinished: root.vmRunning = text.trim() === "running" }
    }
    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: if (!domstate.running) domstate.running = true }

    // ---- where its window is (for the tilted panel): on window events, and every second while it
    // exists (dragging a floating window sends no event)
    Process {
        id: clients
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const all = JSON.parse(text)
                    const lg = all.find(c => c.class === root.appId && c.mapped) ?? null
                    root.window = lg
                    // how much of its spot lies under other windows of its workspace (0..1)
                    let hidden = 0
                    if (lg) {
                        const area = Math.max(1, lg.size[0] * lg.size[1])
                        for (const c of all) {
                            if (c.address === lg.address || !c.mapped || c.hidden || c.workspace?.id !== lg.workspace?.id) continue
                            const ix = Math.min(lg.at[0] + lg.size[0], c.at[0] + c.size[0]) - Math.max(lg.at[0], c.at[0])
                            const iy = Math.min(lg.at[1] + lg.size[1], c.at[1] + c.size[1]) - Math.max(lg.at[1], c.at[1])
                            if (ix > 0 && iy > 0) hidden += ix * iy / area
                        }
                    }
                    root.covered = Math.min(1, hidden)
                } catch (e) { }
            }
        }
    }
    function refresh() { if (!clients.running) clients.running = true }
    Timer { id: soon; interval: 40; onTriggered: root.refresh() }
    Timer { interval: 1000; running: root.window !== null || root.running; repeat: true; onTriggered: root.refresh() }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            const n = event.name
            if (n === "configreloaded") root.probePlugin()
            if (n === "cybertiltframe") root.frameSignal = true
            if (n === "activewindowv2") { const a = String(event.data).trim(); root.activeAddress = a ? "0x" + a : "" }
            if (n.startsWith("openwindow") || n.startsWith("closewindow") || n.startsWith("movewindow")
                || n.startsWith("activewindow") || n.startsWith("fullscreen") || n.startsWith("pin")
                || n.startsWith("changefloatingmode") || n.startsWith("workspace") || n.startsWith("tag"))
                soon.restart()
        }
    }
    Component.onCompleted: { refresh(); probePlugin() }
}
