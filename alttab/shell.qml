// Super+Tab window switcher for Hyprland, like Alt+Tab on Windows / Cmd+Tab on macOS.
//
//   Hold Super, tap Tab (Shift+Tab goes back), let go of Super to switch.
//   Arrow keys + Enter, a click, or Esc (cancel) work too.
//   Every window is listed with a live preview, most recently used first, minimized ones included
//   (picking one brings it back; see the "minimize" block in ~/.config/hypr/custom/keybinds.lua).
//   It wears the look of the desktop that is running: end-4/pC's (rounded, its wallpaper palette)
//   or Cyber's (a HUD panel: cut corners, neon on dark glass, like Cyber's launcher).
//
// Started by Hyprland (custom/execs.lua, written by ~/.local/share/cyber/setup.sh):
//   qs -n -p ~/.local/share/cyber/alttab
// Test without the keyboard:
//   qs -p ~/.local/share/cyber/alttab ipc call alttab next|prev|commit|cancel|state
import QtQuick
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland

ShellRoot {
    id: root

    readonly property string minimizedWorkspace: "special:minimized"
    readonly property int thumbW: 276
    readonly property int thumbH: 170
    readonly property int cardW: thumbW + 24
    readonly property int cardH: thumbH + 62
    readonly property int spacing: 12

    property bool open: false
    property int closeKey: 0   // Enter/Esc pressed in the switcher: acted on when it's let go
    property int index: 0
    property var clients: []   // `hyprctl clients -j`, most recently focused first
    property var entries: []   // what the switcher shows: [{ toplevel, client }]
    property var colors: ({})

    // Colours: end-4's palette, generated from your wallpaper (fallbacks if it's missing)
    function col(name, fallback) { return root.colors[name] ?? fallback }
    function rgba(hex, alpha) {
        const h = String(hex).replace("#", "")
        return Qt.rgba(parseInt(h.substr(0, 2), 16) / 255, parseInt(h.substr(2, 2), 16) / 255,
                       parseInt(h.substr(4, 2), 16) / 255, alpha)
    }
    FileView {
        path: Quickshell.env("HOME") + "/.local/state/quickshell/user/generated/colors.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { try { root.colors = JSON.parse(text()) } catch (e) { } }
    }

    // ---- two looks. Which one: the desktop that is running, from the file desktop.sh keeps (the
    // same one Hyprland's config reads). This program is not part of Cyber's shell (it runs under
    // both desktops), so Cyber's colours and font are repeated here: keep them in step with
    // cyber/Theme.qml.
    property string desktop: ""
    readonly property bool cyber: desktop === "cyber"
    FileView {
        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/hypr-setup/desktop"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.desktop = text().trim()
    }
    readonly property color cyan: "#3cf0ff"
    readonly property color teal: "#5cc8d8"
    readonly property color mag: "#ff2bd6"
    readonly property color yellow: "#f3e600"
    readonly property color fg: "#e8ebf3"
    readonly property color glass: Qt.rgba(14 / 255, 12 / 255, 30 / 255, 0.66)
    FontLoader { id: monoFont; source: "file://" + Quickshell.env("HOME") + "/.local/share/cyber/greeter/themes/cyberpunk/fonts/JetBrainsMono.ttf" }
    readonly property string mono: monoFont.status === FontLoader.Ready ? monoFont.name : "JetBrains Mono"
    readonly property int headH: cyber ? 30 : 0      // Cyber: a title line above the cards ...
    readonly property int footH: cyber ? 26 : 0      // ... and a line of hints below

    // ---- window list, kept fresh so the switcher opens instantly -------------------------------
    property bool refreshPending: false
    function refresh() {
        if (getClients.running) { root.refreshPending = true; return }
        getClients.running = true
    }
    Process {
        id: getClients
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.clients = JSON.parse(text)
                        .filter(c => c.mapped)
                        .sort((a, b) => a.focusHistoryID - b.focusHistoryID)
                } catch (e) { }
            }
        }
        onExited: if (root.refreshPending) { root.refreshPending = false; Qt.callLater(root.refresh) }
    }
    Timer { id: refreshSoon; interval: 60; onTriggered: root.refresh() }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            const n = event.name
            if (n.startsWith("openwindow") || n.startsWith("closewindow") || n.startsWith("movewindow")
                || n.startsWith("activewindow") || n.startsWith("windowtitle"))
                refreshSoon.restart()
        }
    }
    Component.onCompleted: refresh()

    function build() {
        const byAddress = {}
        for (const t of ToplevelManager.toplevels.values) {
            const a = t.HyprlandToplevel?.address
            if (a) byAddress["0x" + a] = t
        }
        const list = []
        for (const c of root.clients) {
            const t = byAddress[c.address]
            if (t) { list.push({ toplevel: t, client: c }); delete byAddress[c.address] }
        }
        for (const a in byAddress) list.push({ toplevel: byAddress[a], client: null })  // brand new
        return list
    }

    // ---- actions ---------------------------------------------------------------------------------
    function move(step) {
        if (!root.open) {
            const list = build()
            if (list.length === 0) return
            root.entries = list
            // Start on the previous window (the first one is the window you're in)
            const current = ToplevelManager.activeToplevel
            const first = (list[0].toplevel === current && current?.activated) ? 1 : 0
            root.index = step > 0 ? Math.min(first, list.length - 1) : list.length - 1
            root.open = true
            return
        }
        const n = root.entries.length
        if (n > 0) root.index = (root.index + step + n) % n
    }
    function commit() {
        if (!root.open) return
        const e = root.entries[root.index]
        root.open = false
        activateSoon.target = e ? e.toplevel : null
        // Cyber's Looking Glass window refuses the focus while it is idle (it lets the pointer through to
        // the windows over it): ask Hyprland to bring it forward (cyber/hypr/lookingglass.lua)
        if (e && e.client.class === "looking-glass-client")
            Quickshell.execDetached(["hyprctl", "eval", "if CyberLookingGlass then CyberLookingGlass.show() end"])
        activateSoon.restart()
    }
    function cancel() { root.open = false }
    // While open, Hyprland's "alttab" submap (custom/keybinds.lua) is active: it has no Super+mouse
    // binds, so a Super+click reaches the cards instead of starting a window drag.
    onOpenChanged: closeKey = 0, Hyprland.dispatch(root.open ? 'hl.dsp.submap("alttab")' : 'hl.dsp.submap("reset")')
    Timer {
        id: activateSoon
        property var target: null
        interval: 30   // once the switcher has let go of the keyboard
        onTriggered: { if (target) target.activate(); target = null }
    }

    // Hyprland binds (custom/keybinds.lua) call these: hl.dsp.global("quickshell:alttabNext") etc.
    GlobalShortcut { name: "alttabNext"; description: "Window switcher: next"; onPressed: root.move(1) }
    GlobalShortcut { name: "alttabPrev"; description: "Window switcher: previous"; onPressed: root.move(-1) }
    // Bound to *releasing* Super: Hyprland reports a release bind as "released", not "pressed"
    GlobalShortcut {
        name: "alttabCommit"
        description: "Window switcher: switch (when Super is let go)"
        onReleased: root.commit()
        onPressed: root.commit()
    }

    IpcHandler {
        target: "alttab"
        function next(): void { root.move(1) }
        function prev(): void { root.move(-1) }
        function commit(): void { root.commit() }
        function cancel(): void { root.cancel() }
        function state(): string {
            return JSON.stringify({
                open: root.open, index: root.index,
                windows: root.entries.map(e => e.client ? `${e.client.class}: ${e.client.title} [${e.client.workspace.name}]` : "?")
            })
        }
    }

    // ---- the popup -------------------------------------------------------------------------------
    PanelWindow {
        id: win
        visible: root.open
        screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "alttab"   // blur: layer rule in custom/rules.lua
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        MouseArea { anchors.fill: parent; onClicked: root.cancel() }   // click outside: cancel

        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                switch (event.key) {
                case Qt.Key_Right: case Qt.Key_Down: case Qt.Key_Tab: root.move(1); break
                case Qt.Key_Left: case Qt.Key_Up: case Qt.Key_Backtab: root.move(-1); break
                // Enter / Esc act on release: closing on the press would hand the still-held key to
                // the window underneath (Esc drops a browser out of fullscreen, Enter sends a message)
                case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space: case Qt.Key_Escape:
                    if (!event.isAutoRepeat) root.closeKey = event.key
                    break
                default: return
                }
                event.accepted = true
            }
            Keys.onReleased: event => {
                // Backup for the Super-release bind in Hyprland
                if (event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R || event.key === Qt.Key_Meta)
                    root.commit()
                else if (!event.isAutoRepeat && event.key === root.closeKey) {
                    root.closeKey = 0
                    if (event.key === Qt.Key_Escape) root.cancel(); else root.commit()
                    event.accepted = true
                }
            }
        }

        Item {
            id: panel
            readonly property int pad: root.cyber ? 20 : 16
            readonly property int perRow: Math.max(1, Math.floor((win.width * 0.92 - 2 * pad + root.spacing) / (root.cardW + root.spacing)))
            readonly property int cols: Math.max(1, Math.min(root.entries.length, perRow))
            readonly property int rows: Math.max(1, Math.ceil(root.entries.length / cols))
            anchors.centerIn: parent
            width: cols * root.cardW + (cols - 1) * root.spacing + 2 * pad
            height: rows * root.cardH + (rows - 1) * root.spacing + 2 * pad + root.headH + root.footH

            Plate {
                anchors.fill: parent
                radius: 24
                cut: root.cyber ? 18 : 0
                fill: root.cyber ? root.glass : root.rgba(root.col("surface", "#121318"), 0.6)
                strokeWidth: 1
                stroke: root.cyber ? Qt.rgba(root.cyan.r, root.cyan.g, root.cyan.b, 0.5) : root.rgba(root.col("outline_variant", "#46464f"), 0.9)
            }
            MouseArea { anchors.fill: parent }   // a click on the panel itself doesn't cancel

            // Cyber: the title line, like the launcher's
            Item {
                visible: root.cyber
                x: panel.pad; y: panel.pad - 4
                width: panel.width - 2 * panel.pad
                height: 18
                Row {
                    spacing: 12
                    Text { text: "WIN // SWITCH"; color: root.cyan; font.family: root.mono; font.pixelSize: 12; font.letterSpacing: 2.3 }
                    Text { visible: panel.cols > 1; text: "切替"; color: root.mag; font.family: "Noto Sans CJK JP"; font.pixelSize: 12 }
                }
                Text {
                    anchors.right: parent.right
                    text: `${root.entries.length} ${root.entries.length === 1 ? "WINDOW" : "WINDOWS"}`
                    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.48)
                    font.family: root.mono; font.pixelSize: 10; font.letterSpacing: 2.3
                }
            }

            Flow {
                x: panel.pad
                y: panel.pad + root.headH
                width: panel.cols * root.cardW + (panel.cols - 1) * root.spacing
                spacing: root.spacing
                Repeater { model: root.entries; delegate: card }
            }

            Text {      // Cyber: what the keys do
                visible: root.cyber
                x: panel.pad
                width: panel.width - 2 * panel.pad - 16
                anchors { bottom: parent.bottom; bottomMargin: 13 }
                text: panel.cols > 1 ? "TAB  NEXT   ·   SHIFT+TAB  BACK   ·   RELEASE SUPER  SWITCH   ·   ESC  CANCEL" : "RELEASE SUPER  SWITCH"
                elide: Text.ElideRight
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.42)
                font.family: root.mono; font.pixelSize: 9; font.letterSpacing: 1.6
            }

            ParallelAnimation {
                id: appear
                NumberAnimation { target: panel; property: "opacity"; from: 0; to: 1; duration: 110; easing.type: Easing.OutCubic }
                NumberAnimation { target: panel; property: "scale"; from: 0.96; to: 1; duration: 140; easing.type: Easing.OutCubic }
            }
            Connections {
                target: root
                function onOpenChanged() { if (root.open) appear.restart() }
            }
        }
    }

    Component {
        id: card
        Item {
            id: c
            required property var modelData
            required property int index
            readonly property var toplevel: modelData.toplevel
            readonly property var client: modelData.client
            readonly property bool selected: index === root.index
            readonly property bool minimized: client?.workspace?.name === root.minimizedWorkspace
            readonly property string appId: toplevel?.appId ?? client?.class ?? ""
            // Cyber: the app's name over the title ("FILES", "ZEN BROWSER")
            readonly property string appName: DesktopEntries.heuristicLookup(appId)?.name ?? appId.split(".").pop()

            width: root.cardW
            height: root.cardH

            Plate {
                anchors.fill: parent
                radius: 16
                cut: root.cyber ? 10 : 0
                fill: root.cyber
                    ? (c.selected ? Qt.rgba(root.cyan.r, root.cyan.g, root.cyan.b, 0.16)
                       : hover.containsMouse ? Qt.rgba(root.cyan.r, root.cyan.g, root.cyan.b, 0.07) : Qt.rgba(0, 0, 0, 0.22))
                    : (c.selected ? root.rgba(root.col("primary", "#bac3ff"), 0.2)
                       : hover.containsMouse ? root.rgba(root.col("on_surface", "#e3e1e9"), 0.07) : "transparent")
                strokeWidth: root.cyber ? (c.selected ? 1.5 : 1) : (c.selected ? 2 : 0)
                stroke: root.cyber ? (c.selected ? root.cyan : Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.22)) : root.col("primary", "#bac3ff")
            }

            Item {
                id: area
                x: 12
                y: 12
                width: root.thumbW
                height: root.thumbH

                Item {
                    id: thumb
                    // Minimized windows can't be captured live (Hyprland doesn't draw hidden
                    // workspaces), so they show the snapshot taken when they were minimized.
                    readonly property bool useSnapshot: c.minimized && snapshot.status === Image.Ready
                    readonly property bool ready: useSnapshot || (!c.minimized && view.hasContent)
                    readonly property real srcW: useSnapshot ? snapshot.implicitWidth : view.sourceSize.width
                    readonly property real srcH: useSnapshot ? snapshot.implicitHeight : view.sourceSize.height
                    readonly property real fit: srcW > 0 && srcH > 0 ? Math.min(area.width / srcW, area.height / srcH) : 0
                    anchors.centerIn: parent
                    width: fit > 0 ? Math.round(srcW * fit) : area.width
                    height: fit > 0 ? Math.round(srcH * fit) : area.height
                    opacity: c.minimized ? 0.8 : 1

                    Image {
                        id: snapshot
                        source: c.minimized && c.client
                            ? `file://${Quickshell.env("HOME")}/.cache/hypr-setup/minimized/${c.client.address}.png` : ""
                        cache: false
                        asynchronous: false
                        sourceSize: Qt.size(root.thumbW * 2, root.thumbH * 2)
                        mipmap: true
                        smooth: true
                        visible: false
                    }

                    // Live capture at full size, shrunk through a mipmapped texture (keeps text smooth)
                    ScreencopyView {
                        id: view
                        captureSource: root.open && !c.minimized ? c.toplevel : null
                        live: true
                        width: Math.max(1, sourceSize.width)
                        height: Math.max(1, sourceSize.height)
                    }
                    ShaderEffectSource {
                        id: tex
                        sourceItem: view
                        hideSource: true
                        live: true
                        mipmap: true
                        smooth: true
                        visible: false
                        textureSize: Qt.size(Math.max(1, Math.round(view.width / 2)), Math.max(1, Math.round(view.height / 2)))
                    }
                    OpacityMask {
                        anchors.fill: parent
                        visible: thumb.ready
                        source: thumb.useSnapshot ? snapshot : tex
                        maskSource: Rectangle { width: thumb.width; height: thumb.height; radius: root.cyber ? 0 : 10 }
                    }
                    Rectangle {   // Cyber: a thin edge round the preview
                        anchors.fill: parent
                        visible: root.cyber && thumb.ready
                        color: "transparent"
                        border.width: 1
                        border.color: c.selected ? Qt.rgba(root.cyan.r, root.cyan.g, root.cyan.b, 0.7) : Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.3)
                    }
                    Rectangle {   // until the first frame arrives (or no snapshot)
                        anchors.fill: parent
                        visible: !thumb.ready
                        radius: root.cyber ? 0 : 10
                        color: root.cyber ? Qt.rgba(0, 0, 0, 0.4) : root.rgba(root.col("surface_container_high", "#292a2f"), 0.8)
                        border.width: root.cyber ? 1 : 0
                        border.color: Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.3)
                        IconImage {
                            anchors.centerIn: parent
                            implicitSize: 56
                            source: icon.source
                        }
                    }
                }

                Rectangle {
                    visible: c.minimized
                    anchors { top: parent.top; right: parent.right; topMargin: 6; rightMargin: 6 }
                    width: badge.implicitWidth + 14
                    height: badge.implicitHeight + 6
                    radius: root.cyber ? 0 : height / 2
                    color: root.cyber ? Qt.rgba(root.yellow.r, root.yellow.g, root.yellow.b, 0.92) : root.rgba(root.col("surface", "#121318"), 0.85)
                    Text {
                        id: badge
                        anchors.centerIn: parent
                        text: root.cyber ? "MINIMIZED" : "minimized"
                        font.family: root.cyber ? root.mono : Qt.application.font.family
                        font.pixelSize: root.cyber ? 9 : 11
                        font.weight: root.cyber ? Font.Bold : Font.Normal
                        font.letterSpacing: root.cyber ? 1.4 : 0
                        color: root.cyber ? "#05040a" : root.col("on_surface_variant", "#c6c5d0")
                    }
                }
            }

            IconImage {
                id: icon
                x: 14
                y: area.y + area.height + 12
                implicitSize: 24
                source: Quickshell.iconPath(DesktopEntries.heuristicLookup(c.appId)?.icon ?? c.appId, "application-x-executable")
            }
            Text {      // end-4/pC: the title beside the icon
                visible: !root.cyber
                anchors { left: icon.right; leftMargin: 8; right: parent.right; rightMargin: 14; verticalCenter: icon.verticalCenter }
                text: c.client?.title || c.toplevel?.title || c.appId
                elide: Text.ElideRight
                font.pixelSize: 13
                font.weight: c.selected ? Font.DemiBold : Font.Normal
                color: root.col("on_surface", "#e3e1e9")
            }
            Column {    // Cyber: the app's name and the workspace, small, over the title
                visible: root.cyber
                anchors { left: icon.right; leftMargin: 10; right: parent.right; rightMargin: 14; verticalCenter: icon.verticalCenter }
                spacing: 1
                Item {
                    width: parent.width
                    height: appLabel.implicitHeight
                    Text {
                        id: appLabel
                        width: parent.width - where.implicitWidth - 8
                        text: c.appName.toUpperCase()
                        elide: Text.ElideRight
                        color: Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.85)
                        font.family: root.mono; font.pixelSize: 9; font.letterSpacing: 1.6
                    }
                    Text {
                        id: where
                        anchors.right: parent.right
                        text: (c.client?.workspace?.id ?? 0) > 0 ? `WS ${String((c.client.workspace.id - 1) % 10 + 1).padStart(2, "0")}` : ""
                        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.42)
                        font.family: root.mono; font.pixelSize: 9; font.letterSpacing: 1.6
                    }
                }
                Text {
                    width: parent.width
                    text: c.client?.title || c.toplevel?.title || c.appId
                    elide: Text.ElideRight
                    color: c.selected ? root.cyan : root.fg
                    font.family: root.mono; font.pixelSize: 12; font.letterSpacing: 0.3
                    font.weight: c.selected ? Font.DemiBold : Font.Normal
                }
            }

            MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                onClicked: { root.index = c.index; root.commit() }
            }
        }
    }
}
