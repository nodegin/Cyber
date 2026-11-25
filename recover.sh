#!/usr/bin/env bash
# Recovery for a stuck Hyprland lock screen. Run it from a text console
# (Ctrl+Alt+F3, log in), with sudo:
#
#   sudo ~/.local/share/cyber/recover.sh          unlock Hyprland, keep all your windows
#   sudo ~/.local/share/cyber/recover.sh logout   end the Hyprland session -> login screen
#                                                   (open windows are closed)
#
# Both modes also make sure locking goes back to end-4/pC's normal lock screen.
set -u
[[ $(id -u) == 0 ]] || { echo "Run with sudo: sudo $0 ${1:-}"; exit 1; }
USR=${SUDO_USER:-u}
UID_N=$(id -u "$USR")
HOM=$(getent passwd "$USR" | cut -d: -f6)
RUN=/run/user/$UID_N
MODE=${1:-unlock}
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
as_user() { runuser -u "$USR" -- env HOME="$HOM" USER="$USR" XDG_RUNTIME_DIR="$RUN" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$RUN/bus" "$@"; }

# The Hyprland session(s) of this user, and the VT they live on
mapfile -t SESSIONS < <(loginctl list-sessions --no-legend | awk -v u="$USR" '$3 == u {print $1}' | while read -r s; do
  [[ $(loginctl show-session "$s" -p Type --value) == wayland ]] && echo "$s"; done)
VT=$(for s in "${SESSIONS[@]}"; do loginctl show-session "$s" -p VTNr --value; done | grep -m1 .)
WAYLAND=$(basename "$(ls -d "$RUN"/wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)")

say "Stopping lock programs"
pkill -u "$USR" -f 'canvasgreet/canvaslock.py' 2>/dev/null
pkill -u "$USR" -x hyprlock 2>/dev/null

say "Locking goes back to end-4/pC's own lock screen"
rm -f "$HOM/.local/share/hypr-setup/use-canvaslock"
as_user bash "$HOM/.local/share/cyber/setup.sh" >/dev/null 2>&1 || true
grep -m1 '^\$lock_cmd' "$HOM/.config/hypr/hypridle.conf" 2>/dev/null | cut -c1-70

logout_hyprland() {
  say "Ending the Hyprland session(s): ${SESSIONS[*]:-none}"
  for s in "${SESSIONS[@]}"; do loginctl terminate-session "$s"; done
  sleep 3
  systemctl is-active --quiet greetd || systemctl restart greetd
  chvt "${VT:-1}"
  say "Done: the login screen is on VT ${VT:-1} (Ctrl+Alt+F${VT:-1})."
}

if [[ $MODE == logout ]]; then logout_hyprland; exit 0; fi

if [[ ${#SESSIONS[@]} == 0 || -z $WAYLAND ]]; then
  say "No Hyprland session found: nothing to unlock."; chvt "${VT:-1}"; exit 0
fi

say "Switching to VT $VT (Hyprland only redraws, and so can only unlock, while it's on screen)"
chvt "$VT"; sleep 2
say "Unlocking (a short-lived lock takes over and releases the session)"
OUT=$(as_user WAYLAND_DISPLAY="$WAYLAND" timeout 30 python3 -I "$HOM/.local/share/cyber/greeter/canvaslock.py" --test 2 2>&1)
if grep -q '\[canvaslock\] unlocked' <<<"$OUT"; then
  say "Unlocked. Your desktop is on VT $VT."
  # hypridle may have been stopped during the trouble: make sure one runs, with the normal lock
  if ! pgrep -u "$USR" -x hypridle >/dev/null; then
    SIG=$(basename "$(ls -td "$RUN"/hypr/*/ | head -1)")
    as_user HYPRLAND_INSTANCE_SIGNATURE="$SIG" hyprctl dispatch 'hl.dsp.exec_cmd("hypridle")' >/dev/null
  fi
else
  echo "$OUT" | grep '^\[canvaslock\]'
  say "Unlocking did not work. To get back in, end the session instead (open windows close):"
  echo "    sudo $0 logout"
fi
