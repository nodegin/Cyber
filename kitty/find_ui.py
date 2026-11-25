#!/usr/bin/env python
# find_ui.py: the overlay half of find.py. Keys and mappings are documented in find.py.
#
# kitty runs this as an overlay on top of the window being searched. stdin is the
# snapshot that find.py took: a JSON header line, then the scrollback and screen
# as ANSI text. The view is redrawn from that snapshot with the same colours and
# the same top line, so opening find does not move anything on screen.
# handle_result() below runs inside kitty after the overlay closes, and scrolls
# the real window so it shows exactly what the find view showed.

import base64
import json
import re
import sys
from bisect import bisect_left, bisect_right

from kittens.tui.handler import Handler, result_handler
from kittens.tui.loop import EventType as MouseEventType
from kittens.tui.loop import Loop, MouseButton
from kittens.tui.operations import MouseTracking
from kitty.fast_data_types import wcswidth
from kitty.key_encoding import EventType


def sgr(*parts: str) -> str:
    return '\x1b[' + ';'.join(parts) + 'm'


def fg(r: int, g: int, b: int) -> str:
    return f'38;2;{r};{g};{b}'


def bg(r: int, g: int, b: int) -> str:
    return f'48;2;{r};{g};{b}'


# Look: a dark bar with a thin cyan frame. Matches are amber, the current match is cyan.
CYAN = (60, 240, 255)
BAR_BG = bg(14, 16, 22)
FRAME = sgr('0', fg(*CYAN), BAR_BG)
TEXT = sgr('0', fg(226, 230, 238), BAR_BG)
DIM = sgr('0', fg(104, 112, 124), BAR_BG)
COUNT = sgr('0', fg(150, 160, 176), BAR_BG)
RED = sgr('0', fg(255, 99, 112), BAR_BG)
SELECTED = sgr('0', fg(240, 250, 255), bg(36, 82, 92))
CHIP = {
    'on': sgr('0', '1', fg(*CYAN), bg(26, 58, 66)),
    'auto': sgr('0', fg(*CYAN), BAR_BG),  # smart case made the search case-sensitive
    'off': sgr('0', fg(88, 96, 108), BAR_BG),
}
HIGHLIGHT = {
    False: sgr('0', fg(24, 20, 12), bg(240, 178, 50)),  # other matches
    True: sgr('0', fg(8, 22, 26), bg(*CYAN)),  # current match
}
BAR_WIDTH = 46
BAR_HEIGHT = 3
WHEEL_LINES = 3

# Escape sequences that can appear in kitty's ANSI output: CSI (SGR), OSC
# (hyperlinks), string commands, and two-byte escapes.
ESC = r'\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[PX^_][^\x1b]*\x1b\\|\x1b[ -/]*[0-~]'
ESC_RE = re.compile(ESC)
SPLIT_RE = re.compile(f'({ESC})')
SGR_RESETS = ('\x1b[m', '\x1b[0m')


def cells(text: str) -> int:
    'Width in cells of the start of a line. Tab stops are every 8 columns, as in a fresh terminal.'
    if '\t' not in text:
        return wcswidth(text)
    col = 0
    for i, chunk in enumerate(text.split('\t')):
        if i:
            col = (col // 8 + 1) * 8
        col += wcswidth(chunk)
    return col


class Doc:
    'The snapshot: physical lines (as on screen) plus one searchable string of logical lines.'

    def __init__(self, body: str):
        parts = re.split('(\r\n|\r)', body)
        ansi = parts[0::2]
        terms = parts[1::2]
        if len(ansi) > len(terms):
            if ansi[-1]:
                terms.append('\n')
            else:
                ansi.pop()
        soft = [t == '\r' for t in terms]
        if soft:
            soft[-1] = False
        plain = [ESC_RE.sub('', a) if '\x1b' in a else a for a in ansi]
        # Soft-wrapped rows are joined, so a match can cross a wrap.
        offs = [0] * len(plain)
        chunks = []
        pos = 0
        for i, p in enumerate(plain):
            offs[i] = pos
            chunks.append(p)
            pos += len(p)
            if not soft[i]:
                chunks.append('\n')
                pos += 1
        self.ansi, self.plain, self.offs = ansi, plain, offs
        self.text = ''.join(chunks)
        self._lower: str | None = None

    def __len__(self) -> int:
        return len(self.ansi)

    def line_of(self, pos: int) -> int:
        return max(0, bisect_right(self.offs, pos) - 1)

    def end_of(self, line: int) -> int:
        return self.offs[line] + len(self.plain[line])

    def lower(self) -> str | None:
        if self._lower is None:
            low = self.text.lower()
            # Offsets only line up when lowercasing kept every character's length.
            self._lower = low if len(low) == len(self.text) else ''
        return self._lower or None

    def find(self, query: str, regex: bool, case_sensitive: bool) -> tuple[list[int], list[int]]:
        starts: list[int] = []
        if not regex:
            hay, needle = self.text, query
            if not case_sensitive:
                low = self.lower()
                if low is None:
                    return self._find_re(re.compile(re.escape(query), re.IGNORECASE))
                hay, needle = low, query.lower()
            n = len(needle)
            find = hay.find
            i = find(needle)
            while i > -1:
                starts.append(i)
                i = find(needle, i + n)
            return starts, [s + n for s in starts]
        return self._find_re(re.compile(query, re.MULTILINE | (0 if case_sensitive else re.IGNORECASE)))

    def _find_re(self, pat: 're.Pattern[str]') -> tuple[list[int], list[int]]:
        starts: list[int] = []
        ends: list[int] = []
        for m in pat.finditer(self.text):
            s, e = m.span()
            if e > s:  # zero-width matches (^, \b, x*) have nothing to highlight
                starts.append(s)
                ends.append(e)
        return starts, ends


def render_line(ansi: str, ranges: list[tuple[int, int, bool]] | None) -> str:
    'Re-emit one row of kitty ANSI output with highlight colours over the given character ranges.'
    if not ranges:
        return ansi
    out: list[str] = []
    state: list[str] = []  # SGR codes since the last reset, to restore after a highlight
    pos = 0
    ri = 0
    in_hl = False
    for k, piece in enumerate(SPLIT_RE.split(ansi)):
        if k & 1:
            if piece.startswith('\x1b[') and piece.endswith('m'):
                if piece in SGR_RESETS:
                    state = []
                else:
                    state.append(piece)
                if in_hl:
                    continue
            out.append(piece)
            continue
        end = pos + len(piece)
        p = pos
        while p < end:
            while ri < len(ranges) and ranges[ri][1] <= p:
                ri += 1
            if ri < len(ranges) and ranges[ri][0] <= p:
                s, e, current = ranges[ri]
                stop = min(end, e)
                if not in_hl:
                    out.append(HIGHLIGHT[current])
                    in_hl = True
                out.append(piece[p - pos : stop - pos])
                p = stop
                if stop == e:
                    out.append('\x1b[m' + ''.join(state))
                    in_hl = False
                    ri += 1
            else:
                stop = min(end, ranges[ri][0]) if ri < len(ranges) else end
                out.append(piece[p - pos : stop - pos])
                p = stop
        pos = end
    return ''.join(out)


class FindUI(Handler):
    use_alternate_screen = True
    mouse_tracking = MouseTracking.buttons_only
    overlay_ready_report_needed = True  # kitty keeps the overlay hidden until the first frame is drawn

    def __init__(self, doc: Doc, meta: dict, saved: dict):
        self.doc = doc
        self.meta = meta
        self.query = str(saved.get('query') or '')
        self.cursor = len(self.query)
        self.all_selected = bool(self.query)
        self.case_sensitive = bool(saved.get('case', False))
        self.regex = bool(saved.get('regex', False))
        self.starts: list[int] = []
        self.ends: list[int] = []
        self.cur = -1
        self.error = ''
        self.top = 0
        self.anchor = 0
        self.revealed = False  # False until the user types or navigates: opening find never scrolls
        self.bar_bottom = False
        self.search_dirty = bool(self.query)
        self.update_pending = False
        self.finished = False
        self.field_x0 = 0
        self.field_start = 0

    # -- setup ---------------------------------------------------------------------

    def initialize(self) -> None:
        self.rows, self.cols = self.screen_size.rows, self.screen_size.cols
        n = len(self.doc)
        self.top = max(0, min(self.meta['hist'] - self.meta['scrolled_by'], self.max_top))
        bottom = min(n, self.top + self.rows)
        # The first match is the newest one above the bottom of the view.
        self.anchor = self.doc.offs[bottom] if bottom < n else len(self.doc.text)
        self.cmd.set_window_title(self.meta.get('title') or 'find')
        self.write('\x1b[?7l')  # no auto-wrap: rows are drawn at exactly the window width
        self.update()

    @property
    def max_top(self) -> int:
        return max(0, len(self.doc) - self.rows)

    def on_resize(self, new_size) -> None:
        super().on_resize(new_size)
        if (new_size.rows, new_size.cols) != (getattr(self, 'rows', new_size.rows), getattr(self, 'cols', new_size.cols)):
            # The real window has reflowed, so the snapshot no longer matches it.
            self.finish(keep_view=False)

    def on_term(self) -> None:
        self.quit_loop(1)

    # -- searching -----------------------------------------------------------------

    def effective_case(self) -> bool:
        if self.case_sensitive:
            return True
        q = re.sub(r'\\.', '', self.query) if self.regex else self.query
        return any(c.isupper() for c in q)  # smart case

    def run_search(self) -> None:
        self.search_dirty = False
        self.error = ''
        self.starts, self.ends, self.cur = [], [], -1
        if not self.query:
            return
        try:
            self.starts, self.ends = self.doc.find(self.query, self.regex, self.effective_case())
        except re.error:
            self.error = 'bad regex'
            return
        if self.starts:
            j = bisect_left(self.starts, self.anchor) - 1
            self.cur = j if j >= 0 else len(self.starts) - 1
            if self.revealed:
                self.ensure_visible()

    def query_changed(self) -> None:
        self.search_dirty = True
        self.revealed = True
        self.schedule()

    def schedule(self) -> None:
        # Coalesce: all input that arrived together leads to one search and one redraw.
        if not self.update_pending and not self.finished:
            self.update_pending = True
            self.asyncio_loop.call_soon(self.update)

    def update(self) -> None:
        self.update_pending = False
        if self.finished:
            return
        if self.search_dirty:
            self.run_search()
        self.draw()

    # -- navigation ----------------------------------------------------------------

    def match_lines(self, idx: int) -> tuple[int, int]:
        return self.doc.line_of(self.starts[idx]), self.doc.line_of(self.ends[idx] - 1)

    def is_visible(self, idx: int, top: int) -> bool:
        ls, le = self.match_lines(idx)
        return top <= ls and le < top + self.rows and not self.bar_hides(idx, top)

    def go(self, delta: int) -> None:
        'delta=-1: older match, delta=+1: newer match. Both wrap.'
        if self.search_dirty:
            self.run_search()
        if self.cur < 0:
            self.schedule()
            return
        if self.revealed or self.is_visible(self.cur, self.top):
            self.cur = (self.cur + delta) % len(self.starts)
        # else: the first key press shows the preselected match instead of skipping it
        self.revealed = True
        self.anchor = self.starts[self.cur] + 1
        self.ensure_visible()
        self.schedule()

    def ensure_visible(self) -> None:
        ls, le = self.match_lines(self.cur)
        top = self.top
        if not (top <= ls and le < top + self.rows):
            top = ls - max(0, (self.rows - (le - ls + 1)) // 2)  # centre it
            top = max(0, min(top, self.max_top))
        self.bar_bottom = False
        if self.bar_hides(self.cur, top):
            if ls >= BAR_HEIGHT:
                top = min(top, ls - BAR_HEIGHT)  # scroll just enough to get it out from under the bar
            else:
                self.bar_bottom = True
        self.top = top

    def scroll(self, delta: int) -> None:
        top = max(0, min(self.top + delta, self.max_top))
        if top != self.top:
            self.top = top
            self.bar_bottom = False
            self.schedule()

    # -- the bar -------------------------------------------------------------------

    def bar_geometry(self) -> tuple[int, int, int]:
        bw = min(BAR_WIDTH, self.cols)
        bx = self.cols - bw - (1 if self.cols - bw >= 4 else 0)
        by = max(0, self.rows - BAR_HEIGHT) if self.bar_bottom else 0
        return bx, by, bw

    def bar_hides(self, idx: int, top: int) -> bool:
        bx, by, bw = self.bar_geometry()
        s, e = self.starts[idx], self.ends[idx]
        ls, le = self.match_lines(idx)
        for line in range(ls, le + 1):
            if by <= line - top < by + BAR_HEIGHT:
                lo, plain = self.doc.offs[line], self.doc.plain[line]
                c0 = cells(plain[: max(s, lo) - lo])
                c1 = cells(plain[: min(e, lo + len(plain)) - lo])
                if c0 < bx + bw and c1 > bx:
                    return True
        return False

    def chip_states(self) -> tuple[str, str]:
        case = 'on' if self.case_sensitive else ('auto' if self.effective_case() else 'off')
        return case, 'on' if self.regex else 'off'

    def counter(self) -> tuple[str, str]:
        if not self.query:
            return '', COUNT
        if self.error:
            return self.error, RED
        if not self.starts:
            return 'no results', RED
        n = len(self.starts)
        return f'{n - self.cur}/{n}', COUNT  # 1 is the newest match

    def field(self, width: int) -> tuple[str, int]:
        q = self.query
        if not q:
            ph = 'Find'[:width]
            self.field_start = 0
            return DIM + ph + ' ' * (width - len(ph)), 0
        start = min(self.field_start, self.cursor)
        while start < self.cursor and wcswidth(q[start : self.cursor]) > width - 1:
            start += 1
        self.field_start = start
        end = start
        while end < len(q) and wcswidth(q[start : end + 1]) <= width:
            end += 1
        vis = q[start:end]
        style = SELECTED if self.all_selected else TEXT
        return style + vis + TEXT + ' ' * max(0, width - wcswidth(vis)), wcswidth(q[start : self.cursor])

    def bar(self) -> tuple[str, int, int]:
        bx, by, bw = self.bar_geometry()
        inner = bw - 2
        counter, counter_style = self.counter()
        chips, chips_w = '', 0
        if inner >= 24:
            case, rx = self.chip_states()
            chips, chips_w = CHIP[case] + ' Aa ' + CHIP[rx] + ' .* ', 8
        right = (counter_style + counter + TEXT + ' ') if counter else ''
        right_w = (len(counter) + 1 if counter else 0) + chips_w
        field_w = max(1, inner - 2 - right_w)
        field, cx = self.field(field_w)
        mid = TEXT + ' ' + field + TEXT + ' ' + right + chips
        self.field_x0 = bx + 2
        lines = (
            FRAME + '╭' + '─' * inner + '╮',
            FRAME + '│' + mid + FRAME + '│',
            FRAME + '╰' + '─' * inner + '╯',
        )
        if self.rows >= BAR_HEIGHT:
            out = ''.join(f'\x1b[{by + r + 1};{bx + 1}H' + lines[r] for r in range(BAR_HEIGHT))
            cursor_y = by + 1
        else:  # a tiny window: just the middle row
            out, cursor_y = f'\x1b[1;{bx + 1}H' + lines[1], 0
        return out + '\x1b[m', cursor_y, self.field_x0 + cx

    # -- drawing -------------------------------------------------------------------

    def draw(self) -> None:
        doc, rows, top = self.doc, self.rows, self.top
        bottom = min(len(doc), top + rows)
        per_line: dict[int, list[tuple[int, int, bool]]] = {}
        if self.starts and bottom > top:
            view_start, view_end = doc.offs[top], doc.end_of(bottom - 1)
            j = bisect_right(self.ends, view_start)
            while j < len(self.starts) and self.starts[j] < view_end:
                s, e = self.starts[j], self.ends[j]
                line = max(top, doc.line_of(s))
                while line < bottom and doc.offs[line] < e:
                    lo = doc.offs[line]
                    a, b = max(s, lo) - lo, min(e, doc.end_of(line)) - lo
                    if b > a:
                        per_line.setdefault(line, []).append((a, b, j == self.cur))
                    line += 1
                j += 1
        out = ['\x1b[?2026h\x1b[?25l']
        for r in range(rows):
            line = top + r
            out.append(f'\x1b[{r + 1}H\x1b[m\x1b[2K')
            if line < bottom:
                out.append(render_line(doc.ansi[line], per_line.get(line)))
                out.append('\x1b[m')
        bar, cy, cx = self.bar()
        out.append(bar)
        out.append(f'\x1b[{cy + 1};{cx + 1}H\x1b[?25h\x1b[?2026l')
        self.write(''.join(out))

    # -- input ---------------------------------------------------------------------

    def insert(self, text: str) -> None:
        text = ''.join(c for c in text if c >= ' ' and c != '\x7f')
        if not text:
            return
        if self.all_selected:
            self.query, self.cursor, self.all_selected = '', 0, False
        self.query = self.query[: self.cursor] + text + self.query[self.cursor :]
        self.cursor += len(text)
        self.query_changed()

    def set_query(self, query: str, cursor: int) -> None:
        changed = query != self.query
        self.query, self.cursor, self.all_selected = query, cursor, False
        if changed:
            self.query_changed()
        else:
            self.schedule()

    def word_start(self) -> int:
        m = re.search(r'(\w+|[^\w\s]+)\s*$', self.query[: self.cursor])
        return m.start() if m else len(self.query[: self.cursor].rstrip())

    def word_end(self) -> int:
        m = re.match(r'\s*(\w+|[^\w\s]+)', self.query[self.cursor :])
        return self.cursor + (m.end() if m else len(self.query) - self.cursor)

    def on_text(self, text: str, in_bracketed_paste: bool = False) -> None:
        self.insert(text.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ') if in_bracketed_paste else text)

    def perform_default_key_action(self, key_event) -> bool:
        return False  # ctrl+c / ctrl+d are handled in on_key_event

    def on_interrupt(self) -> None:
        self.finish()

    def on_key_event(self, ev, in_bracketed_paste: bool = False) -> None:
        if ev.type is EventType.RELEASE or self.finished:
            return
        m = ev.matches
        q, c = self.query, self.cursor
        if m('escape') or m('ctrl+c') or m('ctrl+g'):
            self.finish()
        elif m('enter') or m('kp_enter') or m('up') or m('f3'):
            self.go(-1)
        elif m('shift+enter') or m('shift+kp_enter') or m('down') or m('shift+f3'):
            self.go(1)
        elif m('alt+c'):
            self.case_sensitive = not self.case_sensitive
            self.query_changed()
        elif m('alt+r'):
            self.regex = not self.regex
            self.query_changed()
        elif m('page_up') or m('shift+page_up'):
            self.scroll(-(self.rows - 1))
        elif m('page_down') or m('shift+page_down'):
            self.scroll(self.rows - 1)
        elif m('shift+up') or m('ctrl+shift+up'):
            self.scroll(-1)
        elif m('shift+down') or m('ctrl+shift+down'):
            self.scroll(1)
        elif m('ctrl+home'):
            self.scroll(-len(self.doc))
        elif m('ctrl+end'):
            self.scroll(len(self.doc))
        elif m('ctrl+a') or m('ctrl+f') or m('ctrl+shift+f'):
            self.all_selected, self.cursor = bool(q), len(q)
            self.schedule()
        elif m('ctrl+u'):
            self.set_query('', 0)
        elif self.all_selected and (m('backspace') or m('delete') or m('ctrl+w') or m('ctrl+backspace') or m('alt+backspace')):
            self.set_query('', 0)
        elif m('backspace'):
            if c:
                self.set_query(q[: c - 1] + q[c:], c - 1)
        elif m('delete') or m('ctrl+d'):
            if c < len(q):
                self.set_query(q[:c] + q[c + 1 :], c)
        elif m('ctrl+w') or m('ctrl+backspace') or m('alt+backspace'):
            w = self.word_start()
            self.set_query(q[:w] + q[c:], w)
        elif m('ctrl+delete') or m('alt+d'):
            self.set_query(q[:c] + q[self.word_end() :], c)
        elif m('left'):
            self.set_query(q, 0 if self.all_selected else max(0, c - 1))
        elif m('right'):
            self.set_query(q, len(q) if self.all_selected else min(len(q), c + 1))
        elif m('ctrl+left') or m('alt+left') or m('alt+b'):
            self.set_query(q, self.word_start())
        elif m('ctrl+right') or m('alt+right') or m('alt+f'):
            self.set_query(q, self.word_end())
        elif m('home'):
            self.set_query(q, 0)
        elif m('end') or m('ctrl+e'):
            self.set_query(q, len(q))
        elif not (ev.ctrl or ev.alt or ev.super or ev.hyper or ev.meta):
            text = ev.text
            if not text and len(ev.key) == 1:  # synthesized keys (e.g. kitty's send_key) carry no text
                text = ev.shifted_key if ev.shift and ev.shifted_key else ev.key
            self.insert(text)

    def on_mouse_event(self, ev) -> None:
        if ev.type is not MouseEventType.PRESS or self.finished:
            return
        if ev.buttons == MouseButton.WHEEL_UP:
            self.scroll(-WHEEL_LINES)
            return
        if ev.buttons == MouseButton.WHEEL_DOWN:
            self.scroll(WHEEL_LINES)
            return
        bx, by, bw = self.bar_geometry()
        if not (bx <= ev.cell_x < bx + bw and by <= ev.cell_y < by + BAR_HEIGHT):
            self.finish()  # a click in the text: close, so selection works in the real window
            return
        if ev.buttons != MouseButton.LEFT:
            return
        chips_x = bx + bw - 1 - 8
        if bw - 2 >= 24 and chips_x <= ev.cell_x < chips_x + 4:
            self.case_sensitive = not self.case_sensitive
            self.query_changed()
        elif bw - 2 >= 24 and chips_x + 4 <= ev.cell_x < chips_x + 8:
            self.regex = not self.regex
            self.query_changed()
        elif ev.cell_x >= self.field_x0:
            q, start, x = self.query, self.field_start, ev.cell_x - self.field_x0
            k = start
            while k < len(q) and wcswidth(q[start : k + 1]) <= x:
                k += 1
            self.set_query(q, k)

    # -- closing -------------------------------------------------------------------

    def finish(self, keep_view: bool = True) -> None:
        if self.finished:
            return
        if self.search_dirty:
            self.run_search()  # input that arrived together with Esc still counts
        self.finished = True
        result = {
            'top': self.top if keep_view and self.cur >= 0 else None,
            'lines': self.meta['lines'],
            'cols': self.meta['cols'],
        }
        payload = base64.b85encode(json.dumps(result).encode('utf-8'))
        # Hand the result to kitty now (handle_result() runs when the overlay closes),
        # then freeze rendering. The terminal reset that follows on exit must not
        # flash an empty overlay for one frame before kitty removes it.
        self.write(b'\x1bP@kitty-kitten-result|' + payload + b'\x1b\\')
        self.write('\x1b[?2026h')
        self.quit_loop(0)


def main(args: list[str]) -> None:
    from kitty.config import cached_values_for

    raw = sys.stdin.buffer.read().decode('utf-8', 'replace')
    header, _, body = raw.partition('\n')
    meta = json.loads(header)
    doc = Doc(body)
    with cached_values_for('find-kitten') as saved:
        ui = FindUI(doc, meta, saved)
        Loop().loop(ui)
        if ui.query:
            saved['query'] = ui.query
        saved['case'], saved['regex'] = ui.case_sensitive, ui.regex
    # The result was already written by FindUI.finish(); returning None avoids a second one.


@result_handler(has_ready_notification=True)
def handle_result(args: list[str], data, target_window_id: int, boss) -> None:
    # Runs inside kitty once the overlay has closed.
    w = boss.window_id_map.get(target_window_id)
    if w is None or not isinstance(data, dict) or data.get('top') is None:
        return  # no match: the real window was never touched, so it is still where it was
    s = w.screen
    if s.is_using_alternate_linebuf() or (s.lines, s.columns) != (data['lines'], data['cols']):
        return
    # Row indices count from the oldest scrollback line, so they stay valid while new
    # output is appended (unless the scrollback is full and old lines fall off).
    hist = s.historybuf.count
    target = max(0, min(hist, hist - int(data['top'])))
    finish_animation = getattr(w, 'finish_scroll_animation', None)
    if finish_animation is not None:
        finish_animation()
    s.scroll_to_absolute(float(target))
