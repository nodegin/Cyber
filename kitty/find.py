#!/usr/bin/env python
# find.py: an iTerm2-style "find in terminal" bar for kitty (written against kitty 0.51).
#
#   map ctrl+f      kitten ~/.local/share/cyber/kitty/find.py --alt-screen-key=ctrl+f
#   map kitty_mod+f kitten ~/.local/share/cyber/kitty/find.py
#
# A compact bar opens at the top-right over the unchanged terminal view.
# Matches are highlighted as you type.
#
#   type ............... search live. Smart case: case-insensitive unless the
#                        query has a capital letter.
#   Enter / Up / F3 .... older match  (the first match is the newest one above
#                        the bottom of the view)
#   Shift+Enter / Down . newer match  (Shift+F3 too; both directions wrap around)
#   Alt+C .............. toggle "match case" (the Aa chip)
#   Alt+R .............. toggle regex (the .* chip)
#   PgUp / PgDn, wheel . scroll the view  (Shift+Up / Shift+Down: one line)
#   Ctrl+A or Ctrl+F ... select the whole query    Ctrl+U clear    Ctrl+W delete word
#   Esc ................ close; the terminal stays scrolled to the current match
#                        (if there is no match, it stays where it was)
#   click in the text .. close (so normal mouse selection works again)
#
# --alt-screen-key=KEY: when the window shows a full-screen app (less, vim,
# htop...), send KEY to that app instead of opening find. This keeps Ctrl+F as
# "page down" in less and vim.
#
# The previous query and chip states are remembered in ~/.cache/kitty/find-kitten.json.
# find_ui.py (next to this file) is the overlay UI; this file runs inside kitty,
# snapshots the window, and starts it.

import json
import os

from kittens.tui.handler import result_handler

# realpath: a symlink to this file in ~/.config/kitty still finds find_ui.py next to the real file
UI_KITTEN = os.path.join(os.path.dirname(os.path.realpath((lambda: 0).__code__.co_filename)), 'find_ui.py')


def main(args: list[str]) -> None:
    raise SystemExit('find.py has to be run from a kitty.conf mapping, e.g.:  map ctrl+f kitten /path/to/find.py')


def snapshot(w) -> bytes:
    # Scrollback + screen as ANSI text, one physical line per row. kitty ends every
    # row with \r; a hard line end adds \n, so "\r" alone marks a soft wrap.
    # The scrollback pager history is not included on purpose: the real window
    # cannot scroll there, so a match in it could not be shown after closing.
    s = w.screen
    alt = bool(s.is_using_alternate_linebuf())
    parts: list[str] = []
    if not alt:
        s.as_text_for_history_buf(parts.append, True, True)
    s.as_text_non_visual(parts.append, True, True)
    meta = {
        'hist': 0 if alt else s.historybuf.count,
        'scrolled_by': 0 if alt else s.scrolled_by,
        'lines': s.lines,
        'cols': s.columns,
        'alt': alt,
        'title': w.title or '',
    }
    return (json.dumps(meta) + '\n' + ''.join(parts)).encode('utf-8', 'replace')


@result_handler(no_ui=True)
def handle_result(args: list[str], answer, target_window_id: int, boss) -> None:
    w = boss.window_id_map.get(target_window_id)
    if w is None:
        return
    if not getattr(w, 'kitty_find_overlay', False):
        w = next((x for x in boss.window_id_map.values() if getattr(x, 'kitty_find_overlay', 0) == w.id), w)
    if getattr(w, 'kitty_find_overlay', False):
        # Find is already open on this window: let it select its query (like Cmd+F in iTerm2).
        w.send_key('ctrl+f')
        return
    alt_key = ''
    for a in args[1:]:
        if a.startswith('--alt-screen-key='):
            alt_key = a.partition('=')[2]
    if alt_key and w.screen.is_using_alternate_linebuf():
        w.send_key(alt_key)
        return
    overlay = boss.run_kitten_with_metadata(UI_KITTEN, input_data=snapshot(w), window=w)
    if overlay is not None:
        overlay.kitty_find_overlay = w.id  # marks the overlay and remembers which window it searches
