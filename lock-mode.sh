#!/usr/bin/env bash
# Choose your lock screen, in Hyprland and in COSMIC:
#
#   ~/.local/share/cyber/lock-mode.sh cyberpunk   canvasgreet's cyberpunk lock (canvaslock)
#   ~/.local/share/cyber/lock-mode.sh default     each desktop's own lock (end-4/pC, COSMIC)
#   ~/.local/share/cyber/lock-mode.sh             show what's active
#
# Hyprland: Super+L, power menu > Lock, idle and before-sleep go through hypridle's $lock_cmd.
# COSMIC:   cosmic-session starts its locker by name; ~/.local/bin/cosmic-greeter takes its place.
# Run it inside the desktop you're in to apply there immediately; the other applies at next login.
# Stuck at a lock screen? From a text console: sudo ~/.local/share/cyber/recover.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAG="$HOME/.local/share/hypr-setup/use-canvaslock"
IDLE="$HOME/.config/hypr/hypridle.conf"
SHIM="$HOME/.local/bin/cosmic-greeter"
SHIM_SRC="$HERE/greeter/cosmic/cosmic-greeter"
INSTALLED=/usr/local/lib/canvasgreet/canvaslock.py

mode=${1:-status}
case $mode in
  cyberpunk)
    command -v canvaslock >/dev/null || { echo "canvaslock is not installed: sudo ~/.local/share/cyber/greeter/install.sh install"; exit 1; }
    if ! grep -q 'def run_daemon' "$INSTALLED"; then
      echo "The installed canvaslock is older than this setup needs (stuck-key fix, COSMIC support)."
      echo "Update it first:  sudo ~/.local/share/cyber/greeter/install.sh install"
      exit 1
    fi
    mkdir -p "$(dirname "$FLAG")" "$(dirname "$SHIM")"
    touch "$FLAG"
    install -m755 "$SHIM_SRC" "$SHIM" ;;
  default|end4)
    rm -f "$FLAG" "$SHIM" ;;
  status) ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

if [[ $mode != status ]]; then
  "$HERE/setup.sh" >/dev/null 2>&1   # rewrites hypridle's $lock_cmd from the flag
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    pkill -x hypridle || true
    sleep 0.3
    hyprctl dispatch 'hl.dsp.exec_cmd("hypridle")' >/dev/null
    echo "Hyprland: applied now (hypridle restarted)."
  elif [[ ${XDG_CURRENT_DESKTOP:-} == *COSMIC* ]]; then
    # swap COSMIC's running locker; cosmic-session normally restarts it by itself
    pkill -u "$USER" -x cosmic-greeter || true
    pkill -u "$USER" -f 'canvaslock.py --daemon' || true
    sleep 2
    if ! pgrep -u "$USER" -x cosmic-greeter >/dev/null && ! pgrep -u "$USER" -f 'canvaslock.py --daemon' >/dev/null; then
      if [[ -x $SHIM ]]; then setsid -f "$SHIM" >/dev/null 2>&1; else setsid -f /usr/bin/cosmic-greeter >/dev/null 2>&1; fi
      sleep 1
    fi
    echo "COSMIC: applied now (locker restarted)."
  fi
fi

if grep -q '^\$lock_cmd = canvaslock' "$IDLE" 2>/dev/null; then
  echo "Hyprland lock: cyberpunk (canvaslock, falls back to hyprlock)"
else
  echo "Hyprland lock: end-4/pC's own"
fi
if [[ -x $SHIM && -f $FLAG ]]; then
  echo "COSMIC lock:   cyberpunk (canvaslock, falls back to COSMIC's own)"
else
  echo "COSMIC lock:   COSMIC's own"
fi
if pgrep -u "$USER" -f 'canvaslock.py --daemon' >/dev/null; then echo "  (COSMIC is running the canvaslock listener right now)"; fi
