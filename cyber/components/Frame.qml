// A chamfered HUD panel: dark glass with a thin neon edge and cut corners.
import QtQuick
import QtQuick.Shapes
import qs

Item {
    id: root
    property color fill: Theme.glass
    property color stroke: Theme.alpha(Theme.cyan, 0.5)
    property real strokeWidth: 1
    property int cut: Theme.cut
    property bool cutTopLeft: false
    property bool cutTopRight: true
    property bool cutBottomRight: false
    property bool cutBottomLeft: true
    default property alias content: inner.data

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            id: path
            fillColor: root.fill
            strokeColor: root.stroke
            strokeWidth: root.strokeWidth
            joinStyle: ShapePath.MiterJoin
            readonly property real tl: root.cutTopLeft ? root.cut : 0
            readonly property real tr: root.cutTopRight ? root.cut : 0
            readonly property real br: root.cutBottomRight ? root.cut : 0
            readonly property real bl: root.cutBottomLeft ? root.cut : 0
            readonly property real w: root.width - 0.5
            readonly property real h: root.height - 0.5
            startX: 0.5 + tl; startY: 0.5
            PathLine { x: path.w - path.tr; y: 0.5 }
            PathLine { x: path.w; y: 0.5 + path.tr }
            PathLine { x: path.w; y: path.h - path.br }
            PathLine { x: path.w - path.br; y: path.h }
            PathLine { x: 0.5 + path.bl; y: path.h }
            PathLine { x: 0.5; y: path.h - path.bl }
            PathLine { x: 0.5; y: 0.5 + path.tl }
            PathLine { x: 0.5 + path.tl; y: 0.5 }
        }
    }
    Item { id: inner; anchors.fill: parent }
}
