pragma Singleton
// The FPS readout, per monitor: how many of the screen's refreshes in the last second were served
// on time. 60 on a 60 Hz screen means no frame came late; every refresh a frame missed takes one off.
// It is not "frames drawn": Hyprland only draws when something changed, so a calm desktop draws
// 15-40 frames a second (the wallpaper, a clock) and is still perfectly smooth.
// Measured inside the compositor by the corners plugin (hypr/corners: it times every frame from the
// start of its rendering to the moment the screen shows it), which posts
//   cyberfps>>MONITOR,FPS,DRAWN,LATE,REFRESH
// on Hyprland's event socket once a second: no polling, and nothing is redrawn to measure it.
import QtQuick
import Quickshell
import Quickshell.Hyprland

Singleton {
    id: root
    property var byMonitor: ({})          // name -> { fps, drawn, late, refresh }
    function of(name) { return root.byMonitor[name]?.fps ?? 0 }
    function drawn(name) { return root.byMonitor[name]?.drawn ?? 0 }     // frames Hyprland drew
    function late(name) { return root.byMonitor[name]?.late ?? 0 }       // refreshes a frame missed

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "cyberfps") return
            const p = String(event.data).split(",")
            if (p.length < 2) return
            const next = Object.assign({}, root.byMonitor)
            next[p[0]] = {
                fps: Number(p[1]) || 0,
                drawn: Number(p[2] ?? p[1]) || 0,
                late: Number(p[3]) || 0,
                refresh: Number(p[4]) || 0
            }
            root.byMonitor = next
            stale.restart()
        }
    }
    // no report for a while = nothing was drawn, so nothing was late either
    Timer {
        id: stale
        interval: 2500
        onTriggered: {
            const next = {}
            for (const name in root.byMonitor) {
                const m = root.byMonitor[name]
                next[name] = { fps: m.refresh || m.fps, drawn: 0, late: 0, refresh: m.refresh }
            }
            root.byMonitor = next
        }
    }
}
