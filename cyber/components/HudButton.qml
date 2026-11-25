// A small chamfered HUD button: an icon, optional text, optional key hint underneath.
import QtQuick
import qs

Frame {
    id: root
    property string icon: ""
    property string label: ""
    property string hint: ""                 // key hint shown in the corner
    property bool active: false              // lit (e.g. muted / recording)
    property color accent: Theme.cyan
    signal clicked()
    signal rightClicked()
    signal wheel(int delta)

    implicitWidth: row.implicitWidth + 22
    implicitHeight: 34
    cut: 8
    fill: area.containsMouse ? Theme.alpha(accent, 0.18) : active ? Theme.alpha(accent, 0.12) : Theme.glass
    stroke: Theme.alpha(active || area.containsMouse ? accent : Theme.fg, active || area.containsMouse ? 0.9 : 0.28)

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 7
        Icon { name: root.icon; visible: root.icon !== ""; color: root.active ? root.accent : Theme.fg; size: 17 }
        HudText { text: root.label; visible: root.label !== ""; font.pixelSize: Theme.textSmall; color: root.active ? root.accent : Theme.fg }
    }
    HudText {
        visible: root.hint !== ""
        text: root.hint
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 3; bottomMargin: 0 }
        font.pixelSize: 8
        color: Theme.dim
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: e => e.button === Qt.RightButton ? root.rightClicked() : root.clicked()
        onWheel: e => root.wheel(e.angleDelta.y)
    }
}
