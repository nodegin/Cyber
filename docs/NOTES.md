# Cyber: working notes

The long version: how each part of the desktop works, what was measured, and the traps that were
found on the way. It grew with the project and is written for whoever maintains it (a person or
Claude). The short version, with pictures and the install steps, is the [README](../README.md).

Cyber is a cyberpunk HUD desktop for Hyprland: a Quickshell shell (top and bottom bands, launcher,
power menu, control panel, capture menu, terminate mode, Looking Glass panel), a CRT-glow terminal,
a Super+Tab switcher, a cursor set, and a matching login and lock screen. It runs on top of
end-4's Hyprland config (illogical-impulse) and keeps end-4/pC as a second desktop you can pick
on the lock screen. Everything it needs is in this repo, assets included.

## Recreate it on a fresh Arch install

```sh
# 1. this repo (anywhere; setup.sh links it to ~/.local/share/cyber, the path all configs use)
git clone <this repo> ~/Desktop/Cyber

# 2. end-4's Hyprland config: interactive, asks for sudo itself (details in "Steps" below)
git clone --recurse-submodules https://github.com/end-4/dots-hyprland ~/.cache/dots-hyprland
cd ~/.cache/dots-hyprland && ./setup install

# 3. packages Cyber adds
sudo pacman -S --needed ghostty ttf-sharetech-mono-nerd ttf-jetbrains-mono-nerd grim slurp \
    wl-clipboard jq mpv base-devel
yay -S mpvpaper                       # the video wallpaper

# 4. everything else: no sudo, safe to repeat; it ends with a list of anything still missing
~/Desktop/Cyber/setup.sh

# 5. login + lock screen
sudo ~/.local/share/cyber/greeter/install.sh install
sudo ~/.local/share/cyber/greeter/install.sh enable     # make it the login screen, then reboot
~/.local/share/cyber/lock-mode.sh cyberpunk             # use it as the lock screen too
```
Log into Hyprland, lock once (Super+L) and pick **Cyber** there, or run
`~/.local/share/cyber/desktop.sh apply cyber`.

## What is where

| folder | |
|---|---|
| `cyber/` | the desktop shell (Quickshell): `shell.qml`, `hud/`, `popups/`, `components/`, `services/`, `shaders/`, settings in `config.json`; `cyber/hypr/` is its Hyprland side (window effects, Looking Glass, keys, the corner-marker plugin) |
| `alttab/` | the Super+Tab window switcher |
| `ghostty/`, `kitty/` | the terminal: panel + CRT shader for Ghostty, colours and find bar for kitty |
| `gtk/` | `cyber.css`: Cyber's look for GNOME Files (Nautilus), loaded only while Cyber is the desktop |
| `cursor/` | converts `assets/cursor/Yellow` into the Xcursor theme `Cyber-Yellow` |
| `webpaper/` | shows a web page as the wallpaper, and renders one into a loop video |
| `greeter/` | canvasgreet: the login screen and lock screen (its `themes/cyberpunk` holds the fonts) |
| `assets/` | cursor files and wallpaper; `assets/README.md` says where each came from |
| `setup.sh` | sets everything up; `desktop.sh` switches desktops; `lock-mode.sh` picks the lock screen; `recover.sh` gets you out of a stuck lock; `backup.sh` / `update.sh` for end-4 updates |

Some names still say `hypr-setup` (the project's old name): the marker lines in
`~/.config/hypr/custom/*.lua`, `~/.local/state/hypr-setup`, `~/.local/share/hypr-setup`,
`~/.cache/hypr-setup`. They are only labels; leave them.

## This machine

The display runs on the AMD iGPU (Radeon 610M); the RTX 5090 is bound to vfio-pci for VMs, so
Hyprland never sees it (no NVIDIA setup needed). Monitor: LG 5K2K on HDMI at 3440x1440@60.
Hyprland's default `preferred, auto, scale 1` matches that. The PC never sleeps (suspend hangs
it): setup.sh removes idle suspend.

## Steps in detail (run in a normal terminal)

**0. Optional safety net:** a btrfs snapshot (`/` is one flat btrfs volume, home included).
```sh
sudo btrfs subvolume snapshot -r / /.snapshot-before-hyprland
#   later, once happy:  sudo btrfs subvolume delete /.snapshot-before-hyprland
```
It holds old data as files change (VM disks especially), so don't keep it for months.
Restoring from it means copying files back, since this layout can't boot a snapshot.

**1. Stop yay from fighting end-4's local meta-packages** (their docs ask for this):
```sh
sudo sed -i 's/^#IgnoreGroup =$/IgnoreGroup = illogical-impulse/' /etc/pacman.conf
grep -n '^IgnoreGroup' /etc/pacman.conf
```

**2. end-4's installer.** It's interactive and shows each command; it runs `pacman -Syu`.
```sh
cd ~/.cache/dots-hyprland && ./setup install
```
Answer **yes** to its backup question. It also adds you to the `video,i2c,input` groups
(external-monitor brightness, virtual keyboard) and enables `bluetooth` and `ydotool`.

**3. Local fixes + end4-pC** (no sudo; safe to re-run):
```sh
~/.local/share/cyber/setup.sh
```

**4. New login screen:**
```sh
sudo ~/.local/share/cyber/greeter/install.sh install
canvasgreet --demo --fullscreen              # look first (password "demo", Ctrl+Q)
sudo ~/.local/share/cyber/greeter/install.sh test  # real greeter on VT 7 (optional)
sudo ~/.local/share/cyber/greeter/install.sh enable && reboot
```
Then pick **Hyprland** in the environment list and log in.

## In Hyprland

| keys | |
|---|---|
| `Super+/` | all keybinds |
| `Super` | launcher (type `<` to search keybinds) |
| `Super+N` → gear, or right-click the desktop | end4-pC settings |
| `Super+Space` | float / tile the window |
| `Super+Tab` | window switcher: hold Super, tap Tab (Shift+Tab back), let go to switch |
| `Super+M` | minimize (Super+Tab or a dock click brings it back) |
| `Super+W` / `Super+E` | Zen / GNOME Files (Nautilus) |
| `Ctrl+Super+T` | wallpaper picker |
| `Ctrl+Super+R` | restart the shell |

Your own Hyprland settings go in `~/.config/hypr/custom/*.lua` (updates never touch
them). To go back to the stock end-4 shell, set `"ii"` in `custom/variables.lua`.
`setup.sh` owns the `hypr-setup:` blocks in those files (apps, keybind changes) and rewrites
them each run, so put your own lines outside the markers, or change them in `setup.sh`.
To remove one of end-4's keybinds: `hl.unbind("SUPER + X")` in `custom/keybinds.lua`.
Window opacity and blur strength: end4-pC settings, Hyprland page. Blur through to the windows
behind ("frosted glass": `blur.xray = false`, and undoing end-4's blur-off rule for all windows)
is set by `setup.sh` in `custom/general.lua` and `custom/rules.lua`.

The Super+Tab switcher is its own small Quickshell program, `alttab/shell.qml` (QML: edit it
and it reloads live). Hyprland starts it at login; `Ctrl+Super+R` restarts it with the shell.
It shows live previews, and a snapshot for minimized windows (Hyprland doesn't draw those).
It wears the look of the desktop that is running (it reads `~/.local/state/hypr-setup/desktop`,
live): end-4/pC's rounded panel in the wallpaper's palette, or on Cyber a HUD panel like the
launcher's: cut corners, a "WIN // SWITCH" title line, the keys along the bottom, square previews,
the app's name and workspace over each title, the selected card in cyan. `alttab/Plate.qml` draws
either background. It is not part of Cyber's shell (it runs under both desktops), so Cyber's
colours and font are repeated in `alttab/shell.qml`. Test: `~/.cache/cyber-dev/alttab/sw.sh`
(both looks, through its IPC).

Typing: every window starts in plain English (`keyboard-us`). `Ctrl+Space` is the only switch:
it turns your input method on/off (hold `Ctrl` and tap `Space` again to pick Rime or Mozc).
Shift and Caps Lock never switch to English: off in fcitx5 (`AltTriggerKeys`), in Rime
(`~/.local/share/fcitx5/rime/default.custom.yaml`) and in Mozc (Mozc Settings, "Shift key mode
switch" = Off). After editing Rime's file: `fcitx5-remote -e`, then
`rime_deployer --build ~/.local/share/fcitx5/rime /usr/share/rime-data ~/.local/share/fcitx5/rime/build`,
then start fcitx5 again (`fcitx5 -d`).

## Two desktops in Hyprland: end-4/pC and Cyber
Hyprland can run either of two desktops (both Quickshell programs):
- **end-4/pC**: end-4's illogical-impulse with the end4-pC shell.
- **Cyber**: your own cyberpunk HUD desktop, `~/.local/share/cyber/cyber/` (QML; it reloads
  live when you edit it). Top band: workspace, uptime, CPU/RAM, workspace rail with the active
  window, clock, network. Bottom band: quick buttons, now playing, tray, launcher. It also
  does what pC does in the background: notifications, tray, admin password prompts, volume popup, wallpaper.

**Switching:** lock the screen (Super+L), pick **end-4/pC** or **Cyber** with ↑/↓ on the right,
unlock. Or from a terminal: `~/.local/share/cyber/desktop.sh apply cyber` / `apply end4-pC`
(`desktop.sh status` shows which). Cyber's power menu also has "end-4/pC". The choice is kept
for the next login (the login screen still shows one "Hyprland").

**Same keys in both.** In Cyber: Super = launcher, Super+N = control panel (toggles, volume,
media, notification inbox), Super+/ = all keybinds, Ctrl+Alt+Del = power menu, Super+J = hide
the bands, Super+Tab = switcher, Super+Shift+S/X = snip/OCR, Super+V clipboard, Super+. emoji.
PrintScrn (and the camera button) opens Cyber's capture HUD: a SCREENSHOT or a RECORDING (Tab or
←/→ switches) of a REGION / WINDOW / SCREEN (R/W/S, or PrintScrn again for the whole screen).
The HUD sits in the top-right corner, as far from the edges as the Looking Glass panel is on the
left, and is drawn as that panel's mirror image: swung back on its right edge, so its left side
recedes, and bent (`capture.tilt` in `cyber/config.json`: 0 = flat, 1 = as far as the Looking Glass
panel, default 0.4 because the menu is small text; below 0 = turned the other way; the bend is
`lookingGlass.curve`). It is drawn 1.1 times the size of the shell's other dialogs, so its text
can be read on a large screen (`capture.scale`, 0.8 to 2). Both use `cyber/shaders/curve.vert`
(`flip` = 1 is the mirror image). The mouse works on what is drawn: `popups/Capture.qml` takes the pointer back onto the flat dialog
with the shader's inverse, so the two must be changed together.
**A changed shader needs a new shell process.** A compiled shader (`.qsb`) is read once per
process: saving one reloads the QML but the picture stays the old shader's until the shell is
restarted (Ctrl+Super+R). Tests in a fresh process show the new one, the running desktop does not.
**Colours:** yellow is a screenshot, red is a recording: the HUD's switch and its selected row,
the picker's outline and size, and the banner.
**Picking a region or a window** is the shell's own picker (`cyber/popups/Select.qml`): the screen
is dimmed, what you drag (or the window under the pointer) stays clear inside an outline with
corner brackets, its size in pixels is shown under it and where it starts above it. Esc or the
right mouse button cancels; a drag of a few pixels is ignored. For a screenshot the screen
is photographed first and you pick on that still picture, so what you framed is what is saved
even if the screen moved on; for a recording the live screen shows through.
**A recording is announced** by the status banner in the top-right corner, where the capture HUD
was a moment before (12 px from the edge, under the top band): a blinking warning
triangle, a tab, and a panel that slides out of it with "RECORDING STARTED"
(`cyber/popups/Banner.qml`; the look is `components/HudBanner.qml`). Its shape, red (`Theme.alert`)
and motion follow the banner of another shell that was picked as the model, measured from a
video of it and drawn here from scratch; the typeface is Rajdhani Bold (open licence, in the fonts
folder). The picker's hint ("SELECT A REGION TO CAPTURE") is the same banner in the same corner.
The banner is never in the video: when what is recorded does not reach the banner's corner the
recorder starts at once, otherwise (and for the whole screen) as the banner leaves the screen
(1.9 s, `bannerMs` in `cyber/services/Grab.qml`). `services/Grab.qml` is the one place that runs
a capture: the HUD, Super+Shift+R and `qs -c cyber ipc call cyber shot|record region|window|screen`
all go through it; `qs -c cyber ipc call cyber banner "TEXT"` shows the banner from a script.
The scripts take what was picked (`capture.sh crop "X,Y WxH" PICTURE`, `record.sh geometry
"X,Y WxH"`); their old `region` / `window` modes (slurp) still work by hand.
A screenshot goes to ~/Pictures/Screenshots and the clipboard (`cyber/scripts/capture.sh`).
A recording runs until PrintScrn or the camera button is pressed again (the button is a red stop
sign with the time meanwhile); the video goes to ~/Videos/Recordings and its path to the
clipboard (`cyber/scripts/record.sh`: wf-recorder with the GPU's encoder, no sound, no B-frames
so that it also seeks in a browser that only has the OpenH264 fallback decoder).
Super+Shift+R starts and stops a region recording directly. Ctrl+PrintScrn and end-4/pC keep
end-4's.
The record button starts/stops a full-screen recording with sound and turns red while recording.
end-4-only panels (AI sidebar, widget overlay...) simply aren't there in Cyber.

**Wallpaper:** `cyber/config.json` → `wallpaper`. The first of these that is set and works:
- `web`: a live web page (a Wallpaper Engine "web" wallpaper folder) shown by `webpaper/webpaper.py`.
  Heavy on this GPU; `webFps` and `webScale` limit it.
- `video`: a looping video via `mpvpaper` (no sound, paused while hidden). The default is
  `assets/wallpaper/rainy-city.mp4`, a seamless 20 s loop (15 fps) rendered from the web wallpaper in
  `assets/wallpaper/rainy-city` at full resolution. Render another one with
  `webpaper/render-video.sh FOLDER OUT.mp4 [SECONDS] [FPS]` (a few minutes, nothing shows on screen).
- `image`: used whenever the others can't run, and while they start.
Needs `yay -S mpvpaper` for video; the web page needs `gtk4-layer-shell` and `webkitgtk-6.0` (they
come with the lock screen).

**Look:** while Cyber runs it sets sharp corners, no window borders and a lighter (~4 px) blur;
every HUD panel blurs what's really behind it. The focused window gets cyan corner brackets
┌ ┐ └ ┘, drawn by a small Hyprland plugin (`cyber/hypr/corners/`) so they move with the window.
Hyprland loads it only on Cyber. After a Hyprland update it rebuilds itself on the next login
(or run `cyber/hypr/corners/build.sh reload`). Tune it live, e.g.
`hyprctl eval 'hl.config({ plugin = { cybercorners = { length = 24, thickness = 2, gap = 3 } } })'`.

**Drag and drop (a Hyprland 0.57 workaround in the same plugin, `cyber/hypr/corners/dndfix.cpp`).**
Hyprland 0.57 does not answer a drop target that says what it can do with the data
(`wl_data_offer.set_actions`), and after a drop it gives no window the pointer until the target
reports that it is finished. COSMIC apps need that answer: in COSMIC Files a dragged file was not
moved, and after letting go no window could be clicked any more. The plugin sends the answer
(chosen as Hyprland's main branch does), and calls a drop off if the target has not started to
read it after 1.5 s, so the pointer always comes back. Only on Cyber (the plugin is not loaded on
end-4/pC). `hyprctl eval 'hl.config({ plugin = { cybercorners = { dnd_fix = 0 } } })'` turns it
off; delete `dndfix.cpp` (and its three calls in `corners.cpp`, and its name in `build.sh`) once a
Hyprland release answers `set_actions` itself.

**Pickers (`cyber/popups/Picker.qml`):** Super+. is emoji, Super+V the clipboard history. What is
chosen goes straight into the window that was being typed in: the picker closes, 170 ms later that
window has the keyboard back, and an emoji is typed there (`wtype`), a clipboard entry is made the
clipboard's content and pasted (Ctrl+V; Ctrl+Shift+V when the window is a terminal, by its class).
- **Emoji:** a grid by category, like a phone's emoji keyboard: no names, a row of category tabs,
  the ones used last on top (`~/.local/state/hypr-setup/emoji-recent`). Typing searches by name;
  arrows move, Tab is the next category, Enter or a click inserts. The list is the data part of
  end-4's `~/.config/hypr/hyprland/scripts/fuzzel-emoji.sh`, which is in Unicode's order: the
  categories are cut from it at nine known emoji (`groups` in the file).
- **Clipboard:** a list, newest first (`cliphist list`, kept by the wl-paste watchers end-4's config
  starts; pictures show as "14 KIB PNG 1280X720"); typing filters.
- A pointer that is standing still does not choose: rows that land under it as the list changes get
  hover events too, which took the selection away from the keyboard (`moved()` in the file).
- Before 2026-11-26 both keys opened `fuzzel`, a foreign-looking box that could not be used on the
  live desktop (it worked with a virtual keyboard in the hidden session; why it failed live was
  not found). The first replacement was a list with names that only copied: asked to be a grid
  that inserts.
**Super+Shift+S** is the capture menu's region screenshot (`Grab.start(false, "region")`), the
counterpart of Super+Shift+R; it used to run `hyprshot`. Nothing calls hyprshot any more (the
fallback bind for when no shell runs is `cyber/scripts/capture.sh region`, written by `setup.sh`),
so the package can go: `sudo pacman -Rdd hyprshot` (end-4's installer lists it as a dependency and
may bring it back).

**Things that show nothing by themselves get the banner** (`cyber/popups/Banner.qml`, from
Hyprland's events): pinning a window (Super+P, "WINDOW PINNED TO EVERY WORKSPACE" / "WINDOW
UNPINNED", magenta) and sending a window to another workspace without going there (Super+Alt+1 …
0, "WINDOW SENT TO WORKSPACE 02"). A pinned window also keeps its corner brackets, in magenta,
focused or not (the plugin, `pin_color`).

**Keybinds card (Super+/, or the `?` button after APPS; `cyber/popups/Help.qml`):** a normal window
(Quickshell's `FloatingWindow`, title "Cyber Keybinds"), not an overlay: drag it by any part
(`startSystemMove`) or with Super + drag, leave it open while trying keys; Esc, its × or Super+/
close it. Inside, Cyber's HUD dialog frame with the model card's layout: a "// prefix" line, two
columns of single keys (`components/KeyCap.qml`: one letter size, caps as wide as their text, the
model's cut cap with a grey-blue edge), then the longer combinations as a list. The lists are
written by hand in `Help.qml`: keep them in step with the binds. Hyprland rules for the window are
in the "cyber windows" block of `setup.sh`: it keeps its own size (the 75% rule would enlarge it),
no shadow, no corner markers, blur only where it paints.

**Terminate mode (Super+Q, `cyber/popups/Eliminate.qml`)** shows the status banner ("LOCK ON TARGET TO
TERMINATE", top right, red), flight guides across the middle of the screen (a horizon line with a
dip, a centre line with markers, two lines from the upper corners, a bracket with a reading on
either side; very faint, a tenth) and a reticle on the pointer: three spokes that stand still and,
inside them, a small six-sided outline with three openings that slowly turns (always the same
size, and clear of the spokes); the hairlines across the screen run up to it. Guides and reticle follow another shell's kill mode that was
picked as the model: measured from a video of it and drawn here from scratch.

**Videos open in a window, not over everything.** mpv opens a video at the video's own size; a
screen recording is as large as the screen, and without window borders that looked like a locked
fullscreen (2026-11-26). `setup.sh` puts `autofit-larger=70%x70%` into `~/.config/mpv/mpv.conf`.
In mpv: `q` quits, `f` is fullscreen, the number keys change contrast, brightness and gamma (the
"gamma" message on screen is mpv's).

**Buttons that need hardware** (bottom left): Bluetooth only shows with a Bluetooth adapter, the
Looking Glass button only where `looking-glass-client` is installed (`cyber/services/Has.qml`).

**A dragged window comes along to another workspace (the same plugin, `cyber/hypr/corners/dragws.cpp`).**
Hyprland 0.57 leaves a window behind when the workspace changes while you drag it. Here, while a
window is held with Super + left button (or by its title bar):
- **Screen edges:** keep the pointer on the left or right edge for a second and the previous / next
  workspace comes up with the window still on the pointer; another second, the one after. The edge
  shows it (`cyber/hud/EdgeSwitch.qml`, in yellow so it stands out from the cyan around it: a
  strip of light, a bar that grows from the pointer's height until it fills the whole height of
  the screen as the second runs out, chevrons, the workspace's number). Workspaces go in tens:
  no step past the ends of the ten.
- **Workspace keys:** press 1 .. 0 (Super is already held) or change workspace any other way, and
  the window is on that workspace, where it was under the pointer, and the drag goes on.
- How: when the active workspace changes during a move drag the plugin moves the window there.
  Hyprland ends the drag at that key press and again when the key is let go, so from then until
  the button is released the plugin begins the drag again each time (after key events, at pointer
  movements). The edge is counted in the plugin, which posts `cyberdragedge` events for the picture.
  A drag is only begun again on the workspace that is shown: beginning one on a window of
  another workspace brings that workspace back up, which made every workspace key after the first
  bounce (found 2026-11-26 with the pointer moving and several keys in one drag).
- `hyprctl eval 'hl.config({ plugin = { cybercorners = { drag_ws = 0 } } })'` turns it off,
  `drag_ws_delay = 1000` is the wait at an edge in milliseconds (200 to 5000), and
  `drag_ws_log = 1` writes what happens during a drag to `$XDG_RUNTIME_DIR/cyber-dragws.log`
  (one line per key, workspace change and carry: the place to look when a window stays behind).
- Tested in a hidden session with a virtual mouse and keyboard (`~/.cache/cyber-dev/drag/exp4.sh`,
  `exp5.sh`): the whole drag has to be one pointer sequence, and the test config needs
  `input.resolve_binds_by_sym = true` for the virtual keyboard's keys to reach the binds.

**Windows float** on Cyber, like macOS/Windows: new windows open free and centred. Move with
Super+drag, resize from the edges; `Super+Space` puts one into the tiling layout. Every app opens
at a comfortable size (at least 75% of the width, capped at 1.2× the height, by 72% of the height); small windows
(under 480×360) and modal dialogs keep their own size, and end-4's per-app rules (picture-in-picture,
mixer, file pickers) still apply. The rules are in `custom/env.lua` ("cyber windows").

**Motion:** two glitches with the same look, in two places:
- **Cyber's own menus** (launcher, power menu, control panel, …) tear in and out with a GPU shader
  inside Cyber: `cyber/shaders/glitch.frag`. After editing it:
  `/usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o glitch.frag.qsb glitch.frag`,
  then restart Cyber (Ctrl+Super+R): Quickshell keeps the old compiled shader until then.
- **Windows opening/closing and workspace changes** are glitched by Hyprland itself:
  `cyber/hypr/glitch.lua` runs on Hyprland's own window events and switches on
  `cyber/shaders/screen-glitch.glsl` as the screen shader for a fraction of a second, limited to
  the window's rectangle. It works on the finished frame, so it is always in step with
  Hyprland's own pop-in/fade. (An overlay drawn by another program can't be: that was tried.)
  On close, the glitch goes on the windows that grow into the freed space, at their final size
  (a glitch left on the closed window's old rectangle would lie across half of a bigger window).
  Screenshots and recordings don't show this glitch: they are taken before the screen shader.
  After editing either file: `hyprctl reload`. Errors go to `~/.cache/hypr-setup/glitch.log`.
Each glitch is a short stutter (0.2–0.3 s). Turn any of it off in `cyber/config.json` → `effects`
(`menus`, `windows`, `workspace`), and set how strong all of it is with `intensity`
(0–1, default 0.55); it applies at once.

Preview Cyber without switching: `CYBER_PREVIEW=1 qs -p ~/.local/share/cyber/cyber`
(Ctrl+C to stop). Logs: `qs log -c cyber`. Switch log: `~/.cache/hypr-setup/desktop.log`.

**Files:** Super+E opens **GNOME Files (Nautilus)** with Cyber's look (`gtk/cyber.css`): the window
is shaped like a folder (the glass sidebar is its tab, with the terminal's cut corner; the
near-solid file pane sits 14 px lower behind a slope and has the terminal's long cut bottom
right), the HUD's cool-grey edge, cyan for what is selected, the terminal's typeface for paths
and column titles, GNOME's own folder icons (Adwaita) pulled towards cyan.
- **The shape:** GTK cannot clip a window to a shape, so each pane's glass is a gradient that is
  see-through where the shape ends, and the edge is a small picture used as a border image
  (`gtk/cyber/frame-side.svg`, `frame-main.svg`, rendered with `rsvg-convert X.svg -o X.png`).
  The plugin blurs only where the window itself paints something: window rules tag Files
  `cybershape` (the plugin masks the blur with the window's own picture; any see-through window
  can have that tag), `cyberfolder` (the focus markers follow the folder outline; the numbers
  `FOLDER_CUT` / `DROP` / `BIG` in `corners.cpp` match the stylesheet) and turn its shadow off.
- **The file pane** is the terminal's glass: see-through, dimmed, teal at the top left into navy,
  raster lines.
- **Icons:** on Cyber, Hyprland's config sets the GTK icon theme to Adwaita (end-4/pC: back to
  Breeze), in the same "cyber gtk" block that switches the stylesheet.
- **How it loads:** GTK4 reads one user stylesheet, `~/.config/gtk-4.0/gtk.css`, which is end-4's
  (matugen regenerates it from the wallpaper). `setup.sh` appends `@import url("cyber.css");` to
  it and to matugen's template, and Hyprland's config (block "cyber gtk" in
  `~/.config/hypr/custom/variables.lua`) points `~/.config/gtk-4.0/cyber.css` at `gtk/cyber.css`
  on Cyber and at `/dev/null` on end-4/pC. Apps read it when they start.
- **Scope:** the rules hang on `window.view` (only Nautilus's main window carries that class) and
  on Nautilus's own `.nautilus-…` classes; its dialogs (Properties, …) and other GTK4 apps keep
  end-4's look. Ghostty is not affected (checked).
- **Changing it:** edit `gtk/cyber.css`, open a new Files window. Things GTK gets wrong and the
  file works around: `letter-spacing` and `text-transform` on the sidebar title cut it off.

**Copy Path:** right-click a file, several, or the empty part of a folder > Copy Path puts the full
path(s) on the clipboard. Directly in the menu it is a Files extension
(`gtk/nautilus/cyber-copy-path.py`, linked into `~/.local/share/nautilus-python/extensions/`), and
Files only loads extensions through the package `nautilus-python` (`sudo pacman -S
nautilus-python`, then `nautilus -q`): they are read from a system folder, there is no way in
without a package. Without it the same thing is under Scripts > Copy path
(`gtk/nautilus/Copy path`, linked into `~/.local/share/nautilus/scripts/`); once the extension runs
it removes that link, so there is one entry. Tested without installing: the verified package
unpacked to a scratch folder and bound over the extension folder for one hidden Files
(`~/.cache/cyber-dev/cp/cp2.sh`, bwrap).
**After removing a file manager, look for its daemon:** `dolphin --daemon` kept running from its
deleted binary for days and still held the session's file-manager service
(`org.freedesktop.FileManager1`), so "show this file" requests (Alt+click on a path in the
terminal) ended in "Could not find the program 'dolphin'" (2026-11-26). `busctl --user list |
grep FileManager1` shows who holds it; kill the leftover and Files takes over.

**Quick look:** Space on a file in Files shows it as a HUD panel over the desktop
(`cyber/popups/QuickLook.qml`): pictures, videos and sound, text with JSON re-indented (the first
300 kB), a PDF's first page, and for anything else what it is. Space again closes it, the arrow
keys in Files flip to the next file, a click closes it too.
- **Videos and sound** show their first frame and start half a second later (`startDelay` in
  `QuickLook.qml`), so flipping through a folder stays quiet. Under the picture: a play / pause
  button, the time, a seek bar (click or drag it; the time under the pointer shows above it) and
  the length; below that the size, frame rate and codecs. The wheel steps 5 s per notch, a click
  on the picture pauses. Seeking is by mouse only: the keyboard stays with Files.
- **How:** Files previews nothing itself; on Space it calls the D-Bus service
  `org.gnome.NautilusPreviewer`. `setup.sh` registers Cyber's own for that name
  (`~/.local/share/dbus-1/services/`, `cyber/scripts/previewer.py`), which only works out what
  the file is and writes it to `$XDG_RUNTIME_DIR/cyber-preview.$WAYLAND_DISPLAY`; the shell
  watches that file (`cyber/services/Preview.qml`). The panel never takes the keyboard, which is
  why Space and the arrows keep working in Files. Videos go through Qt's FFmpeg backend, so
  nothing extra needs installing. On end-4/pC (no Cyber shell) Space does nothing.
- Files 51 calls `ShowFile` with four arguments (the last an activation token); a previewer
  that declares three is never reached.
- Files looks for the previewer once, as its process starts. When nothing answers it switches to
  a second name (`org.gnome.NautilusPreviewer.Devel`) and stays on it, so a Files that was open
  before the previewer was installed ignored Space until it was closed. `setup.sh` therefore
  registers both names (the second starts `previewer.py --devel`): such a Files recovers on the
  next click on a file.

**Looking Glass (the Windows VM):** a fixture of the desktop, not a window on top of your work.
- **Starting and stopping:** the monitor button in the bottom bar, next to the camera, starts
  `looking-glass-client` as a user service (`cyber-looking-glass`), so it survives Cyber reloading.
  Click it again to stop it. The button is lit while a client runs, so a crash or closing the window
  turns it off. It shows `VM OFF` when the libvirt domain (`cyber/config.json` → `lookingGlass.vm`,
  default `win11`) isn't running; Cyber never starts or stops VMs.
- **Placement:** top-left, a third of the screen wide, on whichever workspace you are looking at.
- **Idle:** it is the bottom window (every other window is above it, tiled ones too) and shows as a
  live, tilted 3D panel (`cyber/hud/LookingGlassPanel.qml`), bent a little like a wrap-around
  display. How much: `lookingGlass.curve` in `cyber/config.json` (default 0.09: the middle lies
  9% of the panel's width behind its edges; 0 = a flat sheet, below 0 it bulges instead). The
  bend is a vertex shader, `cyber/shaders/curve.vert` (compile it and `curve.frag` like
  `glitch.frag` above). A window lying over it keeps the pointer: the idle window lets it through.
- **Forward** (flat, above the other windows, the real window):
  - point at the part of the tilted picture you can see: until the pointer leaves it;
  - pick it in the Super+Tab switcher, or open it while other windows lie over its spot: until
    another window gets the focus (or the pointer has been on it and left).
  Pointing at a window that lies over its spot does not bring it forward.
- **Fullscreen:** Super+F, like any window.
- **How it works:** the real window never moves. Hyprland only produces frames for windows it draws,
  so a hidden or off-screen window would freeze the picture. Instead, Cyber makes it invisible with
  the tag `cybertilt` while the tilted copy stands in for it. Hyprland decides engaged or idle
  (`cyber/hypr/lookingglass.lua` watches the pointer) and tells Cyber; Cyber plays the swing and sets
  the tag. If Cyber's panel isn't there, Hyprland takes the tag off, so the window can't stay hidden.
- **Errors** go to `~/.cache/hypr-setup/lookingglass.log`.

**Eliminate mode (Super+Q):** the screen goes dark red with a damaged-signal edge and the pointer
becomes a crosshair. The window under it gets target brackets and its name. Click (or Super+Q, Q or
Enter again) to close it; Esc or right-click aborts (`cyber/popups/Eliminate.qml`).

**Hold Super:** after a moment the screen's edges glow cyan, the same effect in a calmer form
(`cyber/hud/SuperGlow.qml`). Both use one shader, `cyber/shaders/damage.frag`; after editing it:
`/usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o damage.frag.qsb damage.frag`,
then restart Cyber. `cyber/hypr/keys.lua` binds Super+Q and makes sure the glow can't stick.

**Screenshot dialog (PrintScrn):** a HUD dialog in the middle of the screen, not a full-screen
menu: `cyber/components/HudDialog.qml` is the reusable frame (the panel outline and glass
described under Terminal below).

**Terminal:** on Cyber, Super+Return / Super+T open **Ghostty** drawn as a HUD panel with a CRT
tube look (`ghostty/config` + the shader `ghostty/crt.glsl`). end-4/pC keeps kitty; kitty has no
shader stage, so it can only do the colours.
- **The panel:** the same outline and glass as Cyber's HUD dialogs: cut top-left corner, small round
  top-right, the right edge stepping inwards part-way down, a long cut bottom-right; a teal glow in
  the top-left falling off to navy; a grey-blue edge. Focused, only the background gradient is see-through
  (80%, `GLASS` in the shader) with the content behind blurred; text and edge stay solid.
  Unfocused, the whole window fades like every other window (Hyprland's `inactive_opacity`, 75%),
  text included.
- **Stars and asterisks** (U+2720-274B, the working indicator of Claude Code) come from one font,
  Adwaita Mono (`font-codepoint-map` in `ghostty/config`): the terminal's own font has none, and
  each came from a different fallback, one of them an emoji font.
- **The tube:** phosphor text that bleeds a little light, dark raster lines (one pixel row in three,
  on the text, the glass and what shows through it: `RASTER…` at the top of `crt.glsl`, 0 turns
  them off), a faint shadow mask on lit text (`MASK`), static, and now and then a thin band of rows
  twitches sideways by a pixel (`JITTER`; only on frames the terminal draws anyway, so it is free).
- **The scan band** drifting down the focused terminal is drawn by the Hyprland plugin, not by the
  shader. It is a ramp: see-through at its top, brightest at its lower edge, where it ends.
  `hyprctl eval 'hl.config({ plugin = { cybercorners = { scan_band = 10, scan_period = 7 } } })'`
  (brightness at the lower edge in percent, 0 = none; seconds from top to bottom). In the shader it would need the
  whole terminal redrawn on every refresh, about a third of this GPU; the plugin redraws only the
  band's rows, about 5%.
- **Three files share the outline's numbers** and must stay in step: `ghostty/crt.glsl` (draws the
  panel), `cyber/components/HudDialog.qml` (the dialogs), `cyber/hypr/corners/corners.cpp` (the
  plugin: the blur behind the glass in the panel's shape, and the cyan focus markers, a `/` outside
  the two cuts and brackets on the other corners). Hyprland's own blur and shadow follow a
  window's rectangle and would show in the cut-away parts, so a rule turns both off for the
  terminal and tags it `cyberpanel` for the plugin (the "cyber desktop" block).
- **`ghostty/panel.css`** makes the GTK window behind the terminal paint nothing. end-4's GTK theme
  (`~/.config/gtk-4.0/gtk.css`, regenerated from the wallpaper) gives every GTK window a solid
  background; without this file that shows as a dark slab behind the glass and black in the
  cut-away corners.
- **Tuning:** the numbers at the top of `ghostty/crt.glsl` (`GLASS`, `GLOW`, `RASTER`, ...); reload
  in Ghostty with Ctrl+Shift+, (or `pkill -USR2 -x ghostty`). Font size and colours are in
  `ghostty/config`.
- **Font:** Share Tech Mono (`sudo pacman -S ttf-sharetech-mono-nerd`) at 15: thin and angular,
  and the glow fattens letters, so `SMEAR` in the shader is low. Without the package, switch to
  the commented JetBrains Mono Light lines in `ghostty/config`.
- **Why the blur is the plugin's:** Hyprland can limit its own window blur to where a window is
  drawn (`render:use_shader_blur_blend` + `decoration:blur:proportional`), but then the blur
  strength follows the opacity: behind an 80% see-through background it is so weak that the text
  behind stays readable (tested 2026-11-23). The plugin's shaped blur is full strength.
- **Cost:** it is a still picture; the shader runs only when the terminal redraws (measured: 1.4% of
  this PC's integrated GPU). Flicker and a rolling band exist behind `MOVING` in the shader plus
  `custom-shader-animation = true`, but one focused terminal then redraws every frame: 47%.
- **Keys:** Ctrl+F (or Ctrl+Shift+F) opens Ghostty's search; Ctrl+C copies when text is selected.
- **Tabs:** Ctrl+T opens one, Ctrl+W closes the one you are on (Ghostty's Ctrl+Shift+T / W still
  work), Ctrl+Tab and Alt+1 … 9 switch. Ctrl+W and Ctrl+T therefore no longer reach the shell
  (delete a word: Alt+Backspace), and with `confirm-close-surface = false` Ctrl+W closes a tab
  without asking, whatever runs in it. The bar shows with two or more tabs and is styled in
  `ghostty/panel.css`: it takes no room of its own (a negative margin of its own height, 26 px) and
  lies over the terminal's top margin (`window-padding-y = 32,18`), see-through, drawing only the
  tabs: HUD segments that share the width, from the right of the cut corner. Every size and colour
  a theme could set on the tab bar's parts is set in that file: end-4's GTK theme pads and colours
  tabs, which first made the bar taller than its margin (the tabs sat across the panel's top edge)
  and the titles pink. Test tab looks with that theme loaded (`tabs.sh` copies `~/.config/gtk-4.0`). So the terminal fills the window with or
  without tabs and the panel's outline stays the shader's and the plugin's. (A bar with room of
  its own puts a rectangle above the panel: the cut corner then sits under it, and the plugin's
  outline, which is the window's, no longer matches the shader's, which is the terminal's.)
  Test: `~/.cache/cyber-dev/term/tabs.sh` (its own config folder and D-Bus: it cannot join the
  running Ghostty).
- **No progress line:** `progress-style = false`. Programs can ask for a progress bar along the top
  of the window (OSC 9;4; Claude Code does while it works): it showed as a coloured line moving
  across the panel's top edge.
- **Reloading:** `kill -USR2 $(pgrep -x ghostty)` (or Ctrl+Shift+,) reloads the config in place,
  sessions stay; a changed `window-padding` only applies to terminals opened afterwards.
- **Needs** `sudo pacman -S ghostty`; without it Cyber keeps kitty.
- **After changing the plugin:** `cyber/hypr/corners/build.sh force`, then
  `hyprctl plugin unload <path>/cybercorners.so` and `hyprctl plugin load <path>/cybercorners.so`
  (a plain `hyprctl reload` does not reload a plugin whose path is unchanged).
- **kitty on Cyber** still gets the neon palette (`kitty/cyber.conf`); `desktop.sh` switches a
  small include file (`~/.local/state/hypr-setup/kitty-desktop.conf`) when you change desktop.

## Performance

The host draws on a weak GPU (Radeon 610M, 3440x1440), and Cyber asks a lot of it: every
see-through window shows what is behind it blurred, in real time. Where the time went, and what
was done (measurements: this machine, same look before and after):

| what | before | after | how |
|---|---|---|---|
| live web wallpaper | 47% of the GPU | 6% | rendered once into a seamless loop video (`webpaper/render-video.sh`), played by mpvpaper with hardware decoding |
| blur behind see-through windows | 9 to 13 ms per redraw | 3.5 to 6 ms | the corners plugin does it (below) |
| blur of hidden things | about 30% | 0 | no blur for windows that are covered, each window clipped to the part not behind an opaque one |
| terminal glow shader | 19 to 25% | 9 to 12% | 9 bloom samples instead of 25 |
| Looking Glass preview, VM picture still | 33 full-screen redraws a second | 0 | a preview frame is fetched only when the VM window drew something new |
| Looking Glass preview, VM picture moving, under tiled windows | 44% | 19% | the same, plus the two rows above |
| locked screen | compositor 68%, lock screen 39 fps | 13%, 60 fps | Hyprland no longer draws the desktop under the (opaque) lock screen |

**Grain in the blur:** Cyber sets `decoration.blur.noise` to 0.0117 (Hyprland's default;
`effects.blurNoise` in `cyber/config.json`, applied by `services/Look.qml`). end-4's config has
0.05, which suits its strong blur (size 10, 3 passes); behind Cyber's light blur that grain read
as picture noise, plainest with a bright page behind a glass window (2026-11-26). The plugin adds
the grain per screen pixel when it draws a backdrop, from the same setting. Measured as the std
dev between neighbouring pixels of a glass surface: 0.96 levels at 0.05, 0.33 at 0.0117, 0.04 at
0 (`~/.cache/cyber-dev/blur/blur.sh`).

**The blur** (corners plugin, `cyber/hypr/corners`, since 3.0). Hyprland blurs at full resolution and
again whenever anything in a see-through window's area is redrawn, also when only the window's own
text changed: about 3.7 ms per megapixel each time on this GPU. The plugin does it the way phone
systems do:
- what is behind the window is shrunk to a quarter of its size, blurred there (1/16 of the pixels)
  and stretched back, with Hyprland's own formulas for contrast, vibrancy and grain. Side by side
  with Hyprland's blur at the same `size` / `passes` the difference is 0.1% of full range.
- the blurred picture is kept per window and brought up to date only where something behind the
  window really changed: a video in one corner behind a big window redoes that corner. The
  window's own redraws reuse it, and Hyprland then skips drawing what is behind the window.
- It covers every see-through window, tiled or floating. Hyprland's shared blur for tiled windows
  (`blur:new_optimizations`) is switched off on Cyber (`cyber/services/Look.qml`): left on, it
  redraws the whole screen whenever anything on the desktop level changes.
- Settings: `hyprctl eval 'hl.config({ plugin = { cybercorners = { backdrop_fps = 0 } } })'`
  hands the blur back to Hyprland (0 = off, default 60 = whenever something changed);
  `backdrop_spread` is the blur width (52 = Hyprland's look). Put a line in
  `~/.config/hypr/custom/general.lua` to keep it.
- What it is doing: `touch $XDG_RUNTIME_DIR/cyber-corners-dump`, then read
  `$XDG_RUNTIME_DIR/cyber-corners-info` a second later.

**Unchanged areas are copied, not redrawn** (plugin 3.7). The screen has three buffers that take
turns, and Hyprland redraws in each frame everything that changed since that buffer was last
used: every change is composited up to three times, and a wallpaper moving 15 times a second
turns about 45 of 60 frames into full-screen redraws whenever anything else moves too. The plugin
copies what did not change since the previous frame straight from the previous buffer and leaves
Hyprland only what really changed (same picture, bit for bit; checked by reading the output
buffer back, `~/.cache/cyber-dev/reusetest.sh`). It steps aside for zoom, a screen shader, a
rotated screen, screen captures and forced full frames.
`hyprctl eval 'hl.config({ plugin = { cybercorners = { reuse_frames = 0 } } })'` turns it off.

**FPS in the HUD** (top left) is the number of the screen's refreshes that were served on time in
the last second: 60 on a 60 Hz screen means no frame came late; every refresh a frame missed takes
one off. It is not "frames drawn": Hyprland draws only when something changed, so a calm desktop
draws 15 to 40 frames a second and is still perfectly smooth. The plugin watches the screen's own
timeline: a refresh that went by without a new frame counts as missed only if a frame had been
started for it (`cyber/services/Fps.qml`, `countFrame` in the plugin).
Watch it live: `python3 ~/.cache/cyber-dev/fpswatch.py 10` prints fps / drawn / late. Frame by
frame (what changed, when the screen showed it): `touch $XDG_RUNTIME_DIR/cyber-corners-dump`, then
read `$XDG_RUNTIME_DIR/cyber-corners-frames`.

**Looking Glass.** Hyprland redraws the whole screen once for every frame of a window it hands to
the tilted preview, whether or not the window changed. So the settled preview fetches a frame
only when the plugin reports that the VM window drew something new, at most
`lookingGlass.previewFps` (30, in `cyber/config.json`; 0 = every frame) times a second,
`lookingGlass.coveredFps` (10) while other windows lie over it (it only shows through their
blurred glass then), and nothing at all while the real window is in front. If Hyprland refuses a
frame (it does while the window changes size, right after it opens), the capture is started
afresh; without that the tilted copy never took over and the real window stayed on top.
While the VM picture keeps moving (a video, a game: 20 new pictures a second or more for 0.4 s) the
preview goes live instead, and back 0.6 s after it stops. Fetching one frame per report cannot
keep up with a moving picture (a fetch takes two refreshes, and the ones asked for meanwhile are
lost): a 60 fps picture came out at about 25 uneven frames a second and video stuttered. Live it
is a steady 30 (half the monitor's rate, the most this kind of capture gives), at about the same
cost. Not while other windows cover nearly all of it. `lookingGlass.stream: false` turns that
off. For the real 60, put the pointer on it (the real window then) or make it fullscreen.
A window that is being captured (this one, or any window share) is always drawn whole by the
plugin; its "skip what an opaque window covers" would otherwise leave a hole in the captured
picture, which the tilt shifted into view beside the covering window.

**What is left** is the effect itself:
- a moving wallpaper makes every see-through window redraw at its frame rate (the loop is 15 fps
  for that reason; `webpaper/render-video.sh ... 20 24` renders a smoother one). A still
  wallpaper frees that: empty `"video"` and `"web"` in `cyber/config.json`.
- A live web page as wallpaper (`"web"`) costs about 40% at 24 fps and half resolution: use the
  rendered loop instead.
- Blur strength: `size` and `passes` in `cyber/services/Look.qml` (two passes at size 4; one pass
  at size 8 was tried and shows artifacts).
- The lock screen's own animation takes about half of the GPU while it shows.
- **A busy CPU makes frames late too.** With the VMs taking 20 and more of the 32 CPU threads
  (load average above 32), the compositor waited 58 to 106 ms of every second for a free core,
  and frames that needed 1 ms of work missed their refresh. `cyber/scripts/priority.sh` (run by
  the shell when it starts) raises the compositor's frame threads to nice -11 through
  RealtimeKit, without root; that brought the wait down to 38 ms. The stronger cure needs root
  and is your call: give the desktop the bigger CPU share whenever both want the CPU,
  `sudo systemctl set-property --runtime user.slice CPUWeight=1000` (until reboot; without
  `--runtime` it stays), or keep a few cores free of the VMs (vCPU pinning).
  How long the compositor waits: `cat /proc/$(pgrep -x Hyprland)/schedstat` (second number, ns).

The test harness is in `~/.cache/cyber-dev` (hidden 3440x1440 Hyprland sessions, nothing shows on
screen): `bench.sh` (scenes, GPU time per frame), `battery.sh` (the plugin through window life),
`lgtest.sh` / `lgperf.sh` (the Looking Glass panel with a stand-in window), `cmp.sh` (compare two
screenshots).

## Mouse cursor

Your own cursor set for the whole session (both desktops, GTK and Qt apps, XWayland, the lock
screen). `setup.sh` converts the Windows `.cur` files in `assets/cursor/Yellow` (or
`CURSOR_SRC=...`) into the Xcursor theme `Cyber-Yellow` in `~/.local/share/icons` with
`cursor/cur2xcursor.py` and sets it everywhere (Hyprland, gsettings, `~/.icons/default`,
`XCURSOR_THEME`). Shapes the set lacks come from Bibata.
- Another size: `CURSOR_SIZE=36 ./setup.sh` (the set has 24, 36, 48 and 96).
- Back to Bibata: `CURSOR_SRC=/nonexistent ./setup.sh` after deleting `~/.local/share/icons/Cyber-Yellow`.
- The lock screen (canvaslock) uses the session's cursor; the login screen keeps its own neon
  pointer, because no user cursor set is loaded there (`cursor = true/false` in
  `/etc/canvasgreet/config.toml` forces one for both).

## kitty: find bar (Ctrl+F)

`kitty/find.py` replaces end-4's search with an iTerm2-style find bar (both desktops): the text
stays put, a bar opens top-right, matches light up as you type with a `3/17` counter.
Enter/↑ older match, Shift+Enter/↓ newer, Alt+C match case, Alt+R regex, wheel/PgUp scroll,
Esc closes and leaves the terminal scrolled to the match. In full-screen apps (less, vim) Ctrl+F
goes to the app; Ctrl+Shift+F opens find there. Mapped by setup.sh ("find bar" in kitty.conf).

## Updating later
```sh
~/.local/share/cyber/update.sh
```
It backs up, pulls end-4 and runs its installer, pulls end4-pC, then re-runs `setup.sh`.
That last step matters: end-4's installer deletes anything extra in `~/.config/quickshell`,
`~/.config/fontconfig` and `~/.config/xdg-desktop-portal`.

## Undo
- Login screen: `sudo ~/.local/share/cyber/greeter/install.sh restore-cosmic && reboot` (needs the
  `cosmic-greeter` package; without COSMIC installed, log in on a text console with Ctrl+Alt+F2
  and start Hyprland from there if the login screen ever fails)
- Dotfiles: `./setup uninstall` in `~/.cache/dots-hyprland` (end-4 says it's imperfect),
  or restore from `~/.local/share/hypr-setup/latest/dot-config.tar.gz`
- Packages added since the backup: `comm -13 ~/.local/share/hypr-setup/latest/packages-all.txt <(pacman -Qq)`

## Notes
- COSMIC is not part of this setup any more (2026-11): nothing here needs it. The login and lock
  screens run on greetd + cage, the file manager is GNOME Files, videos open in mpv.
- Portals: `setup.sh` copies `hyprland-portals.conf` to the generic `portals.conf`. The portal
  service can start at login before it knows the desktop is Hyprland and then reads the generic
  file; with COSMIC's portal named there, GTK4 apps got no icon theme and Files showed plain
  outline icons.
- Keyring: end-4 starts gnome-keyring in Hyprland. To unlock it automatically at login,
  add `auth optional pam_gnome_keyring.so` and
  `session optional pam_gnome_keyring.so auto_start` to `/etc/pam.d/login`.
