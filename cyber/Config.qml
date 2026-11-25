pragma Singleton
// Settings from config.json next to shell.qml (edit it; Cyber picks changes up live).
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property var data: ({})
    readonly property string home: Quickshell.env("HOME")
    function path(p) { return String(p || "").replace(/^~(?=\/|$)/, root.home) }

    // Wallpaper: a web page (a Wallpaper Engine "web" wallpaper folder, shown by webpaper/webpaper.py)
    // if set, else a looping video (mpvpaper) if set and present, else the image
    readonly property string wallpaperWeb: path(data.wallpaper?.web ?? "")
    readonly property real wallpaperWebFps: data.wallpaper?.webFps ?? 24       // animation cap; 0 = none
    readonly property real wallpaperWebScale: data.wallpaper?.webScale ?? 0.5  // render resolution, 0.25 .. 1
    readonly property string wallpaperVideo: path(data.wallpaper?.video ?? "")
    readonly property string wallpaperImage: path(data.wallpaper?.image ?? "~/.local/share/cyber/assets/wallpaper/neon-district.png")
    // Motion. "menus": the glitch when Cyber's own menus open/close (components/Glitch.qml).
    // "windows" and "workspace" in config.json are read by Hyprland (hypr/glitch.lua), not here.
    readonly property var fx: ({ menus: data.effects?.menus ?? true, intensity: data.effects?.intensity ?? 0.55 })
    // The grain in the blur behind glass (Hyprland's decoration.blur.noise) while Cyber is the
    // desktop. end-4's own value, 0.05, suits its much stronger blur; behind Cyber's light blur it
    // reads as picture noise ("jpeg artifacts"), plainest over a bright page. 0.0117 is Hyprland's
    // default: just enough to keep smooth gradients from banding. 0 = none; at most 0.1.
    readonly property real blurNoise: Math.max(0, Math.min(0.1, data.effects?.blurNoise ?? 0.0117))
    readonly property string terminal: data.apps?.terminal ?? "kitty -1"
    readonly property real lgPreviewFps: data.lookingGlass?.previewFps ?? 30   // the idle (tilted) Looking Glass preview; 0 = every frame of the VM
    readonly property real lgCoveredFps: data.lookingGlass?.coveredFps ?? 10   // ... while other windows lie over (nearly) all of it
    // while the VM picture keeps moving (a video, a game) the preview is live instead (a steady half of
    // the monitor's rate, the most this kind of capture gives); false = always the rates above
    readonly property bool lgStream: data.lookingGlass?.stream ?? true
    // how much the idle panel is bent, like a wrap-around display: how far its middle lies behind its
    // edges, as a fraction of its width. 0 = a flat sheet; below 0 it bulges instead. Kept within +-0.3.
    readonly property real lgCurve: Math.max(-0.3, Math.min(0.3, data.lookingGlass?.curve ?? 0.09))
    // the capture HUD (PrintScrn) sits in the top-right corner, as the Looking Glass panel's mirror
    // image: its right edge near, its left side receding. 0 = flat, 1 = turned as far as that panel
    // (hard to read at that size); below 0 = turned the other way. It is bent by lookingGlass.curve.
    readonly property real captureTilt: Math.max(-1, Math.min(1, data.capture?.tilt ?? 0.4))
    // ... and how large it is drawn: 1 = the size of the shell's other dialogs (small on a big screen)
    readonly property real captureScale: Math.max(0.8, Math.min(2, data.capture?.scale ?? 1.1))
    readonly property string desktopScript: path("~/.local/share/cyber/desktop.sh")

    FileView {
        path: Quickshell.shellPath("config.json")
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try { root.data = JSON.parse(text()) } catch (e) { console.warn("cyber: config.json:", e) }
        }
    }
}
