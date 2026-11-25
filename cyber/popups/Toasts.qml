// Notification popups, top right under the band. Click one to dismiss it.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import qs
import qs.components
import qs.services

PanelWindow {
    id: win
    visible: Notifs.popups.length > 0
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
    anchors { top: true; right: true }
    margins { top: 8; right: 10 }
    implicitWidth: 400
    implicitHeight: Math.max(1, column.implicitHeight)
    exclusiveZone: 0
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:toasts"

    Column {
        id: column
        width: parent.width
        spacing: 8
        Repeater {
            model: Notifs.popups
            Glitch {
                id: toastFx
                required property var modelData
                active: true
                speed: 1.3
                width: column.width
                height: toast.height
            Frame {
                id: toast
                readonly property var modelData: toastFx.modelData
                readonly property bool critical: modelData.urgency === NotificationUrgency.Critical
                width: column.width
                height: body.implicitHeight + 26
                fill: Theme.glassHi
                stroke: Theme.alpha(critical ? Theme.red : Theme.cyan, 0.75)
                cutTopLeft: true; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false

                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Notifs.dismiss(toast.modelData) }
                Rectangle { width: 3; height: parent.height - 24; y: 12; color: toast.critical ? Theme.red : Theme.cyan }

                Row {
                    id: body
                    x: 16; y: 13
                    width: parent.width - 30
                    spacing: 12
                    IconImage {
                        id: picture
                        readonly property string src: toast.modelData.image || (toast.modelData.appIcon ? Quickshell.iconPath(toast.modelData.appIcon, true) : "")
                        visible: src !== ""
                        source: src
                        implicitSize: 40
                    }
                    Column {
                        width: body.width - (picture.visible ? 52 : 0)
                        spacing: 4
                        HudText {
                            width: parent.width
                            text: (toast.modelData.appName || "SYSTEM") + (toast.critical ? " // PRIORITY" : " // MSG")
                            font.pixelSize: 9
                            color: toast.critical ? Theme.red : Theme.dim
                        }
                        Text {
                            width: parent.width
                            text: toast.modelData.summary
                            font.family: Theme.display
                            font.pixelSize: 15
                            font.weight: Font.DemiBold
                            color: Theme.fg
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            visible: text !== ""
                            text: toast.modelData.body
                            textFormat: Text.StyledText
                            font.family: Theme.mono
                            font.pixelSize: 12
                            color: Theme.alpha(Theme.fg, 0.8)
                            wrapMode: Text.Wrap
                            maximumLineCount: 4
                            elide: Text.ElideRight
                            linkColor: Theme.cyan
                            onLinkActivated: link => Qt.openUrlExternally(link)
                        }
                        Row {
                            visible: toast.modelData.actions.length > 0
                            spacing: 6
                            topPadding: 4
                            Repeater {
                                model: toast.modelData.actions
                                HudButton {
                                    required property var modelData
                                    label: modelData.text
                                    implicitHeight: 26
                                    onClicked: { modelData.invoke(); Notifs.removePopup(toast.modelData) }
                                }
                            }
                        }
                    }
                }
            }
            }
        }
    }
}
