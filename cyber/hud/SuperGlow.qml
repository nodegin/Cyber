// Hold Super: the screen's edges light up cyan with a damaged-signal glow, the "armed" state of the
// keyboard. It waits a moment first, so quick shortcuts (Super+T...) don't flash it. Clicks go
// through. Eliminate mode (Super+Q) shows the same effect in red instead (popups/Eliminate.qml).
// Ui.superHeld comes from end-4's Super press/release binds; hypr/keys.lua makes sure a lost release
// (Super+Tab's submap, a VM grabbing the keyboard) still turns it off.
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs
import qs.components

Scope {
    id: root
    // only after Super has been held a little while
    property bool armed: false
    Timer { id: hold; interval: 220; onTriggered: root.armed = Ui.superHeld }
    Connections {
        target: Ui
        function onSuperHeldChanged() {
            if (Ui.superHeld) { hold.restart(); Quickshell.execDetached(["hyprctl", "eval", "if CyberKeys then CyberKeys.watch() end"]) }
            else { hold.stop(); root.armed = false }
        }
    }
    readonly property bool on: armed && !Ui.killOpen && !Ui.preview

    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            visible: fx.opacity > 0.01
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "cyber:superglow"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region {}

            DamageFx {
                id: fx
                anchors.fill: parent
                tint: Theme.cyan
                veil: 0
                damage: 0.3
                edgeWidth: 0.16
                opacity: root.on ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.on ? 140 : 200; easing.type: Easing.OutCubic } }
            }
        }
    }
}
