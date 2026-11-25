// Shows its content with a glitch: it stutters in when `active` turns on and out when it turns
// off (hard cuts between heavy tearing, near-clean frames and blackouts, a bit different every
// time). While `busy` (including the way out), keep the window holding it visible:
//   PanelWindow { visible: Ui.powerOpen || g.busy;  Glitch { id: g; active: Ui.powerOpen; ... } }
// aftershocks: small glitches now and then while it stays open. shock(): one on demand.
import QtQuick
import qs

Item {
    id: root
    property bool active: false
    property real strength: 1
    property bool aftershocks: false
    property real speed: 1              // < 1 = longer sequences
    property int maxMs: 520             // a whole in/out sequence never takes longer than this
    // how deep the picture blinks out during a sequence: 1 = to nothing, 0 = no blinking at all
    property real flicker: 0.5 * Config.fx.intensity
    property real amount: 0             // 0 = clean, 1 = fully torn
    property real seed: 0
    property bool leaving: false
    readonly property bool busy: active || leaving
    default property alias content: holder.data
    signal done()                       // a sequence (in, out or shock) has finished

    opacity: 0
    visible: busy

    Item {
        id: holder
        anchors.fill: parent
        layer.enabled: root.amount > 0.001
        layer.effect: ShaderEffect {
            fragmentShader: Qt.resolvedUrl("../shaders/glitch.frag.qsb")
            property real amount: Math.min(1, root.amount * root.strength * Config.fx.intensity)
            property real seed: root.seed
            property point pxSize: Qt.point(root.width, root.height)
        }
    }
    // new tears every frame-ish while it plays
    Timer { interval: 33; repeat: true; running: root.amount > 0.001 && root.visible; onTriggered: root.seed = Math.random() * 100 }

    // [amount, opacity, ms]
    readonly property var inSeq: [[0.85, 0, 25], [0.8, 1, 40], [0.1, 0, 20], [0.65, 1, 45], [0.2, 1, 35],
                                  [0.5, 0.6, 30], [0.08, 1, 45], [0.3, 1, 30], [0, 1, 0]]
    readonly property var outSeq: [[0.25, 1, 30], [0.75, 1, 40], [0.4, 0.5, 25], [0.85, 0, 30], [0.9, 0.5, 25], [1, 0, 0]]
    readonly property var shockSeq: [[0.4, 1, 40], [0.08, 1, 30], [0.5, 1, 35], [0, 1, 0]]
    property var seq: []
    property int step: 0

    function jitter(list) {
        const out = list.map(s => [Math.max(0, Math.min(1, s[0] + (s[2] ? (Math.random() - 0.5) * 0.3 : 0))), s[1],
                                   Math.round(s[2] * (0.7 + Math.random() * 0.6) / speed)])
        const total = out.reduce((n, s) => n + s[2], 0)
        if (total > maxMs) for (const s of out) s[2] = Math.max(s[2] ? 12 : 0, Math.round(s[2] * maxMs / total))
        return out
    }
    function play(list, leaving) {
        root.leaving = leaving
        root.seq = jitter(list)
        root.step = 0
        apply()
    }
    function apply() {
        const s = root.seq[root.step]
        root.amount = s[0]
        // blink depth is limited by `flicker`; on the way out it also fades, so it doesn't just cut off
        const blink = 1 - (1 - s[1]) * root.flicker
        const fade = root.leaving ? 1 - 0.8 * root.step / Math.max(1, root.seq.length - 1) : 1
        root.opacity = blink * fade
        if (s[2] > 0) { stepper.interval = s[2]; stepper.restart() }
        else finish()
    }
    function finish() {
        stepper.stop()
        root.amount = 0
        if (root.leaving) { root.leaving = false; root.opacity = 0 }
        else root.opacity = root.active ? 1 : 0
        root.done()
    }
    Timer {
        id: stepper
        onTriggered: { root.step++; if (root.step < root.seq.length) root.apply(); else root.finish() }
    }

    function show() {
        if (!Config.fx.menus) { stepper.stop(); leaving = false; amount = 0; opacity = 1; return }
        play(inSeq, false)
    }
    function hide() {
        if (!Config.fx.menus) { stepper.stop(); leaving = false; amount = 0; opacity = 0; return }
        play(outSeq, true)
    }
    function shock() { if (active && !stepper.running && Config.fx.menus) play(shockSeq, false) }

    onActiveChanged: active ? show() : hide()
    Component.onCompleted: if (active) show()

    Timer {
        running: root.aftershocks && root.active
        repeat: true
        interval: 2600
        onTriggered: { interval = 1800 + Math.random() * 3800; root.shock() }
    }
}
