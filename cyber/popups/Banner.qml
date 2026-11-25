// The status banner in the top-right corner (where the capture HUD sits): "RECORDING STARTED" (services/Grab.qml announces it and
// says where it sits; components/HudBanner.qml is its look and motion). It never takes the pointer.
// When its window is off the screen it tells Grab, which may be waiting for that to start the
// recorder, so that the banner is not in the video.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.components
import qs.services

PanelWindow {
    id: win
    readonly property int room: 12
    property string title: ""           // the last banner, kept while it fades out
    property color tone: Theme.alert
    Connections {
        target: Grab
        function onBannerChanged() { if (Grab.banner) { win.title = Grab.banner.title; win.tone = Grab.banner.tone } }
    }

    // Things Hyprland does that show nothing by themselves get the banner too:
    //   pinning a window (Super+P): it stays on every workspace
    //   sending a window to another workspace while staying here (Super+Alt+1 … 0): it just vanishes
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            const a = String(event.data).split(",")
            if (event.name === "pin")
                Grab.announce(a[1] === "1" ? "WINDOW PINNED TO EVERY WORKSPACE" : "WINDOW UNPINNED", Theme.mag, null)
            else if (event.name === "movewindowv2" && Number(a[1]) > 0) { sent.to = Number(a[1]); sent.restart() }
        }
    }
    Timer {     // a moment later: only if the view did not go along with the window
        id: sent
        property int to: 0
        interval: 90
        onTriggered: {
            if (to !== (Hyprland.focusedMonitor?.activeWorkspace?.id ?? to))
                Grab.announce(`WINDOW SENT TO WORKSPACE ${String((to - 1) % 10 + 1).padStart(2, "0")}`, Theme.cyan, null)
        }
    }

    visible: Grab.banner !== null || box.busy
    onVisibleChanged: if (!visible) Grab.bannerGone()
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
    anchors { top: true; right: true }
    margins { right: Grab.bannerRight - room; top: Grab.bannerTop - room }
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: Math.ceil(box.implicitWidth) + 2 * room
    implicitHeight: Math.ceil(box.implicitHeight) + 2 * room
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:banner"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}

    HudBanner {
        id: box
        x: win.room; y: win.room
        title: win.title
        tone: win.tone
        active: Grab.banner !== null
    }
}
