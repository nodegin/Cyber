// The top band (reserved space; windows never cover it):
//   left: workspace number, FPS, uptime, CPU, RAM, GPU  ·  centre: workspace rail + active window
//   right: clock, date, network
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.components
import qs.services

PanelWindow {
    id: band
    required property var modelData
    screen: modelData
    visible: !Ui.hudHidden || bandFx.busy
    anchors { top: true; left: true; right: true }
    implicitHeight: Theme.bandTop
    exclusiveZone: Ui.hudHidden ? 0 : Theme.bandTop
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "cyber:hud"

    readonly property var monitor: Hyprland.monitorFor(modelData)
    readonly property int wsId: monitor?.activeWorkspace?.id ?? 1
    // a short glitch when the workspace changes (badge + title jitter, then settle)
    property real glitch: 0
    onWsIdChanged: glitchAnim.restart()
    NumberAnimation { id: glitchAnim; target: band; property: "glitch"; from: 1; to: 0; duration: 320; easing.type: Easing.OutQuad }

    Glitch {
        id: bandFx
        anchors.fill: parent
        active: !Ui.hudHidden
        speed: 0.8

        // ---------------------------------------------------------------- left: system block
        Frame {
            id: sys
            anchors { left: parent.left; top: parent.top; leftMargin: 10; topMargin: 8 }
            width: sysRow.x + sysRow.width + 26      // as wide as what is in it (plus room for the cut corner)
            height: 40
            cutTopLeft: true; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false

            Frame {
                id: badge
                width: 48
                height: parent.height
                cut: 10
                cutTopLeft: true; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false
                fill: band.glitch > 0.5 && Math.random() < 0.5 ? Theme.cyan : Theme.alpha(Theme.red, 0.9)
                stroke: Theme.red
                transform: Translate { x: (Math.random() - 0.5) * 10 * band.glitch; y: (Math.random() - 0.5) * 3 * band.glitch }
                Text {
                    anchors.centerIn: parent
                    text: band.wsId
                    font.family: Theme.display
                    font.pixelSize: 24
                    font.weight: Font.Bold
                    color: Theme.ink
                }
            }
            Row {
                id: sysRow
                x: badge.width + 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 18
                Column {   // refreshes served on time in the last second: 60 = no frame came late (services/Fps.qml)
                    spacing: 3
                    width: 30
                    HudText { text: "FPS"; font.pixelSize: 9; color: Theme.dim }
                    HudText { text: Fps.of(band.monitor?.name ?? ""); font.pixelSize: 13; color: Theme.cyan }
                }
                Column {
                    spacing: 3
                    HudText { text: "UPTIME"; font.pixelSize: 9; color: Theme.dim }
                    HudText { text: Sys.clock(Sys.uptimeSec); font.pixelSize: 13; color: Theme.yellow }
                }
                Column {
                    spacing: 4
                    Row {
                        spacing: 8
                        HudText { text: "CPU"; font.pixelSize: 9; color: Theme.dim }
                        HudText { text: Math.round(Sys.cpu * 100) + "%"; font.pixelSize: 9 }
                    }
                    Meter { width: 120; height: 6; value: Sys.cpu; segments: 16 }
                }
                Column {
                    spacing: 4
                    Row {
                        spacing: 8
                        HudText { text: "RAM"; font.pixelSize: 9; color: Theme.dim }
                        HudText { text: Sys.memUsedGb.toFixed(1) + " / " + Sys.memTotalGb.toFixed(0) + " GB"; font.pixelSize: 9 }
                    }
                    Meter { width: 150; height: 6; value: Sys.mem; segments: 20; color: Theme.green }
                }
                Column {   // GPU load (services/Sys.qml)
                    visible: Sys.gpu >= 0
                    spacing: 4
                    Row {
                        spacing: 8
                        HudText { text: "GPU"; font.pixelSize: 9; color: Theme.dim }
                        HudText { text: Math.round(Sys.gpu * 100) + "%"; font.pixelSize: 9 }
                    }
                    Meter { width: 90; height: 6; value: Sys.gpu; segments: 12; color: Sys.gpu > 0.9 ? Theme.red : Theme.yellow }
                }
            }
        }

        // ---------------------------------------------------------------- centre: rail
        Item {
            id: rail
            anchors.horizontalCenter: parent.horizontalCenter
            y: 6
            width: Math.min(900, band.width - 2 * 520)
            height: 44

            Rectangle { y: 9; width: parent.width; height: 1; color: Theme.alpha(Theme.red, 0.65) }
            Repeater {
                model: 25
                Rectangle {
                    required property int index
                    x: index * (rail.width - 1) / 24
                    y: index % 6 === 0 ? 3 : 6
                    width: 1
                    height: index % 6 === 0 ? 13 : 7
                    color: Theme.alpha(Theme.red, 0.65)
                }
            }
            // active window title in the middle of the rail
            Frame {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 1
                height: 17
                width: Math.min(title.implicitWidth + 36, rail.width * 0.6)
                cut: 6
                cutTopLeft: true; cutTopRight: true; cutBottomRight: false; cutBottomLeft: false
                fill: Theme.alpha(Theme.red, 0.88)
                stroke: Theme.red
                transform: Translate { x: (Math.random() - 0.5) * 16 * band.glitch }
                HudText {
                    id: title
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - 20)
                    text: ToplevelManager.activeToplevel?.title || "NO SIGNAL // 待機"
                    caps: false
                    font.pixelSize: 10
                    font.letterSpacing: 1
                    color: Theme.ink
                }
            }
            // workspaces 1-10: lit = here, outline = has windows
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 25
                spacing: 6
                Repeater {
                    model: 10
                    Frame {
                        id: pip
                        required property int index
                        readonly property int ws: index + 1
                        readonly property bool here: ws === band.wsId
                        readonly property bool used: Hyprland.workspaces.values.some(w => w.id === ws && (w.toplevels?.values?.length ?? 0) > 0)
                        width: Ui.superHeld ? 22 : 16
                        height: 14
                        cut: 4
                        fill: here ? Theme.cyan : used ? Theme.alpha(Theme.cyan, 0.22) : Theme.alpha(Theme.ink, 0.55)
                        stroke: here || used ? Theme.cyan : Theme.dim
                        Behavior on width { NumberAnimation { duration: 120 } }
                        HudText {
                            anchors.centerIn: parent
                            visible: Ui.superHeld
                            text: pip.ws % 10
                            font.pixelSize: 9
                            font.letterSpacing: 0
                            color: pip.here ? Theme.ink : Theme.fg
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Hyprland.dispatch(`hl.dsp.focus({ workspace = ${pip.ws} })`)
                        }
                    }
                }
            }
        }

        // ---------------------------------------------------------------- right: time block
        Frame {
            anchors { right: parent.right; top: parent.top; rightMargin: 10; topMargin: 8 }
            width: timeRow.implicitWidth + 36
            height: 40
            cutTopLeft: false; cutTopRight: true; cutBottomRight: false; cutBottomLeft: true

            Row {
                id: timeRow
                anchors.centerIn: parent
                spacing: 16
                Clock { size: 24; anchors.verticalCenter: parent.verticalCenter; color: Theme.cyan }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3
                    HudText {
                        id: date
                        text: Qt.formatDate(dateClock.date, "ddd dd MMM yyyy")
                        font.pixelSize: 10
                        SystemClock { id: dateClock; precision: SystemClock.Minutes }
                    }
                    Row {
                        spacing: 6
                        Icon {
                            name: !Net.online ? "signal_disconnected" : Net.kind === "wifi" ? "wifi" : "lan"
                            size: 12
                            color: Net.online ? Theme.green : Theme.red
                        }
                        HudText {
                            text: Net.online ? `${Net.name}  ▼ ${Net.rate(Net.down)}  ▲ ${Net.rate(Net.up)}` : "OFFLINE"
                            font.pixelSize: 9
                            color: Theme.dim
                        }
                    }
                }
            }
        }
    }
}
