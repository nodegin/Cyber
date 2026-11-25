// Red warning stripes: diagonal bars on transparent.
// Built from plain rectangles rather than a Canvas: a Canvas sometimes came back blank (black)
// when its popup was shown again.
import QtQuick
import qs

Item {
    id: root
    property color color: Theme.alpha(Theme.red, 0.85)
    property real period: 22      // distance between bars
    property real bar: 9          // bar width, measured along the stripe
    clip: true

    Repeater {
        model: Math.ceil((root.width + root.height) / root.period) + 2
        Rectangle {
            required property int index
            readonly property real cx: -root.height + index * root.period + root.height / 2 + root.bar / 2
            width: root.bar / Math.SQRT2
            height: root.height * Math.SQRT2 + 4
            x: cx - width / 2
            y: (root.height - height) / 2
            rotation: 45
            antialiasing: true
            color: root.color
        }
    }
}
