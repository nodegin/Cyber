// The "damaged screen" edge effect (shaders/damage.frag): a glow with scanlines, tearing and dead
// blocks around the screen's edges, plus an optional veil over everything. Fill a full-screen layer.
//   DamageFx { anchors.fill: parent; tint: Theme.red; veil: 0.35; damage: 1 }
import QtQuick
import qs

ShaderEffect {
    id: root
    property color tint: Theme.cyan
    property real strength: 1
    property real veil: 0
    property real damage: 0.5
    property real edgeWidth: 0.22
    property real time: 0
    property point pxSize: Qt.point(width, height)
    fragmentShader: Qt.resolvedUrl("../shaders/damage.frag.qsb")

    NumberAnimation on time {
        running: root.visible && root.opacity > 0 && root.strength > 0
        from: 0; to: 1000; duration: 1000 * 1000; loops: Animation.Infinite
    }
}
