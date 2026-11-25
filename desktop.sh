#!/usr/bin/env bash
# Two desktops inside Hyprland: end-4/pC (end-4's illogical-impulse + pctrade/end4-pC) and Cyber
# (~/.local/share/cyber/cyber). Both are Quickshell configs; this switches between them live.
#
#   desktop.sh status          which one is running / remembered
#   desktop.sh apply cyber     switch now (also: end4-pC)
#   desktop.sh list            JSON for the lock screen (canvaslock's lock-choices hook)
#
# The choice is remembered in ~/.local/state/hypr-setup/desktop; Hyprland reads it at login and on
# every config reload (custom/variables.lua, written by setup.sh), so a fresh login starts the
# desktop you used last. The lock screen offers both: pick one there and unlock to switch.
set -uo pipefail

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/hypr-setup/desktop"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/hypr-setup/desktop.log"
CYBER_DIR="$HOME/.config/quickshell/cyber"

IDS=(end4-pC cyber)
name_of()    { case $1 in end4-pC) echo "end-4/pC" ;; cyber) echo "Cyber" ;; esac; }
comment_of() { case $1 in end4-pC) echo "illogical-impulse · end4-pC shell" ;; cyber) echo "Neon HUD desktop" ;; esac; }
config_of()  { echo "$1"; }   # the Quickshell config name (~/.config/quickshell/<name>)
available()  { [[ $1 != cyber || -f $CYBER_DIR/shell.qml ]]; }

log() { mkdir -p "$(dirname "$LOG")"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

running_shell() {   # the shell that's actually running, if any
  local id
  for id in "${IDS[@]}"; do
    pgrep -u "$USER" -fx "qs -c $(config_of "$id")" >/dev/null && { echo "$id"; return; }
  done
}
remembered() {
  local id; id=$(cat "$STATE" 2>/dev/null)
  [[ $id == end4-pC || $id == cyber ]] && echo "$id" || echo end4-pC
}
current() { local r; r=$(running_shell); echo "${r:-$(remembered)}"; }

# hyprctl needs the Hyprland instance; the lock screen's environment has it, but be safe
ensure_hypr() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && return 0
  local sig
  sig=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr" 2>/dev/null | head -1)
  [[ -n $sig ]] || return 1
  export HYPRLAND_INSTANCE_SIGNATURE=$sig
}

cmd_list() {
  # Only inside Hyprland: elsewhere (COSMIC) the lock screen keeps its normal entry.
  if [[ ${XDG_CURRENT_DESKTOP:-} != *Hyprland* ]]; then echo "[]"; return; fi
  local cur id sep="" out="["
  cur=$(current)
  for id in "${IDS[@]}"; do
    available "$id" || continue
    out+="$sep{\"id\":\"$id\",\"name\":\"$(name_of "$id")\",\"comment\":\"$(comment_of "$id")\",\"current\":$([[ $id == "$cur" ]] && echo true || echo false)}"
    sep=","
  done
  echo "$out]"
}

# kitty's colours per desktop: kitty.conf includes this file after end-4's generated theme
# (setup.sh, "desktop colours"). Cyber: its neon palette (kitty/cyber.conf). end-4/pC: nothing,
# so end-4's wallpaper colours stay. Running kittys re-read their config on SIGUSR1.
kitty_colours() {
  local f="$(dirname "$STATE")/kitty-desktop.conf"
  mkdir -p "$(dirname "$f")"
  if [[ $1 == cyber ]]; then
    printf '# written by desktop.sh: Cyber is the desktop\ninclude %s/kitty/cyber.conf\n' "$(dirname "$(readlink -f "$0")")" > "$f"
  else
    printf '# written by desktop.sh: end-4/pC is the desktop (its own colours)\n' > "$f"
  fi
  pkill -USR1 -u "$USER" -x kitty 2>/dev/null || true
}

cmd_apply() {
  local id=${1:-}
  [[ $id == end4-pC || $id == cyber ]] || { echo "usage: $0 apply end4-pC|cyber" >&2; return 2; }
  available "$id" || { echo "$id is not installed ($CYBER_DIR/shell.qml missing)" >&2; return 1; }
  ensure_hypr || { echo "not inside a Hyprland session" >&2; return 1; }

  exec 9>"${XDG_RUNTIME_DIR:-/tmp}/hypr-setup-desktop.lock"
  flock -w 20 9 || { log "apply $id: another switch is still running"; return 1; }

  mkdir -p "$(dirname "$STATE")"
  echo "$id" > "$STATE"
  kitty_colours "$id"
  local running; running=$(running_shell)
  if [[ $running == "$id" ]]; then log "apply $id: already running"; echo "$(name_of "$id") is already running."; return 0; fi
  log "apply $id (was: ${running:-none})"

  # 1. stop the other shell (its notification/tray/polkit services go with it)
  local other
  for other in "${IDS[@]}"; do
    [[ $other == "$id" ]] && continue
    pkill -u "$USER" -fx "qs -c $(config_of "$other")" 2>/dev/null
  done
  if [[ $id != cyber ]]; then   # Cyber's live wallpapers
    pkill -u "$USER" -x mpvpaper 2>/dev/null
    pkill -u "$USER" -f '[w]ebpaper\.py' 2>/dev/null
  fi
  local i
  for i in $(seq 30); do
    [[ -z $(running_shell) ]] && break
    sleep 0.1
  done
  pkill -u "$USER" -f '^/usr/bin/cava -p .*/quickshell/end4-pC/' 2>/dev/null   # pC's leftover
  # pC's night light (hyprsunset, warm 19:00-06:30) would keep tinting Cyber brown; pC restarts it
  [[ $id == cyber ]] && pkill -u "$USER" -x hyprsunset 2>/dev/null

  # 2. Hyprland re-reads the state (qsConfig, per-desktop settings)
  hyprctl reload >/dev/null 2>&1

  # 3. start the chosen shell from Hyprland, so it gets Hyprland's environment
  hyprctl dispatch "hl.dsp.exec_cmd(\"qs -c $(config_of "$id")\")" >/dev/null 2>&1
  for i in $(seq 50); do
    [[ $(running_shell) == "$id" ]] && { log "apply $id: started"; echo "Switched to $(name_of "$id")."; return 0; }
    sleep 0.1
  done
  log "apply $id: did not start within 5 s"
  echo "$(name_of "$id") did not start; see: qs log -c $(config_of "$id")" >&2
  return 1
}

cmd_status() {
  local r; r=$(running_shell)
  echo "running:    $([[ -n $r ]] && name_of "$r" || echo none)"
  echo "remembered: $(name_of "$(remembered)")  ($STATE)"
}

case ${1:-status} in
  list)   cmd_list ;;
  apply)  shift; cmd_apply "${1:-}" ;;
  kitty-colours) kitty_colours "$(remembered)" ;;   # (re)write kitty's colours for the current desktop
  status) cmd_status ;;
  *)      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
