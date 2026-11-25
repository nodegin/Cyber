// Quick look: Space on a file in GNOME Files shows it here, as a HUD readout over the desktop.
// Pictures, videos, sound, text (JSON re-indented), PDF first pages; for anything else what it is.
// Space again closes it, the arrow keys in Files flip to the next file, a click closes it too.
//
// Who does what: Files calls a D-Bus previewer on Space; scripts/previewer.py is that previewer and
// only describes the file (services/Preview.qml reads what it writes). This panel never takes the
// keyboard: Files keeps it, which is why Space and the arrows keep working there.
//
// The look: a thin notched frame, a red status strip, the file's type as a large readout with its
// name in yellow, the content in an inner frame with corner ticks, data labels in the lower
// corners. Videos and sound play at once; a click on them pauses.
import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.components
import qs.services

PanelWindow {
    id: win
    visible: Preview.open || fx.busy
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"      // nothing over the rest of the screen: Files stays readable (and Hyprland would blur under any tint)
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:preview"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None      // Files keeps the keys: Space closes, arrows flip

    // what is on the panel: the last file, kept while the panel glitches out
    property var it: ({})
    readonly property string kind: it.kind ?? ""
    readonly property bool plays: kind === "video" || kind === "audio"
    Connections {
        target: Preview
        function onItemChanged() {
            startDelay.stop()
            win.scrub = -1
            if (!Preview.open) { player.stop(); return }
            win.it = Preview.item
            if (win.plays) {
                player.stop()
                player.source = Preview.fileUrl
                player.pause()              // loads it and shows the first frame…
                startDelay.restart()        // …and it starts half a second later (flipping through files stays quiet)
            } else { player.stop(); player.source = "" }
            if (win.kind === "text") textFile.reload()
            readout.play()
        }
    }

    // ---- playing: start after a pause, play / pause, seek
    Timer { id: startDelay; interval: 500; onTriggered: if (Preview.open && win.plays) player.play() }
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    readonly property bool loaded: player.mediaStatus >= MediaPlayer.LoadedMedia && player.mediaStatus !== MediaPlayer.InvalidMedia
    function toggle() {
        if (startDelay.running) return startDelay.stop()        // clicked before it started: it stays paused
        playing ? player.pause() : player.play()
    }
    property real scrub: -1         // 0..1 while the seek bar is dragged (the player follows a little behind), otherwise -1
    readonly property real progress: scrub >= 0 ? scrub : player.duration > 0 ? Math.min(1, player.position / player.duration) : 0
    function seekTo(f) {
        if (player.duration <= 0 || !player.seekable) return
        if (player.playbackState === MediaPlayer.StoppedState) player.pause()      // played to its end: stay on the picked frame
        player.position = Math.round(Math.max(0, Math.min(1, f)) * Math.max(0, player.duration - 100))
    }
    function nudge(ms) {
        if (player.duration <= 0 || !player.seekable) return
        const from = scrub >= 0 ? scrub * player.duration : player.position       // several steps in a row add up
        scrub = Math.max(0, Math.min(1, (from + ms) / player.duration))
        seekTo(scrub); settle.restart()
    }
    Timer { id: seekSoon; interval: 60; onTriggered: if (win.scrub >= 0) win.seekTo(win.scrub) }   // while dragging: at most 16 seeks a second
    Timer { id: settle; interval: 300; onTriggered: win.scrub = -1 }                                // after letting go: until the player is there

    // a fact about what plays, from its first video / audio track or from the file itself
    function fact(key, tracks) {
        const from = tracks && tracks.length ? tracks[0] : player.metaData
        return from ? (from.stringValue(key) ?? "") : ""
    }
    readonly property string mediaInfo: {
        const parts = []
        if (kind === "video") {
            if (video.sourceRect.width > 0) parts.push(`${video.sourceRect.width} × ${video.sourceRect.height}`)
            const fps = Number(fact(MediaMetaData.VideoFrameRate, player.videoTracks))
            if (fps > 0) parts.push(`${Math.round(fps * 100) / 100} FPS`)
            const vc = fact(MediaMetaData.VideoCodec, player.videoTracks)
            if (vc) parts.push(vc)
        }
        const ac = fact(MediaMetaData.AudioCodec, player.audioTracks)
        if (ac) parts.push(ac)
        else if (kind === "video" && loaded) parts.push("NO SOUND")
        return parts.join("  ·  ")
    }
    readonly property string ext: {
        if (kind === "folder") return "DIR"
        const n = it.name ?? "", i = n.lastIndexOf(".")
        return i > 0 && n.length - i <= 6 ? n.slice(i + 1).toUpperCase() : (kind || "FILE").toUpperCase()
    }
    function clock(ms) {
        const s = Math.max(0, Math.floor(ms / 1000)), p = v => String(v).padStart(2, "0")
        return s >= 3600 ? `${Math.floor(s / 3600)}:${p(Math.floor(s / 60) % 60)}:${p(s % 60)}` : `${p(Math.floor(s / 60))}:${p(s % 60)}`
    }
    readonly property string detail: {
        if (kind === "image") return picture.status === Image.Ready ? `${picture.implicitWidth} × ${picture.implicitHeight} PX` : "DECODING"
        if (kind === "pdf") return pdf.status === Image.Ready ? `PAGE 1 / ${Math.max(1, pdf.frameCount)}` : "DECODING"
        if (plays) return mediaInfo
        if (kind === "text") return `${it.lines ?? 0} LINES` + (it.truncated ? "  ·  FIRST 300 KB" : "")
        if (kind === "folder") return (it.items ?? -1) >= 0 ? `${it.items} ITEMS` : "LOCKED"
        return it.mime ?? ""
    }

    readonly property int bar: plays ? 36 : 0       // room under the content for the transport

    // ---- how large the content is: a picture at its own size if it fits, otherwise as large as fits
    readonly property real maxW: Math.round(width * 0.62)
    readonly property real maxH: Math.round(height * 0.66)
    function fit(w, h) {
        if (w <= 0 || h <= 0) return Qt.size(Math.min(960, maxW), Math.min(540, maxH))
        const k = Math.min(maxW / w, maxH / h, 1)
        return Qt.size(Math.max(420, Math.round(w * k)), Math.max(240, Math.round(h * k)))
    }
    readonly property size box: {
        if (kind === "image") return fit(picture.implicitWidth, picture.implicitHeight)
        if (kind === "pdf") return fit(pdf.implicitWidth, pdf.implicitHeight)
        if (kind === "video") return fit(video.sourceRect.width, video.sourceRect.height)
        if (kind === "text") return Qt.size(Math.min(1080, maxW), Math.max(220, Math.min(maxH, Math.ceil((it.lines ?? 1) * 16.25) + 32)))   // as tall as the text, up to the limit
        return Qt.size(640, kind === "audio" ? 200 : 230)
    }

    MediaPlayer {
        id: player
        videoOutput: video
        audioOutput: AudioOutput { volume: 0.7 }
        loops: win.kind === "video" && duration > 0 && duration < 15000 ? MediaPlayer.Infinite : 1
    }
    FileView {
        id: textFile
        path: win.it.text ?? ""
        blockLoading: false
    }

    MouseArea { anchors.fill: parent; onClicked: Preview.close() }      // a click beside the panel

    Glitch {
        id: fx
        active: Preview.open        // glitches in and out only: nothing may disturb the picture while it is open
        flicker: 0.25
        anchors.centerIn: parent
        width: win.box.width + 2 * 22
        height: win.box.height + 96 + 62 + win.bar

        MouseArea {   // a click on the panel: pause what plays, otherwise close; the wheel steps 5 s
            anchors.fill: parent
            onClicked: win.plays ? win.toggle() : Preview.close()
            property real turned: 0
            onWheel: wheel => {
                if (!win.plays) { wheel.accepted = false; return }
                turned += wheel.angleDelta.y                // a touchpad sends many small steps: 5 s for each full notch
                const notches = turned > 0 ? Math.floor(turned / 120) : Math.ceil(turned / 120)
                if (notches) { turned -= notches * 120; win.nudge(notches * 5000) }
            }
        }

        // ---- the frame: thin cyan line, top-left and bottom-right cut, a notch in the top edge
        Frame {
            anchors.fill: parent
            fill: Qt.rgba(0.012, 0.027, 0.047, 0.82)
            stroke: Theme.alpha(Theme.cyan, 0.75)
            strokeWidth: 1
            cut: 16
            cutTopLeft: true; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false
        }
        Rectangle {   // faint raster over the glass
            anchors.fill: parent; anchors.margins: 2
            color: "transparent"
            clip: true
            Column {
                Repeater {
                    model: Math.ceil(fx.height / 3)
                    Item { width: fx.width; height: 3; Rectangle { width: parent.width; height: 1; color: Qt.rgba(0, 0, 0, 0.16) } }
                }
            }
        }
        // edge furniture: ticks down the left edge, a doubled line at the lower left
        Column {
            x: -5; y: 64; spacing: 22
            Repeater { model: Math.max(0, Math.floor((fx.height - 150) / 24)); Rectangle { width: index % 4 === 0 ? 9 : 5; height: 1; color: Theme.alpha(Theme.cyan, 0.6) } }
        }
        Rectangle { x: 0; y: fx.height + 4; width: Math.min(220, fx.width * 0.3); height: 1; color: Theme.alpha(Theme.cyan, 0.45) }
        Rectangle { x: 0; y: fx.height + 7; width: Math.min(90, fx.width * 0.12); height: 2; color: Theme.alpha(Theme.cyan, 0.7) }

        // ---- the red status strip, upper right
        Rectangle {
            id: strip
            anchors { top: parent.top; right: parent.right; topMargin: -7; rightMargin: 22 }
            width: Math.max(stripText.implicitWidth + 30, parent.width * 0.42)
            height: 15
            color: Theme.red
            HudText {
                id: stripText
                anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                text: `PREVIEW LINK  //  ${win.kind || "signal"}  //  ${String(win.it.seq ?? 0).padStart(3, "0")}`
                color: "#12040a"
                font.pixelSize: 9
                font.bold: true
            }
            Rectangle { anchors { right: parent.left; rightMargin: 4; verticalCenter: parent.verticalCenter } width: 26; height: 3; color: Theme.red }
            Rectangle { anchors { right: parent.left; rightMargin: 34; verticalCenter: parent.verticalCenter } width: 8; height: 3; color: Theme.alpha(Theme.red, 0.6) }
        }

        // ---- the header: the type as a large readout, the name in yellow beside it
        Scramble {
            id: readout
            x: 24; y: 16
            target: win.ext
            color: Theme.fg
            font.family: Theme.clock
            font.pixelSize: 38
            font.letterSpacing: 2
            style: Text.Outline; styleColor: Theme.alpha(Theme.cyan, 0.35)
        }
        Column {
            anchors { left: readout.right; leftMargin: 18; right: parent.right; rightMargin: 24 }
            y: 26
            spacing: 3
            HudText {
                width: parent.width
                text: win.it.name ?? ""
                caps: false
                color: Theme.yellow
                font.pixelSize: 15
                font.letterSpacing: 1
                elide: Text.ElideMiddle
            }
            HudText {
                width: parent.width
                text: (win.it.what ?? "") + (win.it.path ? "   ·   " + win.it.path.replace(/\/[^\/]*$/, "/").replace(/^\/home\/[^\/]+/, "~") : "")
                color: Theme.alpha(Theme.teal, 0.8)
                font.pixelSize: 10
                elide: Text.ElideMiddle
            }
        }

        // ---- the content, in an inner frame with corner ticks
        Item {
            id: stage
            x: 22; y: 78
            width: win.box.width
            height: win.box.height

            Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.35); border.width: 1; border.color: Theme.alpha(Theme.teal, 0.35) }
            Repeater {   // corner ticks
                model: 4
                Item {
                    required property int index
                    x: index % 2 ? stage.width - 12 : -1
                    y: index >= 2 ? stage.height - 12 : -1
                    width: 13; height: 13
                    Rectangle { x: index % 2 ? 0 : 0; y: index >= 2 ? 11 : 0; width: 13; height: 2; color: Theme.cyan }
                    Rectangle { x: index % 2 ? 11 : 0; y: 0; width: 2; height: 13; color: Theme.cyan }
                }
            }

            Image {   // pictures (and what Qt reads as one)
                id: picture
                anchors.fill: parent; anchors.margins: 1
                visible: win.kind === "image"
                source: win.kind === "image" ? Preview.fileUrl : ""
                asynchronous: true
                cache: false
                fillMode: Image.PreserveAspectFit
                smooth: true; mipmap: true
            }
            Image {   // a PDF's first page (Qt's PDF picture reader)
                id: pdf
                anchors.fill: parent; anchors.margins: 1
                visible: win.kind === "pdf"
                source: win.kind === "pdf" ? Preview.fileUrl : ""
                asynchronous: true
                cache: false
                fillMode: Image.PreserveAspectFit
            }
            VideoOutput {
                id: video
                anchors.fill: parent; anchors.margins: 1
                visible: win.kind === "video"
                fillMode: VideoOutput.PreserveAspectFit
            }
            Flickable {   // text
                id: page
                anchors.fill: parent; anchors.margins: 14
                visible: win.kind === "text"
                clip: true
                contentWidth: body.implicitWidth
                contentHeight: body.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                Text {
                    id: body
                    text: win.kind === "text" ? textFile.text() : ""
                    textFormat: Text.PlainText
                    color: Theme.alpha(Theme.fg, 0.92)
                    font.family: Theme.mono
                    font.pixelSize: 13
                    lineHeight: 1.25
                }
            }
            Column {   // sound, folders, everything else: a glyph and the facts
                anchors.centerIn: parent
                visible: win.kind === "audio" || win.kind === "folder" || win.kind === "other"
                spacing: 12
                Icon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: win.kind === "audio" ? (player.playbackState === MediaPlayer.PlayingState ? "graphic_eq" : "pause") : win.kind === "folder" ? "folder_open" : "draft"
                    size: 64
                    color: Theme.cyan
                }
                HudText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: win.kind === "audio" ? "AUDIO STREAM" : win.kind === "folder" ? "DIRECTORY NODE" : "NO VISUAL FOR THIS TYPE"
                    color: Theme.dim
                    font.pixelSize: 10
                }
            }
            HudText {   // a picture or video that could not be read
                anchors.centerIn: parent
                visible: (win.kind === "image" && picture.status === Image.Error) || (win.kind === "pdf" && pdf.status === Image.Error) || (win.plays && player.error !== MediaPlayer.NoError)
                text: "SIGNAL LOST  //  CANNOT DECODE"
                color: Theme.red
                font.pixelSize: 12
            }
            Icon {   // paused by hand, or played to its end (not while it waits to start or is being dragged)
                anchors.centerIn: parent
                visible: win.kind === "video" && !win.playing && !startDelay.running && win.scrub < 0 && win.loaded
                name: player.playbackState === MediaPlayer.StoppedState ? "replay" : "pause"
                size: 72
                color: Theme.alpha(Theme.fg, 0.85)
            }
        }

        // ---- the transport: play / pause, where it is, a seek bar (click or drag it), how long it is
        Item {
            id: transport
            visible: win.plays
            x: stage.x
            anchors.top: stage.bottom; anchors.topMargin: 9
            width: stage.width
            height: 26

            Rectangle {
                id: playButton
                width: 30; height: 26
                color: playArea.pressed ? Theme.alpha(Theme.cyan, 0.32) : playArea.containsMouse ? Theme.alpha(Theme.cyan, 0.16) : "transparent"
                border.width: 1
                border.color: Theme.alpha(Theme.cyan, 0.65)
                Icon { anchors.centerIn: parent; name: win.playing ? "pause" : "play_arrow"; size: 20; color: Theme.cyan }
                MouseArea { id: playArea; anchors.fill: parent; hoverEnabled: true; onClicked: win.toggle() }
            }
            HudText {
                id: timeNow
                anchors { left: playButton.right; leftMargin: 12; verticalCenter: parent.verticalCenter }
                width: Math.max(implicitWidth, timeTotal.implicitWidth)     // does not move the bar as digits change
                text: win.clock(win.progress * player.duration)
                color: Theme.cyan
                font.pixelSize: 13
            }
            HudText {
                id: timeTotal
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                text: win.clock(player.duration)
                color: Theme.alpha(Theme.fg, 0.7)
                font.pixelSize: 13
            }
            Item {
                id: track
                anchors { left: timeNow.right; leftMargin: 14; right: timeTotal.left; rightMargin: 14; verticalCenter: parent.verticalCenter }
                height: 22
                opacity: player.seekable ? 1 : 0.45
                readonly property real at: Math.round(width * win.progress)
                readonly property real pointer: Math.max(0, Math.min(1, seekArea.mouseX / Math.max(1, width)))

                Rectangle { y: 9; width: parent.width; height: 4; color: Theme.alpha(Theme.teal, 0.2) }                    // the rail
                Repeater {   // tenths under the rail
                    model: 11
                    Rectangle {
                        required property int index
                        x: Math.round(index / 10 * (track.width - 1)); y: 16
                        width: 1; height: index % 5 === 0 ? 5 : 3
                        color: Theme.alpha(Theme.teal, 0.55)
                    }
                }
                Rectangle { y: 9; width: track.at; height: 4; color: Theme.cyan }                                           // played
                Rectangle { x: Math.max(0, Math.min(track.width - 3, track.at - 1)); y: 3; width: 3; height: 16; color: Theme.fg }   // the handle
                Rectangle {   // where the pointer is, and the time there
                    visible: (seekArea.containsMouse || seekArea.pressed) && player.duration > 0
                    x: Math.round(track.pointer * (track.width - 1)); y: 2
                    width: 1; height: 18
                    color: Theme.alpha(Theme.yellow, 0.8)
                    Rectangle {
                        anchors { bottom: parent.top; bottomMargin: 3; horizontalCenter: parent.horizontalCenter }
                        width: tip.implicitWidth + 12; height: 18
                        color: Qt.rgba(0.012, 0.027, 0.047, 0.95)
                        border.width: 1
                        border.color: Theme.alpha(Theme.yellow, 0.7)
                        HudText { id: tip; anchors.centerIn: parent; text: win.clock(track.pointer * player.duration); color: Theme.yellow; font.pixelSize: 11 }
                    }
                }
                MouseArea {
                    id: seekArea
                    anchors { fill: parent; topMargin: -5; bottomMargin: -5 }
                    hoverEnabled: true
                    preventStealing: true
                    onPressed: { settle.stop(); win.scrub = track.pointer; win.seekTo(win.scrub) }
                    onPositionChanged: if (pressed) { win.scrub = track.pointer; if (!seekSoon.running) seekSoon.start() }
                    onReleased: { seekSoon.stop(); win.seekTo(win.scrub); settle.restart() }
                    onCanceled: { seekSoon.stop(); win.scrub = -1 }
                }
            }
        }

        // ---- data labels in the lower corners, the key hint under them
        Row {
            x: 24
            anchors.top: stage.bottom; anchors.topMargin: 12 + win.bar
            spacing: 8
            Rectangle { width: 7; height: 7; anchors.verticalCenter: parent.verticalCenter; color: "transparent"; border.width: 1.5; border.color: Theme.yellow; rotation: 45 }
            HudText {
                text: `${Preview.sizeText(win.it.size ?? 0)}  ·  MODIFIED ${Preview.timeText(win.it.mtime ?? 0)}`
                color: Theme.yellow
                font.pixelSize: 11
            }
        }
        HudText {
            anchors { right: parent.right; rightMargin: 24; top: stage.bottom; topMargin: 12 + win.bar }
            text: win.detail
            color: Theme.cyan
            font.pixelSize: 11
        }
        HudText {
            x: 24
            anchors.top: stage.bottom; anchors.topMargin: 36 + win.bar
            text: "SPACE  CLOSE   ·   ↑ ↓  NEXT FILE" + (win.plays ? "   ·   CLICK  PAUSE   ·   BAR OR WHEEL  SEEK" : "")
            color: Theme.dim
            font.pixelSize: 9
        }
    }
}
