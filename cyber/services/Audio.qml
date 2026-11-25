pragma Singleton
// Default speaker and microphone (PipeWire). `osd` fires when the volume or mute changes.
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import qs

Singleton {
    id: root

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property PwNode source: Pipewire.defaultAudioSource
    readonly property real volume: sink?.audio?.volume ?? 0
    readonly property bool muted: sink?.audio?.muted ?? false
    readonly property bool micMuted: source?.audio?.muted ?? false
    signal osd()

    PwObjectTracker { objects: [root.sink, root.source] }

    Connections {
        target: root.sink?.audio ?? null
        // the first values arrive while starting up: no popup for those
        function onVolumeChanged() { if (Date.now() - Ui.startedAt > 3000) root.osd() }
        function onMutedChanged() { if (Date.now() - Ui.startedAt > 3000) root.osd() }
    }

    function toggleMute() { if (root.sink?.audio) root.sink.audio.muted = !root.sink.audio.muted }
    function toggleMic() { if (root.source?.audio) root.source.audio.muted = !root.source.audio.muted }
}
