// App launcher (tap Super): type to filter, ↑/↓ or Tab, Enter to start, Esc to close.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import qs
import qs.components

PanelWindow {
    id: win
    visible: Ui.launcherOpen || glitch.busy
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:launcher"
    WlrLayershell.keyboardFocus: Ui.launcherOpen && !Ui.demo ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    property string query: ""
    property int index: 0
    readonly property var apps: {
        const q = query.trim().toLowerCase()
        const all = DesktopEntries.applications.values.filter(e => !e.noDisplay)
        if (!q) return all.slice().sort((a, b) => a.name.localeCompare(b.name))
        const score = e => {
            const n = e.name.toLowerCase()
            if (n.startsWith(q)) return 0
            if (n.includes(q)) return 1
            const more = [e.genericName, e.comment, (e.keywords || []).join(" "), e.id].join(" ").toLowerCase()
            if (more.includes(q)) return 2
            let i = 0
            for (const ch of n) if (ch === q[i]) i++
            return i === q.length ? 3 : -1   // its letters in order
        }
        return all.map(e => [score(e), e]).filter(x => x[0] >= 0)
            .sort((a, b) => a[0] - b[0] || a[1].name.localeCompare(b[1].name)).map(x => x[1])
    }
    onQueryChanged: index = 0
    Connections {
        target: Ui
        function onLauncherOpenChanged() {
            if (!Ui.launcherOpen) return
            input.text = ""; win.index = 0; keyUp.reset()
            Qt.callLater(() => input.forceActiveFocus())
        }
    }

    function launch(entry) {
        if (!entry) return
        Ui.launcherOpen = false
        entry.execute()
    }
    function move(step) { if (apps.length) index = (index + step + apps.length) % apps.length }

    MouseArea { anchors.fill: parent; onClicked: Ui.launcherOpen = false }

    Glitch {
        id: glitch
        active: Ui.launcherOpen
        anchors.centerIn: parent
        // wider than the panel: the glitch streaks spill out to the sides
        width: 660 + 1000
        height: 540 + 120
        strength: 0.85
        Frame {
            id: panel
            anchors.centerIn: parent
            width: 660
            height: 540
            fill: Theme.glassHi
            cut: 18
            cutTopLeft: true; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false
            MouseArea { anchors.fill: parent }

            Column {
                anchors { fill: parent; margins: 22 }
                spacing: 14

                Item {
                    width: parent.width
                    height: 18
                    Row {
                        spacing: 12
                        HudText { text: "NET // LAUNCH"; color: Theme.cyan; font.pixelSize: 12 }
                        Text { text: "起動"; font.family: Theme.jp; font.pixelSize: 12; color: Theme.mag }
                    }
                    HudText { anchors.right: parent.right; text: `${win.apps.length} PROGRAMS`; font.pixelSize: 10; color: Theme.dim }
                }

                Frame {
                    width: parent.width
                    height: 42
                    cut: 10
                    stroke: Theme.alpha(Theme.cyan, input.activeFocus ? 0.9 : 0.4)
                    Icon { x: 12; anchors.verticalCenter: parent.verticalCenter; name: "search"; color: Theme.cyan }
                    TextInput {
                        id: input
                        x: 42
                        width: parent.width - 54
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.fg
                        selectionColor: Theme.alpha(Theme.cyan, 0.4)
                        font.family: Theme.mono
                        font.pixelSize: 15
                        focus: true
                        onTextChanged: win.query = text
                        KeyUp { id: keyUp }   // closing keys act on release (see components/KeyUp.qml)
                        Keys.onReleased: e => keyUp.release(e)
                        Keys.onPressed: e => {
                            if (e.key === Qt.Key_Escape) keyUp.defer(e, () => Ui.launcherOpen = false)
                            else if (e.key === Qt.Key_Down || e.key === Qt.Key_Tab) win.move(1)
                            else if (e.key === Qt.Key_Up || e.key === Qt.Key_Backtab) win.move(-1)
                            else if (e.key === Qt.Key_PageDown) win.move(8)
                            else if (e.key === Qt.Key_PageUp) win.move(-8)
                            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { const app = win.apps[win.index]; keyUp.defer(e, () => win.launch(app)) }
                            else return
                            e.accepted = true
                        }
                        HudText {
                            visible: !input.text
                            anchors.verticalCenter: parent.verticalCenter
                            text: "SEARCH PROGRAMS_"
                            color: Theme.dim
                            font.pixelSize: 12
                        }
                    }
                }

                ListView {
                    id: list
                    width: parent.width
                    height: parent.height - 18 - 42 - 2 * 14
                    clip: true
                    model: win.apps
                    currentIndex: win.index
                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: Item {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool selected: index === win.index
                        width: list.width
                        height: 42
                        Rectangle {
                            anchors.fill: parent
                            color: row.selected ? Theme.alpha(Theme.cyan, 0.16) : "transparent"
                            Rectangle { visible: row.selected; width: 3; height: parent.height; color: Theme.cyan }
                        }
                        Row {
                            x: 14
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 12
                            IconImage {
                                anchors.verticalCenter: parent.verticalCenter
                                implicitSize: 24
                                source: Quickshell.iconPath(row.modelData.icon, "application-x-executable")
                            }
                            HudText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: row.modelData.name
                                caps: false
                                font.letterSpacing: 0.5
                                font.pixelSize: 14
                                color: row.selected ? Theme.cyan : Theme.fg
                            }
                            HudText {
                                anchors.verticalCenter: parent.verticalCenter
                                width: list.width - 300
                                text: row.modelData.genericName || row.modelData.comment || ""
                                caps: false
                                font.letterSpacing: 0.3
                                font.pixelSize: 11
                                color: Theme.dim
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onPositionChanged: win.index = row.index
                            onClicked: win.launch(row.modelData)
                        }
                    }
                }
            }
        }
    }
}
