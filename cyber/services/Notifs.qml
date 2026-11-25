pragma Singleton
// The notification server (Cyber replaces end4-pC's): popups on screen for a few seconds, and a
// history until dismissed.
import QtQuick
import Quickshell
import Quickshell.Services.Notifications

Singleton {
    id: root

    property var popups: []                                       // newest first, on screen now
    readonly property var history: server.trackedNotifications.values
    property bool dnd: false                                      // do not disturb: history only

    function removePopup(n) { root.popups = root.popups.filter(p => p !== n) }
    function dismiss(n) { removePopup(n); n?.dismiss() }
    function clearAll() { for (const n of [...root.history]) n.dismiss(); root.popups = [] }

    NotificationServer {
        id: server
        keepOnReload: false
        actionsSupported: true
        bodyMarkupSupported: true
        bodySupported: true
        imageSupported: true
        persistenceSupported: true
        onNotification: n => {
            n.tracked = true
            n.closed.connect(() => root.removePopup(n))
            const critical = n.urgency === NotificationUrgency.Critical
            if (root.dnd && !critical) return
            root.popups = [n, ...root.popups].slice(0, 4)
            const ms = n.expireTimeout > 0 ? n.expireTimeout : (critical ? 0 : 6500)
            if (ms > 0) hideLater.createObject(root, { notif: n, interval: ms })
        }
    }

    Component {
        id: hideLater
        Timer {
            property var notif
            running: true
            onTriggered: { root.removePopup(notif); destroy() }
        }
    }
}
