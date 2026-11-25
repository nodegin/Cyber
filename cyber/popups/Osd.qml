// Volume / brightness popup above the bottom band; click-through.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.components
import qs.services

PanelWindow {
    id: win
    property string kind: "volume"
    property bool shown: false
    visible: shown || glitch.busy
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
    anchors.bottom: true
    margins.bottom: 24
    implicitWidth: 360
    implicitHeight: 58
    exclusiveZone: 0
    color: "transparent"
    mask: Region {}
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:osd"

    readonly property real value: kind === "volume" ? Audio.volume : Brightness.value
    readonly property bool off: kind === "volume" && Audio.muted

    function show(k) { kind = k; shown = true; hide.restart() }
    Timer { id: hide; interval: 1400; onTriggered: win.shown = false }
    Connections { target: Audio; function onOsd() { win.show("volume") } }
    Connections { target: Brightness; function onOsd() { win.show("brightness") } }

    Glitch {
        id: glitch
        active: win.shown
        anchors.fill: parent
        speed: 1.5
    Frame {
        anchors.fill: parent
        fill: Theme.glassHi
        Row {
            anchors.centerIn: parent
            spacing: 14
            Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: win.kind === "brightness" ? "brightness_6" : win.off ? "volume_off" : "volume_up"
                color: win.off ? Theme.red : Theme.cyan
                size: 22
            }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                HudText {
                    text: (win.kind === "volume" ? "AUDIO OUT" : "BRIGHTNESS") + (win.off ? " // MUTED" : "")
                    font.pixelSize: 9
                    color: win.off ? Theme.red : Theme.dim
                }
                Meter { width: 220; height: 8; value: Math.min(1, win.value); segments: 24; color: win.off ? Theme.faint : Theme.cyan }
            }
            HudText {
                anchors.verticalCenter: parent.verticalCenter
                text: Math.round(win.value * 100)
                font.family: Theme.display
                font.pixelSize: 20
                color: win.off ? Theme.dim : Theme.fg
            }
        }
    }
    }
}
