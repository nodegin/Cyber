// One key of the keybinds card (popups/Help.qml): a key cap with what the key does beside it.
//   KeyCap { cap: "E"; label: "FILES" }
// Every cap has the same letter size and is as wide as its text needs (a single letter: 38 px).
// The look follows the card that was picked as the model, measured from a picture of it: a cap
// with its top-left and bottom-right corners cut, a grey-blue edge, a faint lighter fill, a
// near-white bold letter; the label in a bold green-teal.
import QtQuick
import qs

Row {
    id: root
    property string cap: ""
    property string label: ""
    height: 32
    spacing: 14

    Frame {
        width: Math.max(38, capText.implicitWidth + 24)
        height: 32
        cut: 7
        cutTopLeft: true; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false
        fill: Qt.rgba(0.55, 0.63, 0.71, 0.15)
        stroke: Qt.rgba(0.53, 0.60, 0.66, 0.92)
        strokeWidth: 1.5
        Text {
            id: capText
            anchors.centerIn: parent
            text: root.cap
            color: "#d8e1e8"
            font.family: Theme.banner
            font.pixelSize: 16
            font.weight: Font.Bold
            font.letterSpacing: 0.8
        }
    }
    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: "#52c4c2"
        font.family: Theme.banner
        font.pixelSize: 17
        font.weight: Font.Bold
        font.letterSpacing: 0.9
    }
}
