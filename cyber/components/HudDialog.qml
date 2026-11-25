// A HUD dialog panel. The same outline and glass as Cyber's terminal (ghostty/crt.glsl) and the
// corners plugin (cyber/hypr/corners): keep the numbers in step.
//   outline: a cut top-left corner, a small round top-right, the right edge stepping inwards
//            part-way down, a long cut bottom-right, a square bottom-left
//   glass:   a teal glow in the top-left corner falling off to dark navy
//   edge:    cool grey-blue, heavier along the top
// Header (title, "// subtitle", a rule) and a small footer; put the body inside.
//   HudDialog { title: "OPTICAL CAPTURE"; subtitle: "// SELECT MODE"; footer: "..."; Column { ... } }
import QtQuick
import QtQuick.Shapes
import qs

Item {
    id: root
    property string title: ""
    property string subtitle: ""
    property string footer: ""
    property int padding: 26
    readonly property real headerHeight: head.height + 18
    default property alias content: body.data

    // ---- the outline (pixels)
    readonly property real cut: 14          // top-left cut
    readonly property real round: 5         // top-right rounding
    readonly property real stepIn: 10       // how far the lower part of the right edge steps in
    readonly property real stepAt: 0.43     // where it steps, as a fraction of the height
    readonly property real bigCut: 38       // bottom-right cut
    // ---- the glass and the edge
    readonly property color teal: Qt.rgba(0.114, 0.263, 0.294, glass)    // #1d434b
    readonly property color navy: Qt.rgba(0.020, 0.078, 0.118, glass)    // #05141e
    property real glass: 0.88               // how opaque the glass is
    readonly property color edge: Qt.rgba(0.50, 0.60, 0.66, 0.9)         // #8099a8
    function mix(t) {   // teal -> navy
        return Qt.rgba(teal.r + (navy.r - teal.r) * t, teal.g + (navy.g - teal.g) * t, teal.b + (navy.b - teal.b) * t, glass)
    }

    implicitWidth: body.childrenRect.width + 2 * padding + stepIn
    implicitHeight: headerHeight + body.childrenRect.height + (footer ? 42 : 24) + padding

    Shape {
        id: shape
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        readonly property real w: root.width - 0.75
        readonly property real h: root.height - 0.75
        readonly property real stepY: Math.round(root.height * root.stepAt)

        ShapePath {
            strokeColor: root.edge
            strokeWidth: 1.5
            joinStyle: ShapePath.MiterJoin
            // the teal glow: from the top-left corner outwards, eased like the terminal's shader
            fillGradient: RadialGradient {
                centerX: 0; centerY: 0; focalX: 0; focalY: 0
                centerRadius: Math.max(260, 0.5 * Math.hypot(root.width, root.height))
                GradientStop { position: 0.00; color: root.mix(0) }
                GradientStop { position: 0.25; color: root.mix(0.156) }
                GradientStop { position: 0.50; color: root.mix(0.5) }
                GradientStop { position: 0.75; color: root.mix(0.844) }
                GradientStop { position: 1.00; color: root.mix(1) }
            }
            startX: root.cut; startY: 0.75
            PathLine { x: shape.w - root.round; y: 0.75 }                                  // top
            PathArc { x: shape.w; y: 0.75 + root.round; radiusX: root.round; radiusY: root.round }   // round top-right
            PathLine { x: shape.w; y: shape.stepY }                                        // right edge ...
            PathLine { x: shape.w - root.stepIn; y: shape.stepY + root.stepIn }            // ... stepping in
            PathLine { x: shape.w - root.stepIn; y: shape.h - root.bigCut }
            PathLine { x: shape.w - root.stepIn - root.bigCut; y: shape.h }                // long cut, bottom-right
            PathLine { x: 0.75; y: shape.h }                                               // bottom, square at the left
            PathLine { x: 0.75; y: root.cut }
            PathLine { x: root.cut; y: 0.75 }                                              // cut, top-left
        }
        ShapePath {   // the top edge, heavier
            strokeColor: root.edge
            strokeWidth: 2.6
            fillColor: "transparent"
            capStyle: ShapePath.FlatCap
            startX: root.cut; startY: 1.3
            PathLine { x: shape.w - root.round; y: 1.3 }
        }
    }

    Column {
        id: head
        x: root.padding
        y: 20
        width: root.width - 2 * root.padding - root.stepIn
        spacing: 6
        HudText {
            text: root.title
            font.family: Theme.display
            font.pixelSize: 17
            font.weight: Font.Bold
            font.letterSpacing: 1.5
            color: "#e4f7fb"
        }
        HudText {
            visible: root.subtitle !== ""
            text: root.subtitle
            font.pixelSize: 10
            color: Theme.alpha(Theme.teal, 0.85)
        }
        Rectangle { width: parent.width; height: 1; color: Theme.alpha(Theme.teal, 0.3) }
    }

    Item {
        id: body
        x: root.padding
        y: root.headerHeight + 14
        width: root.width - 2 * root.padding - root.stepIn
    }

    HudText {
        visible: root.footer !== ""
        x: root.padding
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14
        text: root.footer
        font.pixelSize: 8
        color: Theme.alpha(Theme.teal, 0.45)
    }
}
