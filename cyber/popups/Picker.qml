// Pickers: emoji (Super+.) and the clipboard history (Super+V). What is chosen goes straight into
// the window that was being typed in: the picker closes, the window has the keyboard again, and
//   an emoji is typed there (wtype);
//   a clipboard entry is made the clipboard's content and pasted there (Ctrl+V; Ctrl+Shift+V in
//   a terminal).
// Emoji: a grid by category, like a phone's emoji keyboard: no names, a row of category tabs, the
// ones used last on top. Typing searches by name. Arrows move, Tab is the next category, Enter or
// a click inserts. Clipboard: a list, newest first; typing filters; ↑/↓, Enter or a click pastes.
// Esc or a click beside the panel closes.
//   emoji list: end-4's ~/.config/hypr/hyprland/scripts/fuzzel-emoji.sh (after its "### DATA ###"
//     line: one emoji and its keywords per line, in Unicode's order, which is what the categories
//     are cut from: each begins at a known emoji, `groups` below)
//   clipboard: `cliphist list` (kept by the wl-paste watchers end-4's config starts)
// Ui.pickerMode says which one is open ("" = closed); Ui.pick(mode) opens and closes.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.components

PanelWindow {
    id: win
    readonly property bool open: Ui.pickerMode !== ""
    property string mode: "clipboard"       // the one shown (kept while it glitches out)
    readonly property bool emoji: mode === "emoji"

    visible: open || glitch.busy
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "cyber:picker"
    WlrLayershell.keyboardFocus: open && !Ui.demo ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    property string query: ""
    readonly property var words: query.trim().toLowerCase().split(/\s+/).filter(w => w)
    onQueryChanged: { index = 0; sel = 0; still = true }

    // The pointer chooses only once it has really moved. When the picker opens, or the list changes
    // as you type, whatever lands under a pointer that is standing still gets hover events too:
    // without this it took the selection away from the keyboard (Enter then inserted the wrong one).
    property bool still: true
    property point last: Qt.point(-1, -1)
    function moved(item, mouse) {
        const p = item.mapToItem(null, mouse.x, mouse.y)
        const was = last
        last = Qt.point(Math.round(p.x), Math.round(p.y))
        if (still) { if (was.x === last.x && was.y === last.y || was.x < 0) return false; still = false }
        return true
    }

    // ---------------------------------------------------------------- clipboard
    property var clips: []      // [{ line, show, find, image }]
    property int index: 0
    readonly property var shownClips: words.length ? clips.filter(e => words.every(w => e.find.includes(w))) : clips
    Process {
        id: readClips
        command: ["cliphist", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = []
                for (const line of text.split("\n")) {
                    const tab = line.indexOf("\t")
                    if (tab < 0) continue
                    const body = line.slice(tab + 1)
                    const pic = /^\[\[ binary data (.+) \]\]$/.exec(body)      // "[[ binary data 14 KiB png 1280x720 ]]"
                    out.push({ line: line, image: pic !== null, show: pic ? pic[1].toUpperCase() : body.replace(/\s+/g, " ").trim(),
                               find: (pic ? "image picture " + pic[1] : body).toLowerCase() })
                }
                win.clips = out
            }
        }
    }

    // ---------------------------------------------------------------- emoji
    readonly property int cols: 14
    readonly property int cell: 44
    readonly property var groups: [     // in Unicode's order; `first` is where each begins in the list
        { name: "SMILEYS & EMOTION", icon: "mood", first: "😀" },
        { name: "PEOPLE & BODY", icon: "waving_hand", first: "👋" },
        { name: "ANIMALS & NATURE", icon: "pets", first: "🐵" },
        { name: "FOOD & DRINK", icon: "restaurant", first: "🍇" },
        { name: "TRAVEL & PLACES", icon: "flight", first: "🌍" },
        { name: "ACTIVITIES", icon: "sports_soccer", first: "🎃" },
        { name: "OBJECTS", icon: "lightbulb", first: "👓" },
        { name: "SYMBOLS", icon: "emoji_symbols", first: "🏧" },
        { name: "FLAGS", icon: "flag", first: "🏁" },
    ]
    property var emojis: []         // [{ glyph, find, group }]
    property var recent: []         // the ones used last, newest first
    property int sel: 0             // the chosen cell: an index into grid.flat
    // What the grid shows: the rows of a list, each a heading or up to `cols` cells.
    //   rows:  [{ head: "FLAGS" } | { cells: [{ glyph, n }] }]      n = that cell's index in flat
    //   flat:  [{ glyph, row, col }]                                every cell, in order
    //   heads: [{ row, group, at }]                                 where each category begins (group -1 = recent)
    readonly property var grid: {
        const rows = [], flat = [], heads = []
        const add = (title, list, group) => {
            if (!list.length) return
            heads.push({ row: rows.length, group: group, at: flat.length })
            rows.push({ head: title })
            for (let i = 0; i < list.length; i += cols) {
                const cells = []
                for (let k = i; k < Math.min(i + cols, list.length); k++) {
                    cells.push({ glyph: list[k].glyph, n: flat.length })
                    flat.push({ glyph: list[k].glyph, row: rows.length, col: k - i })
                }
                rows.push({ cells: cells })
            }
        }
        if (words.length) {     // a search: the ones named after what was typed first
            const q = words[0], rank = e => e.find.startsWith(q) ? 0 : (" " + e.find).includes(" " + q) ? 1 : 2
            const hit = emojis.filter(e => words.every(w => e.find.includes(w)))
            add("FOUND", hit.map((e, i) => [rank(e), i, e]).sort((a, b) => a[0] - b[0] || a[1] - b[1]).map(x => x[2]), -2)
        } else {
            add("RECENT", recent.map(g => ({ glyph: g })), -1)
            groups.forEach((g, i) => add(g.name, emojis.filter(e => e.group === i), i))
        }
        return { rows: rows, flat: flat, heads: heads }
    }
    readonly property int shownGroup: {     // the category at the top of the list (for the tabs)
        const top = Math.max(0, emojiList.indexAt(8, emojiList.contentY + 8))
        let g = -3
        for (const h of grid.heads) if (h.row <= top) g = h.group
        return g
    }
    onSelChanged: { const c = grid.flat[sel]; if (emoji && c) emojiList.positionViewAtIndex(c.row, ListView.Contain) }
    function step(d) { if (grid.flat.length) sel = Math.max(0, Math.min(grid.flat.length - 1, sel + d)) }
    function stepRow(d) {       // the same column, d rows of cells further (headings are skipped)
        const here = grid.flat[sel]
        if (!here) return
        const dir = d > 0 ? 1 : -1
        let r = here.row, best = sel
        for (let left = Math.abs(d); left > 0; left--) {
            let next = r + dir
            while (next >= 0 && next < grid.rows.length && grid.rows[next].cells === undefined) next += dir
            if (next < 0 || next >= grid.rows.length) break
            r = next
            const cells = grid.rows[r].cells
            best = cells[Math.min(here.col, cells.length - 1)].n
        }
        sel = best
    }
    function jump(group) {      // to the beginning of a category
        const h = grid.heads.find(x => x.group === group)
        if (!h) return
        sel = h.at
        emojiList.positionViewAtIndex(h.row, ListView.Beginning)
    }
    function stepGroup(d) {
        let at = 0
        grid.heads.forEach((h, i) => { if (h.at <= sel) at = i })
        const to = grid.heads[Math.max(0, Math.min(grid.heads.length - 1, at + d))]
        if (to) jump(to.group)
    }
    Process {
        id: readEmoji
        command: ["sh", "-c", 'sed "1,/^### DATA ###$/d" "$HOME/.config/hypr/hyprland/scripts/fuzzel-emoji.sh"']
        stdout: StdioCollector {
            onStreamFinished: {
                const out = []
                let group = 0
                for (const line of text.split("\n")) {
                    const sp = line.indexOf(" ")
                    if (sp <= 0) continue
                    const glyph = line.slice(0, sp)
                    if (group + 1 < win.groups.length && glyph === win.groups[group + 1].first) group++
                    out.push({ glyph: glyph, find: line.slice(sp + 1).trim().toLowerCase(), group: group })
                }
                win.emojis = out
            }
        }
    }
    // the ones used last: one line in a small file, so they are still there after a restart
    readonly property string recentFile: `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/hypr-setup/emoji-recent`
    Process {
        id: makeRecent
        command: ["sh", "-c", 'mkdir -p "$(dirname "$1")" && touch "$1"', "sh", win.recentFile]
        onExited: recentView.path = win.recentFile
    }
    FileView {
        id: recentView
        onLoaded: win.recent = text().split(/\s+/).filter(g => g).slice(0, 2 * win.cols)
    }
    Component.onCompleted: makeRecent.running = true
    function used(glyph) {
        recent = [glyph].concat(recent.filter(g => g !== glyph)).slice(0, 2 * cols)
        Quickshell.execDetached(["sh", "-c", 'printf "%s" "$2" > "$1"', "sh", recentFile, recent.join(" ")])
    }

    // ---------------------------------------------------------------- opening, choosing
    Connections {
        target: Ui
        function onPickerModeChanged() {
            if (!win.open) return
            win.mode = Ui.pickerMode
            input.text = ""; win.index = 0; win.sel = 0; win.still = true; keyUp.reset()
            if (win.emoji) {
                if (!win.emojis.length) readEmoji.running = true
                emojiList.positionViewAtBeginning()
            } else readClips.running = true          // every time: it changes with every copy
            Qt.callLater(() => input.forceActiveFocus())
        }
    }

    // Into the window that had the keyboard: this picker closes, a moment later that window has
    // the keyboard back (Hyprland returns it as soon as the picker asks for none), and then it
    // is typed or pasted there. In a terminal, paste is Ctrl+Shift+V.
    readonly property string paste:
        'printf "%s" "$1" | cliphist decode | wl-copy || exit 0\n' +
        'sleep 0.06\n' +
        'case "$(hyprctl activewindow -j | jq -r ".class // empty")" in\n' +
        '  com.mitchellh.ghostty|kitty|foot|footclient|Alacritty|org.wezfurlong.wezterm|org.kde.konsole|org.gnome.Console|org.gnome.Ptyxis|xterm|XTerm)\n' +
        '    wtype -M ctrl -M shift -k v -m shift -m ctrl ;;\n' +
        '  *) wtype -M ctrl -k v -m ctrl ;;\n' +
        'esac'
    property var todo: null
    function choose(entry) {
        if (!entry) return
        if (entry.glyph !== undefined) used(entry.glyph)
        todo = entry
        Ui.pickerMode = ""
        later.restart()
    }
    Timer {
        id: later
        interval: 170
        onTriggered: {
            const t = win.todo
            win.todo = null
            if (!t) return
            // (if it cannot be typed, it is at least on the clipboard)
            if (t.glyph !== undefined) Quickshell.execDetached(["sh", "-c", 'wtype -- "$1" || printf "%s" "$1" | wl-copy', "sh", t.glyph])
            else Quickshell.execDetached(["bash", "-c", win.paste, "bash", t.line])
        }
    }
    function move(step) { if (shownClips.length) index = (index + step + shownClips.length) % shownClips.length }

    MouseArea { anchors.fill: parent; onClicked: Ui.pickerMode = "" }

    Glitch {
        id: glitch
        active: win.open
        anchors.centerIn: parent
        width: 660 + 1000       // wider than the panel: the glitch streaks spill out to the sides
        height: 540 + 120
        strength: 0.85
        Frame {
            id: panel
            anchors.centerIn: parent
            width: 660
            height: 540
            fill: Theme.glassHi
            cut: 18
            cutTopLeft: true; cutTopRight: false; cutBottomRight: true; cutBottomLeft: false
            MouseArea { anchors.fill: parent }

            Column {
                id: body
                anchors { fill: parent; margins: 22 }
                spacing: 14

                Item {
                    width: parent.width
                    height: 18
                    Row {
                        spacing: 12
                        HudText { text: win.emoji ? "SYM // EMOJI" : "MEM // CLIPBOARD"; color: Theme.cyan; font.pixelSize: 12 }
                        Text { text: win.emoji ? "絵文字" : "履歴"; font.family: Theme.jp; font.pixelSize: 12; color: Theme.mag }
                    }
                    HudText {
                        anchors.right: parent.right
                        text: win.emoji ? "CLICK OR ENTER INSERTS" : `${win.shownClips.length} ENTRIES  ·  CLICK OR ENTER PASTES`
                        font.pixelSize: 10
                        color: Theme.dim
                    }
                }

                Frame {
                    width: parent.width
                    height: 42
                    cut: 10
                    stroke: Theme.alpha(Theme.cyan, input.activeFocus ? 0.9 : 0.4)
                    Icon { x: 12; anchors.verticalCenter: parent.verticalCenter; name: "search"; color: Theme.cyan }
                    TextInput {
                        id: input
                        x: 42
                        width: parent.width - 54
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.fg
                        selectionColor: Theme.alpha(Theme.cyan, 0.4)
                        font.family: Theme.mono
                        font.pixelSize: 15
                        focus: true
                        onTextChanged: win.query = text
                        KeyUp { id: keyUp }   // closing keys act on release (see components/KeyUp.qml)
                        Keys.onReleased: e => keyUp.release(e)
                        Keys.onPressed: e => {
                            if (e.key === Qt.Key_Escape) keyUp.defer(e, () => Ui.pickerMode = "")
                            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                const entry = win.emoji ? win.grid.flat[win.sel] : win.shownClips[win.index]
                                keyUp.defer(e, () => win.choose(entry))
                            } else if (win.emoji) {
                                if (e.key === Qt.Key_Right) win.step(1)
                                else if (e.key === Qt.Key_Left) win.step(-1)
                                else if (e.key === Qt.Key_Down) win.stepRow(1)
                                else if (e.key === Qt.Key_Up) win.stepRow(-1)
                                else if (e.key === Qt.Key_PageDown) win.stepRow(5)
                                else if (e.key === Qt.Key_PageUp) win.stepRow(-5)
                                else if (e.key === Qt.Key_Tab) win.stepGroup(1)
                                else if (e.key === Qt.Key_Backtab) win.stepGroup(-1)
                                else return
                            } else {
                                if (e.key === Qt.Key_Down || e.key === Qt.Key_Tab) win.move(1)
                                else if (e.key === Qt.Key_Up || e.key === Qt.Key_Backtab) win.move(-1)
                                else if (e.key === Qt.Key_PageDown) win.move(8)
                                else if (e.key === Qt.Key_PageUp) win.move(-8)
                                else return
                            }
                            e.accepted = true
                        }
                        HudText {
                            visible: !input.text
                            anchors.verticalCenter: parent.verticalCenter
                            text: win.emoji ? "SEARCH EMOJI_" : "SEARCH WHAT WAS COPIED_"
                            color: Theme.dim
                            font.pixelSize: 12
                        }
                    }
                }

                // ---- emoji: category tabs, then the grid
                Row {
                    visible: win.emoji
                    height: 30
                    spacing: 4
                    opacity: win.words.length ? 0.35 : 1
                    Repeater {
                        model: [{ icon: "schedule", group: -1 }].concat(win.groups.map((g, i) => ({ icon: g.icon, group: i })))
                        Rectangle {
                            id: tab
                            required property var modelData
                            readonly property bool on: win.shownGroup === modelData.group
                            width: 58; height: 30
                            color: on ? Theme.alpha(Theme.cyan, 0.16) : tabArea.containsMouse ? Theme.alpha(Theme.cyan, 0.07) : "transparent"
                            border.width: 1
                            border.color: on ? Theme.cyan : Theme.alpha(Theme.teal, 0.3)
                            opacity: win.grid.heads.some(h => h.group === modelData.group) ? 1 : 0.3
                            Icon { anchors.centerIn: parent; name: tab.modelData.icon; size: 18; color: tab.on ? Theme.cyan : Theme.teal }
                            MouseArea { id: tabArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.jump(tab.modelData.group) }
                        }
                    }
                }
                ListView {
                    id: emojiList
                    visible: win.emoji
                    width: parent.width
                    height: body.height - 18 - 42 - 30 - 3 * 14
                    clip: true
                    model: win.grid.rows
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: Item {
                        id: line
                        required property var modelData
                        readonly property bool head: modelData.head !== undefined
                        width: emojiList.width
                        height: head ? 26 : win.cell
                        HudText {
                            visible: line.head
                            x: 3
                            anchors { bottom: parent.bottom; bottomMargin: 5 }
                            text: line.modelData.head ?? ""
                            font.pixelSize: 10
                            color: Theme.alpha(Theme.teal, 0.85)
                        }
                        Row {
                            visible: !line.head
                            Repeater {
                                model: line.head ? [] : line.modelData.cells
                                Item {
                                    id: one
                                    required property var modelData
                                    readonly property bool on: modelData.n === win.sel
                                    width: win.cell; height: win.cell
                                    Rectangle {
                                        anchors { fill: parent; margins: 2 }
                                        visible: one.on
                                        color: Theme.alpha(Theme.cyan, 0.2)
                                        border.width: 1
                                        border.color: Theme.alpha(Theme.cyan, 0.9)
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        text: one.modelData.glyph
                                        font.family: "Noto Color Emoji"
                                        font.pixelSize: 27
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onPositionChanged: mouse => { if (win.moved(this, mouse)) win.sel = one.modelData.n }
                                        onClicked: win.choose(win.grid.flat[one.modelData.n])
                                    }
                                }
                            }
                        }
                    }
                    HudText {
                        visible: win.grid.flat.length === 0
                        anchors.centerIn: parent
                        text: win.emojis.length === 0 ? "NO EMOJI LIST FOUND" : "NO MATCH"
                        color: Theme.dim
                        font.pixelSize: 11
                    }
                }

                // ---- clipboard: the list
                ListView {
                    id: list
                    visible: !win.emoji
                    width: parent.width
                    height: body.height - 18 - 42 - 2 * 14
                    clip: true
                    model: win.shownClips
                    currentIndex: win.index
                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: Item {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool selected: index === win.index
                        width: list.width
                        height: 40
                        Rectangle {
                            anchors.fill: parent
                            color: row.selected ? Theme.alpha(Theme.cyan, 0.16) : "transparent"
                            Rectangle { visible: row.selected; width: 3; height: parent.height; color: Theme.cyan }
                        }
                        Icon {      // a picture, or text
                            x: 16
                            anchors.verticalCenter: parent.verticalCenter
                            name: row.modelData.image ? "image" : "notes"
                            size: 18
                            color: row.selected ? Theme.cyan : Theme.teal
                        }
                        HudText {
                            x: 48
                            width: list.width - x - 14
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.show
                            caps: false
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            font.letterSpacing: 0.3
                            font.pixelSize: 13
                            color: row.selected ? Theme.cyan : Theme.fg
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: mouse => { if (win.moved(this, mouse)) win.index = row.index }
                            onClicked: win.choose(row.modelData)
                        }
                    }
                    HudText {
                        visible: win.shownClips.length === 0
                        anchors.centerIn: parent
                        text: win.clips.length === 0 ? "NOTHING COPIED YET" : "NO MATCH"
                        color: Theme.dim
                        font.pixelSize: 11
                    }
                }
            }
        }
    }
}
