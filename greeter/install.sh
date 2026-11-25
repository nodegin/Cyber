#!/usr/bin/env bash
# canvasgreet installer. Run with sudo from this folder:
#
#   sudo ./install.sh install          packages + files. Does NOT change your login screen yet.
#   sudo ./install.sh test             try it on VT 7 next to your running session
#   sudo ./install.sh test-stop        end that test
#   sudo ./install.sh enable           make canvasgreet the login screen (cosmic-greeter off)
#   sudo ./install.sh switch-now       start it without rebooting (after logging out)
#        ./install.sh update-themes    refresh installed themes (old ones backed up)
#   sudo ./install.sh restore-cosmic   switch back to cosmic-greeter
#   sudo ./install.sh uninstall        restore-cosmic + remove canvasgreet (themes kept)
#        ./install.sh status           which login screen is active
#
# If the login screen ever fails: press Ctrl+Alt+F2, log in on the text console, run
#   sudo ~/.local/share/cyber/greeter/install.sh restore-cosmic && sudo reboot
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB=/usr/local/lib/canvasgreet
BIN=/usr/local/bin
SHARE=/usr/local/share/canvasgreet
ETC=/etc/canvasgreet
OWNER="${SUDO_USER:-}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
need_root() { [[ $(id -u) == 0 ]] || { echo "Run this with sudo: sudo $0 $*"; exit 1; }; }

cmd_install() {
  need_root install
  say "Installing packages (login screen: cage python-pyqt6-webengine greetd; lock screen: gtk4-layer-shell webkitgtk-6.0)"
  pacman -S --needed --noconfirm cage python-pyqt6-webengine greetd gtk4-layer-shell webkitgtk-6.0

  say "Installing canvasgreet to $LIB"
  install -Dm644 "$SRC/canvasgreet.py"        "$LIB/canvasgreet.py"
  install -Dm644 "$SRC/canvaslock.py"         "$LIB/canvaslock.py"
  install -Dm755 "$SRC/bin/canvaslock"        "$BIN/canvaslock"
  install -Dm644 "$SRC/pam/canvaslock"        /etc/pam.d/canvaslock
  install -Dm644 "$SRC/bridge.js"             "$LIB/bridge.js"
  install -Dm644 "$SRC/fallback/index.html"   "$LIB/fallback/index.html"
  install -Dm755 "$SRC/bin/canvasgreet"         "$BIN/canvasgreet"
  install -Dm755 "$SRC/bin/canvasgreet-session" "$BIN/canvasgreet-session"
  install -Dm644 "$SRC/canvasgreet.desktop"   /usr/local/share/applications/canvasgreet.desktop
  install -Dm644 "$SRC/greetd/test.toml"      "$ETC/greetd-test.toml"
  # Replace the config only if you never edited it (it still equals what we shipped last time).
  if [[ ! -f $ETC/config.toml ]]; then
    install -Dm644 "$SRC/config.toml" "$ETC/config.toml"
  elif cmp -s "$SRC/config.toml" "$ETC/config.toml"; then
    :
  elif [[ -f $LIB/config.shipped.toml ]] && cmp -s "$ETC/config.toml" "$LIB/config.shipped.toml"; then
    install -Dm644 "$SRC/config.toml" "$ETC/config.toml"
    say "$ETC/config.toml updated to the new defaults (it had no changes of yours)"
  else
    install -Dm644 "$SRC/config.toml" "$ETC/config.toml.new"
    warn "$ETC/config.toml has your edits, left untouched (new defaults in config.toml.new)"
  fi
  install -Dm644 "$SRC/config.toml" "$LIB/config.shipped.toml"

  say "Installing themes to $SHARE/themes (existing themes are not overwritten)"
  mkdir -p "$SHARE/themes" "$SHARE/avatars"
  for theme in "$SRC"/themes/*/; do
    name=$(basename "$theme")
    if [[ -e $SHARE/themes/$name ]]; then
      diff -rq "$theme" "$SHARE/themes/$name" >/dev/null 2>&1 ||
        warn "theme '$name' differs from this version, kept as is (update with: $SRC/install.sh update-themes)"
    else
      cp -r "$theme" "$SHARE/themes/$name"
    fi
  done
  if [[ -n $OWNER ]]; then
    # Owned by you, so you can edit themes, add tracks/avatars and run `canvasgreet --use` without sudo.
    chown -R "$OWNER": "$SHARE"
  fi
  chmod -R u+rwX,go+rX,go-w "$SHARE"

  say "Creating /var/cache/canvasgreet for the greeter user"
  install -Dm644 "$SRC/tmpfiles.conf" /etc/tmpfiles.d/canvasgreet.conf
  systemd-tmpfiles --create /etc/tmpfiles.d/canvasgreet.conf

  say "Installed. Your login screen is unchanged. Next:"
  echo "    canvasgreet --demo --fullscreen     preview (password: demo, Ctrl+Q quits)"
  echo "    sudo $SRC/install.sh test           try the real thing on VT 7"
  echo "    sudo $SRC/install.sh enable         switch the login screen"
}

cmd_test() {
  need_root test
  [[ -x $BIN/canvasgreet-session ]] || { echo "Run 'sudo $0 install' first."; exit 1; }
  systemctl stop canvasgreet-test.service 2>/dev/null || true
  systemctl reset-failed canvasgreet-test.service 2>/dev/null || true
  # greetd must run as its own system service, like it does at boot. Started straight from
  # this terminal it would sit inside your login session, logind then refuses the greeter a
  # session of its own (no XDG_RUNTIME_DIR, no seat access) and cage can't start.
  systemd-run --unit=canvasgreet-test --description="canvasgreet test login screen (VT 7)" \
    --property=After=systemd-user-sessions.service --property=KeyringMode=shared \
    --property=SendSIGHUP=yes --property=IgnoreSIGPIPE=no \
    greetd --config "$ETC/greetd-test.toml"
  say "Test login screen started on VT 7 (your screen switches there now)."
  echo "    Back to this desktop:  Ctrl+Alt+F1"
  echo "    Stop the test:         sudo $SRC/install.sh test-stop"
  echo "    Its log:               journalctl -b -u canvasgreet-test"
  echo "    Logging in from the test starts a 2nd session as the same user: fine for a quick"
  echo "    look, but for real use run 'enable' and reboot instead."
}

cmd_test_stop() {
  need_root test-stop
  systemctl stop canvasgreet-test.service 2>/dev/null || true
  systemctl reset-failed canvasgreet-test.service 2>/dev/null || true
  say "Test login screen stopped."
}

cmd_enable() {
  need_root enable
  [[ -x $BIN/canvasgreet-session ]] || { echo "Run 'sudo $0 install' first."; exit 1; }
  if [[ -f /etc/greetd/config.toml && ! -f /etc/greetd/config.toml.before-canvasgreet ]]; then
    cp /etc/greetd/config.toml /etc/greetd/config.toml.before-canvasgreet
  fi
  install -Dm644 "$SRC/greetd/config.toml" /etc/greetd/config.toml
  systemctl stop canvasgreet-test.service 2>/dev/null || true
  systemctl disable cosmic-greeter.service 2>/dev/null || true
  systemctl enable greetd.service
  say "canvasgreet is now the login screen. Reboot to see it, or without rebooting: log out,"
  echo "    Ctrl+Alt+F3, log in on the text console, run: sudo $SRC/install.sh switch-now"
  echo "    Way back: Ctrl+Alt+F2, log in, then: sudo $SRC/install.sh restore-cosmic && sudo reboot"
}

cmd_switch_now() {
  need_root switch-now
  [[ $(systemctl is-enabled greetd.service 2>/dev/null) == enabled ]] || { echo "Run 'sudo $0 enable' first."; exit 1; }
  local s open=""
  for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
    # "closing" = already logged out, only leftover programs still exiting: not a running desktop
    if [[ $(loginctl show-session "$s" -p Class --value) == user &&
          $(loginctl show-session "$s" -p Type --value) =~ ^(wayland|x11)$ &&
          $(loginctl show-session "$s" -p State --value) != closing ]]; then
      open+=" $s"
    fi
  done
  if [[ -n $open ]]; then
    echo "A desktop session is still open (session$open): switching now would end it."
    echo "Save your work and log out, press Ctrl+Alt+F3 at the login screen, log in on"
    echo "the text console and run:  sudo $SRC/install.sh switch-now"
    exit 1
  fi
  systemctl stop canvasgreet-test.service cosmic-greeter.service 2>/dev/null || true
  systemctl restart greetd.service
  say "canvasgreet is running on VT 1 (Ctrl+Alt+F1 if you're not switched there)."
}

cmd_update_themes() {
  [[ -w $SHARE/themes ]] || { echo "No write access to $SHARE/themes: run 'sudo $0 install' first."; exit 1; }
  local backup="$SHARE/themes-backup-$(date +%F-%H%M%S)" name
  mkdir -p "$backup"
  for theme in "$SRC"/themes/*/; do
    name=$(basename "$theme")
    if [[ -d $SHARE/themes/$name ]]; then
      if diff -rq "$theme" "$SHARE/themes/$name" >/dev/null 2>&1; then
        echo "  $name: already current"
        continue
      fi
      cp -a "$SHARE/themes/$name" "$backup/"
    fi
    mkdir -p "$SHARE/themes/$name"
    cp -a "$theme". "$SHARE/themes/$name/"   # overwrite our files, keep ones you added (tracks...)
    echo "  $name: updated"
  done
  if rmdir "$backup" 2>/dev/null; then echo "  (nothing to back up)"; else echo "  previous versions saved in $backup"; fi
  [[ -n $OWNER ]] && chown -R "$OWNER": "$SHARE"
  return 0
}

cmd_restore_cosmic() {
  need_root restore-cosmic
  systemctl disable greetd.service 2>/dev/null || true
  systemctl enable cosmic-greeter.service
  say "cosmic-greeter is the login screen again (after a reboot)."
}

cmd_uninstall() {
  need_root uninstall
  cmd_restore_cosmic
  if [[ -f /etc/greetd/config.toml.before-canvasgreet ]]; then
    mv /etc/greetd/config.toml.before-canvasgreet /etc/greetd/config.toml
  fi
  rm -rf "$LIB" "$BIN/canvasgreet" "$BIN/canvasgreet-session" "$BIN/canvaslock" /etc/pam.d/canvaslock \
    /etc/tmpfiles.d/canvasgreet.conf /var/cache/canvasgreet /usr/local/share/applications/canvasgreet.desktop
  warn "If Hyprland's hypridle.conf uses canvaslock, re-run ~/.local/share/cyber/setup.sh (it falls back to hyprlock)."
  say "Removed canvasgreet. Kept: $ETC (config) and $SHARE (your themes). Delete them by hand if you want."
  echo "    The packages cage and python-pyqt6-webengine are still installed: sudo pacman -Rs cage python-pyqt6-webengine"
}

cmd_status() {
  printf 'display-manager -> %s\n' "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo none)"
  for unit in greetd.service cosmic-greeter.service; do
    printf '%-24s enabled=%s active=%s\n' "$unit" "$(systemctl is-enabled $unit 2>/dev/null || true)" "$(systemctl is-active $unit 2>/dev/null || true)"
  done
  [[ -x $BIN/canvasgreet ]] && "$BIN/canvasgreet" --list || echo "canvasgreet not installed"
}

case "${1:-}" in
  install)         cmd_install ;;
  test)            cmd_test ;;
  test-stop)       cmd_test_stop ;;
  enable)          cmd_enable ;;
  switch-now)      cmd_switch_now ;;
  update-themes)   cmd_update_themes ;;
  restore-cosmic)  cmd_restore_cosmic ;;
  uninstall)       cmd_uninstall ;;
  status)          cmd_status ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1 ;;
esac
