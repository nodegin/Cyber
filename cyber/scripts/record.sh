#!/usr/bin/env bash
# Cyber's screen recording:  record.sh screen | geometry "X,Y WxH" | region | window | stop
#   screen: the focused monitor
#   geometry: that rectangle of Hyprland's layout. This is how the shell's own picker
#           (cyber/popups/Select.qml, through services/Grab.qml) records a region or a window.
#   region: drag a rectangle    window: click a window    (the plain picker, slurp, by hand)
# It records until "record.sh stop" (PrintScrn, or the camera button in the bottom bar, which shows
# a red stop sign and the time meanwhile). The video goes to ~/Videos/Recordings; when it stops, a
# notification shows it and its path is on the clipboard. No sound.
#
# The video is encoded by the GPU's own encoder (VAAPI): this machine's CPUs are busy with the VMs,
# and software encoding of 3440x1440 would take several cores. If that encoder cannot start, it
# falls back to x264 at its fastest setting.
# Without B-frames (bf=0): a browser that has no real H.264 decoder falls back to Cisco's OpenH264
# plug-in, and with that one a video with B-frames plays but ends in "file is corrupt" at the second
# seek (seen in Zen 1.19 with a recording made here, 2026-11-24). The files are a little larger.
# While a recording runs, its file name is in $XDG_RUNTIME_DIR/cyber-recording (the HUD watches that
# file: services/Recorder.qml); the file is emptied when it ends.
set -uo pipefail
mode=${1:-screen}
state="${XDG_RUNTIME_DIR:-/tmp}/cyber-recording"

if [ "$mode" = stop ]; then
    pkill -INT -x wf-recorder      # it finishes the file and exits; the script that started it does the rest
    exit 0
fi
case $mode in region | window | screen | geometry) ;; *) echo "usage: $0 region|window|screen|geometry|stop" >&2; exit 2 ;; esac
command -v wf-recorder >/dev/null || { notify-send -a "Recorder" "Cannot record" "wf-recorder is not installed"; exit 1; }
pgrep -x wf-recorder >/dev/null && exit 0     # one at a time
pidof slurp >/dev/null && exit 0              # already picking

dir="$(xdg-user-dir VIDEOS 2>/dev/null || echo "$HOME/Videos")/Recordings"
mkdir -p "$dir"
file="$dir/Recording_$(date +%Y-%m-%d_%H.%M.%S).mp4"
ws=$(hyprctl activeworkspace -j | jq -r .id)

# the video's width and height must be even: trim an odd pixel off "x,y WxH"
even() {
    local pos=${1% *} size=${1#* }
    local w=${size%x*} h=${size#*x}
    echo "$pos $((w - w % 2))x$((h - h % 2))"
}
case $mode in
    geometry)
        [ -n "${2:-}" ] || { echo "usage: $0 geometry \"X,Y WxH\"" >&2; exit 2; }
        target=(-g "$(even "$2")") ;;
    region)
        geo=$(slurp -d) || exit 0
        target=(-g "$(even "$geo")") ;;
    window)
        geo=$(hyprctl clients -j | jq -r --argjson ws "$ws" \
            '.[] | select(.workspace.id == $ws and .mapped and (.hidden | not)) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' \
            | slurp -r) || exit 0
        target=(-g "$(even "$geo")") ;;
    screen)
        target=(-o "$(hyprctl activeworkspace -j | jq -r .monitor)") ;;
esac
sleep 0.15      # the selection frame is off the screen

log="${XDG_RUNTIME_DIR:-/tmp}/cyber-recording.log"
node=$(ls /dev/dri/renderD* 2>/dev/null | head -1)
record() { wf-recorder "$@" "${target[@]}" -f "$file" -y >"$log" 2>&1; }

printf '%s\n' "$file" > "$state"
trap ': > "$state"' EXIT
started=$(date +%s)
if [ -n "$node" ]; then
    record -c h264_vaapi -d "$node" -p qp=23 -p bf=0
fi
# the GPU encoder did not start (it ended at once and left nothing): the CPU encoder
if [ ! -s "$file" ] && [ $(($(date +%s) - started)) -lt 3 ]; then
    record -c libx264 -x yuv420p -p preset=ultrafast -p crf=23 -p bf=0
fi
: > "$state"

if [ -s "$file" ]; then
    printf '%s' "$file" | wl-copy
    notify-send -a "Recorder" -i video-x-generic "Recording saved" "$(basename "$file") · path copied to clipboard"
else
    notify-send -a "Recorder" "Recording failed" "$(tail -n 2 "$log" 2>/dev/null)"
fi
exit 0
