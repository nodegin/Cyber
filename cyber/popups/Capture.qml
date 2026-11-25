// Capture HUD (PrintScrn, or the camera button): a SCREENSHOT or a RECORDING of a REGION / WINDOW / SCREEN.
// Tab or ←/→ switch between screenshot and recording; ↑/↓ and Enter, the letter keys, or PrintScrn
// again for the whole screen. Esc closes.
// A screenshot goes to ~/Pictures/Screenshots and the clipboard (scripts/capture.sh). A recording runs
// until PrintScrn or the camera button is pressed again and goes to ~/Videos/Recordings
// (scripts/record.sh, services/Recorder.qml). What happens after the choice (picking the region or
// window, the "recording started" banner) is services/Grab.qml.
//
// Where: the top-right corner of the screen, under the top band, as far from the edges as the Looking
// Glass panel is on the left, and drawn as that panel's mirror image: swung back on its right edge,
// so its left side recedes, and bent (shaders/curve.vert with flip = 1; Config.captureTilt: 0 = flat,
// below 0 = turned the other way). Because the dialog is drawn on that surface, what is under the
// pointer is not where its item is: one MouseArea over everything takes the pointer back onto the
// flat dialog (flat(), the shader's inverse) and looks up what was meant.
// A changed shader (.qsb) is only loaded by a NEW shell process: a reload keeps the old one.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.components
import qs.services

PanelWindow {
    id: win
    visible: Ui.captureOpen || fx.busy
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:capture"
    WlrLayershell.keyboardFocus: Ui.captureOpen && !Ui.demo ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    readonly property var modes: [
        { key: "R", icon: "screenshot_region", label: "REGION", hint: "DRAG TO SELECT", mode: "region" },
        { key: "W", icon: "select_window", label: "WINDOW", hint: "CLICK A WINDOW", mode: "window" },
        { key: "S", icon: "screenshot_monitor", label: "SCREEN", hint: "EVERYTHING ON THIS SCREEN", mode: "screen" },
    ]
    property int index: 0
    readonly property bool video: Ui.captureVideo      // false: a screenshot, true: a recording (kept while the shell runs)
    readonly property color accent: video ? Theme.red : Theme.yellow       // the mode's colour: yellow = screenshot, red = recording
    property int revealed: 0
    Timer { id: reveal; interval: 35; repeat: true; onTriggered: { win.revealed++; if (win.revealed >= win.modes.length) stop() } }

    Connections {
        target: Ui
        function onCaptureOpenChanged() {
            if (!Ui.captureOpen) return
            win.index = 0; win.revealed = 0; reveal.restart(); titleFx.play(); keyUp.reset()
            Qt.callLater(() => keys.forceActiveFocus())
        }
    }

    // The capture starts only once this HUD is completely off the screen: its glitch-out and fade
    // are over and the window is gone. Otherwise the still picture of the screen would show the HUD.
    property string pending: ""
    property bool pendingVideo: false
    function shoot(i) {
        win.pending = modes[i].mode
        win.pendingVideo = win.video
        Ui.captureOpen = false
    }
    onVisibleChanged: if (!visible && win.pending !== "") startCapture.restart()
    Timer {
        id: startCapture
        interval: 60      // a few frames for Hyprland to draw the screen without the HUD
        onTriggered: {
            if (win.visible || win.pending === "") return
            Grab.start(win.pendingVideo, win.pending)      // services/Grab.qml: the picker, the banner, the script
            win.pending = ""
        }
    }

    // ---- the pointer on the tilted dialog
    readonly property real tilt: Math.abs(Config.captureTilt)
    readonly property bool mirrored: Config.captureTilt >= 0     // hinged on its right edge (the shader's flip)
    // A point as seen (stage coordinates) -> the same point on the flat dialog, or null beside it.
    // The inverse of shaders/curve.vert: keep the two in step.
    function flat(sx, sy) {
        const W = stage.width, H = stage.height, t = win.tilt
        if (t <= 0) return Qt.point(sx, sy)
        const d = W * 1.6, a = 21 * Math.PI / 180 * t, b = -3 * Math.PI / 180 * t, k = Config.lgCurve
        const q = sy - H / 2
        const y1 = q / (Math.cos(b) + q * Math.sin(b) / d)          // undo the tip back
        const w2 = 1 - y1 * Math.sin(b) / d
        const at = xs => {      // a point xs from the hinge edge: [where it lands (times w2), how far away it is]
            const u = Math.max(0, Math.min(1, xs / W)), z = -k * W * 4 * u * (1 - u) * t
            const x1 = xs * Math.cos(a) + z * Math.sin(a), w1 = 1 - (-xs * Math.sin(a) + z * Math.cos(a)) / d
            return [x1 / w1, w1]
        }
        const want = (win.mirrored ? W - sx : sx) * w2
        let lo = -stage.room, hi = W + stage.room
        if (want < at(lo)[0] || want > at(hi)[0]) return null
        for (let i = 0; i < 24; i++) { const mid = (lo + hi) / 2; if (at(mid)[0] < want) lo = mid; else hi = mid }
        const xs = (lo + hi) / 2
        return Qt.point(win.mirrored ? W - xs : xs, y1 * at(xs)[1] + H / 2)
    }
    function flatAt(wx, wy) { const p = stage.mapFromItem(null, wx, wy); return flat(p.x, p.y) }   // from a point of this window
    function onDialog(wx, wy) { const f = flatAt(wx, wy); return f !== null && f.x >= 0 && f.y >= 0 && f.x < stage.width && f.y < stage.height }
    function targetAt(wx, wy) {     // the switch or row drawn there (each has hover() and tap()), or null
        const f = flatAt(wx, wy)
        if (!f) return null
        for (const list of [kinds, rows]) {
            for (let i = 0; i < list.count; i++) {
                const it = list.itemAt(i)
                if (!it || !it.visible) continue
                const p = it.mapFromItem(stage, f.x, f.y)
                if (p.x >= 0 && p.y >= 0 && p.x < it.width && p.y < it.height) return it
            }
        }
        return null
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true
        KeyUp { id: keyUp }   // closing keys act on release (see components/KeyUp.qml)
        Keys.onPressed: e => {
            const byKey = win.modes.findIndex(m => m.key === e.text.toUpperCase())
            if (e.key === Qt.Key_Escape) keyUp.defer(e, () => Ui.captureOpen = false)
            else if (e.key === Qt.Key_Left || e.key === Qt.Key_Right || e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) Ui.captureVideo = !Ui.captureVideo
            else if (e.key === Qt.Key_Up) win.index = (win.index + win.modes.length - 1) % win.modes.length
            else if (e.key === Qt.Key_Down) win.index = (win.index + 1) % win.modes.length
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) { const i = win.index; keyUp.defer(e, () => win.shoot(i)) }
            else if (e.key === Qt.Key_Print) keyUp.defer(e, () => win.shoot(2))
            else if (byKey >= 0) keyUp.defer(e, () => win.shoot(byKey))
            else return
            e.accepted = true
        }
        Keys.onReleased: e => keyUp.release(e)
    }

    Scramble { id: titleFx; visible: false; target: "OPTICAL CAPTURE" }

    // A dialog in the top-right corner; everything else stays visible and untouched
    Item {
        id: stage
        // Turned the other way (not mirrored) its right side recedes, which brings that edge in: `far`
        // is where the edge is drawn, and the item is moved out by the difference, so the edge as
        // drawn is 12 px from the screen's either way.
        readonly property real far: {
            const a = 21 * Math.PI / 180 * win.tilt
            return win.mirrored ? width : width * Math.cos(a) / (1 + Math.sin(a) / 1.6)
        }
        anchors { top: parent.top; right: parent.right; topMargin: Theme.bandTop + 12; rightMargin: 12 - (width - far) }
        width: Math.round(dialog.width * Config.captureScale)      // the dialog is drawn larger (Config.captureScale): its
        height: Math.round(dialog.height * Config.captureScale)    // own sizes stay as they are, it is scaled as a whole
        readonly property int room: 20          // the glitch reaches this far past the dialog
        // drawn flat into a picture (twice the size, so the small text stays sharp where it recedes),
        // and the shader puts that picture on the curved surface
        layer.enabled: win.tilt > 0
        layer.smooth: true
        layer.sourceRect: Qt.rect(-room, -room, width + 2 * room, height + 2 * room)
        layer.textureSize: Qt.size(2 * (width + 2 * room), 2 * (height + 2 * room))
        layer.effect: ShaderEffect {
            mesh: GridMesh { resolution: Qt.size(48, 1) }
            vertexShader: Qt.resolvedUrl("../shaders/curve.vert.qsb")
            fragmentShader: Qt.resolvedUrl("../shaders/curve.frag.qsb")
            property real tilt: win.tilt
            property real curve: Config.lgCurve
            property real margin: stage.room
            property point size: Qt.point(stage.width, stage.height)
            property real flip: win.mirrored ? 1 : 0
        }

        Glitch {
            id: fx
            anchors.fill: parent
            anchors.margins: -stage.room
            active: Ui.captureOpen
            flicker: 0.2

            HudDialog {
                id: dialog
                anchors.centerIn: parent
                scale: Config.captureScale
                title: titleFx.text
                subtitle: win.video ? "// VIDEO BUFFER  ·  SELECT MODE" : "// IMAGE BUFFER  ·  SELECT MODE"
                footer: win.video ? "SAVED TO ~/VIDEOS/RECORDINGS  ·  PRTSC STOPS IT" : "SAVED TO ~/PICTURES/SCREENSHOTS  ·  COPIED TO CLIPBOARD"

                Column {
                    spacing: 8

                    // what to make: a screenshot or a recording
                    Row {
                        spacing: 8
                        Repeater {
                            id: kinds
                            model: [
                                { video: false, icon: "photo_camera", label: "SCREENSHOT" },
                                { video: true, icon: "videocam", label: "RECORDING" },
                            ]
                            Frame {
                                id: kind
                                required property var modelData
                                readonly property bool on: win.video === modelData.video
                                readonly property color tint: modelData.video ? Theme.red : Theme.yellow
                                width: 196; height: 34
                                cut: 8
                                cutTopLeft: true; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false
                                fill: on ? Theme.alpha(tint, 0.2) : Qt.rgba(0, 0, 0, 0.25)
                                stroke: on ? tint : Theme.alpha("#cfe6ec", 0.35)
                                Row {
                                    anchors.centerIn: parent
                                    spacing: 9
                                    Icon { name: kind.modelData.icon; size: 16; color: kind.on ? kind.tint : Theme.alpha(Theme.teal, 0.6); anchors.verticalCenter: parent.verticalCenter }
                                    HudText {
                                        text: kind.modelData.label
                                        font.pixelSize: 12
                                        font.weight: Font.DemiBold
                                        font.letterSpacing: 1.2
                                        color: kind.on ? kind.tint : Theme.alpha(Theme.teal, 0.6)
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }
                                function hover() {}
                                function tap() { Ui.captureVideo = modelData.video }
                            }
                        }
                    }
                    Item { width: 1; height: 4 }

                    Repeater {
                        id: rows
                        model: win.modes
                        Glitch {
                            id: rowFx
                            required property var modelData
                            required property int index
                            readonly property bool selected: index === win.index
                            active: Ui.captureOpen && index < win.revealed
                            width: 400
                            height: 36
                            speed: 1.4
                            maxMs: 300
                            flicker: 0.15

                            Rectangle {   // highlight of the selected row
                                anchors.fill: parent
                                visible: rowFx.selected
                                color: Theme.alpha(win.accent, 0.09)
                                Rectangle { width: 2; height: parent.height; color: win.accent }
                            }
                            Frame {   // key chip
                                id: chip
                                x: 10
                                anchors.verticalCenter: parent.verticalCenter
                                width: 32; height: 24
                                cut: 6
                                cutTopLeft: true; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false
                                fill: rowFx.selected ? Theme.alpha(win.accent, 0.22) : Qt.rgba(0, 0, 0, 0.25)
                                stroke: rowFx.selected ? win.accent : Theme.alpha("#cfe6ec", 0.55)
                                HudText {
                                    anchors.centerIn: parent
                                    text: rowFx.modelData.key
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                    color: rowFx.selected ? win.accent : "#dceff3"
                                }
                            }
                            Icon {
                                id: icon
                                anchors { left: chip.right; leftMargin: 16; verticalCenter: parent.verticalCenter }
                                name: rowFx.modelData.icon
                                size: 17
                                color: rowFx.selected ? win.accent : Theme.teal
                            }
                            HudText {
                                anchors { left: icon.right; leftMargin: 10; verticalCenter: parent.verticalCenter }
                                text: rowFx.modelData.label
                                font.pixelSize: 12
                                font.weight: Font.DemiBold
                                font.letterSpacing: 1.2
                                color: rowFx.selected ? win.accent : Theme.teal
                            }
                            HudText {
                                anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                                text: rowFx.modelData.hint
                                font.pixelSize: 9
                                color: Theme.alpha(Theme.teal, rowFx.selected ? 0.9 : 0.5)
                            }
                            function hover() { win.index = index }
                            function tap() { win.shoot(index) }
                        }
                    }

                    Item { width: 1; height: 10 }
                    HudText { text: "// CONTROLS"; font.pixelSize: 10; color: Theme.alpha(Theme.teal, 0.85) }
                    Grid {
                        columns: 2
                        columnSpacing: 60
                        rowSpacing: 7
                        Repeater {
                            model: [["TAB  ← →", "SCREENSHOT / RECORDING"], ["↑ ↓", "SELECT"], ["ENTER", win.video ? "RECORD" : "CAPTURE"], ["PRTSC", "WHOLE SCREEN"], ["ESC", "CANCEL"]]
                            Row {
                                required property var modelData
                                spacing: 12
                                HudText { text: modelData[0]; font.pixelSize: 10; font.weight: Font.DemiBold; color: Theme.teal }
                                HudText { text: modelData[1]; font.pixelSize: 10; color: "#dceff3" }
                            }
                        }
                    }
                }
            }
        }
    }

    MouseArea {     // every pointer event of this window (see the top of the file)
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        property var over: null
        cursorShape: over ? Qt.PointingHandCursor : Qt.ArrowCursor
        function look(mouse) { over = Ui.captureOpen ? win.targetAt(mouse.x, mouse.y) : null; if (over) over.hover() }
        onPositionChanged: mouse => look(mouse)
        onExited: over = null
        onClicked: mouse => {
            const t = win.targetAt(mouse.x, mouse.y)
            if (t) t.tap()
            else if (!win.onDialog(mouse.x, mouse.y)) Ui.captureOpen = false     // beside the dialog: cancel
        }
    }
}
