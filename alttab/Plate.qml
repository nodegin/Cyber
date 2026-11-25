// The background of the switcher's panel and of its cards, in either look:
//   cut = 0: a rounded rectangle (end-4/pC's look)
//   cut > 0: a plate with its top-left and bottom-right corners cut (Cyber's HUD look)
import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property color fill: "transparent"
    property color stroke: "transparent"
    property real strokeWidth: 0
    property real radius: 0
    property real cut: 0

    Rectangle {
        visible: root.cut <= 0
        anchors.fill: parent
        radius: root.radius
        color: root.fill
        border.width: root.strokeWidth
        border.color: root.stroke
    }
    Shape {
        visible: root.cut > 0
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            id: path
            readonly property real o: Math.max(0.5, root.strokeWidth / 2)
            readonly property real w: root.width - o
            readonly property real h: root.height - o
            fillColor: root.fill
            strokeColor: root.strokeWidth > 0 ? root.stroke : "transparent"
            strokeWidth: Math.max(0.01, root.strokeWidth)
            joinStyle: ShapePath.MiterJoin
            startX: path.o + root.cut; startY: path.o
            PathLine { x: path.w; y: path.o }
            PathLine { x: path.w; y: path.h - root.cut }
            PathLine { x: path.w - root.cut; y: path.h }
            PathLine { x: path.o; y: path.h }
            PathLine { x: path.o; y: path.o + root.cut }
            PathLine { x: path.o + root.cut; y: path.o }
        }
    }
}
