pragma Singleton
// Network status (NetworkManager) and throughput (/proc/net/dev).
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property string kind: ""      // "wifi", "ethernet" or ""
    property string name: ""      // connection / SSID
    property bool online: false
    property real down: 0         // bytes per second
    property real up: 0
    property var last: null

    Process {
        id: nm
        command: ["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "device"]
        stdout: StdioCollector {
            onStreamFinished: {
                const rows = text.trim().split("\n").map(l => l.split(":"))
                const live = rows.find(r => r[1] === "connected" && (r[0] === "wifi" || r[0] === "ethernet"))
                root.online = !!live
                root.kind = live ? live[0] : ""
                root.name = live ? live.slice(2).join(":") : ""
            }
        }
    }
    Timer { interval: 15000; running: true; repeat: true; triggeredOnStart: true; onTriggered: nm.running = true }

    FileView { id: dev; path: "/proc/net/dev" }
    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            dev.reload()
            let rx = 0, tx = 0
            for (const line of dev.text().split("\n").slice(2)) {
                const [iface, rest] = line.split(":")
                if (!rest || /^\s*(lo|virbr|veth|docker|br-)/.test(iface)) continue
                const f = rest.trim().split(/\s+/).map(Number)
                rx += f[0]; tx += f[8]
            }
            const now = Date.now()
            if (root.last) {
                const s = (now - root.last.t) / 1000
                root.down = Math.max(0, (rx - root.last.rx) / s)
                root.up = Math.max(0, (tx - root.last.tx) / s)
            }
            root.last = { rx, tx, t: now }
        }
    }

    function rate(bps) {
        if (bps >= 1048576) return (bps / 1048576).toFixed(1) + " MB/s"
        if (bps >= 1024) return Math.round(bps / 1024) + " KB/s"
        return Math.round(bps) + " B/s"
    }
}
