// The picker: drag a region or click a window, for a screenshot or a recording (services/Grab.qml
// opens it and gets the answer). The rest of the screen is dimmed, what is picked stays clear, with
// its size beside it. Esc or the right mouse button cancels; a drag of a few pixels is ignored.
//   a screenshot: the screen was photographed just before, and that still picture is what is
//     shown and picked on (yellow)
//   a recording:  the live screen shows through (red)
// A window is found the way eliminate mode does it (popups/Eliminate.qml): Hyprland's window list,
// the topmost one under the pointer.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.components
import qs.services

PanelWindow {
    id: win
    readonly property bool open: Grab.picking !== ""
    readonly property bool windowMode: Grab.picking === "window"
    readonly property color tone: Grab.video ? Theme.alert : Theme.yellow      // red = a recording, yellow = a screenshot

    visible: open
    screen: Quickshell.screens.find(s => s.name === Grab.screenName) ?? Quickshell.screens[0]
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:select"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    readonly property var mon: Hyprland.monitors.values.find(m => m.name === win.screen?.name) ?? null
    readonly property real monX: mon?.lastIpcObject?.x ?? 0
    readonly property real monY: mon?.lastIpcObject?.y ?? 0

    // ---- what is being picked (pixels of this screen)
    property real mx: -1
    property real my: -1
    property bool dragging: false
    property point from: Qt.point(0, 0)
    property var clients: []
    property var aim: null              // window mode: the window under the pointer
    readonly property rect sel: {
        if (windowMode) {
            if (!aim) return Qt.rect(0, 0, 0, 0)
            const x0 = Math.max(0, aim.at[0] - monX), y0 = Math.max(0, aim.at[1] - monY)
            const x1 = Math.min(width, aim.at[0] - monX + aim.size[0]), y1 = Math.min(height, aim.at[1] - monY + aim.size[1])
            return Qt.rect(x0, y0, Math.max(0, x1 - x0), Math.max(0, y1 - y0))
        }
        if (!dragging) return Qt.rect(0, 0, 0, 0)
        return Qt.rect(Math.min(from.x, mx), Math.min(from.y, my), Math.abs(mx - from.x), Math.abs(my - from.y))
    }
    readonly property bool has: sel.width > 0 && sel.height > 0
    // the still picture's pixels for one pixel here (a scaled monitor)
    readonly property real k: still.status === Image.Ready && still.sourceSize.width > 0 && width > 0 ? still.sourceSize.width / width : 1
    readonly property string sizeText: `${Math.round(sel.width * k)} × ${Math.round(sel.height * k)}`

    function point(mouse) {     // the pointer; on the last pixel it counts as the screen's edge, so a region can reach it
        mx = mouse.x >= width - 1 ? width : Math.max(0, Math.round(mouse.x))
        my = mouse.y >= height - 1 ? height : Math.max(0, Math.round(mouse.y))
        if (windowMode) reaim()
    }
    function windowAt(gx, gy) {
        const ws = mon?.activeWorkspace?.id
        const special = mon?.lastIpcObject?.specialWorkspace?.id ?? 0
        let best = null, bestRank = -Infinity
        for (const c of clients) {
            if (!c.mapped || c.hidden || c.monitor !== mon?.id) continue
            const onSpecial = special !== 0 && c.workspace?.id === special
            if (!(c.workspace?.id === ws || c.pinned || onSpecial)) continue
            if (gx < c.at[0] || gy < c.at[1] || gx >= c.at[0] + c.size[0] || gy >= c.at[1] + c.size[1]) continue
            const rank = (c.pinned ? 4000 : onSpecial ? 3000 : c.fullscreen === 2 ? 2000 : c.floating ? 1000 : 0) - c.focusHistoryID
            if (rank > bestRank) { bestRank = rank; best = c }
        }
        return best
    }
    function reaim() { aim = mx >= 0 ? windowAt(mx + monX, my + monY) : null }
    function pick() {
        if (sel.width < 8 || sel.height < 8) return false
        const r = sel
        Grab.picked(`${Math.round(r.x * k)},${Math.round(r.y * k)} ${Math.round(r.width * k)}x${Math.round(r.height * k)}`,
                    `${Math.round(monX + r.x)},${Math.round(monY + r.y)} ${Math.round(r.width)}x${Math.round(r.height)}`)
        return true
    }

    onOpenChanged: {
        if (!open) return
        dragging = false
        aim = null
        keyUp.reset()
        cursorPos.running = true
        getClients.running = true      // always: this runs before windowMode has caught up with Grab.picking
        Qt.callLater(() => keys.forceActiveFocus())
    }
    Process {
        id: getClients
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: { try { win.clients = JSON.parse(text) } catch (e) { win.clients = [] } win.reaim() }
        }
    }
    Process {   // where the pointer is as this opens (before it moves)
        id: cursorPos
        command: ["hyprctl", "cursorpos", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { const p = JSON.parse(text); if (!win.dragging) { win.mx = p.x - win.monX; win.my = p.y - win.monY } } catch (e) { }
                if (win.windowMode) win.reaim()
            }
        }
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true
        KeyUp { id: keyUp }     // closing keys act on release (components/KeyUp.qml)
        Keys.onPressed: e => { if (e.key === Qt.Key_Escape) keyUp.defer(e, () => Grab.cancel()) }
        Keys.onReleased: e => keyUp.release(e)
    }

    Image {     // the still picture (a screenshot is picked on it)
        id: still
        anchors.fill: parent
        visible: Grab.frozen !== ""
        source: win.open && Grab.frozen !== "" ? "file://" + Grab.frozen : ""
        cache: false
        asynchronous: false
        smooth: false
    }

    // ---- everything but the selection, dimmed (a little before there is one, more around it)
    readonly property color shade: Qt.rgba(0.008, 0.016, 0.035, has ? 0.56 : 0.3)
    Rectangle { width: win.width; height: win.has ? win.sel.y : win.height; color: win.shade }
    Rectangle { visible: win.has; y: win.sel.y + win.sel.height; width: win.width; height: win.height - y; color: win.shade }
    Rectangle { visible: win.has; y: win.sel.y; width: win.sel.x; height: win.sel.height; color: win.shade }
    Rectangle { visible: win.has; x: win.sel.x + win.sel.width; y: win.sel.y; width: win.width - x; height: win.sel.height; color: win.shade }

    // ---- before a region is dragged: lines through the pointer, and where it is
    Item {
        anchors.fill: parent
        visible: !win.windowMode && !win.dragging && win.mx >= 0
        Rectangle { y: win.my; width: win.width; height: 1; color: Theme.alpha(win.tone, 0.42) }
        Rectangle { x: win.mx; width: 1; height: win.height; color: Theme.alpha(win.tone, 0.42) }
        Rectangle {
            x: win.mx + 16 + width > win.width ? win.mx - 16 - width : win.mx + 16
            y: win.my + 18 + height > win.height ? win.my - 18 - height : win.my + 18
            width: where.implicitWidth + 16; height: 20
            color: Qt.rgba(0.024, 0.031, 0.059, 0.85)
            border.width: 1
            border.color: Theme.alpha(win.tone, 0.5)
            HudText { id: where; anchors.centerIn: parent; text: `X ${Math.round(win.mx * win.k)}   Y ${Math.round(win.my * win.k)}`; font.pixelSize: 10; color: Theme.alpha(Theme.fg, 0.85) }
        }
    }

    // ---- the selection: an outline with corner brackets, its size under it, where it starts above it
    Item {
        id: box
        visible: win.has
        x: win.sel.x; y: win.sel.y
        width: win.sel.width; height: win.sel.height
        Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: Theme.alpha(win.tone, 0.9) }
        Repeater {
            model: 4
            Item {
                required property int index
                id: corner
                readonly property bool atRight: index % 2 === 1
                readonly property bool atBottom: index >= 2
                x: atRight ? box.width + 3 - width : -3
                y: atBottom ? box.height + 3 - height : -3
                width: Math.min(18, box.width / 2 + 3); height: Math.min(18, box.height / 2 + 3)
                Rectangle { y: corner.atBottom ? corner.height - 2 : 0; width: corner.width; height: 2; color: win.tone }
                Rectangle { x: corner.atRight ? corner.width - 2 : 0; width: 2; height: corner.height; color: win.tone }
            }
        }
    }
    Frame {     // its size
        id: sizeChip
        visible: win.has
        readonly property bool under: win.sel.y + win.sel.height + 10 + height <= win.height - 4
        x: Math.max(4, Math.min(win.width - width - 4, win.sel.x + win.sel.width / 2 - width / 2))
        y: under ? win.sel.y + win.sel.height + 10 : win.sel.y + win.sel.height - height - 10
        width: sizeRow.implicitWidth + 30; height: 28
        fill: Qt.rgba(0.024, 0.031, 0.059, 0.92)
        stroke: Theme.alpha(win.tone, 0.9)
        cut: 8
        cutTopLeft: true; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false
        Row {
            id: sizeRow
            anchors.centerIn: parent
            spacing: 8
            HudText { text: win.sizeText; font.pixelSize: 14; font.weight: Font.Bold; font.letterSpacing: 1.5; color: Theme.fg; anchors.verticalCenter: parent.verticalCenter }
            HudText { text: "PX"; font.pixelSize: 9; color: win.tone; anchors.verticalCenter: parent.verticalCenter }
        }
    }
    HudText {   // where it starts, or which window it is
        visible: win.has
        readonly property bool above: win.sel.y - implicitHeight - 7 >= 4
        x: Math.max(4, Math.min(win.width - implicitWidth - 4, win.sel.x))
        y: above ? win.sel.y - implicitHeight - 7 : win.sel.y + 7
        text: win.windowMode ? String(win.aim?.class ?? "") : `X ${Math.round(win.sel.x * win.k)}   Y ${Math.round(win.sel.y * win.k)}`
        font.pixelSize: 10
        color: win.tone
        style: Text.Outline
        styleColor: Qt.rgba(0, 0, 0, 0.7)
    }

    // ---- what to do: the status banner, in its corner (out of the way while a region is dragged)
    HudBanner {
        x: win.width - Grab.bannerRight - width; y: Grab.bannerTop
        visible: !win.dragging
        active: win.open
        title: win.windowMode ? "SELECT A WINDOW TO CAPTURE" : "SELECT A REGION TO CAPTURE"
        tone: win.tone
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.CrossCursor
        onPositionChanged: mouse => win.point(mouse)
        onPressed: mouse => {
            if (mouse.button === Qt.RightButton) return
            win.point(mouse)
            if (!win.windowMode) { win.from = Qt.point(win.mx, win.my); win.dragging = true }
        }
        onReleased: mouse => {      // acts when the button is let go, so the window underneath never sees half a click
            if (mouse.button === Qt.RightButton) { Grab.cancel(); return }
            win.point(mouse)
            win.pick()
            win.dragging = false
        }
    }
}
