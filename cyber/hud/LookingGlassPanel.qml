// Looking Glass, tilted: while the VM's window is idle (the pointer isn't on it) it hangs in its
// corner of the desktop as a live 3D panel (tilted and slightly curved), under every other window.
// Point at it and it comes forward: it swings flat above the other windows and becomes the real
// window.
//
// How: the real window never moves; idle, it is the bottom-most window (hypr/lookingglass.lua). This
// layer is on the desktop level right below it and shows a live copy. Hyprland only produces frames for
// windows it draws, so the real one can't be parked elsewhere: instead it is made invisible while it
// carries the tag "cybertilt". This file is the only place that sets and clears that tag:
//   losing focus:  copy appears (flat, exactly under the window) -> tag: the window vanishes -> the copy tilts
//   getting focus: the copy swings flat -> tag off: the window appears on top of it -> the copy hides
// So nothing ever shows twice or not at all. Idle, the real window lets the pointer through (Hyprland
// would otherwise hand it the pointer even under a tiled window); this panel takes it instead, where
// it shows, and asks Hyprland to bring the window forward. Idle or engaged is decided by Hyprland
// (LookingGlass.focused), in one place.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.components
import qs.services

PanelWindow {
    id: win

    readonly property var w: LookingGlass.window
    readonly property int pad: 12
    readonly property var mon: w ? Hyprland.monitors.values.find(m => m.id === w.monitor) ?? null : null
    readonly property real monX: mon?.lastIpcObject?.x ?? 0
    readonly property real monY: mon?.lastIpcObject?.y ?? 0

    // in its spot (not fullscreen, not minimized). Hyprland keeps it on the workspace being looked at.
    readonly property bool present: w !== null && LookingGlass.toplevel !== null && w.fullscreen === 0
        && !String(w.workspace?.name ?? "").startsWith("special")
    // the copy should be standing in for the window
    readonly property bool tiltOn: present && view.hasContent && !LookingGlass.focused

    property real tilt: 0            // 0 flat .. 1 tilted
    // How the copy is kept current. Fetching a frame is not free: Hyprland redraws the whole screen once
    // for every frame it hands out, and hands them out whether or not the window changed.
    //   no picture yet, or swinging:  live (every frame Hyprland can give)
    //   settled idle (paced):         one frame when the real window has drawn something new (the corners
    //                                 plugin says so), at most Config.lgPreviewFps a second: a VM that
    //                                 is not changing costs nothing
    //   engaged, copy hidden (resting): nothing; it goes live again the moment the pointer leaves
    readonly property bool paced: Config.lgPreviewFps > 0 && present && view.hasContent && showCopy && wantTag && tilt >= 1
        && LookingGlass.toplevel !== null && !streamNow
    //   settled idle, VM picture moving (a video, a game): live again (streaming). Fetching one frame
    //                                 per signal cannot keep up with a moving picture: a fetch takes two
    //                                 refreshes and the frames asked for meanwhile are lost, so a 60 fps
    //                                 picture came out at about 25 uneven frames a second (measured, and
    //                                 reported as video stutter, 2026-11-24). Live gives a steady half of
    //                                 the monitor's rate. It starts when new pictures have kept coming
    //                                 for 0.4 s (20 a second or more) and ends 0.6 s after they stop.
    //                                 Not while other windows cover (nearly) all of it: there it only
    //                                 shows through their glass and live cost 12% more GPU (measured).
    property int recentPics: 0          // "new picture" signals in the current 200 ms
    property int busyFor: 0             // ... consecutive busy / quiet 200 ms slices
    property int quietFor: 0
    property bool streaming: false
    readonly property bool streamNow: streaming && Config.lgStream && LookingGlass.covered < 0.9
    Timer {
        running: win.present && win.showCopy && LookingGlass.frameSignal && Config.lgStream
        interval: 200; repeat: true
        onRunningChanged: if (!running) { win.streaming = false; win.busyFor = 0; win.quietFor = 0; win.recentPics = 0 }
        onTriggered: {
            const busy = win.recentPics >= 4
            win.recentPics = 0
            if (busy) { win.busyFor++; win.quietFor = 0 } else { win.quietFor++; win.busyFor = 0 }
            if (!win.streaming && win.busyFor >= 2) win.streaming = true
            else if (win.streaming && win.quietFor >= 3) win.streaming = false
        }
    }
    readonly property bool resting: present && view.hasContent && LookingGlass.focused && !showCopy && !wantTag
    // The capture can fail: Hyprland refuses a frame while the window is changing size (the client
    // does that right after it opens, and when the guest changes resolution), and Quickshell then
    // stops capturing for good. Without a picture the copy never takes over and the real window
    // stays on screen over everything (seen on 2026-11-24). So: no picture although there should
    // be one, or the window changed size -> start the capture afresh.
    property bool srcOn: true
    function restartCapture() { if (srcOn) { srcOn = false; srcBack.restart() } }
    Timer { id: srcBack; interval: 40; onTriggered: win.srcOn = true }
    Timer {
        running: win.present && win.srcOn && LookingGlass.toplevel !== null && !view.hasContent
        interval: 500; repeat: true
        onTriggered: win.restartCapture()
    }
    readonly property string sizeKey: w ? `${w.size[0]}x${w.size[1]}` : ""
    onSizeKeyChanged: if (present && view.hasContent) restartCapture()

    property double lastGrab: 0
    // Hidden under other windows it only shows through their blurred glass: a lower rate is enough there
    // (every frame fetched makes Hyprland redraw the whole screen once).
    readonly property real previewFps: LookingGlass.covered >= 0.9 ? Math.min(Config.lgPreviewFps, Config.lgCoveredFps) : Config.lgPreviewFps
    function grab() {
        if (!paced) return
        const gap = 1000 / Math.max(1, previewFps), since = Date.now() - lastGrab
        if (since >= gap) { lastGrab = Date.now(); view.captureFrame() }
        else if (!grabLater.running) { grabLater.interval = Math.max(1, gap - since); grabLater.start() }
    }
    Timer { id: grabLater; onTriggered: win.grab() }
    onPacedChanged: if (paced) grab()          // settled: one more frame, so nothing from the swing is missed
    Connections {
        target: Hyprland
        function onRawEvent(event) { if (event.name === "cybertiltframe") { win.recentPics++; win.grab() } }
    }
    // the plugin's signal is the normal way; once a second anyway, in case one was missed
    Timer { running: win.paced && win.visible && LookingGlass.frameSignal; interval: 1000; repeat: true; onTriggered: win.grab() }
    // no signal (plugin not loaded, or older than 3.2): a plain timer
    Timer {
        running: win.paced && win.visible && !LookingGlass.frameSignal
        interval: Math.round(1000 / Math.max(1, win.previewFps)); repeat: true
        onTriggered: win.grab()
    }
    property bool showCopy: false    // the copy is drawn
    property bool wantTag: false     // the real window should be invisible

    onTiltOnChanged: {
        if (tiltOn) {
            flatten.stop(); hideCopy.stop()
            showCopy = true
            hideWindow.restart()       // a moment later, once the copy is on screen
        } else if (!present) {
            hideWindow.stop(); swing.stop(); flatten.stop(); hideCopy.stop()
            wantTag = false; showCopy = false; tilt = 0
        } else {
            hideWindow.stop(); swing.stop()
            if (showCopy) flatten.restart(); else wantTag = false
        }
    }
    Timer { id: hideWindow; interval: 70; onTriggered: { win.wantTag = true; fx.shock(); swing.restart() } }
    NumberAnimation { id: swing; target: win; property: "tilt"; to: 1; duration: 460; easing.type: Easing.OutCubic }
    NumberAnimation {
        id: flatten; target: win; property: "tilt"; to: 0; duration: 220; easing.type: Easing.OutCubic
        onFinished: { win.wantTag = false; hideCopy.restart() }
    }
    Timer { id: hideCopy; interval: 90; onTriggered: if (!win.tiltOn) win.showCopy = false }

    // ---- the tag, kept in step with wantTag (checked again whenever the window is re-read)
    // What we know of the window's tags is as old as the last look at Hyprland's window list (there is
    // no event for a tag change): up to a second. So a change of wantTag is always sent (adding a tag
    // twice or removing a missing one does nothing); only the later re-checks compare first. Trusting
    // the old list made the window stay on screen for up to a second when the pointer came and went
    // quickly: the list still said "tagged" from before, so nothing was sent (seen in a recording,
    // 2026-11-24).
    function syncTag(always) {
        if (!w) return
        const has = (w.tags ?? []).some(t => String(t).replace(/\*$/, "") === "cybertilt")
        if (always || has !== wantTag) {
            Hyprland.dispatch(`hl.dsp.window.tag({ tag = "${wantTag ? "+" : "-"}cybertilt", window = "address:${w.address}" })`)
            LookingGlass.refresh()
        }
    }
    onWantTagChanged: syncTag(true)
    onWChanged: syncTag(false)
    Component.onDestruction: {
        if (w) Quickshell.execDetached(["hyprctl", "dispatch",
            `hl.dsp.window.tag({ tag = "-cybertilt", window = "address:${w.address}" })`])
    }

    screen: Quickshell.screens.find(s => s.name === win.mon?.name) ?? Quickshell.screens[0]
    visible: present
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    // idle: on the desktop, under every window. Engaged (the pointer is on it): above the windows,
    // like the real window, so the swing flat is seen and lands exactly on it.
    WlrLayershell.layer: LookingGlass.focused ? WlrLayer.Top : WlrLayer.Bottom
    WlrLayershell.namespace: "cyber:lg"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors { top: true; left: true }
    margins {
        left: w ? Math.max(0, w.at[0] - win.monX - win.pad) : 0
        top: w ? Math.max(0, w.at[1] - win.monY - win.pad) : 0
    }
    implicitWidth: (w?.size[0] ?? 100) + 2 * pad
    implicitHeight: (w?.size[1] ?? 100) + 2 * pad
    // Idle: takes the pointer where the copy is. It is under every window, so that is only where
    // nothing covers it. Engaged (above the windows): nothing, the real window has the pointer.
    mask: LookingGlass.focused ? nowhere : spot
    Region { id: nowhere }
    Region { id: spot; item: stage }
    function reach() {
        if (LookingGlass.focused || reachGap.running) return
        LookingGlass.engage()
        reachGap.start()
    }
    Timer { id: reachGap; interval: 200 }

    Item {
        id: stage
        x: win.pad
        y: win.pad
        width: win.w?.size[0] ?? 100
        height: win.w?.size[1] ?? 100
        opacity: win.showCopy ? 1 : 0     // kept "visible" so the capture stays warm
        // Swung back on its left edge (the right side recedes), tipped back a touch, and bent like a
        // wrap-around display: the panel is drawn flat into a picture, and shaders/curve.vert puts
        // that picture on the curved surface (Config.lgCurve; 0 = a flat sheet). The picture has a
        // few pixels of room around the panel, so the outline is not cut and its edge stays soft.
        readonly property int room: 4
        layer.enabled: true
        layer.smooth: true
        layer.sourceRect: Qt.rect(-room, -room, width + 2 * room, height + 2 * room)
        layer.effect: ShaderEffect {
            mesh: GridMesh { resolution: Qt.size(48, 1) }
            vertexShader: Qt.resolvedUrl("../shaders/curve.vert.qsb")
            fragmentShader: Qt.resolvedUrl("../shaders/curve.frag.qsb")
            property real tilt: win.tilt
            property real curve: Config.lgCurve
            property real margin: stage.room
            property point size: Qt.point(stage.width, stage.height)
            property real flip: 0        // hinged on its left edge (1 = the mirror image, as the capture HUD uses it)
        }

        MouseArea {   // the pointer on the idle copy: come forward
            anchors.fill: parent
            z: 5
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
            onEntered: win.reach()
            onPositionChanged: win.reach()
            onPressed: win.reach()
        }

        Glitch {
            id: fx
            anchors.fill: parent
            active: win.present
            flicker: 0.2

            // The copy (see "How the copy is kept current" at the top). Live until the first frame is
            // there, so it can never be stuck without a picture (a plain timer did that on 2026-11-23).
            ScreencopyView {
                id: view
                anchors.fill: parent
                captureSource: win.present && win.srcOn ? LookingGlass.toplevel : null
                live: !win.paced && !win.resting
                onStopped: if (win.present && win.srcOn) stoppedRetry.restart()   // Hyprland refused a frame: Quickshell gave up
            }
            Timer { id: stoppedRetry; interval: 150; onTriggered: if (win.present) win.restartCapture() }

            // HUD dressing, fading in with the tilt
            Item {
                anchors.fill: parent
                opacity: win.tilt

                Rectangle { anchors.fill: parent; color: Theme.alpha(Theme.ink, 0.16) }
                Column {   // scanlines
                    anchors.fill: parent
                    clip: true
                    Repeater {
                        model: Math.ceil(stage.height / 3)
                        Item {
                            width: stage.width; height: 3
                            Rectangle { width: parent.width; height: 1; color: Qt.rgba(0, 0, 0, 0.18) }
                        }
                    }
                }
                Frame {
                    anchors.fill: parent
                    anchors.margins: -1
                    fill: "transparent"
                    stroke: Theme.alpha(Theme.red, 0.9)
                    strokeWidth: 1.5
                    cut: 18
                    cutTopLeft: false; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false
                }
                Rectangle {   // title chip
                    x: 10; y: 10
                    width: title.implicitWidth + 18
                    height: title.implicitHeight + 8
                    color: Theme.alpha(Theme.ink, 0.72)
                    border.width: 1
                    border.color: Theme.alpha(Theme.yellow, 0.5)
                    HudText {
                        id: title
                        anchors.centerIn: parent
                        text: `${LookingGlass.vm.toUpperCase()} // LOOKING GLASS`
                        color: Theme.yellow
                        font.pixelSize: Theme.textSmall
                        font.bold: true
                    }
                }
                Row {   // link status
                    anchors { right: parent.right; top: parent.top; rightMargin: 12; topMargin: 14 }
                    spacing: 6
                    Rectangle {
                        width: 7; height: 7
                        anchors.verticalCenter: parent.verticalCenter
                        color: LookingGlass.vmRunning ? Theme.green : Theme.red
                        // the same slow pulse, in 10 steps a second: a smooth animation would make
                        // the whole panel redraw 60 times a second for one 7 px dot
                        property int beat: 0
                        opacity: 0.25 + 0.75 * Math.abs(1 - (beat % 14) / 7)
                        Timer { running: win.visible && win.showCopy; interval: 100; repeat: true; onTriggered: parent.beat++ }
                    }
                    HudText {
                        text: LookingGlass.vmRunning ? "UPLINK LIVE" : "NO SIGNAL"
                        color: LookingGlass.vmRunning ? Theme.green : Theme.red
                        font.pixelSize: Theme.textSmall
                    }
                }
                HudText {
                    anchors { left: parent.left; bottom: parent.bottom; leftMargin: 12; bottomMargin: 8 }
                    text: "CLICK TO LINK  ·  SUPER+F FULLSCREEN"
                    color: Theme.dim
                    font.pixelSize: 9
                }
            }
        }
    }
}
