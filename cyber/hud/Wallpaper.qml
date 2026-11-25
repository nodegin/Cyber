// Wallpaper, the first of these that is set in config.json and works:
//   web    a web page (Wallpaper Engine "web" wallpaper folder) through webpaper/webpaper.py
//   video  a looping video through mpvpaper (one process for all screens)
//   image  also shown while one of the others is starting, or cannot run
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs

Scope {
    id: root
    property bool videoUp: false
    property bool webUp: false
    property bool webCannot: false
    readonly property bool wantWeb: Config.wallpaperWeb !== ""

    Process {
        id: web
        running: root.wantWeb
        // exit 3 = cannot show it (no page there, or gtk4-layer-shell / WebKitGTK missing): the image stays
        command: ["python3", Config.path("~/.local/share/cyber/webpaper/webpaper.py"), Config.wallpaperWeb,
                  "--fps", String(Config.wallpaperWebFps), "--scale", String(Config.wallpaperWebScale)]
        stdout: SplitParser { onRead: line => { if (line.trim() === "ready") root.webUp = true } }   // the page has loaded
        onRunningChanged: if (!running) root.webUp = false
        onExited: code => {
            root.webCannot = code === 3
            if (code !== 3 && root.wantWeb) console.warn("cyber: webpaper stopped, exit code", code)
        }
    }
    // it stopped although it is wanted (crashed, or was killed): start it again
    Timer { running: root.wantWeb && !web.running && !root.webCannot; interval: 2000; onTriggered: web.running = true }

    readonly property bool wantVideo: !root.wantWeb && Config.wallpaperVideo !== ""
    property bool videoCannot: false
    onWantVideoChanged: { videoCannot = false; mpv.running = wantVideo }
    Connections {   // another file in config.json: start over with it
        target: Config
        function onWallpaperVideoChanged() { root.videoCannot = false; mpv.running = false; if (root.wantVideo) again.restart() }
    }
    Timer { id: again; interval: 300; onTriggered: mpv.running = root.wantVideo }

    Process {
        id: mpv
        running: root.wantVideo
        // exit 3 = nothing to play (mpvpaper not installed or no file): the image stays
        command: ["sh", "-c",
            'command -v mpvpaper >/dev/null && [ -f "$1" ] || exit 3; pkill -x mpvpaper; ' +
            'exec mpvpaper -p -o "no-audio loop profile=fast hwdec=auto-safe panscan=1.0 video-sync=audio interpolation=no" ALL "$1"',
            "sh", Config.wallpaperVideo]
        onRunningChanged: if (!running) root.videoUp = false
        onExited: code => {
            root.videoCannot = code === 3
            if (code !== 3 && root.wantVideo) console.warn("cyber: mpvpaper stopped, exit code", code)
        }
    }
    // it stopped although it is wanted (crashed, or was killed): start it again
    Timer { running: root.wantVideo && !mpv.running && !root.videoCannot && !again.running; interval: 2000; onTriggered: mpv.running = true }
    // hide the image once mpvpaper has had time to show its first frame
    Timer { running: mpv.running; interval: 1500; onTriggered: root.videoUp = mpv.running }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            visible: !root.videoUp && !root.webUp
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "cyber:wallpaper"
            color: Theme.ink
            Image {
                anchors.fill: parent
                source: "file://" + Config.wallpaperImage
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                sourceSize: Qt.size(parent.width, parent.height)
            }
        }
    }
}
