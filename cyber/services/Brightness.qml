pragma Singleton
// Screen brightness through brightnessctl (laptop panels; most desktop monitors have none).
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property real value: -1      // 0..1, -1 = no backlight
    signal osd()

    function change(step) {   // step: +0.05 / -0.05
        const pct = Math.round(Math.abs(step) * 100) + (step < 0 ? "%-" : "%+")
        run.command = ["brightnessctl", "-m", "s", pct]
        run.running = true
    }

    Process {
        id: run
        stdout: StdioCollector {
            onStreamFinished: {
                // brightnessctl -m: device,class,current,percent,max
                const pct = text.trim().split(",")[3]
                if (pct) { root.value = parseInt(pct) / 100; root.osd() }
            }
        }
    }
}
