#!/usr/bin/env bash
# Cyber: set up (or repair) the whole desktop from this repo. No sudo needed; safe to repeat.
# Run it after cloning, after end-4's `./setup install` and after every update of end-4's dots,
# which wipe parts of ~/.config:
#
#   ./setup.sh
#
# The repo can live anywhere: step 0 links it to ~/.local/share/cyber, and everything else
# (Hyprland config, Ghostty, kitty, the lock-screen hook) refers to that path.
#
#   0. the link ~/.local/share/cyber -> this repo
#   1. the end4-pC shell (pctrade/end4-pC), kept in ~/.local/src and symlinked into
#      ~/.config/quickshell, because end-4's installer rsync --delete's that folder
#   2. Hyprland settings for both desktops + your apps, keybinds and blur, in
#      ~/.config/hypr/custom/ (never overwritten by updates)
#   3. fcitx5 (mozc/rime) in Hyprland: start it + the IM environment variables
#   4. your sans-serif font rule (Yshi-YuanGothic), deleted by the fontconfig sync
#   5. Cyber's GTK4 look for GNOME Files (an import in end-4's gtk.css and its matugen template)
#   6. your GTK font (gsettings), which the installer switches to Google Sans Flex
#   7. the lock screen: canvaslock (greeter/, the cyberpunk theme) via hypridle, if installed
#   8. kitty: start your own shell (zsh) instead of end-4's fish; Ghostty with a CRT glow as
#      Cyber's terminal (if installed)
#   9. two desktops, end-4/pC and Cyber (desktop.sh): the Cyber shell link + the lock-screen hook
#  10. the mouse cursor set (assets/cursor/Yellow, converted to an Xcursor theme)
#  11. a list of the packages this desktop uses that are not installed yet
set -euo pipefail

ROOT="$(dirname "$(readlink -f "$0")")"    # this repo
STABLE="$HOME/.local/share/cyber"          # the path everything refers to
PC_SRC="$HOME/.local/src/end4-pC"
CUSTOM="$HOME/.config/hypr/custom"
GTK_FONT="${GTK_FONT:-Yshi-YuanGothic 10.5}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

[[ -f $HOME/.config/hypr/hyprland.lua ]] || {
  echo "~/.config/hypr/hyprland.lua not found: run end-4's installer first (see README.md)."; exit 1; }

# 0. The stable path ---------------------------------------------------------------------
if [[ -e $STABLE && ! -L $STABLE ]]; then
  echo "$STABLE exists and is not a link: move it away first."; exit 1
fi
mkdir -p "$(dirname "$STABLE")"
ln -sfn "$ROOT" "$STABLE"
say "Cyber: $ROOT (linked at $STABLE)"

# Remove a block between marker lines (also used for blocks older versions of this script wrote).
drop_block() { # file name [comment-prefix, default "--" for Lua]
  local file=$1 c=${3:---}
  [[ -f $file ]] || return 0
  awk -v b="$c >>> hypr-setup: $2" -v e="$c <<< hypr-setup: $2" \
    '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}
# Replace (or add) a block between marker lines in a file, so re-running never duplicates it.
put_block() { # file name content [comment-prefix, default "--" for Lua]
  local file=$1 name=$2 content=$3 c=${4:---}
  mkdir -p "$(dirname "$file")"; touch "$file"
  drop_block "$file" "$name" "$c"
  printf '%s >>> hypr-setup: %s\n%s\n%s <<< hypr-setup: %s\n' "$c" "$name" "$content" "$c" "$name" >> "$file"
}

# 1. end4-pC -----------------------------------------------------------------
if [[ ! -d $PC_SRC/.git ]]; then
  say "Cloning end4-pC to $PC_SRC"
  git clone https://github.com/pctrade/end4-pC "$PC_SRC"
fi
LINK="$HOME/.config/quickshell/end4-pC"
mkdir -p "$HOME/.config/quickshell"
if [[ -d $LINK && ! -L $LINK ]]; then
  mv "$LINK" "$LINK.moved-$(date +%s)"   # a real folder from a manual clone: keep it, out of the way
fi
ln -sfn "$PC_SRC" "$LINK"
say "end4-pC linked: $LINK -> $PC_SRC"

# 2. Hyprland: use end4-pC instead of ii, your apps, your keybind changes ------
put_block "$CUSTOM/variables.lua" "quickshell config" \
'-- Two desktops: end4-pC (pctrade/end4-pC) or cyber (~/.local/share/cyber/cyber). desktop.sh
-- stores the choice; it is read at login and on every config reload. ("ii" = stock end-4 shell)
local desktop_file = io.open(os.getenv("HOME") .. "/.local/state/hypr-setup/desktop")
DESKTOP = desktop_file and desktop_file:read("l") or "end4-pC"
if desktop_file then desktop_file:close() end
if DESKTOP ~= "cyber" then DESKTOP = "end4-pC" end
hl.env("qsConfig", DESKTOP)'
put_block "$CUSTOM/variables.lua" "apps" \
'browser = "zen-browser"        -- Super+W
-- Super+E: GNOME Files (Nautilus). Until it is installed, whatever end-4 finds first.
do
    local f = io.open("/usr/bin/nautilus")
    if f then f:close(); fileManager = "nautilus --new-window" end
end'
put_block "$CUSTOM/variables.lua" "cyber terminal" \
'-- Cyber opens Ghostty (CRT glow shader: ~/.local/share/cyber/ghostty), end-4/pC keeps kitty.
-- Super+Return / Super+T / Ctrl+Alt+T use this variable.
do
    local f = io.open("/usr/bin/ghostty")
    if f then f:close() end
    if DESKTOP == "cyber" and f then terminal = "ghostty" end
end'
put_block "$CUSTOM/variables.lua" "cyber gtk" \
'-- GTK4 apps (GNOME Files) wear Cyber'"'"'s look only while Cyber is the desktop. end-4'"'"'s GTK4
-- stylesheet ends with an import of ~/.config/gtk-4.0/cyber.css (setup.sh adds it); that name
-- points at Cyber'"'"'s stylesheet (~/.local/share/cyber/gtk/cyber.css) here and at nothing on
-- end-4/pC. Apps read it when they start.
do
    local home = os.getenv("HOME")
    local to = DESKTOP == "cyber" and (home .. "/.local/share/cyber/gtk/cyber.css") or "/dev/null"
    os.execute("ln -sfn \"" .. to .. "\" \"" .. home .. "/.config/gtk-4.0/cyber.css\"")
    -- the pictures that stylesheet uses (the outline frames): ~/.config/gtk-4.0/cyber/
    os.execute("ln -sfn \"" .. home .. "/.local/share/cyber/gtk/cyber\" \"" .. home .. "/.config/gtk-4.0/cyber\"")
    -- GTK apps also get GNOME'"'"'s own icon set here (Adwaita: the folders Files is drawn for);
    -- end-4/pC keeps its Breeze icons. Open windows change at once.
    os.execute("gsettings set org.gnome.desktop.interface icon-theme " .. (DESKTOP == "cyber" and "Adwaita" or "breeze-dark") .. " &")
end'
drop_block "$CUSTOM/keybinds.lua" "end4-pC settings"   # Super+Esc (removed: tapping Super opens search)
put_block "$CUSTOM/keybinds.lua" "keybinds" \
'-- Float/tile the active window: Super+Space (end-4 has it on Super+Alt+Space)
hl.unbind("SUPER + ALT + Space")
hl.bind("SUPER + Space", hl.dsp.window.float({ action = "toggle" }), { description = "Window: Float/Tile" })
-- Super+Shift+S (screen snip): with a shell running, the shell does it. The fallback for when none
-- runs called hyprshot, the only thing here that needed that program. It is the capture script of
-- this repo instead (grim + slurp), so hyprshot can be uninstalled.
hl.unbind("SUPER + SHIFT + S")
hl.bind("SUPER + SHIFT + S", hl.dsp.global("quickshell:regionScreenshot"), { description = "Utilities: Screen snip" })
hl.bind("SUPER + SHIFT + S", hl.dsp.exec_cmd("qs -c $qsConfig ipc call TEST_ALIVE || pidof slurp || " .. os.getenv("HOME") .. "/.local/share/cyber/cyber/scripts/capture.sh region"))'
put_block "$CUSTOM/keybinds.lua" "minimize" "$(cat <<'LUA'
-- Minimize (Hyprland has none): Super+M, or an app's own minimize button, puts the window in a
-- hidden workspace, special:minimized. Clicking it in the dock or the Super+Tab switcher (anything
-- that focuses it) brings it back to the workspace you are on.
local MINIMIZED = "special:minimized"
-- Hyprland doesn't draw windows in a hidden workspace, so the Super+Tab switcher can't show them
-- live. Take a snapshot just before hiding; the switcher shows that instead.
local SNAPSHOTS = "$HOME/.cache/hypr-setup/minimized"

local function minimize(w)
    if not w or (w.workspace and w.workspace.name == MINIMIZED) then return end
    if w.visible and w.at and w.size then
        local move = string.format(
            "hl.dispatch(hl.dsp.window.move({ workspace = '%s', follow = false, window = 'address:%s' }))",
            MINIMIZED, w.address)
        hl.exec_cmd(string.format('mkdir -p "%s"; grim -g "%d,%d %dx%d" "%s/%s.png"; hyprctl eval "%s"',
            SNAPSHOTS, w.at.x, w.at.y, w.size.x, w.size.y, SNAPSHOTS, w.address, move))
    else
        hl.dispatch(hl.dsp.window.move({ workspace = MINIMIZED, follow = false, window = "address:" .. w.address }))
    end
end

local function restore(w)
    local ws = hl.get_active_workspace()   -- the normal workspace on the focused monitor
    if not ws then return end
    local target = "address:" .. w.address
    -- Focusing it opened the hidden workspace. Close that first: otherwise, once this window
    -- leaves, focus falls to the next minimized window there and restores that one too.
    for _, m in ipairs(hl.get_monitors()) do
        if m.active_special_workspace and m.active_special_workspace.name == MINIMIZED then
            hl.dispatch(hl.dsp.workspace.toggle_special("minimized"))
        end
    end
    hl.dispatch(hl.dsp.window.move({ workspace = ws.id, follow = false, window = target }))
    hl.dispatch(hl.dsp.focus({ window = target }))
end

hl.unbind("SUPER + M")   -- was: media controls (still in the bar)
hl.bind("SUPER + M", function() minimize(hl.get_active_window()) end, { description = "Window: Minimize" })
-- Focusing a minimized window first opens the hidden workspace, which briefly focuses the window
-- last used there. So wait a moment and restore only the window that ends up focused.
local function in_minimized(w) return w and w.workspace and w.workspace.name == MINIMIZED end
hl.on("window.active", function(w)
    if not in_minimized(w) then return end
    hl.timer(function()
        local now = hl.get_active_window()
        if in_minimized(now) then restore(now) end
    end, { timeout = 40, type = "oneshot" })
end)
hl.on("window.minimize", function(w, minimized)
    if minimized ~= false then minimize(w) end
end)
LUA
)"
put_block "$CUSTOM/keybinds.lua" "window switcher" "$(cat <<'LUA'
-- Super+Tab window switcher (~/.local/share/cyber/alttab): hold Super, tap Tab (Shift+Tab goes
-- back), let go of Super to switch. Lists every window, minimized ones too.
hl.unbind("SUPER + Tab")   -- was: end4-pC's workspace overview
-- Letting go of Super switches. A "Super released" bind alone isn't enough: Hyprland only runs it
-- if no other key is still down, so lifting Super a moment before Tab left the switcher open.
-- While the switcher is in use, Hyprland therefore also watches the Super keys themselves.
local alttabWatching = false
local function alttabSuperDown()
    local ok, down = pcall(function() return hl.is_key_down("Super_L") or hl.is_key_down("Super_R") end)
    return ok and down
end
local function alttabWatch()
    if alttabSuperDown() then
        hl.timer(alttabWatch, { timeout = 25, type = "oneshot" })
    else
        alttabWatching = false
        hl.dispatch(hl.dsp.submap("reset"))
        hl.dispatch(hl.dsp.global("quickshell:alttabCommit"))
    end
end
local function alttabStep(name)
    return function()
        hl.dispatch(hl.dsp.global("quickshell:" .. name))
        if not alttabWatching then
            alttabWatching = true
            hl.timer(alttabWatch, { timeout = 25, type = "oneshot" })
        end
    end
end
hl.bind("SUPER + Tab", alttabStep("alttabNext"), { repeating = true, description = "Window: Switcher" })
hl.bind("SUPER + SHIFT + Tab", alttabStep("alttabPrev"), { repeating = true })
-- (these fire at once when Tab was let go first; the watch above covers the other order)
hl.bind("SUPER_L", hl.dsp.global("quickshell:alttabCommit"), { ignore_mods = true, transparent = true, release = true })
hl.bind("SUPER_R", hl.dsp.global("quickshell:alttabCommit"), { ignore_mods = true, transparent = true, release = true })
-- While the switcher is open it puts Hyprland in this submap, so Super+click / Super+scroll reach the
-- switcher instead of starting a window drag or a workspace change. The watch above leaves it when
-- Super is let go; the release binds in here are a last resort (press and release Super again).
hl.define_submap("alttab", function()
    hl.bind("SUPER + Tab", alttabStep("alttabNext"), { repeating = true })
    hl.bind("SUPER + SHIFT + Tab", alttabStep("alttabPrev"), { repeating = true })
    for _, key in ipairs({ "SUPER_L", "SUPER_R" }) do
        hl.bind(key, function()
            hl.dispatch(hl.dsp.submap("reset"))
            hl.dispatch(hl.dsp.global("quickshell:alttabCommit"))
        end, { ignore_mods = true, transparent = true, release = true })
    end
end)
-- Ctrl+Super+R (restart the shell) kills every Quickshell: start the switcher again too
hl.unbind("CTRL + SUPER + R")
hl.bind("CTRL + SUPER + R",
    hl.dsp.exec_cmd("killall ydotool qs quickshell; qs -c $qsConfig & (sleep 1; qs -n -p ~/.local/share/cyber/alttab) &"),
    { description = "Shell: Restart widgets" })
LUA
)"
drop_block "$CUSTOM/keybinds.lua" "cyber keys"   # older name of the block below
put_block "$CUSTOM/keybinds.lua" "cyber desktop" "$(cat <<'LUA'
-- Cyber desktop only (DESKTOP comes from custom/variables.lua); end-4/pC is untouched.
if DESKTOP == "cyber" then
    -- PrintScrn opens Cyber's screenshot HUD (region / window / screen)
    hl.unbind("Print")
    hl.bind("Print", hl.dsp.global("quickshell:captureToggle"), { description = "Utilities: Screenshot (Cyber HUD)" })

    -- (How windows open on Cyber, floating / centred / sized, is in custom/env.lua: "cyber windows".)
    -- Move a window with Super+drag or its title bar, resize it from its edges or Super+right-drag.
    hl.config({ general = { resize_on_border = true, extend_border_grab_area = 15, hover_icon_on_border = true } })

    -- No window borders (Look.qml); the focused window gets cyan corner brackets instead, drawn by a
    -- small Hyprland plugin (cyber/hypr/corners) so they move with the window. Hyprland unloads it by
    -- itself when switching to end-4/pC. After a Hyprland update it rebuilds itself in the background
    -- and reloads (log: ~/.cache/hypr-setup/corners-build.log); until then there are no corners.
    do
        local dir = HOME .. "/.local/share/cyber/cyber/hypr/corners"
        local f = io.open(dir .. "/cybercorners.stamp")
        local stamp = f and f:read("a") or ""
        if f then f:close() end
        local so = io.open(dir .. "/cybercorners.so")
        if so then so:close() end
        if so and stamp:match("^%S+%s+(%S+)") == hl.version() then
            hl.plugin.load(dir .. "/cybercorners.so")
        else
            os.execute(dir .. "/build.sh reload >>" .. HOME .. "/.cache/hypr-setup/corners-build.log 2>&1 &")
        end
    end

    -- The glitch on windows opening/closing and on workspace changes is run by Hyprland itself
    -- (its own events + a screen shader, so it is drawn in the same frame as the window).
    local ok, err = pcall(dofile, os.getenv("HOME") .. "/.local/share/cyber/cyber/hypr/glitch.lua")
    if not ok then print("cyber glitch: " .. tostring(err)) end

    -- Looking Glass (the Windows VM): a fixture top-left, under the other windows and tilted while
    -- idle, raised and flat while the pointer is on it (cyber/hypr/lookingglass.lua; bar button starts it)
    ok, err = pcall(dofile, os.getenv("HOME") .. "/.local/share/cyber/cyber/hypr/lookingglass.lua")
    if not ok then print("cyber looking glass: " .. tostring(err)) end

    -- Super+Q: eliminate mode (aim at a window, click to close it); the cyan edge glow while Super
    -- is held never sticks (cyber/hypr/keys.lua)
    ok, err = pcall(dofile, os.getenv("HOME") .. "/.local/share/cyber/cyber/hypr/keys.lua")
    if not ok then print("cyber keys: " .. tostring(err)) end

    -- Cyber's terminal (Ghostty) draws itself as a HUD panel with cut corners (ghostty/crt.glsl).
    -- Hyprland's shadow follows a window's rectangle and would show in the cut-away parts, so it
    -- is off for the terminal. The blur is Hyprland's own, like for any window: the corners
    -- plugin clips it to the panel's shape for windows tagged "cyberpanel", and draws the focus
    -- markers along the outline.
    do
        local term = { class = "^com\\.mitchellh\\.ghostty$" }
        hl.window_rule({ match = term, tag = "+cyberpanel" })
        hl.window_rule({ match = term, no_shadow = true })
    end
    -- GNOME Files in Cyber's look (gtk/cyber.css) has a folder-shaped outline with cut corners: no
    -- shadow (it follows the rectangle), the blur in the window's own shape (the corners plugin draws
    -- it only where a window tagged "cybershape" paints something) and the focus markers along the
    -- folder outline ("cyberfolder").
    do
        local files = { class = "^org\\.gnome\\.Nautilus$" }
        hl.window_rule({ match = files, tag = "+cybershape" })
        hl.window_rule({ match = files, tag = "+cyberfolder" })
        hl.window_rule({ match = files, no_shadow = true })
    end
end
LUA
)"
put_block "$CUSTOM/execs.lua" "window switcher" \
'hl.on("hyprland.start", function ()
    hl.exec_cmd("rm -rf ~/.cache/hypr-setup/minimized; qs -n -p ~/.local/share/cyber/alttab")
end)'
put_block "$CUSTOM/rules.lua" "window switcher" \
'-- Super+Tab switcher: frosted glass behind its panel (not the transparent rest), no slide-in
hl.layer_rule({ match = { namespace = "alttab" }, blur = true })
hl.layer_rule({ match = { namespace = "alttab" }, ignore_alpha = 0 })
hl.layer_rule({ match = { namespace = "alttab" }, no_anim = true })
-- blur what is really behind it (windows, video), not just the wallpaper
hl.layer_rule({ match = { namespace = "alttab" }, xray = false })'
put_block "$CUSTOM/rules.lua" "cyber" \
'-- Cyber desktop (~/.local/share/cyber/cyber): every HUD panel and popup blurs what is really
-- behind it (windows, the video wallpaper), only where it draws (transparent parts stay clear)
hl.layer_rule({ match = { namespace = "cyber:.*" }, blur = true })
hl.layer_rule({ match = { namespace = "cyber:.*" }, ignore_alpha = 0.02 })
hl.layer_rule({ match = { namespace = "cyber:.*" }, xray = false })
hl.layer_rule({ match = { namespace = "cyber:(launcher|power|polkit|osd|toasts|panel|help|hud|capture|lg|kill|superglow|preview|select|banner|edge|picker)" }, no_anim = true })   -- Cyber glitches them itself
hl.layer_rule({ match = { namespace = "cyber:lg" }, blur = false })   -- the tilted Looking Glass panel: an opaque live picture
hl.layer_rule({ match = { namespace = "cyber:(kill|superglow|wallpaper|select|banner|edge)" }, blur = false })   -- full-screen tints and the wallpaper picture: nothing to frost'
# Opacity and blur strength live in end4-pC's settings (Hyprland page); xray isn't there.
# Performance on a weak GPU (measured on the Radeon 610M at 3440x1440, see docs/NOTES.md "Performance"):
# Hyprland's scheduling mode for underpowered devices keeps frames coming when one takes too long.
put_block "$CUSTOM/general.lua" "performance" \
'hl.config({ render = { new_render_scheduling = true } })'
put_block "$CUSTOM/general.lua" "frosted glass" \
'-- Transparent windows blur the windows behind them, not just the wallpaper (end-4: xray = true)
hl.config({ decoration = { blur = { xray = false } } })'
put_block "$CUSTOM/rules.lua" "frosted glass" \
'-- end-4 turns blur off for every window (hyprland/rules.lua). Turn it back on, but keep it off
-- for XWayland context menus (no class, no title), like end-4 does.
hl.window_rule({ match = { class = ".*" }, no_blur = false })
hl.window_rule({ match = { class = "^()$", title = "^()$" }, no_blur = true })'

# 3. fcitx5 ---------------------------------------------------------------------
# Hyprland (without uwsm) ignores /etc/xdg/autostart, so fcitx5 must be started here.
# GTK_IM_MODULE is deliberately not set: GTK uses the Wayland text-input protocol.
# kitty: an iTerm2-style find bar on Ctrl+F (kitty/find.py) instead of end-4's search.py.
# Appended, so these maps come after end-4's and win. Ctrl+F in full-screen apps (less, vim)
# still goes to the app; Ctrl+Shift+F opens find there too.
put_block "$HOME/.config/kitty/kitty.conf" "find bar" "$(cat <<'CONF'
map ctrl+f      kitten ~/.local/share/cyber/kitty/find.py --alt-screen-key=ctrl+f
map kitty_mod+f kitten ~/.local/share/cyber/kitty/find.py
CONF
)" "#"
# kitty colours per desktop: Cyber has a neon palette (kitty/cyber.conf), end-4/pC keeps its
# wallpaper colours. desktop.sh points the included file at one or the other when you switch.
put_block "$HOME/.config/kitty/kitty.conf" "desktop colours" "$(cat <<'CONF'
dynamic_background_opacity yes
include ~/.local/state/hypr-setup/kitty-desktop.conf
CONF
)" "#"
"$ROOT/desktop.sh" kitty-colours 2>/dev/null || true
pkill -USR1 -x kitty 2>/dev/null || true   # running kittys reload their config

# Cyber: how new windows open. It sits in env.lua because that loads BEFORE end-4's rules.lua, so
# end-4's per-app rules (picture-in-picture in the corner, mixer / file-picker sizes, ...) still win.
put_block "$CUSTOM/env.lua" "cyber windows" "$(cat <<'LUA'
do
    local f = io.open(HOME .. "/.local/state/hypr-setup/desktop")
    local desktop = f and f:read("l") or ""
    if f then f:close() end
    if desktop == "cyber" then
        -- Every window floats, like on macOS / Windows, and opens centred. Super+Space tiles one.
        hl.window_rule({ match = { class = ".*" }, float = true })
        hl.window_rule({ match = { class = ".*" }, center = true })
        -- ...at a comfortable size, for every app: a window asking for less than 75% of the screen
        -- width (at most 1.2x its height) by 72% of its height is enlarged to that. Small windows
        -- (under 480x360: confirmations, pop-ups) and modal dialogs keep their size; apps that
        -- remember a bigger size keep it. Notes: a class pattern must match the WHOLE class name;
        -- the size is plain arithmetic because Hyprland's expression engine mishandles ?: around
        -- two-argument functions (the rule then silently does nothing).
        local big = "(window_w>=480)*(window_h>=360)"
        hl.window_rule({ match = { class = ".*", modal = false },
                         size = "window_w+" .. big .. "*max(0,min(monitor_w*0.75,monitor_h*1.2)-window_w) "
                             .. "window_h+" .. big .. "*max(0,monitor_h*0.72-window_h)" })
        -- The keybinds card (cyber/popups/Help.qml) is a window of the shell itself: it keeps the
        -- size it asks for, has no shadow and no corner markers (it has cut corners and an edge of
        -- its own), and is blurred only where it paints ("cybershape", the corners plugin).
        do
            local keys = { class = "^org\\.quickshell$", title = "^Cyber Keybinds$" }
            hl.window_rule({ match = keys, size = "window_w window_h" })
            hl.window_rule({ match = keys, tag = "+cybershape" })
            hl.window_rule({ match = keys, no_shadow = true })
            hl.window_rule({ match = keys, decorate = false })
        end
    end
end
LUA
)"

put_block "$CUSTOM/env.lua" "fcitx5" \
'hl.env("XMODIFIERS", "@im=fcitx")
hl.env("QT_IM_MODULE", "fcitx")
hl.env("QT_IM_MODULES", "wayland;fcitx")
hl.env("SDL_IM_MODULE", "fcitx")
hl.env("GLFW_IM_MODULE", "ibus")   -- kitty and other GLFW apps'
put_block "$CUSTOM/execs.lua" "fcitx5" \
'hl.on("hyprland.start", function ()
    hl.exec_cmd("fcitx5 -d --replace")
end)'
say "Hyprland custom config updated in $CUSTOM"

# 4. fontconfig: your default sans-serif ----------------------------------------
mkdir -p "$HOME/.config/fontconfig/conf.d"
cat > "$HOME/.config/fontconfig/conf.d/99-local-sans.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<!-- re-created by ~/.local/share/cyber/setup.sh -->
<fontconfig>
  <match target="pattern">
    <test name="family"><string>sans-serif</string></test>
    <!-- strong: otherwise 60-latin.conf's Noto Sans wins over it -->
    <edit name="family" mode="prepend" binding="strong"><string>Yshi-YuanGothic</string></edit>
  </match>
</fontconfig>
EOF
fc-cache -f >/dev/null 2>&1 || true
say "Font rule restored (sans-serif -> $(fc-match -f '%{family[0]}' sans-serif))"

# 5. GTK4 look for GNOME Files on Cyber ------------------------------------------------
# end-4's ~/.config/gtk-4.0/gtk.css is regenerated by matugen from its template whenever the
# wallpaper changes: the import goes into both, so it survives that. What it imports is switched
# per desktop by the "cyber gtk" block above.
for css in "$HOME/.config/gtk-4.0/gtk.css" "$HOME/.config/matugen/templates/gtk-4.0/gtk.css"; do
  [[ -f $css ]] || continue
  grep -qF '@import url("cyber.css");' "$css" || printf '\n@import url("cyber.css");\n' >> "$css"
done
mkdir -p "$HOME/.config/gtk-4.0"
[[ -e $HOME/.config/gtk-4.0/cyber.css || -L $HOME/.config/gtk-4.0/cyber.css ]] || ln -s /dev/null "$HOME/.config/gtk-4.0/cyber.css"
say "GTK4: Cyber's look for GNOME Files is imported (active on Cyber only)"
# The portal that hands GTK apps their settings (icon theme, fonts, dark mode) can start at login
# before it knows the desktop is Hyprland; it then reads the generic portals.conf instead of
# hyprland-portals.conf. That file used to name COSMIC's portal (gone now), which passes no icon
# theme: GTK4 apps asked for a theme that does not exist and Files showed plain outline icons
# (2026-11-25). The generic file now says the same as Hyprland's.
PORTALS="$HOME/.config/xdg-desktop-portal"
if [[ -f $PORTALS/hyprland-portals.conf ]]; then
  cp "$PORTALS/hyprland-portals.conf" "$PORTALS/portals.conf"
  say "Portal preference: the generic fallback matches Hyprland's"
fi

# Files: "Copy Path" in the right-click menu. Directly in the menu it is a Files extension
# (gtk/nautilus/cyber-copy-path.py), which Files only loads with the package nautilus-python
# (extensions are read from a system folder: there is no way without a package). Without it the
# same thing is one level down, under Scripts (Files lists what is in ~/.local/share/nautilus/scripts).
# The extension is linked either way; the Scripts entry only while the package is missing.
mkdir -p "$HOME/.local/share/nautilus/scripts" "$HOME/.local/share/nautilus-python/extensions"
ln -sfn "$STABLE/gtk/nautilus/cyber-copy-path.py" "$HOME/.local/share/nautilus-python/extensions/cyber-copy-path.py"
if pacman -Q nautilus-python >/dev/null 2>&1; then
  [ -L "$HOME/.local/share/nautilus/scripts/Copy path" ] && rm -f "$HOME/.local/share/nautilus/scripts/Copy path"
  say "Files: Copy Path is in the right-click menu"
else
  ln -sfn "$STABLE/gtk/nautilus/Copy path" "$HOME/.local/share/nautilus/scripts/Copy path"
  say "Files: Copy path is in the right-click menu under Scripts (directly in the menu: sudo pacman -S nautilus-python, then nautilus -q)"
fi

# Videos (mpv): a window never larger than 70% of the screen. mpv opens a video at the video's own
# size, and a screen recording is as large as the screen: borderless, it covered everything.
mkdir -p "$HOME/.config/mpv"; touch "$HOME/.config/mpv/mpv.conf"
[ -z "$(tail -c1 "$HOME/.config/mpv/mpv.conf")" ] || echo >> "$HOME/.config/mpv/mpv.conf"      # end the last line first
put_block "$HOME/.config/mpv/mpv.conf" "video window" \
'# A video opened from Files gets a window of the video'"'"'s own size. A screen recording is as large
# as the screen: its window covered everything, without a border, and looked like a locked
# fullscreen (2026-11-26). So: never larger than 70% of the screen.
autofit-larger=70%x70%' "#"

# Quick look: Space on a file in GNOME Files. Files calls the D-Bus service
# org.gnome.NautilusPreviewer; this makes Cyber's (cyber/scripts/previewer.py) the one D-Bus starts.
# A service file in the home folder comes before a system one (GNOME's own previewer, "sushi").
# Two names: Files looks for the first one only once, as its process starts; when nothing answers
# it moves to the ".Devel" name for good. A Files that is open while this runs is in that state,
# and finds the previewer under the second name on the next click, without being closed first.
mkdir -p "$HOME/.local/share/dbus-1/services"
printf '[D-BUS Service]\nName=org.gnome.NautilusPreviewer\nExec=%s/cyber/scripts/previewer.py\n' "$STABLE" \
  > "$HOME/.local/share/dbus-1/services/org.gnome.NautilusPreviewer.service"
printf '[D-BUS Service]\nName=org.gnome.NautilusPreviewer.Devel\nExec=%s/cyber/scripts/previewer.py --devel\n' "$STABLE" \
  > "$HOME/.local/share/dbus-1/services/org.gnome.NautilusPreviewer.Devel.service"
busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig >/dev/null 2>&1 || true
say "Quick look: Space in Files shows Cyber's preview panel"

# 6. GTK font ----------------------------------------------------------------------
gsettings set org.gnome.desktop.interface font-name "$GTK_FONT"
say "GTK font set back to '$GTK_FONT' (override: GTK_FONT='...' $0)"

# 8. kitty: your own shell (zsh + your oh-my-zsh theme) instead of end-4's fish -------
# end-4's kitty.conf says `shell fish`; kitty uses the last value it reads, so this wins.
# "." = your login shell from /etc/passwd. kitty's colours/font stay end-4's.
if [[ -f $HOME/.config/kitty/kitty.conf ]]; then
  put_block "$HOME/.config/kitty/kitty.conf" "login shell" 'shell .' "#"
  say "kitty starts your login shell ($(basename "$(getent passwd "$USER" | cut -d: -f7)"))"
fi

# 8b. Ghostty: Cyber's terminal, with the CRT glow (ghostty/config + crt.glsl + panel.css) -----
# Needs `sudo pacman -S ghostty`. Its own config file only points at the one in this folder.
if command -v ghostty >/dev/null; then
  mkdir -p "$HOME/.config/ghostty"
  G="$HOME/.config/ghostty/config"
  if [[ -f $G ]] && ! grep -q "hypr-setup" "$G"; then mv "$G" "$G.before-hypr-setup"; fi
  printf '# hypr-setup: the real config is in the project folder (edit that one)\nconfig-file = %s/ghostty/config\n' \
    "$STABLE" > "$G"
  say "Ghostty set up: Cyber's terminal (CRT glow)"
else
  say "Ghostty isn't installed: Cyber keeps kitty (for the CRT glow: sudo pacman -S ghostty, then run this again)"
fi

# 6b. Never sleep -----------------------------------------------------------------------
# This PC is a server (VM passthrough) and does not come back from suspend: it hung on
# 2026-11-22 and had to be power-cycled. Drop hypridle's "suspend after 15 min" listener
# and the "screen off after 10 min" one too (the monitor stays on; lock after 5 min stays).
# The system-wide block is
#   sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
IDLE="$HOME/.config/hypr/hypridle.conf"
if [[ -f $IDLE ]] && grep -qE 'on-timeout = (\$suspend_cmd|.*dpms)' "$IDLE"; then
  perl -0pi -e 's/\n*listener \{\n[^}]*on-timeout = \$suspend_cmd\n\}\n?/\n# hypr-setup: no idle suspend (this PC never sleeps)\n/' "$IDLE"
  perl -0pi -e 's/\n*listener \{\n((?!\})[^\n]*\n)*?[^\n]*dpms[^\n]*\n((?!\})[^\n]*\n)*\}\n?/\n# hypr-setup: no idle screen-off (the monitor stays on)\n/' "$IDLE"
  pkill -x hypridle && (setsid -f hypridle >/dev/null 2>&1 </dev/null)
  say "Idle suspend and screen-off removed from hypridle"
fi

# 7. Lock screen ----------------------------------------------------------------------
# Every lock in Hyprland (Super+L, the session menu, idle, before sleep) goes through
# `loginctl lock-session`, which hypridle turns into $lock_cmd. Point it at canvaslock
# (canvasgreet's theme), falling back to hyprlock if canvaslock can't start.
# Opt-in: only when ~/.local/share/hypr-setup/use-canvaslock exists (touch it to enable).
IDLE="$HOME/.config/hypr/hypridle.conf"
FLAG="$HOME/.local/share/hypr-setup/use-canvaslock"
if [[ -f $FLAG ]] && command -v canvaslock >/dev/null && [[ -f $IDLE ]]; then
  if ! grep -q '^\$lock_cmd = canvaslock' "$IDLE"; then
    sed -i 's@^\$lock_cmd = .*@# hypr-setup: lock screen is canvaslock (falls back to hyprlock); the original was:\n# &\n$lock_cmd = canvaslock || hyprlock@' "$IDLE"
  fi
  say "Lock screen: canvaslock (takes effect when hypridle restarts: next login)"
elif [[ -f $IDLE ]] && grep -q '^\$lock_cmd = canvaslock' "$IDLE"; then
  # turned off again: put end-4's original line back
  sed -i -e '/^# hypr-setup: lock screen is canvaslock/{N;s@^[^\n]*\n# \(.*\)@\1@}' -e '/^\$lock_cmd = canvaslock/d' "$IDLE"
  say "Lock screen: end4-pC's own again"
else
  say "Lock screen: end4-pC's own (cyberpunk lock is opt-in: touch $FLAG)"
fi

# 9. Two desktops: end-4/pC and Cyber -------------------------------------------------
# Cyber lives in ~/.local/share/cyber/cyber; link it in like end4-pC (the installer wipes the
# folder). The lock screen asks desktop.sh which desktops exist and switches after unlock.
if [[ -f $HOME/.local/share/cyber/cyber/shell.qml ]]; then
  ln -sfn "$HOME/.local/share/cyber/cyber" "$HOME/.config/quickshell/cyber"
fi
mkdir -p "$HOME/.config/canvasgreet"
ln -sfn "$HOME/.local/share/cyber/desktop.sh" "$HOME/.config/canvasgreet/lock-choices"
say "Desktops: $("$HOME/.local/share/cyber/desktop.sh" status | head -1 | sed 's/  */ /g')"

# 10. Mouse cursor -------------------------------------------------------------------------
# Your own cursor set for the whole session (both desktops, GTK/Qt apps, XWayland, the lock screen):
# the Windows .cur files in assets/cursor/Yellow (or CURSOR_SRC) converted to the Xcursor theme CURSOR_THEME in
# ~/.local/share/icons by cursor/cur2xcursor.py. The .cur files stay where they are. Without the
# folder (and without an already converted theme) end-4's Bibata stays.
CURSOR_SRC="${CURSOR_SRC:-$ROOT/assets/cursor/Yellow}"
CURSOR_THEME="${CURSOR_THEME:-Cyber-Yellow}"
CURSOR_SIZE="${CURSOR_SIZE:-24}"
CURSOR_DIR="$HOME/.local/share/icons/$CURSOR_THEME"
CUR2X="$ROOT/cursor/cur2xcursor.py"
if [[ -d $CURSOR_SRC && ( ! -f $CURSOR_DIR/cursors/left_ptr || $CUR2X -nt $CURSOR_DIR/index.theme ) ]]; then
  python3 "$CUR2X" "$CURSOR_SRC" "$CURSOR_DIR" --name "${CURSOR_THEME//-/ }" >/dev/null || true
fi
if [[ -f $CURSOR_DIR/cursors/left_ptr ]]; then
  gsettings set org.gnome.desktop.interface cursor-theme "$CURSOR_THEME" 2>/dev/null || true
  gsettings set org.gnome.desktop.interface cursor-size "$CURSOR_SIZE" 2>/dev/null || true
  mkdir -p "$HOME/.icons/default"   # what XWayland and older toolkits look up
  printf '[Icon Theme]\nName=Default\nInherits=%s\n' "$CURSOR_THEME" > "$HOME/.icons/default/index.theme"
  put_block "$CUSTOM/env.lua" "cursor" \
"hl.env(\"XCURSOR_THEME\", \"$CURSOR_THEME\")
hl.env(\"XCURSOR_SIZE\", \"$CURSOR_SIZE\")"
  # end-4 sets Bibata at start (hyprland/execs.lua); this runs a moment later and wins
  put_block "$CUSTOM/execs.lua" "cursor" \
"hl.on(\"hyprland.start\", function ()
    hl.exec_cmd(\"sleep 2; hyprctl setcursor $CURSOR_THEME $CURSOR_SIZE\")
end)"
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && hyprctl setcursor "$CURSOR_THEME" "$CURSOR_SIZE" >/dev/null 2>&1 || true
  say "Cursor: $CURSOR_THEME ($CURSOR_SIZE px)"
else
  drop_block "$CUSTOM/env.lua" "cursor"; drop_block "$CUSTOM/execs.lua" "cursor"
  say "Cursor: end-4's (no cursor set in $CURSOR_SRC)"
fi

# 11. What is not installed yet --------------------------------------------------------------
# command or font  ->  package (what it is for). Nothing is installed from here: pacman needs sudo.
missing=()
need() { command -v "$1" >/dev/null || missing+=("$2  ($3)"); }
need qs            "quickshell: comes with end-4's installer" "the Cyber shell itself"
need ghostty       "ghostty" "Cyber's terminal"
need nautilus      "nautilus" "the file manager (Super+E), styled by gtk/cyber.css"
need grim          "grim" "screenshots"
need slurp         "slurp" "screenshots (the plain picker, when the shell's own cannot run)"
need magick        "imagemagick" "cuts a region or window screenshot out of the still picture"
need wf-recorder   "wf-recorder" "screen recordings"
need wl-copy       "wl-clipboard" "screenshots to the clipboard"
need jq            "jq" "scripts"
need cliphist      "cliphist: comes with end-4's installer" "the clipboard picker (Super+V)"
need mpvpaper      "mpvpaper (AUR) + mpv" "the video wallpaper"
need canvaslock    "run: sudo $STABLE/greeter/install.sh install" "the lock and login screen"
need g++           "base-devel" "builds the corner-marker plugin"
fonts=$(fc-list : family 2>/dev/null || true)
grep -qi "ShureTechMono" <<<"$fonts" || missing+=("ttf-sharetech-mono-nerd  (the terminal font)")
grep -qi "JetBrainsMono N" <<<"$fonts" || missing+=("ttf-jetbrains-mono-nerd  (fallback terminal font)")
if ((${#missing[@]})); then
  say "Not installed yet:"; printf '      %s\n' "${missing[@]}"
fi

echo
echo "Done. In Hyprland press Ctrl+Super+R (or log out and in) to reload the shell."
