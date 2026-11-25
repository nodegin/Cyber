#!/usr/bin/env python3
"""Turn a folder of Windows cursors (.cur, named like Chromium's cursor types: pointer.cur,
hand.cur, i_beam.cur, ...) into an Xcursor theme that Hyprland, GTK, Qt and XWayland can use.

    cur2xcursor.py SRC_DIR DEST_THEME_DIR [--name "Cyber Yellow"] [--inherits Bibata-Modern-Classic]

The cursor files themselves stay where you downloaded them: this only writes the converted theme
(~/.local/share/icons/<Theme>/). Shapes the set does not have come from the inherited theme.
Needs nothing but Python: the frames inside the .cur files are read directly (PNG, 8-bit RGBA).
Size: a 32 px Windows cursor is the normal size, so it is stored as Xcursor size 24 (48 -> 36,
64 -> 48, 128 -> 96).
"""
import argparse
import os
import struct
import sys
import zlib

# Xcursor file name -> (source .cur name, other names that are links to it)
SHAPES = {
    "left_ptr": ("pointer", ["default", "arrow", "top_left_arrow"]),
    "hand2": ("hand", ["pointer", "pointing_hand", "hand", "9d800788f1b08800ae810202380a0822",
                       "e29285e634086352946a0e7090d73106"]),
    "xterm": ("i_beam", ["text", "ibeam"]),
    "vertical-text": ("vertical_text", []),
    "wait": ("wait", ["watch"]),
    "left_ptr_watch": ("progress", ["progress", "half-busy", "00000000000000020006000e7e9ffc3f",
                                    "08e8e1c95fe2fc01f976f1e063a24ccd", "3ecb610c1bf2410f44200f48c40d3599"]),
    "question_arrow": ("help", ["help", "left_ptr_help", "whats_this", "5c6cd98b3f3ebcb1f9c7f1c204630408",
                                "d9ce0ab605698f320427677b458ad60b"]),
    "crosshair": ("cross", ["cross", "tcross", "cross_reverse", "diamond_cross", "color-picker"]),
    "plus": ("cell", ["cell"]),
    "copy": ("copy", ["dnd-copy", "1081e37283d90000800003c07f3ef6bf", "6407b0e94181790501fd1e167b474872",
                      "b66166c04f8c3109214a4fbd64a50fc8"]),
    "link": ("alias", ["alias", "dnd-link", "3085a0e285430894940527032f8b26df",
                       "640fb0e74195791501fd1ed57b41487f", "a2a266d0498c3104214a47bd64ab0fc8"]),
    "context-menu": ("context_menu", []),
    "move": ("move", ["fleur", "size_all", "pointer-move", "4498f0e0c1937ffe01fd06f973665830",
                      "9081237383d90e509aa00f00170e968f"]),
    "all-scroll": ("middle_panning", []),
    "dnd_no_drop": ("no_drop", ["no-drop", "dnd-no-drop"]),
    "crossed_circle": ("not_allowed", ["not-allowed", "forbidden", "circle", "03b6e0fcb3499374a867c041f52298f0"]),
    "hand1": ("grab", ["grab", "openhand"]),
    "grabbing": ("grabbing", ["closedhand", "dnd-move", "dnd-none", "fcf21c00b30f7e3f83fe0dfd12e71cff"]),
    "col-resize": ("column_resize", ["split_h"]),
    "row-resize": ("row_resize", ["split_v"]),
    "sb_h_double_arrow": ("east_west_resize", ["ew-resize", "h_double_arrow", "size-hor", "size_hor",
                                               "028006030e0e7ebffc7f7070c0600140", "14fef782d02440884392942c1120523"]),
    "sb_v_double_arrow": ("north_south_resize", ["ns-resize", "v_double_arrow", "double_arrow", "size-ver", "size_ver",
                                                 "00008160000006810000408080010102", "2870a09082c103050810ffdffffe0204"]),
    "right_side": ("east_resize", ["e-resize"]),
    "left_side": ("west_resize", ["w-resize"]),
    "top_side": ("north_resize", ["n-resize"]),
    "bottom_side": ("south_resize", ["s-resize"]),
    "top_right_corner": ("north_east_resize", ["ne-resize"]),
    "top_left_corner": ("north_west_resize", ["nw-resize"]),
    "bottom_right_corner": ("south_east_resize", ["se-resize"]),
    "bottom_left_corner": ("south_west_resize", ["sw-resize"]),
    "fd_double_arrow": ("north_east_south_west_resize", ["nesw-resize", "size_bdiag", "fcf1c3c7cd4491d801f1e1c78f100000"]),
    "bd_double_arrow": ("north_west_south_east_resize", ["nwse-resize", "size_fdiag", "c7088f0f3e6c8088236ef8e1e3e70000"]),
    "zoom-in": ("zoom_in", ["zoom_in"]),
    "zoom-out": ("zoom_out", ["zoom_out"]),
}
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def decode_png(data):
    """8-bit RGBA, not interlaced -> (width, height, bytearray of RGBA rows)."""
    if data[:8] != PNG_MAGIC:
        raise ValueError("frame is not a PNG")
    pos, idat, head = 8, [], None
    while pos < len(data):
        length, kind = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            head = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
        pos += 12 + length
    w, h, depth, colour, _, _, interlace = head
    if (depth, colour, interlace) != (8, 6, 0):
        raise ValueError(f"unsupported PNG kind (depth {depth}, colour type {colour}, interlace {interlace})")
    raw = zlib.decompress(b"".join(idat))
    stride, out, prev = w * 4, bytearray(), bytearray(w * 4)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - 4] if i >= 4 else 0
            b = prev[i]
            c = prev[i - 4] if i >= 4 else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line
        prev = line
    return w, h, out


def read_cur(path):
    """-> list of (width, height, hot_x, hot_y, premultiplied BGRA bytes), smallest first."""
    data = open(path, "rb").read()
    _, kind, count = struct.unpack_from("<HHH", data, 0)
    if kind != 2:
        raise ValueError("not a .cur file")
    frames = []
    for i in range(count):
        _, _, _, _, hot_x, hot_y, size, offset = struct.unpack_from("<BBBBHHII", data, 6 + 16 * i)
        w, h, rgba = decode_png(data[offset:offset + size])
        bgra = bytearray(len(rgba))
        for p in range(0, len(rgba), 4):
            r, g, b, a = rgba[p:p + 4]
            bgra[p:p + 4] = bytes(((b * a + 127) // 255, (g * a + 127) // 255, (r * a + 127) // 255, a))
        frames.append((w, h, hot_x, hot_y, bgra))
    return fix_hotspots(sorted(frames, key=lambda fr: fr[0]))


def fix_hotspots(frames):
    """Some sets carry a wrong hotspot in one size (the big size's numbers copied into a small
    frame, or 0,0). The sizes are the same drawing scaled, so a hotspot that disagrees with the
    others (median, as a fraction of the size) is replaced by the agreed one."""
    def median(values):
        v = sorted(values)
        return (v[(len(v) - 1) // 2] + v[len(v) // 2]) / 2
    if len(frames) < 3:
        return frames
    mx = median([f[2] / f[0] for f in frames])
    my = median([f[3] / f[1] for f in frames])
    out = []
    for w, h, hot_x, hot_y, px in frames:
        tol = max(1.5, 0.05 * w)
        if abs(hot_x - mx * w) > tol or abs(hot_y - my * h) > tol:
            hot_x, hot_y = round(mx * w), round(my * h)
        out.append((w, h, hot_x, hot_y, px))
    return out


def halve(frame):
    """A frame at half the size (2x2 average): for sets that lack a small size."""
    w, h, hot_x, hot_y, px = frame
    nw, nh, out = w // 2, h // 2, bytearray((w // 2) * (h // 2) * 4)
    for y in range(nh):
        for x in range(nw):
            for c in range(4):
                s = sum(px[((2 * y + dy) * w + 2 * x + dx) * 4 + c] for dy in (0, 1) for dx in (0, 1))
                out[(y * nw + x) * 4 + c] = (s + 2) // 4
    return nw, nh, hot_x // 2, hot_y // 2, out


def write_xcursor(path, frames):
    toc, chunks, pos = b"", b"", 16 + 12 * len(frames)
    for w, h, hot_x, hot_y, px in frames:
        nominal = round(w * 0.75)
        chunk = struct.pack("<9I", 36, 0xFFFD0002, nominal, 1, w, h, min(hot_x, w - 1), min(hot_y, h - 1), 0) + bytes(px)
        toc += struct.pack("<3I", 0xFFFD0002, nominal, pos)
        chunks += chunk
        pos += len(chunk)
    with open(path, "wb") as f:
        f.write(struct.pack("<4s3I", b"Xcur", 16, 0x10000, len(frames)) + toc + chunks)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("src")
    ap.add_argument("dest")
    ap.add_argument("--name", default=None)
    ap.add_argument("--inherits", default="Bibata-Modern-Classic")
    args = ap.parse_args()

    cursors = os.path.join(args.dest, "cursors")
    os.makedirs(cursors, exist_ok=True)
    made = missing = 0
    for target, (source, links) in SHAPES.items():
        cur = os.path.join(args.src, source + ".cur")
        if not os.path.isfile(cur):
            missing += 1
            continue
        frames = read_cur(cur)
        sizes = {f[0] for f in frames}
        for want in (64, 32):                      # every cursor gets the two common sizes
            if want not in sizes and 2 * want in sizes:
                frames.append(halve(next(f for f in frames if f[0] == 2 * want)))
                sizes.add(want)
        frames.sort(key=lambda fr: fr[0])
        out = os.path.join(cursors, target)
        if os.path.islink(out):
            os.unlink(out)
        write_xcursor(out, frames)
        made += 1
        for link in links:
            lp = os.path.join(cursors, link)
            if os.path.islink(lp) or os.path.exists(lp):
                os.unlink(lp)
            os.symlink(target, lp)
    name = args.name or os.path.basename(os.path.normpath(args.dest))
    theme = f"[Icon Theme]\nName={name}\nComment=Converted by hypr-setup/cursor/cur2xcursor.py\nInherits={args.inherits}\n"
    for fn in ("index.theme", "cursor.theme"):
        with open(os.path.join(args.dest, fn), "w") as f:
            f.write(theme)
    print(f"{name}: {made} cursors written to {cursors}" + (f" ({missing} not in the set: inherited)" if missing else ""))
    return 0 if made else 1


if __name__ == "__main__":
    sys.exit(main())
