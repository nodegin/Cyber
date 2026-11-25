pragma Singleton
// Screen recording (scripts/record.sh; wf-recorder). The capture HUD starts one (popups/Capture.qml,
// its RECORDING side); PrintScrn or the camera button in the bottom bar stop it.
// The script runs on its own, not as a child of this shell, so a recording survives the shell
// reloading. While it runs, the script keeps the video's file name in
// $XDG_RUNTIME_DIR/cyber-recording, and empties that file when it ends: this watches it.
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string stateFile: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/cyber-recording`
    property string file: ""                      // the video being written ("" = not recording)
    readonly property bool recording: file !== ""
    property double since: 0
    property int seconds: 0
    readonly property string clock: `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`

    // start(mode): region | window | screen. The picking and the "recording started" banner are
    // services/Grab.qml's; it then calls run(), which starts the script.
    function start(mode) { Grab.start(true, mode) }
    function run(mode, geometry) { Quickshell.execDetached([Quickshell.shellPath("scripts/record.sh"), mode].concat(geometry ? [geometry] : [])) }
    function stop() { Quickshell.execDetached([Quickshell.shellPath("scripts/record.sh"), "stop"]) }

    onFileChanged: { since = Date.now(); seconds = 0 }
    Timer { running: root.recording; interval: 500; repeat: true; onTriggered: root.seconds = Math.floor((Date.now() - root.since) / 1000) }

    // the state file must exist before it can be watched
    Process {
        id: make
        command: ["sh", "-c", 'touch "$1"', "sh", root.stateFile]
        onExited: watch.path = root.stateFile
    }
    FileView {
        id: watch
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.file = text().trim()
        onLoadFailed: root.file = ""
    }
    Component.onCompleted: make.running = true
}
