"""Screen bodies for the Waycar Apple Watch V0 mockups (W1 to W6, Live Activity, notification).

Imported by make_mockups.py, which adds the spec sheets, flow board, gallery, and file output.
Primitives live in mockup_kit.py.
"""
import math

from mockup_kit import *  # noqa: F401,F403


# ---------------------------------------------------------------- W1 list
def count_pills(s, x, y):
    """Idle drops first when the row does not fit (ViewThatFits). Digits SF Mono, status ink."""
    f = s.fn1[0]
    g = s.ph * .55
    pills = [('blocked', 1), ('done', 1), ('working', 2), ('idle', 1)]
    pw = lambda c: s.php + g + 3 + tw(str(c), f, True) + s.php
    while sum(pw(c) for _, c in pills) + s.pg * (len(pills) - 1) > s.W - 2 * s.m:
        pills.pop()
    o = []
    for i, (st, cnt) in enumerate(pills):
        w = pw(cnt)
        o.append(rect(x, y, w, s.ph, s.ph / 2, WASH[st], WASH_OP))
        o.append(glyph(st, x + s.php + g / 2, y + s.ph / 2, g, st))
        o.append(T(x + s.php + g + 3, y + s.ph / 2 + .35 * f, str(cnt), f, st, 600, True))
        if i == 0:
            A['cpill1'] = (x, y, w, s.ph)
        x += w + s.pg
    A['npills'] = len(pills)
    return ''.join(o)


def agent_row(s, y, a):
    x, w = s.m, s.W - 2 * s.m
    tx, maxw = x + s.rp, w - 2 * s.rp
    top = y + (s.row - s.head[1] - s.fn1[1]) / 2
    title = trunc(a['title'], s.head[0], maxw, bold=True)
    o = rect(x, y, w, s.row, s.rr, 'plat') + T(tx, bl(top, s.head), title, s.head[0], 'fg', 600) + \
        status_line(s, tx, top + s.head[1], a['st'], [a['age'], a['host']], maxw)
    return o, dict(rect=(x, y, w, s.row), tx=tx, title_mid=top + s.head[1] / 2,
                   title_end=tx + tw(title, s.head[0], bold=True), status_mid=top + s.head[1] + s.fn1[1] / 2,
                   status_end=A['sl'][2])


def w1(s, u, stale=False):
    o = [status_bar(s, 'Waycar')]
    y = s.tb + 2
    if stale:  # pinned under the top bar, above the pills
        f = s.fn1[0]
        g = s.ig
        avail = s.W - 2 * s.m - g - s.igap
        segs = ['iPhone not reachable', '3m ago']  # wraps at the segment boundary, never mid-phrase
        lines = [' · '.join(segs)] if tw(' · '.join(segs), f, bold=True) <= avail else segs
        wt = 600 if tw(lines[0], f, bold=True) <= avail else None
        o.append(glyph('iphone', s.m + g / 2, y + s.fn1[1] / 2, g, 'danger'))
        for i, ln in enumerate(lines):
            o.append(T(s.m + g + s.igap, bl(y + i * s.fn1[1], s.fn1), ln, f, 'fg2' if i else 'danger', None if i else wt))
        y += s.fn1[1] * len(lines) + s.rh
        o.append('<g opacity="0.45">')
    o.append(count_pills(s, s.m, y))
    y += s.ph + s.rh
    rows = []
    for a in AGENTS:
        svg, info = agent_row(s, y, a)
        o.append(svg)
        rows.append(info)
        y += s.row + s.rg
    A['rows'] = rows
    return ''.join(o) + ('</g>' if stale else '')


def w1_stale(s, u):
    return w1(s, u, stale=True)


# ---------------------------------------------------------------- detail screens
def head_items(s, st, segs, title):
    """Content head: status line (row line 2 anatomy), gap 2, title (Headline, <=2 lines)."""
    return [item_status(s, st, segs), 2, item_title(s, title), s.rh]


def w2(s, u):
    return detail(s, u, head_items(s, 'done', ['4m', 'studio'], 'site · codex') + [item_body(s, LATEST)], mic=True)


def w3_items(s, tail):
    return head_items(s, 'blocked', ['1m', 'studio'], 'waycar · claude') + [
        item_kicker(s, 'WANTS TO RUN'), 4, item_command(s, COMMAND), s.rh] + tail


def w3_buttons(s):
    return [item_capsule(s, 'Allow', 'check', 'accent', 'white', key='allow'), s.rh,
            item_capsule(s, 'Deny', 'xmark', 'glass', 'danger', key='deny')]


def w3(s, u):
    return detail(s, u, w3_items(s, w3_buttons(s)))


def w3_end(s, u):
    return detail(s, u, w3_items(s, w3_buttons(s)), anchor='bottom')


def w3_allowed(s, u):
    """Buttons replaced by the stamp; status line shows the phone's next state (Working)."""
    items = head_items(s, 'working', ['now', 'studio'], 'waycar · claude') + [
        item_kicker(s, 'WANTS TO RUN'), 4, item_command(s, COMMAND), s.rh,
        item_stamp(s, 'Allowed', '10:10', s.fn1, 'fg', w=600)]
    return detail(s, u, items, mic=True, anchor='bottom', clock='10:10')


def w3_reading(s, u):
    return detail(s, u, head_items(s, 'blocked', ['1m', 'studio'], 'waycar · claude') + [
        item_pending(s, 'Reading prompt…')])


def w3_readonly(s, u):
    return detail(s, u, head_items(s, 'blocked', ['1m', 'studio'], 'waycar · claude') + [
        item_body(s, 'Answer this one on iPhone.')])


def w5(s, u):
    items = head_items(s, 'working', ['now', 'studio'], 'site · codex') + [
        item_body(s, LATEST, dim=True), s.rh,
        item_bubble(s, DICTATED), 3,
        item_stamp(s, 'Sent', '10:10', s.fn2, right=True), s.rh,
        item_pending(s, 'Waiting for reply')]
    return detail(s, u, items, mic=True, anchor='bottom', clock='10:10')


def w5_not_sent(s, u):
    items = head_items(s, 'done', ['4m', 'studio'], 'site · codex') + [
        item_body(s, LATEST), s.rh,
        item_bubble(s, DICTATED), 3,
        item_wrapped(s, 'Not sent — iPhone didn\'t answer', s.fn2, 'danger'), s.rh,
        item_capsule(s, 'Try again', None, 'glass', 'accent')]
    return detail(s, u, items, mic=True, anchor='bottom', clock='10:10')


# ---------------------------------------------------------------- Waycar recorder, sending
def recorder(s, level=True, timer=None):
    """Waycar's own voice recorder: no transcript. level = pulsing level rings (speech);
    timer = fraction of the silence-timer ring (fills over 3.5 s of silence, then sends)."""
    o = [back_bar(s, 'xmark')]
    y = s.by + s.back / 2 + s.rh
    o.append(T(s.W / 2, bl(y, s.fn1), 'To site · codex', s.fn1[0], 'fg2', anchor='middle'))
    r = s.rec / 2
    cx, cy = s.W / 2, s.H * .53
    A['rec'] = (cx, cy, r)
    if level:
        for i, op in ((1, .35), (2, .16)):
            o.append(circ(cx, cy, r + 7 * i, 'accent', op))
    if timer is not None:
        rr = r + 7
        o.append('<circle cx="%s" cy="%s" r="%s" fill="none" %s stroke-width="4"/>' % (
            n(cx), n(cy), n(rr), F('fg', .18, 'stroke')))
        a = math.radians(-90 + 360 * timer)
        o.append('<path d="M%s %sA%s %s 0 %d 1 %s %s" fill="none" %s stroke-width="4" stroke-linecap="round"/>' % (
            n(cx), n(cy - rr), n(rr), n(rr), 1 if timer > .5 else 0, n(cx + rr * math.cos(a)), n(cy + rr * math.sin(a)),
            F('accent', 1, 'stroke')))
    o.append(circ(cx, cy, r, 'accent'))
    o.append(glyph('mic', cx, cy, r * .9, 'white'))
    hint = 'Tap or double-tap to send' if timer is None else 'Sends when the ring fills'
    o.append(T(s.W / 2, s.H - s.R * .62, hint, s.fn2[0], 'fg2', anchor='middle'))
    return ''.join(o)


def w4a(s, u):
    return recorder(s)


def w4b(s, u):
    return recorder(s, level=False, timer=.6)


def item_voice(s, secs):
    """Placeholder You-bubble while the iPhone transcribes: waveform + duration, no text."""
    f, lead = s.cap1
    g = 34
    w = 10 + g + 6 + tw(secs, f) + 10
    h = lead + 12

    def draw(y):
        x = s.W - s.m - w
        return (rect(x, y, w, h, 14, 'chatu') + glyph('waveform', x + 10 + g / 2, y + h / 2, g, 'chatt') +
                T(x + 10 + g + 6, bl(y + 6, s.cap1), secs, f, 'chatt'))
    return (h, draw)


def w5a(s, u):
    items = head_items(s, 'done', ['4m', 'studio'], 'site · codex') + [
        item_body(s, LATEST, dim=True), s.rh,
        item_voice(s, '0:06'), s.rh,
        item_pending(s, 'Transcribing on iPhone…')]
    return detail(s, u, items, mic=True, anchor='bottom', clock='10:10')


def w6(s, u):
    o = [status_bar(s, 'Waycar')]
    g = 42
    cy = s.H * .4
    o.append(glyph('iphone', s.W / 2, cy, g, 'fg2'))
    f, lead = s.fn1
    lines = wrap('Open Waycar on your iPhone to add a Host.', f, s.W - 2 * s.m - 16)
    y = cy + g / 2 + s.rh * 2
    for i, ln in enumerate(lines):
        o.append(T(s.W / 2, bl(y + i * lead, s.fn1), ln, f, 'fg2', anchor='middle'))
    return ''.join(o)


def la_card(s, x, y, counts_only=False):
    """studio card: lead '1 Blocked', trailing counts in each status ink (Idle last if room)."""
    w, h = s.la
    p = s.lap
    o = [rect(x, y, w, h, 20, 'plat')]
    lines_h = s.head[1] + (s.fn1[1] if counts_only else s.fn1[1] + s.fn2[1])
    top = y + (h - lines_h) / 2
    hf = s.head[0]
    g1 = hf * .75
    cy = top + s.head[1] / 2
    o.append(glyph('blocked', x + p + g1 / 2, cy, g1, 'blocked'))
    o.append(T(x + p + g1 + 3, bl(top, s.head), '1 Blocked', hf, 'blocked', 600))
    f = s.fn1[0]
    xr = x + w - p
    g2 = f * .7
    for st, cnt in (('working', '1'), ('done', '1')):
        o.append(T(xr, bl(top, s.head), cnt, f, st, 600, True, anchor='end'))
        xr -= tw(cnt, f, True) + 1.5
        o.append(glyph(st, xr - g2 / 2, cy, g2, st))
        xr -= g2 + 5
    l2 = bl(top + s.head[1], s.fn1)
    if counts_only:
        o.append(T(x + p, l2, 'Waycar', f, 'fg2', 600))
    else:
        o.append(T(x + p, l2, trunc('waycar · claude', f, w - 2 * p, bold=True), f, 'fg', 600))
        o.append(T(x + p, bl(top + s.head[1] + s.fn1[1], s.fn2), 'studio', s.fn2[0], 'fg2', 500))
    return ''.join(o)


def la_screen(s, u, counts_only=False):
    o = [status_bar(s, None)]
    w, h = s.la
    x = (s.W - w) / 2
    y = s.tb + s.rh
    o.append(la_card(s, x, y, counts_only))
    y2 = y + h + s.rh
    o.append(rect(x, y2, w, h, 20, 'plat', .55))
    o.append(circ(x + s.lap + 10, y2 + s.lap + 10, 10, 'fg', .18))
    o.append(rect(x + s.lap + 26, y2 + s.lap + 4, w * .4, 7, 3.5, 'fg', .18))
    o.append(rect(x + s.lap + 26, y2 + s.lap + 15, w * .25, 6, 3, 'fg', .12))
    return ''.join(o)


def la_counts(s, u):
    return la_screen(s, u, True)


def n1(s, u, kind='done', end=False):
    """System long look with the real push strings. end=True: scrolled to the actions (sash stays pinned)."""
    ic = 20 if s is SMALL else 22
    by = s.tb / 2
    full = s.W - 2 * s.m
    inner = full - 2 * s.cp
    if kind == 'done':
        title, body, actions = 'site · Codex', 'Done: ' + LATEST, ['Reply', 'Open', 'Dismiss']
    else:
        title, body, actions = 'waycar · Claude', 'Blocked: Wants to run make test-app.', ['Review', 'Dismiss']
    tl = wrap(title, s.head[0], inner, bold=True)
    bls = wrap(body, s.body[0], inner)
    h = 2 * s.cp + s.head[1] * len(tl) + 2 + s.body[1] * len(bls)

    def platter(y):
        o = [rect(s.m, y, full, h, s.cr, 'fg', .14)]
        ty = y + s.cp
        for ln in tl:
            o.append(T(s.m + s.cp, bl(ty, s.head), ln, s.head[0], 'fg', 600))
            ty += s.head[1]
        for i, ln in enumerate(bls):
            o.append(T(s.m + s.cp, bl(ty + 2 + i * s.body[1], s.body), ln, s.body[0], 'fg'))
        return ''.join(o)

    def action(a, first):
        accent = first and a != 'Dismiss'
        return (s.bh, lambda y: capsule(s, s.m, y, full, a, None, 'accent' if accent else 'fg',
                                        'white' if accent else 'fg', 1 if accent else .14))
    items = [(h, platter)]
    for i, a in enumerate(actions):
        items += [s.rh, action(a, i == 0)]
    y0 = s.tb + 2
    _, total = stack(items, 0)
    off = min(y0, s.H - s.m - total) if end else y0
    o = [stack(items, off)[0]]
    if off < y0:
        o.append('<defs>%s</defs><rect width="%s" height="%s" fill="url(#%sft)"/>' % (
            fade_defs(u, top=True), n(s.W), n(y0 + 4), u))
    o += [rect(s.tx, by - ic / 2, ic, ic, ic * .26, 'accent'),
          T(s.tx + ic / 2, by + .35 * ic * .6, 'W', ic * .6, 'white', 700, anchor='middle'),
          T(s.tx + ic + 5, by + .35 * s.fn2[0], 'WAYCAR', s.fn2[0], 'fg2', 600, ls=.6)]
    return ''.join(o)


def n1_actions(s, u):
    return n1(s, u, end=True)


def n1_blocked(s, u):
    return n1(s, u, 'blocked', end=True)
