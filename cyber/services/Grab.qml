pragma Singleton
// One capture, from the choice in the capture HUD (or a shortcut) to the script that does it.
//   a screenshot of a region / window:  the screen is photographed first (grim), the picker
//     (popups/Select.qml) shows that still picture and what is picked is cut out of it
//     (scripts/capture.sh crop): what was framed is what is saved, even if the screen moved on
//   a recording of a region / window:  the picker works on the live screen
//   the whole screen:                   no picker
// A recording is announced by the banner (popups/Banner.qml), which must not be in the video:
// when the recorded part does not touch the banner's corner the recorder starts at once, and
// otherwise (and for the whole screen) as the banner leaves the screen.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs

Singleton {
    id: root

    // ---- the picker
    property string picking: ""          // "" = closed, "region", "window"
    property bool video: false           // what the pick is for: a recording (true) or a screenshot
    property string frozen: ""           // the still picture the picker shows ("" = the live screen)
    property string screenName: ""       // the monitor it is about
    readonly property string freezeFile: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/cyber-freeze.ppm`
    property string askedMode: ""

    function start(video, mode) {        // mode: region | window | screen
        if (picking !== "" || photograph.running || after !== null) return
        root.video = video
        root.screenName = Hyprland.focusedMonitor?.name ?? ""
        if (mode === "screen") {
            if (video) record("screen", "")
            else Quickshell.execDetached([Quickshell.shellPath("scripts/capture.sh"), "screen"])
        } else if (video) {
            frozen = ""
            picking = mode
        } else {
            askedMode = mode
            photograph.running = true
        }
    }
    Process {
        id: photograph
        command: ["grim", "-t", "ppm", "-o", root.screenName, root.freezeFile]
        onExited: code => {
            if (code === 0) { root.frozen = root.freezeFile; root.picking = root.askedMode }
            else Quickshell.execDetached([Quickshell.shellPath("scripts/capture.sh"), root.askedMode])    // no picture: the plain picker
        }
    }
    // The picker's answer. inPicture: "x,y WxH" in the still picture's pixels; inLayout: the same
    // place in Hyprland's layout (what the recorder wants).
    function picked(inPicture, inLayout) {
        const still = frozen
        picking = ""
        frozen = ""
        if (video) record("geometry", inLayout)
        else Quickshell.execDetached([Quickshell.shellPath("scripts/capture.sh"), "crop", inPicture, still])
    }
    function cancel() {
        if (frozen !== "") Quickshell.execDetached(["rm", "-f", frozen])
        picking = ""
        frozen = ""
    }

    // ---- the banner
    // where it sits (popups/Banner.qml; the picker's hint too): the top-right corner, where the capture HUD was
    readonly property int bannerRight: 12
    readonly property int bannerTop: Theme.bandTop + 12
    readonly property int bannerMs: 1900    // how long it shows
    property var banner: null               // { title, tone } while one shows
    property var after: null                // what to do once it has left the screen
    function announce(title, tone, then) {
        if (then) after = then          // (a plain banner never drops what an earlier one is waiting to do)
        banner = { title: title, tone: tone }
        bannerOff.restart()
        if (after) lateStart.restart()
    }
    Timer { id: bannerOff; interval: root.bannerMs; onTriggered: root.banner = null }
    function bannerGone() {                 // popups/Banner.qml: its window is off the screen
        lateStart.stop()
        const todo = after
        after = null
        if (todo) todo()
    }
    // should the banner never report back (the shell reloading half-way): start anyway
    Timer { id: lateStart; interval: root.bannerMs + 1500; onTriggered: root.bannerGone() }

    function touchesBanner(geometry) {      // "x,y WxH" in the layout: does it reach the banner's corner?
        const m = /^(-?\d+),(-?\d+) (\d+)x(\d+)$/.exec(geometry)
        if (!m) return true
        const o = Hyprland.monitors.values.find(q => q.name === screenName)?.lastIpcObject
        if (!o || !o.width) return true
        const right = o.x + o.width / (o.scale || 1), by = o.y + bannerTop - 20      // the corner's box: 640 x 90
        return +m[1] < right && +m[1] + +m[3] > right - 640 && +m[2] < by + 90 && +m[2] + +m[4] > by
    }
    function record(mode, geometry) {
        if (mode === "geometry" && !touchesBanner(geometry)) {
            announce("RECORDING STARTED", Theme.alert, null)
            Recorder.run(mode, geometry)
        } else announce("RECORDING STARTED", Theme.alert, () => Recorder.run(mode, geometry))
    }
}
