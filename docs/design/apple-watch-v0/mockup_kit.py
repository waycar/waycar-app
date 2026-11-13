"""Primitives for the Waycar Apple Watch V0 mockups: sizes, palette, text fitting, glyphs, components.

Imported by make_mockups.py. Stdlib only. SF Symbols cannot be embedded in SVG, so glyphs are simple
vector stand-ins. Text widths use advances measured from SF Compact (Regular / Semibold) plus a 3%
margin; SF Mono advances are 0.62 em.
"""
import html
import math


class Size:
    def __init__(self, **kw):
        self.__dict__.update(kw)


SMALL = Size(key='40mm', W=162, H=197, R=34, m=8, tb=28, row=52, rr=12, rg=6, rp=8, ig=13, igap=4,
             ph=22, php=8, pg=4, cr=18, cp=10, bh=44, mic=44, micg=20, mici=6, binset=56, rh=6,
             back=32, bx=22, by=20, rec=64, la=(152, 69.5), lap=8,
             title=(19, 21.5), head=(16, 18.5), body=(16, 18.5), cap1=(15, 17.5), fn1=(13, 15.5), fn2=(12, 14.5))
LARGE = Size(key='49mm', W=211, H=257, R=46, m=10, tb=32, row=58, rr=14, rg=8, rp=10, ig=14, igap=4,
             ph=24, php=9, pg=5, cr=18, cp=12, bh=48, mic=50, micg=22, mici=8, binset=64, rh=8,
             back=36, bx=28, by=24, rec=76, la=(191, 81.5), lap=10,
             title=(20, 22.5), head=(17, 19.5), body=(17, 19.5), cap1=(16, 18.5), fn1=(14, 16.5), fn2=(13, 15.5))
for _s in (SMALL, LARGE):
    _s.tx = round(_s.R * 0.45, 1)  # leading inset of title/time inside the corner mask

# (color, opacity). Status inks from AgentStatusPalette (Mocha); Idle/other wash is #7F849C.
P = dict(bg=('#000000', 1), plat=('#222224', 1), glass=('#2a2a2e', .9), fg=('#edeef3', 1), fg2=('#a1a7b5', 1),
         accent=('#8b5cf6', 1), danger=('#f87171', 1), white=('#ffffff', 1), note=('#7c8597', 1),
         chatu=('#5b3fb8', 1), chatt=('#f5f3ff', 1),
         blocked=('#89B4FA', 1), done=('#A6E3A1', 1), working=('#F9E2AF', 1), idle=('#A6ADC8', 1),
         idlew=('#7F849C', 1))
WASH = dict(blocked='blocked', done='done', working='working', idle='idlew')
WASH_OP = .15

SANS = '".SF Compact","SF Compact Text","SF Compact",-apple-system,system-ui,sans-serif'
MONO = '".SF NS Mono","SF Mono",ui-monospace,Menlo,monospace'
STYLE = '<style>.f{font-family:%s}.m{font-family:%s}</style>' % (SANS, MONO)

# Anchors recorded while drawing, read by the spec sheets.
A = {}

# ---------------------------------------------------------------- sample data
AGENTS = [
    dict(title='waycar · claude', st='blocked', age='1m', host='studio'),
    dict(title='site · codex', st='done', age='4m', host='studio'),
    dict(title='waycar · omp', st='working', age='12m', host='studio'),
    dict(title='relay · pi', st='working', age='3m', host='linuxhost'),
    dict(title='plugin · claude', st='idle', age='1h', host='linuxhost'),
]
WORD = dict(blocked='Blocked', done='Done', working='Working', idle='Idle')
COMMAND = "make test-app TEST_FLAGS='-only-testing:WaycarTests/WatchListModelTests'"
LATEST = 'Added the Apple Watch page to the help docs and fixed two broken links.'
DICTATED = 'Now run the tests and commit if they pass.'


# ---------------------------------------------------------------- primitives
def n(v):
    s = ('%.2f' % v).rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


def F(name, op=1.0, attr='fill'):
    c, o = P[name]
    o *= op
    r = '%s="%s"' % (attr, c)
    if o < 0.999:
        r += ' %s-opacity="%s"' % (attr, n(o))
    return r


# SF Compact advances in 1/1000 em (Regular, Semibold), measured from the macOS system font.
_CH = ' !"#$%&\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~·…—✓⟳↪\xa0'
_RW = (226, 281, 433, 609, 561, 749, 663, 232, 348, 348, 480, 561, 250, 410, 293, 348, 609, 456, 561, 572, 587, 585, 600,
       536, 599, 599, 310, 310, 561, 561, 561, 490, 843, 615, 625, 637, 658, 563, 531, 649, 694, 274, 502, 608, 510, 802,
       692, 668, 589, 670, 621, 592, 538, 678, 614, 847, 578, 561, 587, 348, 348, 348, 401, 438, 488, 545, 590, 530, 591,
       547, 392, 574, 597, 287, 287, 524, 268, 875, 594, 567, 590, 589, 392, 508, 376, 591, 508, 744, 523, 534, 500, 348,
       348, 348, 570, 322, 777, 1000, 828, 1000, 1000, 226)
_SW = (222, 297, 496, 626, 596, 778, 685, 261, 374, 374, 480, 596, 254, 410, 304, 374, 628, 476, 584, 596, 615, 608, 623,
       559, 628, 623, 314, 313, 596, 596, 596, 502, 860, 641, 640, 650, 674, 576, 547, 663, 711, 299, 545, 640, 523, 822,
       700, 684, 610, 687, 641, 615, 551, 690, 636, 879, 604, 588, 600, 374, 374, 374, 452, 442, 488, 561, 609, 545, 610,
       562, 411, 597, 613, 301, 300, 563, 289, 895, 610, 580, 608, 608, 416, 527, 405, 608, 536, 789, 553, 557, 513, 374,
       374, 374, 570, 322, 848, 1000, 855, 1000, 1000, 222)
_REG, _SEMI = dict(zip(_CH, _RW)), dict(zip(_CH, _SW))


def tw(t, f, mono=False, bold=False):
    """Width in pt. bold = semibold (also used for medium, slightly conservative)."""
    if mono:
        return len(t) * f * .62
    tab = _SEMI if bold else _REG
    return sum(tab.get(c, 1000) for c in t) * f * 1.03 / 1000


def trunc(t, f, maxw, mono=False, bold=False):
    if tw(t, f, mono, bold) <= maxw:
        return t
    while t and tw(t + '…', f, mono, bold) > maxw:
        t = t[:-1]
    return t.rstrip(' ·') + '…'


def wrap(t, f, maxw, bold=False):
    """Word wrap for SF Compact text."""
    lines, cur = [], ''
    for w in t.split(' '):
        c = (cur + ' ' + w) if cur else w
        if not cur or tw(c, f, bold=bold) <= maxw:
            cur = c
        else:
            lines.append(cur)
            cur = w
    return lines + [cur] if cur else lines


def clamp(lines, k, f, maxw, bold=False):
    if len(lines) <= k:
        return lines
    last = lines[k - 1]
    while last and tw(last + '…', f, bold=bold) > maxw:
        last = last[:-1]
    return lines[:k - 1] + [last.rstrip(' ,.') + '…']


def bl(top, style):
    f, lead = style
    return top + lead / 2 + 0.35 * f


def T(x, y, t, f, col='fg', w=None, mono=False, anchor=None, op=1.0, ls=None):
    a = '<text x="%s" y="%s" class="%s" font-size="%s"' % (n(x), n(y), 'm' if mono else 'f', n(f))
    if w:
        a += ' font-weight="%s"' % w
    if anchor:
        a += ' text-anchor="%s"' % anchor
    if ls:
        a += ' letter-spacing="%s"' % n(ls)
    if t != t.strip():
        a += ' xml:space="preserve"'
    return a + ' ' + F(col, op) + '>' + html.escape(t, quote=False) + '</text>'


def rect(x, y, w, h, r, fill='plat', op=1.0, extra=''):
    return '<rect x="%s" y="%s" width="%s" height="%s" rx="%s" %s%s/>' % (
        n(x), n(y), n(w), n(h), n(r), F(fill, op), extra)


def line(x1, y1, x2, y2, col, sw, op=1.0):
    return '<line x1="%s" y1="%s" x2="%s" y2="%s" %s stroke-width="%s" stroke-linecap="round"/>' % (
        n(x1), n(y1), n(x2), n(y2), F(col, op, 'stroke'), n(sw))


def poly(pts, col, sw, op=1.0):
    return '<polyline points="%s" fill="none" %s stroke-width="%s" stroke-linecap="round" stroke-linejoin="round"/>' % (
        ' '.join('%s,%s' % (n(x), n(y)) for x, y in pts), F(col, op, 'stroke'), n(sw))


def circ(cx, cy, r, fill, op=1.0, extra=''):
    return '<circle cx="%s" cy="%s" r="%s" %s%s/>' % (n(cx), n(cy), n(r), F(fill, op), extra)


def outline_rect(x, y, w, h, r, col, sw, op=1.0):
    return '<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="none" %s stroke-width="%s"/>' % (
        n(x), n(y), n(w), n(h), n(r), F(col, op, 'stroke'), n(sw))


# ---------------------------------------------------------------- glyph stand-ins
def glyph(kind, cx, cy, g, col='fg', op=1.0):
    u = g / 16.0
    o = []
    if kind == 'blocked':  # hand.raised.fill
        o.append(rect(cx - 4.6 * u, cy - 1.5 * u, 9.6 * u, 8.6 * u, 3 * u, col, op))
        for i, top in enumerate((-6.8, -8, -7.4, -5.6)):
            o.append(rect(cx - 4.6 * u + i * 2.5 * u, cy + top * u, 2.1 * u, -top * u + 2.5 * u, 1.05 * u, col, op))
        o.append(line(cx - 3.6 * u, cy + 3.2 * u, cx - 7 * u, cy - 0.6 * u, col, 2.2 * u, op))
    elif kind == 'done':  # checkmark.circle.fill
        o.append(circ(cx, cy, 0.47 * g, col, op))
        o.append(poly([(cx - .22 * g, cy + .01 * g), (cx - .06 * g, cy + .17 * g), (cx + .23 * g, cy - .16 * g)], 'bg', .11 * g))
    elif kind == 'working':  # progress spinner
        for half, hop in ((range(0, 4), 1.0), (range(4, 8), .4)):
            d = ''.join('M%s %sL%s %s' % (
                n(cx + math.cos(math.radians(i * 45 - 90)) * .22 * g), n(cy + math.sin(math.radians(i * 45 - 90)) * .22 * g),
                n(cx + math.cos(math.radians(i * 45 - 90)) * .46 * g), n(cy + math.sin(math.radians(i * 45 - 90)) * .46 * g))
                for i in half)
            o.append('<path d="%s" %s stroke-width="%s" stroke-linecap="round"/>' % (d, F(col, op * hop, 'stroke'), n(.11 * g)))
    elif kind == 'idle':  # moon.zzz.fill
        c1 = (cx - .1 * g, cy + .08 * g, .36 * g)
        c2 = (cx + .1 * g, cy - .12 * g, .29 * g)
        dx, dy = c2[0] - c1[0], c2[1] - c1[1]
        d = math.hypot(dx, dy)
        a = (c1[2] ** 2 - c2[2] ** 2 + d * d) / (2 * d)
        h = math.sqrt(c1[2] ** 2 - a * a)
        mx, my = c1[0] + a * dx / d, c1[1] + a * dy / d
        p1 = (mx - h * dy / d, my + h * dx / d)
        p2 = (mx + h * dy / d, my - h * dx / d)
        o.append('<path d="M%s %sA%s %s 0 1 1 %s %sA%s %s 0 0 0 %s %sZ" %s/>' % (
            n(p1[0]), n(p1[1]), n(c1[2]), n(c1[2]), n(p2[0]), n(p2[1]),
            n(c2[2]), n(c2[2]), n(p1[0]), n(p1[1]), F(col, op)))
        o.append(poly([(cx + .2 * g, cy - .46 * g), (cx + .44 * g, cy - .46 * g),
                       (cx + .2 * g, cy - .24 * g), (cx + .44 * g, cy - .24 * g)], col, max(.07 * g, .8), op))
    elif kind == 'mic':
        o.append(rect(cx - .17 * g, cy - .48 * g, .34 * g, .58 * g, .17 * g, col, op))
        o.append('<path d="M%s %sA%s %s 0 0 0 %s %s" fill="none" %s stroke-width="%s" stroke-linecap="round"/>' % (
            n(cx - .3 * g), n(cy - .1 * g), n(.3 * g), n(.3 * g), n(cx + .3 * g), n(cy - .1 * g),
            F(col, op, 'stroke'), n(.08 * g)))
        o.append(line(cx, cy + .2 * g, cx, cy + .42 * g, col, .08 * g, op))
        o.append(line(cx - .16 * g, cy + .44 * g, cx + .16 * g, cy + .44 * g, col, .08 * g, op))
    elif kind == 'iphone':
        o.append(outline_rect(cx - .27 * g, cy - .46 * g, .54 * g, .92 * g, .11 * g, col, .08 * g, op))
        o.append(line(cx - .07 * g, cy - .35 * g, cx + .07 * g, cy - .35 * g, col, .06 * g, op))
    elif kind == 'xmark':
        o.append(line(cx - .3 * g, cy - .3 * g, cx + .3 * g, cy + .3 * g, col, .13 * g, op))
        o.append(line(cx + .3 * g, cy - .3 * g, cx - .3 * g, cy + .3 * g, col, .13 * g, op))
    elif kind == 'check':
        o.append(poly([(cx - .38 * g, cy + .02 * g), (cx - .12 * g, cy + .28 * g), (cx + .38 * g, cy - .3 * g)], col, .14 * g, op))
    elif kind == 'chev':
        o.append(poly([(cx + .12 * g, cy - .34 * g), (cx - .17 * g, cy), (cx + .12 * g, cy + .34 * g)], col, .14 * g, op))
    elif kind == 'cont':  # continuation hook arrow for wrapped command lines
        o.append(poly([(cx - .3 * g, cy - .4 * g), (cx - .3 * g, cy + .12 * g), (cx + .34 * g, cy + .12 * g)], col, .1 * g, op))
        o.append(poly([(cx + .12 * g, cy - .1 * g), (cx + .36 * g, cy + .12 * g), (cx + .12 * g, cy + .34 * g)], col, .1 * g, op))
    elif kind == 'waveform':
        hs = (.3, .6, .9, .5, 1, .7, .35, .8, .55, .25)
        step = g / len(hs)
        d = ''.join('M%s %sV%s' % (n(cx - g / 2 + step * (i + .5)), n(cy - hh * g * .22), n(cy + hh * g * .22))
                    for i, hh in enumerate(hs))
        o.append('<path d="%s" %s stroke-width="%s" stroke-linecap="round"/>' % (d, F(col, op, 'stroke'), n(step * .5)))
    else:  # circle.fill
        o.append(circ(cx, cy, .3 * g, col, op))
    return ''.join(o)


def glass_circle(cx, cy, d, kind, gcol='fg', gk=.42):
    return circ(cx, cy, d / 2, 'glass', 1, ' ' + F('fg', .14, 'stroke') + ' stroke-width="0.5"') + glyph(kind, cx, cy, d * gk, gcol)


def capsule(s, x, y, w, label, kind=None, fill='glass', tcol='fg', fop=1.0):
    h = s.bh
    f = s.head[0]
    edge = ' ' + F('fg', .1, 'stroke') + ' stroke-width="0.5"' if fill == 'glass' else ''
    o = [rect(x, y, w, h, h / 2, fill, fop, edge)]
    g = f * 1.05
    lw = tw(label, f, bold=True) + (g + 6 if kind else 0)
    lx = x + (w - lw) / 2
    if kind:
        o.append(glyph(kind, lx + g / 2, y + h / 2, g, tcol))
        lx += g + 6
    o.append(T(lx, y + h / 2 + .35 * f, label, f, tcol, 600))
    return ''.join(o)


def status_bar(s, title):
    """Root top bar: accent title leading (optional), time trailing."""
    f = s.title[0]
    y = s.tb / 2 + .35 * f
    o = [T(s.tx, y, title, f, 'accent', 600)] if title else []
    o.append(T(s.W - s.tx, y, '10:09', f, 'fg', 600, anchor='end'))
    return ''.join(o)


def back_bar(s, kind='chev', clock='10:09', center=False):
    """System nav bar: glass back (or cancel) button top-leading, time trailing (or centered)."""
    f = s.title[0]
    y = s.by + .35 * f
    return glass_circle(s.bx, s.by, s.back, kind) + (
        T(s.W / 2, y, clock, f, 'fg', 600, anchor='middle') if center else
        T(s.W - s.tx, y, clock, f, 'fg', 600, anchor='end'))


def status_line(s, x, y, st, segs, maxw):
    """Inline glyph + status word (SF Mono semibold, ink) + ' · seg' parts, dropped whole from the end."""
    f, lead = s.fn1
    word = WORD[st]
    gap = f * .28
    avail = maxw - s.ig - s.igap - tw(word, f, True) - gap
    segs = list(segs)
    while segs and tw('· ' + ' · '.join(segs), f) > avail:
        segs.pop()
    rest = '· ' + ' · '.join(segs) if segs else ''
    b = bl(y, s.fn1)
    end = x + s.ig + s.igap + tw(word, f, True) + (gap + tw(rest, f) if rest else 0)
    A['sl'] = (x, y, end)
    return (glyph(st, x + s.ig / 2, y + lead / 2, s.ig, st) +
            '<text x="%s" y="%s" font-size="%s"><tspan class="m" font-weight="600" %s>%s</tspan>'
            '<tspan class="f" dx="%s" %s>%s</tspan></text>' % (
                n(x + s.ig + s.igap), n(b), n(f), F(st), word, n(gap), F('fg2'), html.escape(rest, quote=False)))


def fade_defs(u, top=False, bottom=False):
    c, o = P['bg']
    d = []
    if top:
        d.append('<linearGradient id="%sft" x1="0" y1="0" x2="0" y2="1"><stop offset=".7" stop-color="%s" stop-opacity="%s"/>'
                 '<stop offset="1" stop-color="%s" stop-opacity="0"/></linearGradient>' % (u, c, n(o), c))
    if bottom:
        d.append('<linearGradient id="%sfb" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="%s" stop-opacity="0"/>'
                 '<stop offset=".7" stop-color="%s" stop-opacity="%s"/></linearGradient>' % (u, c, c, n(o)))
    return ''.join(d)


# ---------------------------------------------------------------- scroll stack for detail screens
def stack(items, y0):
    """items: numbers (spacing) or (height, draw(y)) pairs. Returns (svg, end_y)."""
    out, y = [], y0
    for it in items:
        if isinstance(it, (int, float)):
            y += it
        else:
            h, fn = it
            out.append(fn(y))
            y += h
    return ''.join(out), y


def detail(s, u, items, mic=False, anchor='top', clock='10:09'):
    """Detail screen, nav bar = back + time. anchor='top' = on open; 'bottom' = scrolled to end."""
    y0 = s.by + s.back / 2 + s.rh
    _, total = stack(items, 0)
    limit = s.H - (s.binset if mic else s.m)
    off = y0 if anchor == 'top' else min(y0, limit - total)
    content, end = stack(items, off)
    chrome = ['<defs>%s</defs>' % fade_defs(u, top=off < y0, bottom=mic)] if off < y0 or mic else []
    if off < y0:
        chrome.append('<rect x="0" y="0" width="%s" height="%s" fill="url(#%sft)"/>' % (n(s.W), n(y0 + 4), u))
    if mic:
        top = s.H - s.mici - s.mic - 22
        chrome.append('<rect x="0" y="%s" width="%s" height="%s" fill="url(#%sfb)"/>' % (n(top), n(s.W), n(s.H - top), u))
        cy = s.H - s.mici - s.mic / 2
        chrome.append(circ(s.W / 2, cy, s.mic / 2, 'glass', 1, ' ' + F('fg', .14, 'stroke') + ' stroke-width="0.5"'))
        chrome.append(glyph('mic', s.W / 2, cy, s.micg, 'accent'))
    chrome.append(back_bar(s, clock=clock))
    return content + ''.join(chrome)


def item_status(s, st, segs):
    return (s.fn1[1], lambda y: status_line(s, s.m, y, st, segs, s.W - 2 * s.m))


def item_title(s, title):
    f, lead = s.head
    lines = clamp(wrap(title, f, s.W - 2 * s.m, bold=True), 2, f, s.W - 2 * s.m, bold=True)

    def draw(y):
        A['title'] = (s.m, y, len(lines))
        return ''.join(T(s.m, bl(y + i * lead, s.head), ln, f, 'fg', 600) for i, ln in enumerate(lines))
    return (lead * len(lines), draw)


def item_kicker(s, text):
    f = s.fn2[0]

    def draw(y):
        A['kicker'] = (s.m, y)
        return T(s.m, bl(y, s.fn2), text, f, 'fg2', 600, True, ls=.08 * f)
    return (s.fn2[1], draw)


def item_body(s, text, dim=False):
    f, lead = s.body
    lines = wrap(text, f, s.W - 2 * s.m)

    def draw(y):
        o = ''.join(T(s.m, bl(y + i * lead, s.body), ln, f, 'fg') for i, ln in enumerate(lines))
        return '<g opacity="0.45">%s</g>' % o if dim else o
    return (lead * len(lines), draw)


def code_lines(s, text):
    """Character-level wrap at the column limit; the gutter holds the continuation marker."""
    f = s.fn1[0]
    gutter = f * .62 + 2
    cols = int((s.W - 2 * s.m - 2 * s.cp - gutter) // (f * .62))
    return [text[i:i + cols] for i in range(0, len(text), cols)], gutter, cols


def item_command(s, text):
    f, lead = s.fn1
    lines, gutter, cols = code_lines(s, text)
    h = 2 * s.cp + lead * len(lines)

    def draw(y):
        A['card'] = (s.m, y, s.W - 2 * s.m, h, cols)
        x0 = s.m + s.cp
        o = [rect(s.m, y, s.W - 2 * s.m, h, s.cr, 'blocked', WASH_OP, ' ' + F('blocked', .4, 'stroke') + ' stroke-width="1"')]
        for i, ln in enumerate(lines):
            top = y + s.cp + i * lead
            if i:
                o.append(glyph('cont', x0 + gutter / 2 - 1, top + lead / 2, f * .55, 'fg2', .55))
            o.append(T(x0 + gutter, bl(top, s.fn1), ln, f, 'fg', mono=True))
        return ''.join(o)
    return (h, draw)


def item_capsule(s, label, kind, fill, tcol, key=None):
    def draw(y):
        if key:
            A[key] = (s.m, y, s.W - 2 * s.m, s.bh)
        return capsule(s, s.m, y, s.W - 2 * s.m, label, kind, fill, tcol)
    return (s.bh, draw)


def item_bubble(s, text):
    """You-bubble: chat-user fill, chat-user-text, radius 14, pad 10x6, max width 86%, right-aligned."""
    f, lead = s.cap1
    maxw = (s.W - 2 * s.m) * .86
    lines = wrap(text, f, maxw - 20)
    w = max(tw(ln, f) for ln in lines) + 20
    h = lead * len(lines) + 12

    def draw(y):
        x = s.W - s.m - w
        return rect(x, y, w, h, 14, 'chatu') + ''.join(
            T(x + 10, bl(y + 6 + i * lead, s.cap1), ln, f, 'chatt') for i, ln in enumerate(lines))
    return (h, draw)


def item_stamp(s, word, clock, style, col='fg2', right=False, w=None):
    """'Sent ✓ 10:10' / 'Allowed ✓ 10:10' with a vector check."""
    f, lead = style

    def draw(y):
        b = bl(y, style)
        g = f * .9
        parts = [(word, tw(word, f, bold=bool(w)) + 3), (None, g + 3), (clock, tw(clock, f, bold=bool(w)))]
        x = s.W - s.m - sum(p[1] for p in parts) if right else s.m
        o = []
        for t, pw in parts:
            o.append(T(x, b, t, f, col, w) if t else glyph('check', x + g / 2, b - .35 * f, g, col))
            x += pw
        return ''.join(o)
    return (lead, draw)


def item_pending(s, text):
    """Spinner + secondary text; wraps under the text column when it does not fit."""
    f, lead = s.fn1
    g = f * 1.05
    lines = wrap(text, f, s.W - 2 * s.m - g - 5)

    def draw(y):
        return glyph('working', s.m + g / 2, y + lead / 2, g, 'fg2') + ''.join(
            T(s.m + g + 5, bl(y + i * lead, s.fn1), ln, f, 'fg2') for i, ln in enumerate(lines))
    return (lead * len(lines), draw)


def item_wrapped(s, text, style, col):
    lines = wrap(text, style[0], s.W - 2 * s.m)

    def draw(y):
        return ''.join(T(s.m, bl(y + i * style[1], style), ln, style[0], col) for i, ln in enumerate(lines))
    return (style[1] * len(lines), draw)


# ---------------------------------------------------------------- framing
def screen_group(s, body, u, x=0, y=0, k=1.0, caption=(), ext=None):
    """Watch screen at (x, y) scaled by k. ext: content continuing below the screen, dimmed."""
    inner = body(s, u)
    o = ['<g transform="translate(%s %s)%s">' % (n(x), n(y), ' scale(%s)' % n(k) if k != 1 else '')]
    o.append('<clipPath id="%sc"><rect width="%s" height="%s" rx="%s"/></clipPath>' % (u, n(s.W), n(s.H), n(s.R)))
    o.append(rect(0, 0, s.W, s.H, s.R, 'bg'))
    if ext:
        o.append('<clipPath id="%se"><rect y="%s" width="%s" height="%s"/></clipPath>' % (u, n(s.H), n(s.W), n(ext)))
        o.append('<rect y="%s" width="%s" height="%s" fill="#000" fill-opacity=".85" stroke="#7c8597" '
                 'stroke-dasharray="3 3" stroke-width=".5"/>' % (n(s.H), n(s.W), n(ext)))
        o.append('<g clip-path="url(#%se)" opacity=".5">%s</g>' % (u, inner))
    o.append('<g clip-path="url(#%sc)">%s</g>' % (u, inner))
    for i, c in enumerate(caption):
        o.append(T(s.W / 2, s.H + 9 + 9 * i, c, 7, 'note', anchor='middle'))
    o.append('</g>')
    return ''.join(o)


def svg_doc(vw, vh, body, pw=None, ph=None):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%s" height="%s" viewBox="0 0 %s %s">%s%s</svg>\n' % (
        n(pw or vw), n(ph or vh), n(vw), n(vh), STYLE, body))


def screen_file(s, body, caption=()):
    h = s.H + (3 + 9 * len(caption) if caption else 0)
    return svg_doc(s.W, h, screen_group(s, body, 'a', caption=caption), 2 * s.W, 2 * h)


# ---------------------------------------------------------------- annotation sheets
INK = '#5f6b7f'
LBL = '#2b2f38'


def ann_text(x, y, t, size=12, col=LBL, anchor=None, w=None):
    return '<text x="%s" y="%s" class="f" font-size="%s"%s%s fill="%s">%s</text>' % (
        n(x), n(y), n(size), ' text-anchor="%s"' % anchor if anchor else '', ' font-weight="%s"' % w if w else '',
        col, html.escape(t, quote=False))


def callouts(side, colx, edgex, items, ytop):
    """items: (target_x, target_y, [lines]). Labels stack without overlap. Each leader runs horizontally from
    the label, jogs vertically outside the screen, then reaches the target horizontally, so targets must be
    chosen where the path from the screen edge is empty (margins, gaps, ends of text)."""
    out, y, jogs = [], ytop, 0
    sgn = -1 if side == 'left' else 1
    for tx, ty, lines in sorted(items, key=lambda i: i[1]):
        ly = max(ty, y)
        anchor = 'end' if side == 'left' else None
        for i, t in enumerate(lines):
            out.append(ann_text(colx, ly + 4 + i * 15, t, 12, LBL if i == 0 else INK, anchor, 600 if i == 0 else None))
        sx = colx - 6 * sgn
        if ly > ty:
            jx = edgex - sgn * 4 * (jogs % 4)
            jogs += 1
            pts = [(sx, ly), (jx, ly), (jx, ty), (tx, ty)]
        else:
            pts = [(sx, ty), (tx, ty)]
        out.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="1"/>' % (
            ' '.join('%s,%s' % (n(a), n(b)) for a, b in pts), INK))
        out.append('<circle cx="%s" cy="%s" r="2.5" fill="#ffffff" stroke="%s" stroke-width="1.2"/>' % (n(tx), n(ty), INK))
        y = ly + len(lines) * 15 + 8
    return ''.join(out), y


def dim_h(x1, x2, y, label):
    return ('<path d="M%s %sH%sM%s %sv10M%s %sv10" stroke="%s"/>' % (
        n(x1), n(y), n(x2), n(x1), n(y - 5), n(x2), n(y - 5), INK) +
            ann_text((x1 + x2) / 2, y - 7, label, 12, LBL, 'middle', 600))


def arrow(x1, y, x2):
    return ('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="1.5"/>' % (n(x1), n(y), n(x2 - 6), n(y), INK) +
            '<path d="M%s %sl-7 -4.5v9z" fill="%s"/>' % (n(x2), n(y), INK))
