// A column of hex "data" scrolling up (decoration), fading toward the top.
import QtQuick
import qs

Column {
    id: root
    property int lines: 24
    property color color: Theme.cyan
    property var rows: []
    spacing: 3

    function line() {
        const hex = (n, w) => Math.floor(Math.random() * n).toString(16).toUpperCase().padStart(w, "0")
        let s = "0x" + hex(0xffff, 4) + "  "
        for (let i = 0; i < 6; i++) s += hex(256, 2) + " "
        return s
    }
    Timer {
        interval: 110; repeat: true; running: root.visible
        onTriggered: root.rows = root.rows.concat([root.line()]).slice(-root.lines)
    }
    Component.onCompleted: { const r = []; for (let i = 0; i < lines; i++) r.push(line()); rows = r }

    Repeater {
        model: root.rows
        HudText {
            required property var modelData
            required property int index
            text: modelData
            font.pixelSize: 10
            font.letterSpacing: 1
            color: Theme.alpha(Math.random() < 0.06 ? Theme.red : root.color, 0.1 + 0.55 * index / root.lines)
        }
    }
}
