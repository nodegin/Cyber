// Control panel (Super+N): quick toggles, volume, the media player and the notification inbox.
// Esc or a click outside closes it.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import qs
import qs.components
import qs.services
import qs.hud

PanelWindow {
    id: win
    visible: Ui.panelOpen || glitch.busy
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
    anchors { top: true; bottom: true; left: true; right: true }
    exclusiveZone: 0
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:panel"
    WlrLayershell.keyboardFocus: Ui.panelOpen && !Ui.demo ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Connections { target: Ui; function onPanelOpenChanged() { if (Ui.panelOpen) { keyUp.reset(); Qt.callLater(() => keys.forceActiveFocus()) } } }
    MouseArea { anchors.fill: parent; onClicked: Ui.panelOpen = false }
    Item {
        id: keys
        focus: true
        KeyUp { id: keyUp }   // Esc closes on release (see components/KeyUp.qml)
        Keys.onPressed: e => { if (e.key === Qt.Key_Escape) keyUp.defer(e, () => Ui.panelOpen = false) }
        Keys.onReleased: e => keyUp.release(e)
    }

    Glitch {
        id: glitch
        active: Ui.panelOpen
        anchors { right: parent.right; top: parent.top; bottom: parent.bottom; margins: 10 }
        width: 440
        Frame {
            id: panel
            anchors.fill: parent
            fill: Theme.glassHi
            cut: 18
            cutTopLeft: true; cutTopRight: false; cutBottomRight: false; cutBottomLeft: true
            MouseArea { anchors.fill: parent }

            Column {
                id: top
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 22 }
                spacing: 16

                Item {
                    width: parent.width
                    height: 18
                    Row {
                        spacing: 12
                        HudText { text: "SYS // CONTROL"; color: Theme.cyan; font.pixelSize: 12 }
                        Text { text: "制御"; font.family: Theme.jp; font.pixelSize: 12; color: Theme.mag }
                    }
                    Clock { anchors.right: parent.right; size: 14; color: Theme.dim }
                }

                // quick toggles
                Flow {
                    width: parent.width
                    spacing: 6
                    HudButton { icon: Notifs.dnd ? "notifications_off" : "notifications"; label: "DND"; active: Notifs.dnd; accent: Theme.yellow; onClicked: Notifs.dnd = !Notifs.dnd }
                    HudButton { icon: Audio.muted ? "volume_off" : "volume_up"; label: "MUTE"; active: Audio.muted; accent: Theme.red; onClicked: Audio.toggleMute() }
                    HudButton { icon: Audio.micMuted ? "mic_off" : "mic"; label: "MIC"; active: Audio.micMuted; accent: Theme.red; onClicked: Audio.toggleMic() }
                    HudButton { icon: "visibility_off"; label: "HUD"; active: Ui.hudHidden; onClicked: Ui.hudHidden = !Ui.hudHidden }
                    HudButton { icon: "palette"; label: "WALL"; onClicked: { Ui.panelOpen = false; Quickshell.execDetached(["xdg-open", Config.path("~/.local/share/cyber/cyber/config.json")]) } }
                }

                // volume
                Column {
                    width: parent.width
                    spacing: 6
                    Row {
                        spacing: 10
                        HudText { text: "AUDIO OUT"; font.pixelSize: 9; color: Theme.dim }
                        HudText { text: Audio.muted ? "MUTED" : Math.round(Audio.volume * 100) + "%"; font.pixelSize: 9 }
                    }
                    Meter {
                        width: parent.width
                        height: 10
                        segments: 32
                        value: Math.min(1, Audio.volume)
                        color: Audio.muted ? Theme.faint : Theme.cyan
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: e => { if (Audio.sink?.audio) Audio.sink.audio.volume = Math.max(0, Math.min(1, e.x / width)) }
                            onWheel: e => { if (Audio.sink?.audio) Audio.sink.audio.volume = Math.max(0, Math.min(1, Audio.volume + (e.angleDelta.y > 0 ? 0.02 : -0.02))) }
                        }
                    }
                }

                // media player
                Frame {
                    visible: Media.player !== null
                    width: parent.width
                    height: 96
                    cut: 10
                    fill: Theme.glass
                    stroke: Theme.alpha(Theme.mag, 0.6)
                    Image {
                        id: art
                        x: 10; y: 10
                        width: 76; height: 76
                        source: Media.art
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize: Qt.size(152, 152)
                        visible: Media.art !== ""
                    }
                    Column {
                        x: art.visible ? 98 : 14
                        width: parent.width - x - 12
                        y: 12
                        spacing: 4
                        HudText { width: parent.width; text: Media.playing ? "NOW PLAYING // 再生中" : "PAUSED // 一時停止"; font.pixelSize: 9; color: Theme.mag }
                        Text { width: parent.width; text: Media.title || "UNKNOWN TRACK"; font.family: Theme.display; font.pixelSize: 14; font.weight: Font.DemiBold; color: Theme.fg; elide: Text.ElideRight }
                        HudText { width: parent.width; text: Media.artist; caps: false; font.letterSpacing: 0.5; font.pixelSize: 11; color: Theme.dim }
                        Row {
                            spacing: 6
                            topPadding: 2
                            HudButton { icon: "skip_previous"; implicitHeight: 24; onClicked: Media.player?.previous() }
                            HudButton { icon: Media.playing ? "pause" : "play_arrow"; implicitHeight: 24; accent: Theme.mag; active: Media.playing; onClicked: Media.player?.togglePlaying() }
                            HudButton { icon: "skip_next"; implicitHeight: 24; onClicked: Media.player?.next() }
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: 22
                    HudText { anchors.verticalCenter: parent.verticalCenter; text: `INBOX // ${Notifs.history.length}`; color: Theme.cyan; font.pixelSize: 11 }
                    HudButton {
                        anchors.right: parent.right
                        visible: Notifs.history.length > 0
                        label: "CLEAR ALL"
                        implicitHeight: 22
                        accent: Theme.red
                        onClicked: Notifs.clearAll()
                    }
                }
            }

            // notification inbox
            ListView {
                anchors { left: parent.left; right: parent.right; top: top.bottom; bottom: parent.bottom; margins: 22; topMargin: 10 }
                clip: true
                spacing: 6
                model: [...Notifs.history].reverse()
                boundsBehavior: Flickable.StopAtBounds
                delegate: Frame {
                    id: item
                    required property var modelData
                    width: ListView.view.width
                    height: col.implicitHeight + 18
                    cut: 8
                    fill: Theme.glass
                    stroke: Theme.alpha(Theme.fg, 0.18)
                    Column {
                        id: col
                        x: 12; y: 9
                        width: parent.width - 24
                        spacing: 3
                        HudText { width: parent.width; text: item.modelData.appName || "SYSTEM"; font.pixelSize: 9; color: Theme.dim }
                        Text { width: parent.width; text: item.modelData.summary; font.family: Theme.display; font.pixelSize: 13; color: Theme.fg; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                        Text {
                            width: parent.width
                            visible: text !== ""
                            text: item.modelData.body
                            textFormat: Text.StyledText
                            font.family: Theme.mono; font.pixelSize: 11
                            color: Theme.alpha(Theme.fg, 0.75)
                            wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                        }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Notifs.dismiss(item.modelData) }
                }
                HudText {
                    anchors.centerIn: parent
                    visible: Notifs.history.length === 0
                    text: "NO MESSAGES // 受信なし"
                    color: Theme.dim
                    font.pixelSize: 11
                }
            }
        }
    }
}
