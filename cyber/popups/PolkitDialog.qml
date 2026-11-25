// The password prompt when an app asks for admin rights (pkexec, system settings...).
// Cyber is the polkit agent while it runs (end4-pC is otherwise).
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Polkit
import qs
import qs.components

Scope {
    id: root
    property bool failed: false

    PolkitAgent {
        id: agent
        onAuthenticationRequestStarted: { root.failed = false }
    }
    Connections {
        target: agent.flow
        function onAuthenticationFailed() { root.failed = true; input.text = ""; input.forceActiveFocus() }
    }

    PanelWindow {
        id: win
        visible: agent.isActive || glitch.busy
        screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: Theme.alpha(Theme.ink, 0.6 * glitch.opacity)
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "cyber:polkit"
        WlrLayershell.keyboardFocus: agent.isActive ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        onVisibleChanged: if (visible) { input.text = ""; input.forceActiveFocus() }

        function submit() { if (agent.flow) { agent.flow.submit(input.text); input.text = "" } }
        function cancel() { agent.flow?.cancelAuthenticationRequest() }

        Glitch {
            id: glitch
            active: agent.isActive
            anchors.centerIn: parent
            width: 560
            height: 250
            Frame {
            anchors.fill: parent
                fill: Theme.glassHi
                stroke: Theme.alpha(root.failed ? Theme.red : Theme.yellow, 0.8)
                cut: 18

                Column {
                    anchors { fill: parent; margins: 26 }
                    spacing: 14
                    Row {
                        spacing: 12
                        Icon { name: "shield_lock"; color: Theme.yellow; size: 20 }
                        HudText { text: "AUTHORIZATION REQUIRED"; color: Theme.yellow; font.pixelSize: 12 }
                        Text { text: "権限認証"; font.family: Theme.jp; font.pixelSize: 12; color: Theme.mag }
                    }
                    Text {
                        width: parent.width
                        text: agent.flow?.message ?? ""
                        color: Theme.fg
                        font.family: Theme.mono
                        font.pixelSize: 13
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                    }
                    Frame {
                        width: parent.width
                        height: 42
                        cut: 10
                        stroke: Theme.alpha(root.failed ? Theme.red : Theme.cyan, 0.8)
                        TextInput {
                            id: input
                            x: 14
                            width: parent.width - 28
                            anchors.verticalCenter: parent.verticalCenter
                            echoMode: agent.flow?.responseVisible ? TextInput.Normal : TextInput.Password
                            passwordCharacter: "◆"
                            color: Theme.fg
                            font.family: Theme.mono
                            font.pixelSize: 15
                            focus: true
                            // Enter / Esc act on release: the dialog closes right after, and a key
                            // still held would reach the app underneath (components/KeyUp.qml)
                            KeyUp { id: keyUp }
                            Keys.onPressed: e => {
                                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) keyUp.defer(e, () => win.submit())
                                else if (e.key === Qt.Key_Escape) keyUp.defer(e, () => win.cancel())
                            }
                            Keys.onReleased: e => keyUp.release(e)
                            HudText {
                                visible: !input.text
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.failed ? "ACCESS DENIED // TRY AGAIN" : (agent.flow?.inputPrompt || "PASSWORD").replace(/:\s*$/, "")
                                color: root.failed ? Theme.red : Theme.dim
                                font.pixelSize: 12
                            }
                        }
                    }
                    Row {
                        anchors.right: parent.right
                        spacing: 8
                        HudButton { label: "CANCEL"; hint: "ESC"; onClicked: win.cancel() }
                        HudButton { label: "AUTHORIZE"; hint: "ENTER"; accent: Theme.yellow; active: true; onClicked: win.submit() }
                    }
                }
            }
        }
    }
}
