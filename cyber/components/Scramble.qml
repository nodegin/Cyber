// Text that decodes itself: random characters settle into `target` from left to right.
// Call play() (e.g. when a menu opens).
import QtQuick
import qs

HudText {
    id: root
    property string target: ""
    property int stepMs: 28
    property int revealed: target.length
    readonly property string noise: "▓▒░#%&@01/\\<>[]{}=+*?ABCDEFX"

    function play() { revealed = 0; timer.restart() }
    onTargetChanged: if (!timer.running) revealed = target.length

    text: {
        let out = target.slice(0, revealed)
        for (let i = revealed; i < target.length; i++)
            out += target[i] === " " ? " " : noise[Math.floor(Math.random() * noise.length)]
        return out
    }
    Timer {
        id: timer
        interval: root.stepMs
        repeat: true
        onTriggered: {
            root.revealed += 1
            if (root.revealed >= root.target.length) { root.revealed = root.target.length; stop() }
        }
    }
}
