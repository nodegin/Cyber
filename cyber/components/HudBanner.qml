// A status banner: a blinking warning triangle, a tab beside it, and a panel that slides out of the
// tab with one line of text ("RECORDING STARTED"). Its shape, red, type and motion follow the banner
// the user chose as the model, measured from a video of it (2026-11-25): the numbers below are that
// banner's pixels. Drawn here from scratch; the typeface is Rajdhani Bold (open licence, in the
// fonts folder).
//   HudBanner { title: "RECORDING STARTED"; active: true }
// active: it plays in (the triangle at once, then the tab, then the panel slides out and the text
// comes up); turning it off fades everything out. busy: something of it is still on screen.
import QtQuick
import QtQuick.Shapes
import qs

Item {
    id: root
    property string title: ""
    property color tone: Theme.alert
    property bool active: false
    // the panel's glass: the model's dark maroon for its red; for another colour a dark shade of that colour
    readonly property color glass: Qt.colorEqual(tone, Theme.alert) ? Qt.rgba(0.157, 0.090, 0.102, 0.94)
                                                                    : Qt.rgba(0.045 + tone.r * 0.085, 0.045 + tone.g * 0.085, 0.05 + tone.b * 0.085, 0.94)
    readonly property bool busy: active || opacity > 0.01

    // ---- measures
    readonly property real panelX: 63.5             // where the panel begins: after the triangle, a gap and the tab
    readonly property real fullW: Math.max(444, panelX + label.implicitWidth + 2 * 56)
    readonly property real y0: 0.75
    readonly property real y1: 45.75
    property real out: 0                            // 0 = the tab alone .. 1 = the panel fully out
    readonly property real edge: panelX + (fullW - panelX) * out          // the panel's right edge now
    readonly property real cut: Math.min(12, Math.max(0, edge - panelX))  // its cut lower corner
    property bool tab: false
    property bool lit: true                         // the triangle blinks
    implicitWidth: fullW
    implicitHeight: 46.5
    opacity: 0

    // ---- the sequence
    function start() { leave.stop(); out = 0; tab = false; lit = true; opacity = 1; play.restart() }
    onActiveChanged: { if (active) start(); else { play.stop(); leave.restart() } }
    Component.onCompleted: if (active) start()
    SequentialAnimation {
        id: play
        PauseAnimation { duration: 110 }
        ScriptAction { script: root.tab = true }
        PauseAnimation { duration: 170 }
        NumberAnimation { target: root; property: "out"; from: 0; to: 1; duration: 300; easing.type: Easing.OutCubic }
    }
    NumberAnimation { id: leave; target: root; property: "opacity"; to: 0; duration: 140 }
    Timer { running: root.busy; interval: 100; repeat: true; onTriggered: root.lit = root.lit ? Math.random() < 0.55 : true }

    // ---- the warning triangle, with its four small ticks
    Item {
        width: 42; height: 46
        opacity: root.lit ? 1 : 0.5
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: root.tone
                strokeWidth: 3.2
                fillColor: "transparent"
                joinStyle: ShapePath.MiterJoin
                startX: 21; startY: 5
                PathLine { x: 39.4; y: 36.5 }
                PathLine { x: 2.6; y: 36.5 }
                PathLine { x: 21; y: 5 }
            }
        }
        Rectangle { x: 19.5; y: 16; width: 3; height: 12; color: root.tone }
        Rectangle { x: 19.5; y: 30.5; width: 3; height: 3; color: root.tone }
        Repeater {
            model: [[9, 3], [28.5, 3], [9, 42.5], [28, 42.5]]
            Rectangle { required property var modelData; x: modelData[0]; y: modelData[1]; width: 5; height: 1.5; color: Theme.alpha(root.tone, 0.7) }
        }
    }

    // ---- the tab and the panel
    Shape {
        anchors.fill: parent
        visible: root.tab
        preferredRendererType: Shape.CurveRenderer
        ShapePath {     // the panel's glass
            strokeColor: "transparent"
            strokeWidth: 0
            fillColor: root.glass
            startX: root.panelX; startY: root.y0
            PathLine { x: root.edge; y: root.y0 }
            PathLine { x: root.edge; y: root.y1 - root.cut }
            PathLine { x: root.edge - root.cut; y: root.y1 }
            PathLine { x: root.panelX; y: root.y1 }
            PathLine { x: root.panelX; y: root.y0 }
        }
        ShapePath {     // the outline, round the tab and the panel: cut corners at the left, a long cut lower right
            strokeColor: Theme.alpha(root.tone, 0.85)
            strokeWidth: 1.5
            fillColor: "transparent"
            joinStyle: ShapePath.MiterJoin
            startX: 58; startY: root.y0
            PathLine { x: root.edge; y: root.y0 }
            PathLine { x: root.edge; y: root.y1 - root.cut }
            PathLine { x: root.edge - root.cut; y: root.y1 }
            PathLine { x: 55.5; y: root.y1 }
            PathLine { x: 52.75; y: root.y1 - 2.75 }
            PathLine { x: 52.75; y: root.y0 + 4 }
            PathLine { x: 58; y: root.y0 }
        }
        ShapePath {     // the line between the tab and the panel
            strokeColor: Theme.alpha(root.tone, 0.85)
            strokeWidth: 1.5
            fillColor: "transparent"
            startX: root.panelX; startY: root.y0
            PathLine { x: root.panelX; y: root.y1 }
        }
        ShapePath {     // the tab: a solid bar, a little wider at its ends
            strokeColor: "transparent"
            strokeWidth: 0
            fillColor: root.tone
            startX: 55; startY: 3
            PathLine { x: 63; y: 3 }
            PathLine { x: 63; y: 9 }
            PathLine { x: 61.5; y: 9 }
            PathLine { x: 61.5; y: 37.5 }
            PathLine { x: 63; y: 37.5 }
            PathLine { x: 63; y: 43.5 }
            PathLine { x: 55; y: 43.5 }
            PathLine { x: 55; y: 3 }
        }
    }

    // ---- the text: in the middle of the panel, uncovered as the panel slides out
    Item {
        x: root.panelX
        width: Math.max(0, root.edge - root.panelX)
        height: parent.height
        clip: true
        visible: root.tab
        Text {
            id: label
            x: (root.fullW - root.panelX - implicitWidth) / 2
            y: (parent.height - implicitHeight) / 2 + 1
            text: root.title
            color: root.tone
            opacity: Math.max(0, Math.min(1, (root.out - 0.6) / 0.4))
            font.family: Theme.banner
            font.pixelSize: 20
            font.weight: Font.Bold
            font.letterSpacing: 1.25
            font.capitalization: Font.AllUppercase
        }
    }
}
