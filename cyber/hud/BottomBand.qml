// The bottom band (reserved space): quick buttons on the left, tray + launcher on the right.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Services.SystemTray
import Quickshell.Io
import qs
import qs.components
import qs.services

PanelWindow {
    id: band
    required property var modelData
    screen: modelData
    visible: !Ui.hudHidden || bandFx.busy
    anchors { bottom: true; left: true; right: true }
    implicitHeight: Theme.bandBottom
    exclusiveZone: Ui.hudHidden ? 0 : Theme.bandBottom
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "cyber:hud"

    function run(cmd) { Quickshell.execDetached(["sh", "-c", cmd]) }

    Glitch {
        id: bandFx
        anchors.fill: parent
        active: !Ui.hudHidden
        speed: 0.8

        // ---------------------------------------------------------------- quick buttons
        Row {
            anchors { left: parent.left; bottom: parent.bottom; leftMargin: 10; bottomMargin: 7 }
            spacing: 6
            HudButton {
                icon: Audio.muted ? "volume_off" : Audio.volume > 0.5 ? "volume_up" : "volume_down"
                label: Audio.muted ? "MUTED" : Math.round(Audio.volume * 100) + "%"
                active: Audio.muted
                accent: Theme.red
                onClicked: Audio.toggleMute()
                onRightClicked: band.run("pavucontrol-qt || pavucontrol")
                onWheel: d => { if (Audio.sink?.audio) Audio.sink.audio.volume = Math.max(0, Math.min(1.5, Audio.volume + (d > 0 ? 0.02 : -0.02))) }
            }
            HudButton {
                icon: Audio.micMuted ? "mic_off" : "mic"
                active: Audio.micMuted
                accent: Theme.red
                onClicked: Audio.toggleMic()
            }
            HudButton {
                icon: !Net.online ? "signal_disconnected" : Net.kind === "wifi" ? "wifi" : "lan"
                label: Net.online ? Net.name : "OFFLINE"
                active: !Net.online
                accent: Theme.red
                onClicked: band.run(`${Config.terminal} nmtui`)
            }
            HudButton {
                visible: Has.bluetooth      // only on a machine with a Bluetooth adapter (services/Has.qml)
                icon: "bluetooth"
                onClicked: band.run("kcmshell6 kcm_bluetooth || blueman-manager")
            }
            HudButton {   // screenshots and recordings (popups/Capture.qml); while one records: the time, and a click stops it
                icon: Recorder.recording ? "stop_circle" : "photo_camera"
                label: Recorder.recording ? Recorder.clock : ""
                hint: "PRTSC"
                active: Ui.captureOpen || Recorder.recording
                accent: Recorder.recording ? Theme.red : Theme.cyan
                onClicked: Recorder.recording ? Recorder.stop() : Ui.toggle("captureOpen")
            }
            HudButton {   // Looking Glass: the Windows VM's screen (services/LookingGlass.qml)
                visible: Has.lookingGlass   // only where its client is installed (services/Has.qml)
                icon: "desktop_windows"
                label: LookingGlass.vmRunning ? "" : "VM OFF"
                accent: Theme.yellow
                active: LookingGlass.running
                opacity: LookingGlass.vmRunning || LookingGlass.running ? 1 : 0.55
                onClicked: if (LookingGlass.running || LookingGlass.vmRunning) LookingGlass.toggle()
            }
            HudButton {
                icon: "power_settings_new"
                accent: Theme.red
                active: Ui.powerOpen
                onClicked: Ui.toggle("powerOpen")
            }
        }

        // ---------------------------------------------------------------- now playing (click: control panel)
        Frame {
            visible: Media.player !== null
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 7 }
            width: Math.min(nowRow.implicitWidth + 28, 620)
            height: 34
            cut: 8
            stroke: Theme.alpha(Theme.mag, 0.55)
            Row {
                id: nowRow
                anchors.centerIn: parent
                spacing: 10
                Icon { name: Media.playing ? "graphic_eq" : "pause"; color: Theme.mag; size: 16 }
                HudText {
                    width: Math.min(implicitWidth, 560)
                    text: Media.title + (Media.artist ? "  //  " + Media.artist : "")
                    caps: false
                    font.letterSpacing: 0.5
                    font.pixelSize: 11
                }
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Ui.toggle("panelOpen") }
        }

        // ---------------------------------------------------------------- tray + launcher
        Row {
            anchors { right: parent.right; bottom: parent.bottom; rightMargin: 10; bottomMargin: 7 }
            spacing: 8
            Frame {
                visible: SystemTray.items.values.length > 0
                width: tray.implicitWidth + 20
                height: 34
                cut: 8
                Row {
                    id: tray
                    anchors.centerIn: parent
                    spacing: 10
                    Repeater {
                        model: SystemTray.items
                        IconImage {
                            id: trayIcon
                            required property SystemTrayItem modelData
                            implicitSize: 18
                            source: modelData.icon
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: e => {
                                    const item = trayIcon.modelData
                                    if (e.button === Qt.LeftButton && !item.onlyMenu) { item.activate(); return }
                                    if (item.hasMenu) {
                                        const p = trayIcon.mapToItem(null, 0, 0)
                                        item.display(band, p.x, p.y - 4)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HudButton {
                icon: "apps"
                label: "APPS"
                hint: "SUPER"
                active: Ui.launcherOpen
                onClicked: Ui.toggle("launcherOpen")
            }
            HudButton {   // the keybinds cheat sheet (popups/Help.qml)
                icon: "question_mark"
                active: Ui.helpOpen
                onClicked: Ui.helpOpen = !Ui.helpOpen
            }
        }
    }
}
