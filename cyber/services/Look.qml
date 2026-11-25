pragma Singleton
// Cyber's Hyprland look: sharp corners, neon borders, a lighter blur (~4 px). Applied at runtime, so it disappears with
// any `hyprctl reload` (and when switching back to end-4/pC); re-applied after Hyprland reloads.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs

Singleton {
    id: root

    readonly property string lua: [
        'hl.config({ decoration = { rounding = 0 } })',
        'hl.config({ general = { border_size = 0 } })',   // no borders: the focused window gets corner brackets (hypr/corners)
        'hl.config({ general = { col = { active_border = "rgba(3cf0ffcc)", inactive_border = "rgba(ff2bd633)" } } })',
        'hl.config({ general = { gaps_in = 4, gaps_out = 10 } })',
        // real-time blur behind the HUD and see-through windows while Cyber is the desktop: two
        // passes at size 4. (One pass at size 8 was tried on 2026-11-23: cheaper, but it shows
        // artifacts; this is the lowest quality that looks clean.)
        'hl.config({ decoration = { blur = { size = 4, passes = 2 } } })',
        // ... with less grain than end-4 gives its own, stronger blur (Config.blurNoise says why)
        'hl.config({ decoration = { blur = { noise = ' + Config.blurNoise + ' } } })',
        // Every see-through window gets its blur from the corners plugin (hypr/corners), so Hyprland's
        // shared blur of the desktop level is not used. Left on, Hyprland still redraws the whole
        // screen whenever anything on that level changes (a wallpaper frame, the Looking Glass
        // preview) as long as a see-through tiled window exists: measured 12 -> 6 ms a frame with
        // the preview under tiled windows (2026-11-24).
        'hl.config({ decoration = { blur = { new_optimizations = false } } })',
        // The lock screen is opaque: do not draw the desktop under it. (end-4's default keeps drawing it;
        // measured 2026-11-24 while locked: the compositor at 68% of the GPU and the lock screen at 39 of
        // 60 frames a second.)
        'hl.config({ misc = { session_lock_xray = false } })',
        // Window and workspace animations: Hyprland's own (they are drawn by the compositor, so they
        // stay in sync with the windows); snappy pop-in, fade, slide-fade between workspaces.
        'hl.curve("cyberSnap", { type = "bezier", points = { {0.2, 1.1}, {0.4, 1} } })',
        'hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.4, bezier = "cyberSnap", style = "popin 90%" })',
        'hl.animation({ leaf = "fadeIn", enabled = true, speed = 2.4, bezier = "cyberSnap" })',
        'hl.animation({ leaf = "windowsOut", enabled = true, speed = 2.2, bezier = "cyberSnap", style = "popin 85%" })',
        'hl.animation({ leaf = "fadeOut", enabled = true, speed = 2.2, bezier = "cyberSnap" })',
        'hl.animation({ leaf = "windowsMove", enabled = true, speed = 3, bezier = "cyberSnap" })',
        'hl.animation({ leaf = "workspaces", enabled = true, speed = 2.6, bezier = "cyberSnap", style = "slidefade 10%" })',
    ].join("\n")

    function apply() {
        hyprEval.running = false; hyprEval.running = true
        // the compositor's frame threads get a higher scheduling priority (scripts/priority.sh says why)
        Quickshell.execDetached([Quickshell.shellPath("scripts/priority.sh")])
    }

    Process { id: hyprEval; command: ["hyprctl", "eval", root.lua] }
    onLuaChanged: soon.restart()      // a setting in config.json changed (the blur's grain)
    Timer { id: soon; interval: 300; onTriggered: root.apply() }
    Connections {
        target: Hyprland
        function onRawEvent(event) { if (event.name === "configreloaded") soon.restart() }
    }
    Component.onCompleted: apply()
}
