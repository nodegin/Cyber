// Same keys in both desktops: Cyber answers end-4's keybinds (~/.config/hypr/hyprland/keybinds.lua)
// with the global-shortcut names end4-pC uses (the IPC targets are in Ipc.qml). Where Cyber has no
// screen of its own, it runs end-4's fallback command for that key.
import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs
import qs.services

Scope {
    function run(cmd) { Quickshell.execDetached(["bash", "-c", cmd]) }
    readonly property string hyprScripts: "$HOME/.config/hypr/hyprland/scripts"
    readonly property string pcScripts: "$HOME/.config/quickshell/end4-pC/scripts"
    readonly property string ocr: 'pidof slurp && exit; f=$(mktemp --suffix=.png) && grim -g "$(slurp $SLURP_ARGS)" "$f" && ' +
        'tesseract "$f" stdout -l "$(tesseract --list-langs | awk \'NR>1{print $1}\' | paste -sd+)" | wl-copy; rm -f "$f"'

    GlobalShortcut { name: "sessionToggle"; onPressed: Ui.toggle("powerOpen") }
    GlobalShortcut { name: "sidebarRightToggle"; onPressed: Ui.toggle("panelOpen") }   // Super+N
    GlobalShortcut { name: "cheatsheetToggle"; onPressed: Ui.helpOpen = !Ui.helpOpen }      // Super+/
    // PrintScrn (Cyber only): the capture HUD, or the end of a running recording
    GlobalShortcut { name: "captureToggle"; onPressed: Recorder.recording ? Recorder.stop() : Ui.toggle("captureOpen") }
    GlobalShortcut { name: "barToggle"; onPressed: Ui.hudHidden = !Ui.hudHidden }
    GlobalShortcut { name: "workspaceNumber"; onPressed: Ui.superHeld = true; onReleased: Ui.superHeld = false }
    // sent by hypr/keys.lua when it sees Super is up but the release didn't arrive
    GlobalShortcut { name: "superReleased"; onPressed: Ui.superHeld = false; onReleased: Ui.superHeld = false }
    GlobalShortcut {   // Super+Q (hypr/keys.lua): open eliminate mode, or shoot when it's open
        name: "eliminateToggle"
        onPressed: Ui.killOpen ? Ui.killFire() : Ui.toggle("killOpen")
    }
    GlobalShortcut { name: "regionScreenshot"; onPressed: Grab.start(false, "region") }   // Super+Shift+S: the capture menu's region screenshot
    GlobalShortcut { name: "regionSearch"; onPressed: run(`pidof slurp || ${hyprScripts}/snip_to_search.sh`) }
    GlobalShortcut { name: "regionOcr"; onPressed: run(ocr) }
    GlobalShortcut { name: "regionRecord"; onPressed: Recorder.recording ? Recorder.stop() : Recorder.start("region") }   // Super+Shift+R
    GlobalShortcut { name: "overviewEmojiToggle"; onPressed: Ui.pick("emoji") }           // Super+.  (popups/Picker.qml)
    GlobalShortcut { name: "overviewClipboardToggle"; onPressed: Ui.pick("clipboard") }   // Super+V
}
