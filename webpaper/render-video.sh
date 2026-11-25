#!/usr/bin/env bash
# Pre-render a web wallpaper (a Wallpaper Engine "web" folder, or any local page) into a seamless
# loop video that mpvpaper plays for a few percent of the GPU, instead of 40% for the live page.
#
#   render-video.sh FOLDER OUT.mp4 [SECONDS=20] [FPS=24] [WIDTHxHEIGHT=your monitor's]
#
# It starts a hidden Hyprland of its own (nothing appears on your screen), shows the page there at
# full resolution, steps the page's clock one frame at a time (so the weak GPU cannot drop
# frames), records each frame, and cross-fades the end into the start so the loop has no seam.
# Takes a few minutes. Then set "video" in cyber/config.json to OUT.mp4 and empty "web".
set -euo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
SRC=${1:?usage: render-video.sh FOLDER OUT.mp4 [SECONDS] [FPS] [WxH]}
OUT=${2:?usage: render-video.sh FOLDER OUT.mp4 [SECONDS] [FPS] [WxH]}
SECS=${3:-20}; FPS=${4:-24}; OVER=2
SIZE=${5:-$(hyprctl monitors -j | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print(str(m["width"]) + "x" + str(m["height"]))')}
for c in Hyprland hyprctl grim ffmpeg python3; do command -v "$c" >/dev/null || { echo "$c is not installed"; exit 1; }; done

TMP=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/cyber-render.XXXXXX")
HP=""
cleanup() { [[ -n $HP ]] && kill "$HP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
cat > "$TMP/hypr.lua" <<LUA
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.monitor({ output = "WAYLAND-1", disabled = true })   -- no window on your real screen
hl.monitor({ output = "RENDER", mode = "${SIZE}@60", position = "0x0", scale = 1 })
hl.config({ animations = { enabled = false }, misc = { disable_hyprland_logo = true, disable_splash_rendering = true, disable_watchdog_warning = true,
                     disable_hyprland_guiutils_check = true, background_color = "rgb(000000)" },
            decoration = { blur = { enabled = false }, shadow = { enabled = false } }, cursor = { inactive_timeout = 1 } })
LUA
Hyprland -c "$TMP/hypr.lua" > "$TMP/hypr.log" 2>&1 &
HP=$!
SIG=""; SOCK=""
for _ in $(seq 40); do
  read -r SIG SOCK < <(hyprctl instances -j 2>/dev/null | python3 -c "
import json,sys
for i in json.load(sys.stdin):
    if i.get('pid') == $HP: print(i['instance'], i['wl_socket'])" 2>/dev/null) || true
  [[ -n $SIG ]] && break
  sleep 0.25
done
[[ -n $SIG && $SIG != "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || { echo "the hidden compositor did not start (see $TMP/hypr.log)"; trap - EXIT; exit 1; }
hyprctl -i "$SIG" output create headless RENDER >/dev/null
sleep 1
hyprctl -i "$SIG" dispatch 'hl.dsp.cursor.move({ x = 1, y = 1 })' >/dev/null 2>&1 || true   # pointer out of the picture

echo "Rendering $SECS s at $FPS fps, $SIZE ..."
env -u HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY="$SOCK" python3 "$HERE/webpaper.py" "$SRC" \
    --record "$TMP/raw.mkv" --seconds "$SECS" --overlap "$OVER" --rec-fps "$FPS" --grim-output RENDER 2>"$TMP/webpaper.log" \
  | grep --line-buffered -E "^frame|^recorded" || true
[[ -s $TMP/raw.mkv ]] || { echo "nothing was recorded (see $TMP/webpaper.log)"; trap - EXIT; exit 1; }
kill "$HP" 2>/dev/null || true; HP=""

echo "Encoding the loop ..."
L=$SECS; E=$(python3 -c "print($SECS + $OVER)")
ffmpeg -loglevel error -y -i "$TMP/raw.mkv" -filter_complex "
  [0:v]split=3[a][b][c];
  [a]trim=start=$OVER:end=$L,setpts=PTS-STARTPTS[main];
  [b]trim=start=$L:end=$E,setpts=PTS-STARTPTS[tail];
  [c]trim=start=0:end=$OVER,setpts=PTS-STARTPTS[head];
  [tail][head]xfade=transition=fade:duration=$OVER:offset=0[x];
  [x][main]concat=n=2:v=1:a=0,format=yuv420p[out]" -map "[out]" \
  -c:v libx265 -preset medium -crf 22 -tag:v hvc1 -x265-params "log-level=error:keyint=$(python3 -c "print(int($FPS*2))")" \
  -movflags +faststart -an -f mp4 "$OUT.part"
mv -f "$OUT.part" "$OUT"      # in one step: a player that has the old file open keeps playing it
echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
