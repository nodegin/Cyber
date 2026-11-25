// Keybinds card (Super+/, or the [?] button at the right end of the bottom band): the keys of the
// Cyber desktop. A normal window: it can be dragged anywhere (by any part of it, or Super + drag),
// stays open while you try the keys, and closes with Esc, its × or Super+/ again.
// The layout follows the cheat sheet of another shell that was picked as the model: a title, a
// "// prefix" line, two columns of single keys with what each does, then a list of the longer
// combinations. The card itself is Cyber's own HUD dialog, the same as the capture menu's.
// The lists are written by hand: keep them in step with the binds (end-4's
// ~/.config/hypr/hyprland/keybinds.lua, ~/.config/hypr/custom/keybinds.lua, cyber/Shortcuts.qml).
// Hyprland knows the window by its title (rules in setup.sh, "cyber windows"): it keeps the size
// asked for here, has no shadow, and is blurred only where it paints.
import QtQuick
import Quickshell
import qs
import qs.components

FloatingWindow {
    id: win
    title: "Cyber Keybinds"
    color: "transparent"
    implicitWidth: Math.ceil(card.implicitWidth)
    implicitHeight: Math.ceil(card.implicitHeight)
    minimumSize: Qt.size(implicitWidth, implicitHeight)
    maximumSize: Qt.size(implicitWidth, implicitHeight)

    // open and closed with Ui.helpOpen; closed by the window manager (Super+Q), it says so
    visible: false
    Connections { target: Ui; function onHelpOpenChanged() { win.visible = Ui.helpOpen; if (Ui.helpOpen) { keyUp.reset(); keys.forceActiveFocus() } } }
    onClosed: Ui.helpOpen = false
    onVisibleChanged: if (!visible && Ui.helpOpen) Ui.helpOpen = false

    // Held with Super: [key, what it does]. Single keys only; longer ones are in the list below.
    readonly property var left: [
        ["SUPER", "APP LAUNCHER"],
        ["E", "FILES"],
        ["W", "BROWSER"],
        ["T", "TERMINAL"],
        ["Q", "TERMINATE MODE"],
        ["L", "LOCK SCREEN"],
        ["N", "CONTROL PANEL"],
        ["J", "HIDE THE HUD"],
        ["/", "KEYBINDS"],
    ]
    readonly property var right: [
        ["V", "CLIPBOARD"],
        [".", "EMOJI"],
        ["F", "FULLSCREEN"],
        ["D", "MAXIMIZE"],
        ["M", "MINIMIZE"],
        ["P", "PIN TO ALL WORKSPACES"],
        ["=", "ZOOM IN"],
        ["-", "ZOOM OUT"],
    ]
    // Longer combinations: [keys, what]
    readonly property var more: [
        ["SUPER + TAB", "WINDOW SWITCHER"],
        ["SUPER + SPACE", "FLOAT / TILE TOGGLE"],
        ["SUPER + ← → ↑ ↓", "FOCUS WINDOW"],
        ["SUPER + 1…0", "WORKSPACE"],
        ["SUPER + ALT + 1…0", "WINDOW → WORKSPACE"],
        ["SUPER + LEFT / RIGHT DRAG", "MOVE / RESIZE WINDOW"],
        ["DRAG + 1…0 / SCREEN EDGE", "CARRY WINDOW ALONG"],
        ["PRTSC", "CAPTURE MENU"],
        ["SUPER + SHIFT + S / R", "SCREENSHOT / RECORD REGION"],
        ["SPACE IN FILES", "QUICK LOOK"],
        ["CTRL + ALT + DEL", "POWER MENU"],
        ["CTRL + SUPER + R", "RESTART THE SHELL"],
    ]

    HudDialog {
        id: card
        anchors.fill: parent
        title: "KEYBINDS"
        subtitle: "// PREFIX: SUPER + KEY"
        footer: "ESC TO CLOSE  ·  DRAG TO MOVE"

        Column {
            spacing: 0
            Row {
                Column { width: 300; spacing: 12; Repeater { model: win.left; KeyCap { required property var modelData; cap: modelData[0]; label: modelData[1] } } }
                Column { width: 300; spacing: 12; Repeater { model: win.right; KeyCap { required property var modelData; cap: modelData[0]; label: modelData[1] } } }
            }
            Item { width: 1; height: 24 }
            HudText { text: "// MORE"; font.pixelSize: 10; color: Theme.alpha(Theme.teal, 0.85) }
            Item { width: 1; height: 8 }
            Rectangle { width: 600; height: 1; color: Theme.alpha(Theme.teal, 0.3) }
            Item { width: 1; height: 14 }
            Column {
                spacing: 9
                Repeater {
                    model: win.more
                    Row {
                        required property var modelData
                        height: 20      // the same for every line (an arrow from another font is taller)
                        Text { width: 300; anchors.verticalCenter: parent.verticalCenter; text: modelData[0]; color: "#52c4c2"; font.family: Theme.banner; font.pixelSize: 15; font.weight: Font.Bold; font.letterSpacing: 0.8 }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: modelData[1]; color: "#b9c6ce"; font.family: Theme.banner; font.pixelSize: 15; font.weight: Font.Bold; font.letterSpacing: 0.8 }
                    }
                }
            }
            Item { width: 1; height: 8 }
        }
    }

    MouseArea {     // any part of the card: drag the window
        anchors.fill: parent
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.ArrowCursor
        onPressed: win.startSystemMove()
    }
    Item {          // ×
        x: win.width - 58; y: 16
        width: 30; height: 30
        Icon { anchors.centerIn: parent; name: "close"; size: 20; color: shut.containsMouse ? Theme.red : Theme.alpha("#cfe6ec", 0.7) }
        MouseArea { id: shut; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Ui.helpOpen = false }
    }
    Item {          // Esc closes, on its release (see components/KeyUp.qml)
        id: keys
        focus: true
        KeyUp { id: keyUp }
        Keys.onPressed: e => { if (e.key === Qt.Key_Escape) keyUp.defer(e, () => Ui.helpOpen = false) }
        Keys.onReleased: e => keyUp.release(e)
    }
}
