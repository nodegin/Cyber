#!/usr/bin/env bash
# Cyber's screenshot:  capture.sh region | window | screen | crop "X,Y WxH" PICTURE
#   screen: the focused monitor
#   crop:   cut that rectangle out of PICTURE, a photograph of the screen taken a moment ago, and
#           delete PICTURE. This is how the shell's own picker (cyber/popups/Select.qml, through
#           services/Grab.qml) makes a region or window screenshot.
#   region: drag a rectangle    window: click a window    (the plain picker, slurp, on a frozen
#           screen: what runs when the shell's picker cannot, and by hand)
# The picture goes to ~/Pictures/Screenshots and the clipboard, a notification shows it, and the
# screen glitches once. Esc while picking cancels.
set -uo pipefail
mode=${1:-region}
dir="$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")/Screenshots"
mkdir -p "$dir"
file="$dir/Screenshot_$(date +%Y-%m-%d_%H.%M.%S).png"

pidof slurp >/dev/null && exit 0          # already picking

# The window that has focus now. The freeze and the picker take the keyboard while you pick, and
# Hyprland doesn't always hand it back: afterwards the window would stay unfocused (translucent).
ws=$(hyprctl activeworkspace -j | jq -r .id)
focused=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')
[ -n "$focused" ] || focused=$(hyprctl clients -j | jq -r --argjson ws "$ws" \
  '[.[] | select(.workspace.id == $ws and .mapped and (.hidden | not))] | min_by(.focusHistoryID) | .address // empty')
refocus() {
  [ -n "$focused" ] || return 0
  [ "$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')" = "$focused" ] && return 0
  hyprctl dispatch "hl.dsp.focus({ window = 'address:$focused' })" >/dev/null 2>&1
}

freeze_pid=""
freeze() { hyprpicker -r -z >/dev/null 2>&1 & freeze_pid=$!; sleep 0.15; }
unfreeze() { [ -n "$freeze_pid" ] && kill "$freeze_pid" 2>/dev/null; freeze_pid=""; }
trap 'unfreeze; sleep 0.05; refocus' EXIT

case $mode in
  crop)
    geo=${2:-}; still=${3:-}
    [ -n "$geo" ] && [ -s "$still" ] || { echo "usage: $0 crop \"X,Y WxH\" PICTURE" >&2; exit 2; }
    pos=${geo% *}; size=${geo#* }
    magick "$still" -crop "${size}+${pos%,*}+${pos#*,}" +repage "$file"
    rm -f "$still" ;;
  region)
    freeze
    geo=$(slurp -d) || exit 0
    grim -g "$geo" "$file" ;;
  window)
    freeze
    geo=$(hyprctl clients -j | jq -r --argjson ws "$ws" \
      '.[] | select(.workspace.id == $ws and .mapped and (.hidden | not)) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' \
      | slurp -r) || exit 0
    grim -g "$geo" "$file" ;;
  screen)
    grim -o "$(hyprctl activeworkspace -j | jq -r .monitor)" "$file" ;;
  *)
    echo "usage: $0 region|window|screen|crop" >&2; exit 2 ;;
esac
unfreeze
[ -s "$file" ] || exit 1

wl-copy --type image/png < "$file"
notify-send -a "Screenshot" -i "$file" -h "string:image-path:$file" "Screenshot saved" "$(basename "$file") · copied to clipboard"
hyprctl eval 'if CyberGlitch then CyberGlitch.screen(0.6) end' >/dev/null 2>&1   # the screen glitches once
exit 0
