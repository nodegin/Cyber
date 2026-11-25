pragma Singleton
// The media player to show (MPRIS): the one playing, else the first one around.
import QtQuick
import Quickshell
import Quickshell.Services.Mpris

Singleton {
    readonly property var players: Mpris.players.values
    readonly property var player: players.find(p => p.isPlaying) ?? players[0] ?? null
    readonly property string title: player?.trackTitle || ""
    readonly property string artist: player?.trackArtist || ""
    readonly property string art: player?.trackArtUrl || ""
    readonly property bool playing: player?.isPlaying ?? false
}
