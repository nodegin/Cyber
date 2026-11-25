// A segmented level meter (0..1).
import QtQuick
import qs

Item {
    id: root
    property real value: 0
    property color color: Theme.cyan
    property color warn: Theme.red
    property real warnAt: 0.85
    property int segments: 20
    property int gap: 2
    implicitHeight: 6

    Row {
        anchors.fill: parent
        spacing: root.gap
        Repeater {
            model: root.segments
            Rectangle {
                required property int index
                readonly property bool lit: (index + 0.5) / root.segments <= root.value
                width: (root.width - (root.segments - 1) * root.gap) / root.segments
                height: root.height
                color: !lit ? Theme.faint : root.value >= root.warnAt ? root.warn : root.color
            }
        }
    }
}
