// Power menu (Ctrl+Alt+Del, or the power button): a full-screen "system override".
// ←/→ (or Tab) and Enter, or the letter keys. Log out, reboot and power off ask for a second
// press within 3 s. Esc or a click outside aborts.
import QtQuick
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.components

PanelWindow {
    id: win
    visible: Ui.powerOpen || fx.busy || backdrop.opacity > 0.01
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:power"
    WlrLayershell.keyboardFocus: Ui.powerOpen && !Ui.demo ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    readonly property var actions: [
        { key: "L", icon: "lock", label: "LOCK", code: "SEC.LOCK", cmd: "loginctl lock-session" },
        { key: "D", icon: "swap_horiz", label: "end-4/pC", code: "ENV.SWAP", cmd: `${Config.desktopScript} apply end4-pC` },
        { key: "E", icon: "logout", label: "LOG OUT", code: "USR.EXIT", confirm: true, cmd: "hyprctl dispatch 'hl.dsp.exit()'" },
        { key: "R", icon: "restart_alt", label: "REBOOT", code: "SYS.CYCLE", confirm: true, cmd: "systemctl reboot || loginctl reboot" },
        { key: "P", icon: "power_settings_new", label: "POWER OFF", code: "SYS.HALT", confirm: true, cmd: "systemctl poweroff || loginctl poweroff" },
    ]
    property int index: 0
    property int armed: -1
    property string status: "SELECT PROTOCOL"
    property int revealed: 0      // tiles shown so far (they glitch in one after another)
    Timer { id: reveal; interval: 35; repeat: true; onTriggered: { win.revealed++; if (win.revealed >= win.actions.length) stop() } }

    Connections {
        target: Ui
        function onPowerOpenChanged() {
            if (!Ui.powerOpen) return
            win.index = 0; win.armed = -1; win.status = "SELECT PROTOCOL"
            win.revealed = 0; reveal.restart()
            title.play(); sub.play(); keyUp.reset()
            Qt.callLater(() => keys.forceActiveFocus())
        }
    }

    function pick(i) {
        const a = actions[i]
        index = i
        if (a.confirm && armed !== i) {
            armed = i
            status = `${a.code} ARMED // PRESS AGAIN TO EXECUTE`
            disarm.restart()
            return
        }
        status = `EXECUTING ${a.code}`
        Ui.powerOpen = false
        Quickshell.execDetached(["sh", "-c", a.cmd])
    }
    function move(step) {
        index = (index + step + actions.length) % actions.length
        if (armed !== -1 && armed !== index) { armed = -1; status = "SELECT PROTOCOL" }
    }
    Timer { id: disarm; interval: 3000; onTriggered: { win.armed = -1; win.status = "TIMEOUT // PROTOCOL DISARMED" } }

    Item {
        id: keys
        anchors.fill: parent
        focus: true
        KeyUp { id: keyUp }   // closing keys act on release (see components/KeyUp.qml)
        Keys.onReleased: e => keyUp.release(e)
        Keys.onPressed: e => {
            const byKey = win.actions.findIndex(a => a.key === e.text.toUpperCase())
            if (e.key === Qt.Key_Escape) keyUp.defer(e, () => Ui.powerOpen = false)
            else if (e.key === Qt.Key_Left || e.key === Qt.Key_Up || e.key === Qt.Key_Backtab) win.move(-1)
            else if (e.key === Qt.Key_Right || e.key === Qt.Key_Down || e.key === Qt.Key_Tab) win.move(1)
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) { const i = win.index; keyUp.defer(e, () => win.pick(i)) }
            else if (byKey >= 0) keyUp.defer(e, () => win.pick(byKey))
            else return
            e.accepted = true
        }
    }

    // dimmed, scanlined background: it fades in and out smoothly and never blinks; click to abort
    Item {
        id: backdrop
        anchors.fill: parent
        opacity: Ui.powerOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
        Rectangle { anchors.fill: parent; color: Theme.alpha(Theme.ink, 0.62) }
        Canvas {
            anchors.fill: parent
            onPaint: {
                const ctx = getContext("2d")
                ctx.fillStyle = "rgba(0,0,0,0.22)"
                for (let y = 0; y < height; y += 3) ctx.fillRect(0, y, width, 1)
            }
        }
    }
    MouseArea { anchors.fill: parent; onClicked: Ui.powerOpen = false }

    // only the menu itself (a band across the screen) glitches in and out
    Glitch {
        id: fx
        anchors.centerIn: parent
        width: parent.width
        height: stage.height + 160
        active: Ui.powerOpen
        flicker: 0.2

        HexStream { anchors { right: stage.left; rightMargin: 60; verticalCenter: stage.verticalCenter } }
        HexStream {
            anchors { left: stage.right; leftMargin: 60; verticalCenter: stage.verticalCenter }
            color: Theme.mag
        }

        Item {
            id: stage
            anchors.centerIn: parent
            width: tiles.implicitWidth
            height: 470
            MouseArea { anchors.fill: parent }

            Hazard { id: topStripe; width: parent.width; height: 12 }

            Row {
                y: 30
                spacing: 20
                Rectangle { width: 6; height: 46; color: Theme.red; anchors.verticalCenter: parent.verticalCenter }
                Column {
                    spacing: 4
                    Scramble { id: title; visible: false; target: "SYSTEM OVERRIDE" }
                    ChromaText {
                        text: title.text
                        split: 1.2
                        color: Theme.fg
                        font.family: Theme.display
                        font.pixelSize: 40
                        font.weight: Font.Bold
                        font.letterSpacing: 7
                    }
                    Scramble {
                        id: sub
                        target: "POWER CONTROL PROTOCOL // OPERATOR " + Quickshell.env("USER").toUpperCase()
                        stepMs: 14
                        font.pixelSize: 11
                        color: Theme.dim
                    }
                }
            }
            Column {
                anchors.right: parent.right
                y: 32
                spacing: 6
                Text { anchors.right: parent.right; text: "電源管理 // 権限確認"; font.family: Theme.jp; font.pixelSize: 15; color: Theme.red }
                HudText { anchors.right: parent.right; text: "PWR.CTL 0x7F3A // AUTH LVL 0"; font.pixelSize: 10; color: Theme.dim }
            }

            Row {
                id: tiles
                y: 118
                spacing: 14
                Repeater {
                    model: win.actions
                    Glitch {
                        id: tileFx
                        required property var modelData
                        required property int index
                        active: Ui.powerOpen && index < win.revealed
                        width: 182
                        height: 236
                        speed: 1.4
                        maxMs: 340   // + 35 ms per tile before it: all done by ~520 ms
                        flicker: 0.15
                        Timer { running: tile.isArmed; repeat: true; interval: 900; onTriggered: tileFx.shock() }
                    Frame {
                        id: tile
                        anchors.fill: parent
                        readonly property var modelData: tileFx.modelData
                        readonly property int index: tileFx.index
                        readonly property bool selected: index === win.index
                        readonly property bool isArmed: index === win.armed
                        readonly property color accent: isArmed ? Theme.red : selected ? Theme.cyan : Theme.fg
                        cut: 26
                        cutTopLeft: false; cutTopRight: true; cutBottomRight: false; cutBottomLeft: true
                        fill: isArmed ? Theme.alpha(Theme.red, 0.22) : selected ? Theme.alpha(Theme.cyan, 0.13) : Theme.alpha(Theme.ink, 0.55)
                        stroke: isArmed ? Theme.red : selected ? Theme.cyan : Theme.alpha(Theme.fg, 0.22)
                        strokeWidth: selected || isArmed ? 2 : 1
                        scale: selected ? 1.04 : 1
                        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }

                        // a light sweeping down the selected tile, clipped to the tile's cut shape
                        Item {
                            anchors.fill: parent
                            visible: tile.selected
                            layer.enabled: visible
                            layer.effect: OpacityMask { maskSource: sweepMask }
                            Rectangle {
                                width: parent.width
                                height: 46
                                gradient: Gradient {
                                    GradientStop { position: 0; color: "transparent" }
                                    GradientStop { position: 0.92; color: Theme.alpha(tile.accent, 0.26) }
                                    GradientStop { position: 1; color: Theme.alpha(tile.accent, 0.6) }
                                }
                                NumberAnimation on y { running: tile.selected; loops: Animation.Infinite; from: -46; to: tile.height; duration: 1400 }
                            }
                        }
                        Item {   // the mask: the tile's shape, 3 px inside its border
                            id: sweepMask
                            anchors.fill: parent
                            visible: false
                            Frame {
                                anchors { fill: parent; margins: 3 }
                                cut: tile.cut - 2
                                cutTopLeft: tile.cutTopLeft; cutTopRight: tile.cutTopRight
                                cutBottomRight: tile.cutBottomRight; cutBottomLeft: tile.cutBottomLeft
                                fill: "white"
                                stroke: "transparent"
                            }
                        }

                        HudText {
                            x: 16; y: 14
                            text: String(tile.index + 1).padStart(2, "0")
                            font.family: Theme.display
                            font.pixelSize: 28
                            font.weight: Font.Bold
                            color: Theme.alpha(tile.accent, tile.selected || tile.isArmed ? 0.9 : 0.3)
                        }
                        Icon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 74
                            name: tile.modelData.icon
                            size: 50
                            color: tile.accent
                            opacity: tile.isArmed && blink.on ? 0.35 : 1
                        }
                        Column {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 146
                            spacing: 6
                            HudText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: tile.isArmed ? "CONFIRM" : tile.modelData.label
                                caps: tile.isArmed || tile.modelData.label === tile.modelData.label.toUpperCase()
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                                color: tile.accent
                            }
                            HudText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: tile.modelData.code
                                font.pixelSize: 9
                                color: Theme.dim
                            }
                        }
                        // key chip
                        Frame {
                            x: parent.width - 40; y: parent.height - 36
                            width: 26; height: 22; cut: 6
                            fill: Theme.alpha(tile.accent, tile.selected ? 0.25 : 0.08)
                            stroke: Theme.alpha(tile.accent, 0.6)
                            HudText { anchors.centerIn: parent; text: tile.modelData.key; font.pixelSize: 11; font.letterSpacing: 0; color: tile.accent }
                        }
                        // armed: the 3 s window drains away
                        Rectangle {
                            visible: tile.isArmed
                            x: 14; y: parent.height - 10
                            height: 3
                            color: Theme.red
                            width: (parent.width - 28) * drain.value
                            QtObject { id: drain; property real value: 1 }
                            NumberAnimation { target: drain; property: "value"; running: tile.isArmed; from: 1; to: 0; duration: 3000 }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: win.move(tile.index - win.index)
                            onClicked: win.pick(tile.index)
                        }
                    }
                    }
                }
            }

            // status line + key help
            Row {
                y: 384
                spacing: 12
                Rectangle { width: 10; height: 10; anchors.verticalCenter: parent.verticalCenter; color: win.armed >= 0 ? Theme.red : Theme.cyan; opacity: blink.on ? 1 : 0.25 }
                HudText { text: "> " + win.status; font.pixelSize: 13; color: win.armed >= 0 ? Theme.red : Theme.cyan }
            }
            HudText {
                anchors.right: parent.right
                y: 386
                text: "[←→] SELECT    [ENTER] EXECUTE    [ESC] ABORT"
                font.pixelSize: 10
                color: Theme.dim
            }
            Hazard { y: parent.height - 12; width: parent.width; height: 12 }
        }
    }

    QtObject { id: blink; property bool on: true }
    Timer { running: win.visible; interval: 420; repeat: true; onTriggered: blink.on = !blink.on }
}
