// The picture at the screen's edge while a dragged window waits there to be taken to the next
// workspace. The plugin counts and does it (hypr/corners/dragws.cpp); this only shows it: the edge
// lights up, a bar along the edge grows from the pointer's height until it fills the whole height
// of the screen as the wait runs out, chevrons point the way, and a chip says which workspace
// comes. When it happens the strip flashes once. Yellow, so that it stands out from the cyan of
// everything else (the edges glow cyan while Super is held).
// Clicks go through. Events (on Hyprland's event socket, from the plugin):
//   cyberdragedge>>left|right,<workspace>,<ms>,<y>     waiting on that edge, <y> from the top
//   cyberdragedge>>go,<left|right>,<workspace>         now
//   cyberdragedge>>off                                 not any more
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.components

PanelWindow {
    id: win
    property string side: ""            // "left" | "right" while the wait runs
    property string last: "right"       // the side it was on (kept while it fades)
    property int workspace: 0
    property real pointerY: 0           // the pointer's height, as the plugin said it
    readonly property real at: Math.max(60, Math.min(height - 60, pointerY))        // where the chevrons and the chip sit
    property real charge: 0             // 0..1: how much of the wait has passed
    property real glow: side !== "" ? 1 : 0
    property real flash: 0
    property int tick: 0
    readonly property color tone: Theme.yellow
    readonly property bool right: last === "right"

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "cyberdragedge") return
            const a = String(event.data).split(",")
            if (a[0] === "left" || a[0] === "right") {
                win.last = a[0]
                win.workspace = Number(a[1]) || 0
                win.pointerY = a[3] !== undefined ? Number(a[3]) : win.height / 2
                wait.duration = Math.max(100, Number(a[2]) || 1000)
                win.side = a[0]
                wait.restart()
            } else {
                wait.stop()
                if (a[0] === "go") { win.charge = 1; burst.restart() }
                win.side = ""
            }
        }
    }
    NumberAnimation { id: wait; target: win; property: "charge"; from: 0; to: 1 }
    NumberAnimation { id: burst; target: win; property: "flash"; from: 1; to: 0; duration: 280; easing.type: Easing.OutCubic }
    Behavior on glow { NumberAnimation { duration: 130 } }
    Timer { running: win.visible; interval: 110; repeat: true; onTriggered: win.tick++ }

    visible: glow > 0.01 || flash > 0.01
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:edge"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}

    // Laid out for the right edge; for the left edge the whole strip is mirrored.
    Item {
        id: strip
        width: 190
        height: win.height
        x: win.right ? win.width - width : 0
        opacity: Math.min(1, win.glow + win.flash)
        transform: Scale { xScale: win.right ? 1 : -1; origin.x: strip.width / 2 }

        Rectangle {     // the light coming off the edge, the whole height
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.6; color: Theme.alpha(win.tone, 0.03 + 0.08 * win.flash) }
                GradientStop { position: 1.0; color: Theme.alpha(win.tone, 0.12 + 0.22 * win.charge + 0.45 * win.flash) }
            }
        }
        Rectangle { x: parent.width - 2; width: 2; height: parent.height; color: Theme.alpha(win.tone, 0.4) }      // the rail
        Rectangle {     // the bar: from the pointer's height, up and down, until it is as tall as the screen
            x: parent.width - 10
            width: 10
            y: win.at * (1 - win.charge)
            height: win.height * win.charge
            color: win.tone
        }
        Repeater {      // ticks along the rail
            model: 25
            Rectangle {
                required property int index
                x: strip.width - (index % 4 === 0 ? 28 : 20)
                y: Math.round((index + 0.5) * strip.height / 25)
                width: index % 4 === 0 ? 14 : 6; height: 1
                color: Theme.alpha(win.tone, 0.6)
            }
        }
        Row {           // chevrons running towards the edge
            y: win.at - height / 2
            x: parent.width - width - 34
            spacing: -18
            Repeater {
                model: 3
                Icon {
                    required property int index
                    name: "chevron_right"
                    size: 64
                    color: win.tone
                    opacity: (win.tick + 3 - index) % 3 === 0 ? 1 : 0.3
                }
            }
        }
    }
    Frame {             // which workspace comes
        visible: strip.opacity > 0.01
        opacity: strip.opacity
        x: win.right ? win.width - width - 40 : 40
        y: Math.max(8, win.at - 78)
        width: label.implicitWidth + 30; height: 30
        fill: Qt.rgba(0.024, 0.031, 0.059, 0.9)
        stroke: Theme.alpha(win.tone, 0.9)
        cut: 8
        cutTopLeft: true; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false
        HudText {
            id: label
            anchors.centerIn: parent
            text: `WORKSPACE ${String((win.workspace - 1) % 10 + 1).padStart(2, "0")}`
            font.pixelSize: 13
            font.weight: Font.Bold
            font.letterSpacing: 1.5
            color: Theme.fg
        }
    }
}
