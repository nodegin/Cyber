// A Material Symbols (Sharp) icon by name, e.g. Icon { name: "volume_up" }.
import QtQuick
import qs

Text {
    property string name: ""
    property int size: 18
    text: name
    color: Theme.fg
    font.family: "Material Symbols Sharp"
    font.pixelSize: size
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignHCenter
}
