//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
// Cyber: a cyberpunk HUD desktop for Hyprland, the second desktop next to end-4/pC.
//   switch:  pick it on the lock screen, or ~/.local/share/cyber/desktop.sh apply cyber|end4-pC
//   logs:    qs log -c cyber
//   preview: CYBER_PREVIEW=1 qs -p ~/.local/share/cyber/cyber   (next to end4-pC, see Ui.qml)
import QtQuick
import Quickshell
import qs
import qs.services
import qs.hud
import qs.popups

ShellRoot {
    Hud {}
    Osd {}
    Launcher {}
    Picker {}
    PowerMenu {}
    Capture {}
    Select {}
    Banner {}
    Eliminate {}
    SuperGlow {}
    EdgeSwitch {}
    ControlPanel {}
    Help {}
    QuickLook {}

    // What Cyber takes over from end4-pC while it's the desktop
    LazyLoader { active: !Ui.preview; component: Wallpaper {} }
    LazyLoader { active: !Ui.preview; component: Toasts {} }
    LazyLoader { active: !Ui.preview; component: PolkitDialog {} }
    LazyLoader { active: !Ui.preview; component: LookingGlassPanel {} }
    Ipc {}
    LazyLoader { active: !Ui.preview; component: Shortcuts {} }
    Component.onCompleted: {
        if (Ui.preview) return
        Notifs.dnd   // start the notification server now, not on first use
        Look.lua     // and Cyber's Hyprland look
    }
}
