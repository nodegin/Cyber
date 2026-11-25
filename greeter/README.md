# canvasgreet

A login screen for greetd whose UI is an ordinary web page. Any HTML/CSS/JS
(canvas, WebGL, Web Audio, blur, frameworks...) becomes your login screen, with a
small JavaScript API for users, environments (COSMIC, Hyprland...), login and power.

```
greetd ──($GREETD_SOCK, JSON)──► canvasgreet.py   (user "greeter", inside cage)
                                    │  QWebChannel bridge (bridge.js)
                                    ▼
                    theme = web page served at greeter://theme/   (Chromium, GPU)
```

Measured on a Radeon 610M iGPU at 3440x1440: both the cyberpunk theme (WebGL
distortion shader, rain, tilted HUD, live blur) and the music theme hold 60 fps.

## Install / try / switch / undo

```sh
sudo ./install.sh install          # packages + files; login screen unchanged
canvasgreet --demo --fullscreen    # preview (password "demo", F12 devtools, Ctrl+Q quit)
sudo ./install.sh test             # the real greeter on VT 7; Ctrl+Alt+F1 back, Ctrl+C stop
sudo ./install.sh enable           # make it the login screen, then reboot
sudo ./install.sh restore-cosmic   # back to cosmic-greeter (then reboot)
./install.sh status
```

**If the login screen ever breaks:** `Ctrl+Alt+Shift+F` switches to a plain built-in
login form. If even that fails, `Ctrl+Alt+F2` gives a text console: log in and run
`sudo ~/.local/share/cyber/greeter/install.sh restore-cosmic && sudo reboot`.
Logs: `journalctl -b -u greetd` (theme `console.log` output appears there too).

## Lock screen (canvaslock)

The same theme also works as your lock screen. `canvaslock` runs inside your session and
locks it with the Wayland session-lock protocol (gtk4-layer-shell), so the compositor shows
and sends input to nothing else, and a crash leaves the session locked. The page is shown with
WebKitGTK and the password is checked by PAM (`/etc/pam.d/canvaslock`, same as login).
Themes see `greeter.info.mode === "lock"`: one user, the locked session, only sleep.

```sh
canvaslock --demo --fullscreen   # preview, nothing locked (password "demo", Ctrl+Q quits)
canvaslock --test 30             # really lock, unlocks by itself after 30 s
canvaslock                       # lock
```

Switch it on or off for both desktops with `~/.local/share/cyber/lock-mode.sh cyberpunk|default`:

- **Hyprland:** hypridle's `$lock_cmd` becomes `canvaslock || hyprlock`, covering Super+L,
  the power menu's Lock, idle and before-sleep.
- **COSMIC:** cosmic-session starts its locker by name (`cosmic-greeter`) and `~/.local/bin`
  comes first in your PATH, so `~/.local/bin/cosmic-greeter` runs `canvaslock --daemon`
  instead. That listener locks on every lock request (Super+Escape, the panel,
  `loginctl lock-session`) and before sleep. If it fails, COSMIC's real locker runs.

**Several desktops in one session:** if `~/.config/canvasgreet/lock-choices` is executable,
the lock screen lists what `lock-choices list` prints (JSON
`[{"id", "name", "comment", "current"}]`) instead of the one locked session, shows the names
exactly as given, and after you unlock with another one selected runs
`lock-choices apply <id>` (detached, after the screen is unlocked; it never delays the unlock).
`~/.local/share/cyber/desktop.sh` is such a hook: it switches Hyprland between end-4/pC and
Cyber. Outside Hyprland it prints `[]`, so the COSMIC lock is unchanged.

**Layers against getting stuck:** Ctrl/Alt that Hyprland wrongly thinks are held after
`Ctrl+Alt+F1` are ignored (your password still types correctly). A theme that doesn't
start within 12 s is replaced by a built-in password box (also `Ctrl+Alt+Shift+F`). A
crashed lock is restarted, then handed to hyprlock. And from any text console:
`sudo ~/.local/share/cyber/recover.sh` (unlock) or `... recover.sh logout`.

## Themes

Themes live in `/usr/local/share/canvasgreet/themes/<name>/index.html` and are owned by
you, so no sudo is needed to edit them.

| theme   | |
|---------|---|
| `cyberpunk` (default) | HUD login: your wallpaper (`wallpaper.png`) through a WebGL visor shader (lens warp, colour fringing, scanlines, rain, glitch bursts), tilted side panels with live CPU/MEM/NET, environment list as "uplink targets", passphrase cells, ICE alert after 3 failures, CRT power-off on login. Options: `[theme_options.cyberpunk]` in the config. |
| `music` | music-player login: generative ambient track, cover art, visualizer, environment picker as a playlist. Put your own audio in `tracks/` (see `tracks/README.txt`). |
| `blank` | a commented single-file template to paint on |

```sh
canvasgreet --list                # installed themes (* = active)
canvasgreet --use blank           # choose the login screen theme
canvasgreet --demo --theme blank  # live preview; reloads on every save
cp -r /usr/local/share/canvasgreet/themes/blank /usr/local/share/canvasgreet/themes/mine
```

Login picture: `/usr/local/share/canvasgreet/avatars/<username>.png`.
Settings (zoom, default environment, theme options, network): `/etc/canvasgreet/config.toml`.

### JavaScript API

```js
const greeter = await window.greeterReady;
greeter.info                       // { hostname, demo, preferredUser, preferredSession, options, ... }
await greeter.users()              // [{ name, realName, avatar }]
await greeter.sessions()           // [{ id, name, comment }]  (COSMIC, Hyprland, ...)
await greeter.login(user, password, sessionId)   // { ok: true } | { ok: false, error }
greeter.on("prompt", p => greeter.respond(code)) // extra PAM questions (OTP...)
await greeter.power("poweroff" | "reboot" | "suspend" | "hibernate")
await greeter.themeFiles("tracks") // files in a folder of your theme
await greeter.system()             // { uptime, load, cpu, mem, net, power }  for live widgets
```

Full reference: the comment at the top of `bridge.js`.

## Security model

- The password goes page → `canvasgreet.py` → greetd over its socket. It is never logged
  or stored. All the code that sees it is in `canvasgreet.py`.
- Themes can't reach the network (`allow_network = false`): no remote scripts, fonts,
  images or requests, so no theme can send anything anywhere. They also can't read files
  outside their own folder. Both are enforced in Python, not in the page.
- The greeter runs as the unprivileged `greeter` user. Its cache (last user/session, GPU
  shader cache) is `/var/cache/canvasgreet`.
- Trade-off: the themes folder is writable by your user, which is what makes sudo-free
  editing possible. Anyone who can run code as you could change the login page, though
  with networking off it has no way to send anything out.

## Performance notes (iGPU)

- Measure in full screen: `canvasgreet --demo --fullscreen`. A window on a desktop with
  fractional scaling is composited differently and showed half the frame rate in testing.
- `backdrop-filter: blur()` on cards is cheap. Avoid CSS `filter` on full-screen
  layers that change every frame.
- Give full-screen animated elements their own layer: `will-change: transform`.
