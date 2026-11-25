pragma Singleton
// What this machine has, for the HUD buttons that only make sense with it:
//   bluetooth:     a Bluetooth adapter (something in /sys/class/bluetooth; a switched-off one counts)
//   lookingGlass:  the Looking Glass client is installed (looking-glass-client is on the PATH)
// Looked up when the shell starts and every half minute (a USB adapter can be plugged in later).
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root
    property bool bluetooth: false
    property bool lookingGlass: false

    Process {
        id: look
        command: ["sh", "-c", 'ls /sys/class/bluetooth 2>/dev/null | grep -q . && echo bluetooth; command -v looking-glass-client >/dev/null 2>&1 && echo lookingglass; true']
        stdout: StdioCollector {
            onStreamFinished: {
                const found = text.split("\n")
                root.bluetooth = found.includes("bluetooth")
                root.lookingGlass = found.includes("lookingglass")
            }
        }
    }
    Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true; onTriggered: look.running = true }
}
