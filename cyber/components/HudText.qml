// HUD label: monospace, upper case, wide letter spacing.
import QtQuick
import qs

Text {
    property bool caps: true
    color: Theme.fg
    font.family: Theme.mono
    font.pixelSize: Theme.text
    font.letterSpacing: Theme.spacing
    font.capitalization: caps ? Font.AllUppercase : Font.MixedCase
    elide: Text.ElideRight
    verticalAlignment: Text.AlignVCenter
}
