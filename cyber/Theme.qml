pragma Singleton
// Cyber's look: the same palette and fonts as the cyberpunk lock screen (canvasgreet).
import QtQuick
import Quickshell

Singleton {
    id: root

    readonly property color fg: "#e8ebf3"
    readonly property color dim: Qt.rgba(232 / 255, 235 / 255, 243 / 255, 0.48)
    readonly property color faint: Qt.rgba(232 / 255, 235 / 255, 243 / 255, 0.14)
    readonly property color cyan: "#3cf0ff"
    readonly property color teal: "#5cc8d8"     // softer cyan: HUD dialog edges and labels
    readonly property color red: "#ff3d6e"
    readonly property color alert: "#d25058"    // the status banner's red (components/HudBanner.qml), and what goes with it
    readonly property color mag: "#ff2bd6"
    readonly property color yellow: "#f3e600"
    readonly property color green: "#3dff9e"
    readonly property color ink: "#05040a"
    readonly property color glass: Qt.rgba(6 / 255, 5 / 255, 14 / 255, 0.42)     // panel fill (blurred behind)
    readonly property color glassHi: Qt.rgba(14 / 255, 12 / 255, 30 / 255, 0.66) // popups

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    // Fonts: one copy in the repo, in the lock screen theme's folder (Kleemax is a personal-use font)
    readonly property string fontDir: Quickshell.env("HOME") + "/.local/share/cyber/greeter/themes/cyberpunk/fonts/"
    readonly property string mono: monoFont.status === FontLoader.Ready ? monoFont.name : "JetBrains Mono"
    readonly property string display: displayFont.status === FontLoader.Ready ? displayFont.name : mono
    readonly property string clock: clockFont.status === FontLoader.Ready ? clockFont.name : display
    readonly property string banner: bannerFont.status === FontLoader.Ready ? bannerFont.name : display   // components/HudBanner.qml
    readonly property string jp: "Noto Sans CJK JP"
    FontLoader { id: monoFont; source: "file://" + root.fontDir + "JetBrainsMono.ttf" }
    FontLoader { id: displayFont; source: "file://" + root.fontDir + "Oxanium.ttf" }
    FontLoader { id: clockFont; source: "file://" + root.fontDir + "kleemaxdemo.otf" }
    FontLoader { id: bannerFont; source: "file://" + root.fontDir + "Rajdhani-Bold.ttf" }

    // Sizes (logical px)
    readonly property int textSmall: 11
    readonly property int text: 13
    readonly property int textBig: 18
    readonly property real spacing: 0.18 * text   // letter spacing for HUD labels
    readonly property int cut: 12                 // chamfer size
    readonly property int bandTop: 54             // reserved band at the top of the screen
    readonly property int bandBottom: 48          // and at the bottom
}
