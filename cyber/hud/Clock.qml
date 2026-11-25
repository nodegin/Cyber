// HH:MM in the Kleemax display font. Kleemax has no colon glyph, so the colon is drawn.
import QtQuick
import Quickshell
import qs
import qs.components

Row {
    id: root
    property int size: 26
    property color color: Theme.fg
    property date now: clock.date
    spacing: Math.round(size * 0.18)

    SystemClock { id: clock; precision: SystemClock.Seconds }

    Text {
        text: Qt.formatTime(root.now, "hh")
        font.family: Theme.clock
        font.pixelSize: root.size
        color: root.color
    }
    Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Math.round(root.size * 0.22)
        Repeater {
            model: 2
            Rectangle {
                width: Math.max(3, Math.round(root.size * 0.13)); height: width
                color: root.now.getSeconds() % 2 ? Theme.alpha(root.color, 0.35) : root.color
            }
        }
    }
    Text {
        text: Qt.formatTime(root.now, "mm")
        font.family: Theme.clock
        font.pixelSize: root.size
        color: root.color
    }
}
