// Eliminate mode (Super+Q): the screen goes dark red with a damaged-signal edge, the pointer becomes
// a crosshair, and the window under it is marked as the target. Click (or Super+Q / Q / Enter
// again) to close it; Esc or right-click aborts. One shot, then it's gone.
// The window under the crosshair is worked out from Hyprland's window list (this layer covers the
// screen, so the pointer never reaches the windows): pinned on top, then an open special
// workspace, a fullscreen window, floating windows (most recently focused first), tiled ones.
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.components
import qs.services

PanelWindow {
    id: win
    visible: Ui.killOpen || fx.opacity > 0.01 || flash.running
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:kill"
    WlrLayershell.keyboardFocus: Ui.killOpen && !Ui.demo ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    readonly property var mon: Hyprland.monitors.values.find(m => m.name === win.screen?.name) ?? null
    readonly property real monX: mon?.lastIpcObject?.x ?? 0
    readonly property real monY: mon?.lastIpcObject?.y ?? 0
    property var clients: []
    property real mx: width / 2
    property real my: height / 2
    property var aim: null            // the window under the crosshair (from hyprctl clients -j)
    property var shot: ({ x: 0, y: 0, w: 0, h: 0 })   // the window just eliminated, for the flash
    readonly property color red: Theme.red

    Connections {
        target: Ui
        function onKillOpenChanged() {
            if (!Ui.killOpen) return
            keyUp.reset()
            win.aim = null
            getClients.running = true
            cursorPos.running = true
            Qt.callLater(() => keys.forceActiveFocus())
        }
        function onKillFire() { win.fire() }
    }

    Process {
        id: getClients
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: { try { win.clients = JSON.parse(text) } catch (e) { win.clients = [] } win.reaim() }
        }
    }
    Process {   // where the pointer is when the mode opens (before it moves)
        id: cursorPos
        command: ["hyprctl", "cursorpos", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { const p = JSON.parse(text); win.mx = p.x - win.monX; win.my = p.y - win.monY } catch (e) { }
                win.reaim()
            }
        }
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
    function reaim() {
        const a = windowAt(mx + monX, my + monY)
        if ((a?.address ?? "") !== (aim?.address ?? "")) { aim = a; lock.restart() }
    }
    function fire() {
        const a = win.aim
        if (!Ui.killOpen) return
        if (Ui.demo) { Ui.killOpen = false; return }   // preview (ipc call cyber demo killOpen): never fires
        if (!a) { miss.restart(); return }
        win.shot = { x: a.at[0] - monX, y: a.at[1] - monY, w: a.size[0], h: a.size[1] }
        flash.restart()
        Hyprland.dispatch(`hl.dsp.window.close({ window = "address:${a.address}" })`)
        Ui.killOpen = false
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true
        KeyUp { id: keyUp }   // act on release, so the key doesn't reach the next window
        Keys.onPressed: e => {
            if (e.key === Qt.Key_Escape) keyUp.defer(e, () => Ui.killOpen = false)
            else if (e.key === Qt.Key_Q || e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) keyUp.defer(e, () => win.fire())
            else return
            e.accepted = true
        }
        Keys.onReleased: e => keyUp.release(e)
    }

    // ---- the screen: dark red, damaged edges
    DamageFx {
        id: fx
        anchors.fill: parent
        tint: win.red
        veil: 0.42
        damage: 1
        edgeWidth: 0.2
        opacity: Ui.killOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Ui.killOpen ? 120 : 220; easing.type: Easing.OutCubic } }
    }

    // ---- the target: brackets that snap onto the window under the crosshair
    property real lockT: 1        // 0 = just acquired (brackets wide), 1 = locked
    NumberAnimation { id: lock; target: win; property: "lockT"; from: 0; to: 1; duration: 170; easing.type: Easing.OutCubic }
    Item {
        id: box
        visible: Ui.killOpen && win.aim !== null
        readonly property real grow: (1 - win.lockT) * 18
        x: (win.aim?.at[0] ?? 0) - win.monX - grow
        y: (win.aim?.at[1] ?? 0) - win.monY - grow
        width: (win.aim?.size[0] ?? 0) + 2 * grow
        height: (win.aim?.size[1] ?? 0) + 2 * grow
        opacity: 0.4 + 0.6 * win.lockT

        Rectangle { anchors.fill: parent; color: Theme.alpha(win.red, 0.08); border.width: 1; border.color: Theme.alpha(win.red, 0.35) }
        Repeater {   // corner brackets
            model: 4
            Item {
                required property int index
                readonly property bool isRight: index % 2 === 1
                readonly property bool isBottom: index >= 2
                x: isRight ? box.width - 30 : -2
                y: isBottom ? box.height - 30 : -2
                width: 32; height: 32
                Rectangle { y: parent.isBottom ? 30 : 0; width: 32; height: 2.5; color: win.red }
                Rectangle { x: parent.isRight ? 29.5 : 0; y: 0; width: 2.5; height: 32; color: win.red }
            }
        }
        Column {   // label
            x: 0
            y: box.y > 64 ? -height - 10 : 12
            spacing: 4
            Frame {
                width: tag.implicitWidth + 30
                height: 24
                cut: 8
                cutTopLeft: false; cutTopRight: true; cutBottomRight: false; cutBottomLeft: false
                fill: Theme.alpha(win.red, 0.9)
                stroke: "transparent"
                HudText {
                    id: tag
                    anchors.verticalCenter: parent.verticalCenter
                    x: 10
                    text: "▲ ELIMINATE // " + String(win.aim?.class || win.aim?.initialClass || "UNKNOWN").toUpperCase()
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    color: Theme.ink
                }
            }
            HudText {
                text: String(win.aim?.title ?? "").slice(0, 80)
                font.pixelSize: 10
                color: Theme.alpha(win.red, 0.85)
            }
        }
    }

    // ---- flight guides across the middle of the screen (they stand still): a horizon line with a dip
    // in its middle, a centre line with a marker above and below, two lines running in from the
    // upper corners, a bracket with a reading on either side. After the same model as the reticle
    // (its numbers are that video's pixels, on a screen 880 high: scaled to this one).
    Item {
        id: guides
        visible: Ui.killOpen
        readonly property real k: Math.max(0.25, win.height / 880)
        readonly property real thin: 1 / k + 0.4            // about a pixel and a half on the screen, whatever the scale
        readonly property real reach: win.width / 2 / k - 8          // how far the horizon runs to either side
        readonly property color c: Qt.rgba(0.81, 0.90, 0.93, 0.10)         // faint: a tenth
        x: win.width / 2
        y: win.height / 2
        scale: k
        transformOrigin: Item.TopLeft
        Shape {
            preferredRendererType: Shape.CurveRenderer
            ShapePath {     // the horizon, with its dip
                strokeColor: guides.c; strokeWidth: guides.thin; fillColor: "transparent"
                startX: -guides.reach; startY: 0
                PathLine { x: -77; y: 0 }
                PathLine { x: -64; y: 17 }
                PathLine { x: 64; y: 17 }
                PathLine { x: 77; y: 0 }
                PathLine { x: guides.reach; y: 0 }
            }
            ShapePath {     // the centre line
                strokeColor: guides.c; strokeWidth: guides.thin; fillColor: "transparent"
                startX: 0; startY: -123
                PathLine { x: 0; y: 10 }
            }
            ShapePath {     // from the upper left
                strokeColor: guides.c; strokeWidth: guides.thin; fillColor: "transparent"
                startX: -273; startY: -250
                PathLine { x: -80; y: -170 }
            }
            ShapePath {     // from the upper right
                strokeColor: guides.c; strokeWidth: guides.thin; fillColor: "transparent"
                startX: 273; startY: -250
                PathLine { x: 80; y: -170 }
            }
            ShapePath {     // the bracket on the left
                strokeColor: guides.c; strokeWidth: guides.thin; fillColor: "transparent"
                startX: -275; startY: -83
                PathQuad { x: -258; y: -70; controlX: -258; controlY: -83 }
                PathLine { x: -258; y: -20 }
            }
            ShapePath {     // and on the right
                strokeColor: guides.c; strokeWidth: guides.thin; fillColor: "transparent"
                startX: 275; startY: -83
                PathQuad { x: 258; y: -70; controlX: 258; controlY: -83 }
                PathLine { x: 258; y: -20 }
            }
            ShapePath {     // the marker above the centre line, pointing down
                strokeColor: "transparent"; strokeWidth: 0; fillColor: guides.c
                startX: -5; startY: -160
                PathLine { x: 5; y: -160 }
                PathLine { x: 0; y: -151 }
                PathLine { x: -5; y: -160 }
            }
            ShapePath {     // the one below, pointing up
                strokeColor: "transparent"; strokeWidth: 0; fillColor: Qt.rgba(0.81, 0.90, 0.93, 0.07)
                startX: -5; startY: 58
                PathLine { x: 5; y: 58 }
                PathLine { x: 0; y: 49 }
                PathLine { x: -5; y: 58 }
            }
        }
        Rectangle { x: -1.5; y: -51.5; width: 3; height: 3; radius: 1.5; color: guides.c }      // a dot on the centre line
        Repeater {      // small marks far out, above the horizon
            model: [-393, 393]
            Rectangle { required property real modelData; x: modelData; y: -62; width: guides.thin; height: 9; color: guides.c }
        }
        HudText { x: -244; y: -76; text: "000"; font.pixelSize: 8; color: guides.c }
        HudText { x: 244 - implicitWidth; y: -76; text: "000"; font.pixelSize: 8; color: guides.c }
    }

    // ---- what to do: the status banner, where the capture banners are (components/HudBanner.qml)
    HudBanner {
        x: win.width - Grab.bannerRight - width
        y: Grab.bannerTop
        active: Ui.killOpen
        title: "LOCK ON TARGET TO TERMINATE"
    }

    // ---- crosshair: hairlines across the screen and a reticle on the pointer
    Item {
        anchors.fill: parent
        visible: Ui.killOpen
        readonly property color line: Theme.alpha(win.red, 0.32)
        Rectangle { x: 0; y: Math.round(win.my); width: Math.max(0, win.mx - 54); height: 1; color: parent.line }
        Rectangle { x: win.mx + 54; y: Math.round(win.my); width: Math.max(0, parent.width - win.mx - 54); height: 1; color: parent.line }
        Rectangle { x: Math.round(win.mx); y: 0; width: 1; height: Math.max(0, win.my - 54); color: parent.line }
        Rectangle { x: Math.round(win.mx); y: win.my + 54; width: 1; height: Math.max(0, parent.height - win.my - 54); color: parent.line }

        Item {
            id: reticle
            readonly property real half: 55
            x: win.mx - half
            y: win.my - half
            width: 2 * half; height: 2 * half
            readonly property color c: win.aim ? win.red : Theme.alpha(win.red, 0.7)

            // Its shape follows the reticle of the kill mode that was picked as the model (measured
            // from a video of it, 2026-11-26; drawn here from scratch): three spokes a third of a turn
            // apart, which stand still, and inside them three pieces of an outline (an angled bracket
            // on either side of the upper spoke, a shallow cup under the lower two), which slowly
            // turn. The spokes begin outside that outline (26 px
            // out; it reaches 17), so the turning pieces never run over them. Numbers: pixels from
            // the middle.
            Shape {     // the spokes
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {     // upwards
                    strokeColor: reticle.c; strokeWidth: 2; fillColor: "transparent"; capStyle: ShapePath.FlatCap
                    startX: reticle.half; startY: reticle.half - 44
                    PathLine { x: reticle.half; y: reticle.half - 26 }
                }
                ShapePath {     // down to the left
                    strokeColor: reticle.c; strokeWidth: 2; fillColor: "transparent"; capStyle: ShapePath.FlatCap
                    startX: reticle.half - 22.5; startY: reticle.half + 13
                    PathLine { x: reticle.half - 38.1; y: reticle.half + 22 }
                }
                ShapePath {     // down to the right
                    strokeColor: reticle.c; strokeWidth: 2; fillColor: "transparent"; capStyle: ShapePath.FlatCap
                    startX: reticle.half + 22.5; startY: reticle.half + 13
                    PathLine { x: reticle.half + 38.1; y: reticle.half + 22 }
                }
            }
            Shape {     // the outline between them, turning
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                // (always the same size: it used to tighten on a target, which read as a bug, since
                // the windows are in the middle of the screen and the empty desktop at its edges)
                RotationAnimation on rotation { running: Ui.killOpen; from: 0; to: 360; duration: 6000; loops: Animation.Infinite }
                // A six-sided outline, 15.74 px to its corners, open in three places (7.87 px each): at
                // the top and at the lower left and right, where the model has its spokes pass. Always
                // this size. (How it got here: 24 px was too large, 19.68 a little too large; the
                // openings were 6.56.)
                ShapePath {     // the bracket left of the top opening
                    strokeColor: reticle.c; strokeWidth: 2; fillColor: "transparent"; capStyle: ShapePath.FlatCap; joinStyle: ShapePath.MiterJoin
                    startX: reticle.half - 3.94; startY: reticle.half - 13.63
                    PathLine { x: reticle.half - 7.87; y: reticle.half - 13.63 }
                    PathLine { x: reticle.half - 15.74; y: reticle.half }
                    PathLine { x: reticle.half - 13.78; y: reticle.half + 3.41 }
                }
                ShapePath {     // and right of it
                    strokeColor: reticle.c; strokeWidth: 2; fillColor: "transparent"; capStyle: ShapePath.FlatCap; joinStyle: ShapePath.MiterJoin
                    startX: reticle.half + 3.94; startY: reticle.half - 13.63
                    PathLine { x: reticle.half + 7.87; y: reticle.half - 13.63 }
                    PathLine { x: reticle.half + 15.74; y: reticle.half }
                    PathLine { x: reticle.half + 13.78; y: reticle.half + 3.41 }
                }
                ShapePath {     // the cup below
                    strokeColor: reticle.c; strokeWidth: 2; fillColor: "transparent"; capStyle: ShapePath.FlatCap; joinStyle: ShapePath.MiterJoin
                    startX: reticle.half - 9.84; startY: reticle.half + 10.23
                    PathLine { x: reticle.half - 7.87; y: reticle.half + 13.63 }
                    PathLine { x: reticle.half + 7.87; y: reticle.half + 13.63 }
                    PathLine { x: reticle.half + 9.84; y: reticle.half + 10.23 }
                }
            }
            Rectangle { x: reticle.half - 2; y: reticle.half - 2; width: 4; height: 4; radius: 2; color: reticle.c }
            HudText {
                x: reticle.width - 14; y: reticle.height - 22
                text: `${Math.round(win.mx)},${Math.round(win.my)}  ${win.aim ? "LOCK ON" : "SCANNING"}`
                font.pixelSize: 9
                color: reticle.c
            }
        }
    }

    // ---- banner and hints
    Column {
        visible: Ui.killOpen
        anchors.horizontalCenter: parent.horizontalCenter
        y: Theme.bandTop + 22
        spacing: 6
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 14
            Repeater {
                model: 2
                Item {
                    required property int index
                    width: 230; height: 12
                    Rectangle { y: 6; width: parent.width; height: 1; color: win.red }
                    Repeater {
                        model: 5
                        Rectangle { required property int index; x: index * 57; y: 1; width: 1; height: 11; color: win.red }
                    }
                }
            }
        }
        HudText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "ELIMINATE PROTOCOL  //  ARMED"
            font.family: Theme.display
            font.pixelSize: 15
            font.weight: Font.Bold
            font.letterSpacing: 4
            color: win.red
            SequentialAnimation on opacity {
                running: Ui.killOpen; loops: Animation.Infinite
                NumberAnimation { to: 0.55; duration: 600 }
                NumberAnimation { to: 1; duration: 600 }
            }
        }
    }
    HudText {
        id: hint
        visible: Ui.killOpen
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.bandBottom + 30
        text: "⚠  [CLICK / SUPER+Q] ELIMINATE    [ESC / RIGHT CLICK] ABORT"
        font.pixelSize: 11
        font.letterSpacing: 1.5
        color: Theme.alpha(win.red, 0.9)
        transform: Translate { id: shake }
        SequentialAnimation {   // shakes when you fire at nothing
            id: miss
            NumberAnimation { target: shake; property: "x"; to: 8; duration: 40 }
            NumberAnimation { target: shake; property: "x"; to: -8; duration: 60 }
            NumberAnimation { target: shake; property: "x"; to: 0; duration: 40 }
        }
    }

    // ---- click anywhere: fire (left) / abort (right)
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.BlankCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPositionChanged: m => { win.mx = m.x; win.my = m.y; win.reaim() }
        onClicked: m => m.button === Qt.RightButton ? Ui.killOpen = false : win.fire()
    }

    // ---- the shot: the eliminated window flashes red-white and burns out
    Rectangle {
        id: shotRect
        x: win.shot.x; y: win.shot.y; width: win.shot.w; height: win.shot.h
        color: "white"
        opacity: 0
        SequentialAnimation {
            id: flash
            PropertyAction { target: shotRect; property: "color"; value: "white" }
            NumberAnimation { target: shotRect; property: "opacity"; from: 0.85; to: 0.5; duration: 50 }
            PropertyAction { target: shotRect; property: "color"; value: Theme.red }
            NumberAnimation { target: shotRect; property: "opacity"; to: 0; duration: 260; easing.type: Easing.OutCubic }
        }
    }
}
