pragma Singleton
// CPU, memory and uptime from /proc, every 2 s.
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property real cpu: 0          // 0..1
    property real memUsedGb: 0
    property real memTotalGb: 0
    readonly property real mem: memTotalGb > 0 ? memUsedGb / memTotalGb : 0
    property int uptimeSec: 0
    // GPU load 0..1 (-1 = this GPU does not report it): the average of the kernel's busy samples
    // over the last 2 s. With FPS it tells whether the desktop is held back by the GPU: FPS below 60
    // with the GPU well under 100% only means nothing asked for more frames.
    property real gpu: -1
    property string gpuPath: ""
    property var gpuSamples: []
    property var lastCpu: null


    FileView { id: stat; path: "/proc/stat" }
    FileView { id: meminfo; path: "/proc/meminfo" }
    FileView { id: uptime; path: "/proc/uptime" }
    FileView { id: gpuBusy; path: root.gpuPath }
    Process {
        running: true
        command: ["sh", "-c", "ls /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -1"]
        stdout: SplitParser { onRead: line => root.gpuPath = line.trim() }
    }
    Timer {
        interval: 250; repeat: true; running: root.gpuPath !== ""
        onTriggered: {
            gpuBusy.reload()
            const v = parseInt(gpuBusy.text())
            if (!isNaN(v)) root.gpuSamples.push(v)
        }
    }

    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            stat.reload(); meminfo.reload(); uptime.reload()
            const m = stat.text().match(/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/)
            if (m) {
                const v = m.slice(1).map(Number)
                const total = v.reduce((a, b) => a + b, 0), idle = v[3] + v[4]
                if (root.lastCpu && total > root.lastCpu.total)
                    root.cpu = 1 - (idle - root.lastCpu.idle) / (total - root.lastCpu.total)
                root.lastCpu = { total, idle }
            }
            const t = meminfo.text()
            const kb = key => Number(t.match(new RegExp(key + ":\\s*(\\d+)"))?.[1] ?? 0)
            root.memTotalGb = kb("MemTotal") / 1048576
            root.memUsedGb = (kb("MemTotal") - kb("MemAvailable")) / 1048576
            root.uptimeSec = Math.floor(parseFloat(uptime.text()) || 0)
            if (root.gpuSamples.length) {
                root.gpu = root.gpuSamples.reduce((a, b) => a + b, 0) / root.gpuSamples.length / 100
                root.gpuSamples = []
            }
        }
    }

    function clock(sec) {
        const p = n => String(n).padStart(2, "0")
        return `${p(Math.floor(sec / 3600))}:${p(Math.floor(sec / 60) % 60)}:${p(sec % 60)}`
    }
}
