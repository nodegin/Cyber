// One top band and one bottom band per screen.
import QtQuick
import Quickshell

Scope {
    Variants {
        model: Quickshell.screens
        TopBand {}
    }
    Variants {
        model: Quickshell.screens
        BottomBand {}
    }
}
