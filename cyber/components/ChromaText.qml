// Text with an RGB split (red fringe left, cyan right) that jumps now and then, like a signal
// that doesn't quite line up.
import QtQuick
import qs

Item {
    id: root
    property string text: ""
    property alias font: main.font
    property color color: Theme.fg
    property real split: 1.2
    property real dx: 0
    implicitWidth: main.implicitWidth
    implicitHeight: main.implicitHeight

    Timer {
        interval: 70; repeat: true; running: root.visible
        onTriggered: root.dx = Math.random() < 0.1 ? (Math.random() - 0.5) * 5 : 0
    }
    Text { x: -root.split - root.dx; text: root.text; font: main.font; color: Theme.alpha(Theme.red, 0.85) }
    Text { x: root.split + root.dx * 0.6; text: root.text; font: main.font; color: Theme.alpha(Theme.cyan, 0.85) }
    Text { id: main; x: root.dx * 0.3; text: root.text; color: root.color }
}
