#!/bin/sh
# priority.sh [off]
# Give the compositor's frame-producing threads (Hyprland's main thread and the graphics driver's
# threads inside it) a higher scheduling priority: nice -11, through RealtimeKit, the unprivileged
# service PipeWire uses for audio threads. No root, no realtime class, undone with "priority.sh off".
#
# Why: this machine also runs VMs that take 20 and more of its 32 CPU threads (load average 33 on
# 2026-11-24). At normal priority the compositor then waits for a free core, 58 to 106 ms out of
# every second, and frames that only needed 1 ms of work miss their refresh. At nice -11 it waited
# 38 ms. (RealtimeKit allows a user 25 such threads in all, audio included: only these eight are
# taken, never the compositor's shader or cache helpers.)
p=$(pgrep -x -u "$(id -u)" Hyprland | head -1)
[ -n "$p" ] || exit 0
for t in /proc/"$p"/task/*; do
    tid=${t##*/}
    case "$(cat "$t/comm" 2>/dev/null)" in
        Hyprland | Hyprland:gl0 | Hyprland:gdrv0 | Hyprland:cs0) ;;
        *) continue ;;
    esac
    nice=$(awk '{print $19}' "$t/stat" 2>/dev/null)
    if [ "${1:-}" = off ]; then
        [ "$nice" != 0 ] && renice -n 0 -p "$tid" >/dev/null 2>&1
    elif [ "${nice:-0}" -gt -11 ]; then
        busctl --system call -- org.freedesktop.RealtimeKit1 /org/freedesktop/RealtimeKit1 org.freedesktop.RealtimeKit1 \
            MakeThreadHighPriorityWithPID tti "$p" "$tid" -11 >/dev/null 2>&1
    fi
done
exit 0
