pragma Singleton
// UI state shared by the HUD and popups.
import QtQuick
import Quickshell

Singleton {
    id: root
    property bool launcherOpen: false
    property bool powerOpen: false
    property bool panelOpen: false    // Super+N
    property bool helpOpen: false     // Super+/: the keybinds card, a normal window (popups/Help.qml): it stays while other popups come and go
    property bool captureOpen: false  // PrintScrn: capture HUD (screenshot / recording)
    property bool captureVideo: false // ... its switch: false = a screenshot, true = a recording
    property bool killOpen: false     // Super+Q: eliminate mode (popups/Eliminate.qml)
    property string pickerMode: ""    // Super+V / Super+.: popups/Picker.qml ("clipboard", "emoji"; "" = closed)
    signal killFire()                 // Super+Q again while it's open: shoot the window under the crosshair
    // screenshot mode (ipc call cyber demo <popup>): a popup opens without taking the keyboard
    property bool demo: false
    property bool hudHidden: false    // Super+J: hide the top/bottom bands
    property bool superHeld: false    // hold Super: show workspace numbers
    readonly property double startedAt: Date.now()
    // CYBER_PREVIEW=1 qs -p ~/.local/share/cyber/cyber: look at it next to end4-pC without taking
    // over notifications, the polkit agent, shortcuts, the wallpaper or Hyprland's look.
    readonly property bool preview: Quickshell.env("CYBER_PREVIEW") === "1"

    function closePopups() { launcherOpen = false; powerOpen = false; panelOpen = false; captureOpen = false; killOpen = false; pickerMode = ""; demo = false }
    // open one popup (closing the others), or close it if it's open: toggle("panelOpen")
    function toggle(name) { const was = root[name]; closePopups(); root[name] = !was }
    // the same for a picker: pick("emoji")
    function pick(mode) { const was = pickerMode; closePopups(); pickerMode = was === mode ? "" : mode }
}
