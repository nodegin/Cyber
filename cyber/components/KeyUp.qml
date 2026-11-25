// Runs a popup's closing action when the key is let go, not when it goes down.
//
// Closing on the press hands keyboard focus back to the app underneath while the key is still held,
// and Hyprland tells that app which keys are down: it then acts on them too (Esc dropped a browser
// out of fullscreen, Enter would send a chat message). Keys that keep the popup open (arrows) can
// stay on the press.
//
//   KeyUp { id: keyUp }
//   Keys.onPressed:  e => { if (e.key === Qt.Key_Escape) keyUp.defer(e, () => Ui.xOpen = false) }
//   Keys.onReleased: e => keyUp.release(e)
//   (and keyUp.reset() when the popup opens)
import QtQuick

QtObject {
    property var pending: null

    function defer(e, action) {
        if (!e.isAutoRepeat) pending = { key: e.key, action: action }
        e.accepted = true
    }
    function release(e) {
        if (e.isAutoRepeat || !pending || e.key !== pending.key) return
        const action = pending.action
        pending = null
        e.accepted = true
        action()
    }
    function reset() { pending = null }
}
