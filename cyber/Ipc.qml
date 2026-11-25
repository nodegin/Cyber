// IPC targets: the ones end-4's keybinds call through `qs -c $qsConfig ipc call ...`, plus "cyber"
// for scripts and testing. (Per instance, so these never clash with end4-pC's.)
import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.services

Scope {
    // Super (tap): `qs -c $qsConfig ipc call search toggle`
    IpcHandler {
        target: "search"
        function toggle(): void { Ui.toggle("launcherOpen") }
        function open(): void { Ui.closePopups(); Ui.launcherOpen = true }
        function close(): void { Ui.launcherOpen = false }
    }
    // clipboard watcher started by Hyprland (wl-paste ... ipc call cliphistService update)
    IpcHandler { target: "cliphistService"; function update(): void {} }
    IpcHandler {
        target: "brightness"
        function increment(): void { Brightness.change(0.05) }
        function decrement(): void { Brightness.change(-0.05) }
    }
    // for scripts and testing: qs -c cyber ipc call cyber <function>
    IpcHandler {
        target: "cyber"
        function launcher(): void { Ui.toggle("launcherOpen") }
        function power(): void { Ui.toggle("powerOpen") }
        function panel(): void { Ui.toggle("panelOpen") }
        function help(): void { Ui.helpOpen = !Ui.helpOpen }
        function capture(): void { Recorder.recording ? Recorder.stop() : Ui.toggle("captureOpen") }
        // record region|window|screen|stop: a screen recording without the HUD;  captureMode true|false: the HUD's switch
        function record(mode: string): void { mode === "stop" ? Recorder.stop() : Recorder.start(mode) }
        // shot region|window|screen: a screenshot without the HUD
        function shot(mode: string): void { Grab.start(false, mode) }
        // banner "TEXT": the status banner (top left), for scripts
        function banner(text: string): void { Grab.announce(text, Theme.alert, null) }
        function captureMode(video: bool): void { Ui.captureVideo = video }
        function hud(): void { Ui.hudHidden = !Ui.hudHidden }
        function close(): void { Ui.closePopups(); Ui.helpOpen = false }
        // open launcherOpen / powerOpen / panelOpen / helpOpen without taking the keyboard (screenshots)
        function demo(popup: string): void { Ui.closePopups(); Ui.demo = true; Ui[popup] = true }
        // pick clipboard|emoji: the picker (Super+V, Super+.);  demoPick: the same without taking the keyboard
        function pick(mode: string): void { Ui.pick(mode) }
        function demoPick(mode: string): void { Ui.closePopups(); Ui.demo = true; Ui.pickerMode = mode }
        function state(): string {
            return JSON.stringify({ launcher: Ui.launcherOpen, power: Ui.powerOpen, hudHidden: Ui.hudHidden,
                                    notifications: Notifs.history.length, popups: Notifs.popups.length })
        }
    }
}
