#!/usr/bin/env python3
"""Generate the Waycar Apple Watch V0 mockup SVGs (design only).

Run: python3 docs/design/apple-watch-v0/make_mockups.py
Stdlib only, deterministic. Small = 40mm SE 3 (162x197 pt), Large = 49mm Ultra 3/4 (211x257 pt).
Screens live in mockup_screens.py; primitives in mockup_kit.py.
"""
import os
import sys

sys.dont_write_bytecode = True  # keep docs/ free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mockup_kit import *  # noqa: E402,F401,F403
from mockup_png import Renderer  # noqa: E402
from mockup_screens import *  # noqa: E402,F401,F403

OUT = os.path.dirname(os.path.abspath(__file__))
SYS = ('system UI, approximate',)


# ---------------------------------------------------------------- spec sheets
def sty(name, st, extra=''):
    return '%s %s/%s%s' % (name, n(st[0]), n(st[1]), extra)


def spec_sheet(s):
    k, col, pad = 2, 250, 34
    sw, sh = s.W * k, s.H * k
    big = s is LARGE
    top = 146
    p1x = 30 + col + pad
    p2x = p1x + sw + pad + col + 60 + col + pad
    total_w = p2x + sw + pad + col + 30
    o = []
    # W1: leaders reach margins, gaps, or the ends of text, never cross sample text.
    A.clear()
    g1 = screen_group(s, w1, 'p', p1x, top, k)
    r0, r1, cp = A['rows'][0], A['rows'][1], A['cpill1']
    X = lambda v: p1x + v * k
    Y = lambda v: top + v * k
    rb = r0['rect'][1] + s.row
    left = [
        (X(.5), Y(s.tb), ['Top bar %s pt' % n(s.tb), 'system; title leading, time trailing']),
        (X(s.tx - 1), Y(s.tb / 2), ['Nav title', sty('Title 3 semibold', s.title, ' · accent')]),
        (X(cp[0] - .5), Y(cp[1] + cp[3] / 2), ['Count pill h %s · pad %s · gap %s' % (n(s.ph), n(s.php), n(s.pg)),
                                               'digits Footnote 1 SF Mono sb · wash 15%',
                                               'Idle drops first (%d fit here)' % A['npills']]),
        (X(s.m), Y(r0['rect'][1] + 9), ['Edge margin %s pt' % n(s.m)]),
        (X(r0['tx'] - .5), Y(r0['status_mid']), ['Inline status glyph %s pt' % n(s.ig),
                                                 'glyph→word gap %s · status ink' % n(s.igap)]),
        (X(s.m + .5), Y(rb - s.rr), ['Row platter h %s · r %s · pad h %s' % (n(s.row), n(s.rr), n(s.rp)),
                                     'mock #222224']),
        (X(s.m + 20), Y(rb + s.rg / 2), ['Row gap %s pt' % n(s.rg)]),
    ]
    right = [
        (X(s.W - s.tx + 1), Y(s.tb / 2), ['Time', sty('Title 3 semibold', s.title)]),
        (X(r0['title_end'] + 2), Y(r0['title_mid']), ['Row title, full row width', sty('Headline sb', s.head, ', tail-truncates')]),
        (X(r0['status_end'] + 2), Y(r0['status_mid']), ['Status line', 'word: Footnote 1 SF Mono sb, ink, never cut',
                                                        '· age · host: Footnote 1, #a1a7b5',
                                                        'drops host, then age, whole']),
        (X(r1['status_end'] + 2), Y(r1['status_mid']), ['Host shown when it fits']),
        (X(s.W - s.R * .29), Y(s.H - s.R * .29), ['Corner mask ≈%s pt' % n(s.R), 'approximate, Apple unpublished']),
    ]
    a1, _ = callouts('left', p1x - pad, p1x - 10, left, top - 10)
    a2, _ = callouts('right', p1x + sw + pad, p1x + sw + 10, right, top - 10)
    o += [g1, a1, a2, dim_h(p1x, p1x + sw, top - 16, '%s × %s pt  (%s × %s px)' % (s.W, s.H, 2 * s.W, 2 * s.H)),
          ann_text(p1x, top - 44, 'W1 Agents list', 16, LBL, None, 700)]
    # W3 at full scroll length
    A.clear()
    _, end = stack(w3_items(s, w3_buttons(s)), s.by + s.back / 2 + s.rh)
    ext = end - s.H + s.m
    g3 = screen_group(s, w3, 'q', p2x, top, k, ext=ext)
    X = lambda v: p2x + v * k
    sl, tt, kk, cd, al, de = A['sl'], A['title'], A['kicker'], A['card'], A['allow'], A['deny']
    tb_ = tt[1] + tt[2] * s.head[1]
    left3 = [
        (X(s.bx - s.back / 2), Y(s.by), ['Back button (system)', 'visual Ø%s · hit region ≥44 pt' % n(s.back),
                                         'nav bar = back + time, no title']),
        (X(s.m - .5), Y(sl[1] + s.fn1[1] / 2), ['Status line = row line 2', 'glyph %s · %s' % (n(s.ig), sty('Footnote 1', s.fn1))]),
        (X(s.m - .5), Y(tt[1] + s.head[1] / 2), ['Agent title in content', sty('Headline sb', s.head, ', ≤2 lines')]),
        (X(s.m - .5), Y(kk[1] + s.fn2[1] / 2), ['Kicker', sty('Footnote 2 SF Mono sb', s.fn2, ', tracking 0.08 em')]),
        (X(s.m), Y(cd[1] + s.cr), ['Command card r %s · pad %s' % (n(s.cr), n(s.cp)), 'Blocked wash 15% + 1 pt ink border 40%']),
        (X(s.m + s.cp + 2), Y(cd[1] + s.cp + s.fn1[1] * 1.5), ['↪ continuation marker (dim, gutter)',
                                                               'not part of the command, not read aloud']),
        (X(s.m), Y(al[1] + al[3] / 2), ['Allow capsule h %s' % n(s.bh), 'accent fill, white Headline; only for .allow']),
        (X(s.m), Y(de[1] + de[3] / 2), ['Deny capsule h %s' % n(s.bh), 'glass, danger Headline']),
    ]
    right3 = [
        (X(s.W - s.tx + 1), Y(s.by), ['Time', sty('Title 3 semibold', s.title)]),
        (X(s.W - s.m), Y(sl[1] + s.fn1[1] + 1), ['Status → title gap 2 pt']),
        (X(s.W - s.m), Y(tb_ + s.rh / 2), ['Vertical rhythm %s pt' % n(s.rh), 'between blocks']),
        (X(s.W - s.m + .5), Y(cd[1] + s.cp + s.fn1[1] / 2), ['Command', sty('Footnote 1 SF Mono', s.fn1),
                                                             'char-level wrap at %d columns, lossless' % cd[4]]),
        (X(s.W - .5), Y(s.H), ['Screen bottom; dimmed part', 'is reached by scrolling (Crown)']),
        (X(s.W - s.m), Y(al[1] + al[3] + s.rh / 2), ['Button gap %s pt' % n(s.rh)]),
    ]
    b1, yb1 = callouts('left', p2x - pad, p2x - 10, left3, top - 10)
    b2, yb2 = callouts('right', p2x + sw + pad, p2x + sw + 10, right3, top - 10)
    o += [g3, b1, b2, dim_h(p2x, p2x + sw, top - 16, '%s × %s pt' % (s.W, s.H)),
          ann_text(p2x, top - 44, 'W3 Detail, Blocked (full scroll length)', 16, LBL, None, 700)]
    # Legend: color tokens, type styles, components
    ly = max(top + sh + ext * k, yb1, yb2) + 60
    o.append(ann_text(30, ly, 'Color tokens', 15, LBL, None, 700))
    toks = [('Background', '#000000'), ('Row platter', '#222224'), ('Glass button', '#2a2a2e @90%'),
            ('Text', '#edeef3'), ('Text 2', '#a1a7b5'), ('Accent', '#8b5cf6'), ('Danger text', '#f87171'),
            ('Chat user', '#5b3fb8'), ('Chat user text', '#f5f3ff'), ('Blocked', '#89B4FA'), ('Done', '#A6E3A1'),
            ('Working', '#F9E2AF'), ('Idle / other ink', '#A6ADC8'), ('Idle / other wash', '#7F849C'),
            ('Unknown', '#F38BA8')]
    cw = 150
    for i, (name, hx) in enumerate(toks):
        cx = 30 + (i % 5) * cw
        cy = ly + 18 + (i // 5) * 44
        o.append('<rect x="%s" y="%s" width="28" height="28" rx="6" fill="%s" stroke="#c9ced8"/>' % (n(cx), n(cy), hx.split()[0]))
        o.append(ann_text(cx + 36, cy + 12, name, 12, LBL, None, 600))
        o.append(ann_text(cx + 36, cy + 26, hx, 11, INK))
    o.append(ann_text(30, ly + 168, 'Wash = status wash @15% (count pills); command card = Blocked wash 15% + 1 pt ink border @40%.', 12, INK))
    o.append(ann_text(30, ly + 186, 'Always On: drop washes and fills, text @60%, glyphs outline only. Status is never color-only.', 12, INK))
    tx0 = 30 + 5 * cw + 40
    o.append(ann_text(tx0, ly, 'Type styles (%s, Dynamic Type %s)' % (s.key, 'xLarge' if big else 'Large'), 15, LBL, None, 700))
    rows = [('Title 3 sb', s.title, 'nav title, time'), ('Headline sb', s.head, 'row and Agent title, buttons, LA header'),
            ('Body', s.body, 'Latest text'), ('Caption 1', s.cap1, 'You-bubble, voice placeholder'),
            ('Footnote 1', s.fn1, 'status line, pill digits, command'), ('Footnote 2', s.fn2, 'kicker, Sent stamp, errors')]
    for i, (nm, st, use) in enumerate(rows):
        yy = ly + 26 + i * 22
        o.append(ann_text(tx0, yy, '%s  %s / %s pt' % (nm, n(st[0]), n(st[1])), 12, LBL, None, 600))
        o.append(ann_text(tx0 + 170, yy, use, 12, INK))
    o.append(ann_text(tx0, ly + 168, 'SF Mono: status word, command, kicker, count-pill and LA digits.', 12, INK))
    o.append(ann_text(tx0, ly + 186, 'Kicker tracking 0.08 em. Everything else SF Compact. Min 12 pt.', 12, INK))
    cx0 = tx0 + 450
    o.append(ann_text(cx0, ly, 'Components', 15, LBL, None, 700))
    mk = 1.5
    mcx, mcy = cx0 + 36, ly + 26 + s.mic * mk / 2
    o.append('<g transform="translate(%s %s) scale(%s)">%s%s</g>' % (
        n(mcx), n(mcy), n(mk), circ(0, 0, s.mic / 2 + 4, 'bg'),
        circ(0, 0, s.mic / 2, 'glass', 1, ' ' + F('fg', .14, 'stroke') + ' stroke-width="0.5"') + glyph('mic', 0, 0, s.micg, 'accent')))
    lx = mcx + (s.mic / 2 + 4) * mk + 14
    o.append(ann_text(lx, mcy - 14, 'Mic glass button Ø %s pt · glyph %s' % (n(s.mic), n(s.micg)), 12, LBL, None, 600))
    o.append(ann_text(lx, mcy + 2, 'bottom inset %s · floats over content' % n(s.mici), 12, INK))
    o.append(ann_text(lx, mcy + 18, 'content end inset %s (clears mic)' % n(s.binset), 12, INK))
    by_ = mcy + (s.mic / 2 + 4) * mk + 10
    bw, bh = 72, s.cap1[1] + 12
    o.append('<g transform="translate(%s %s) scale(%s)">%s%s</g>' % (
        n(cx0), n(by_), n(mk), rect(0, 0, bw, bh, 14, 'chatu'), T(10, bl(6, s.cap1), 'Run it.', s.cap1[0], 'chatt')))
    o.append(ann_text(cx0 + 124, by_ + 12, 'You-bubble r 14 · pad 10×6 · max width 86%', 12, LBL, None, 600))
    o.append(ann_text(cx0 + 124, by_ + 28, 'chat-user #5b3fb8 · text #f5f3ff', 12, INK))
    o.append(ann_text(cx0 + 124, by_ + 44, sty('Caption 1', s.cap1, ', right-aligned'), 12, INK))
    ny = max(ly + 168, by_ + bh * mk + 20)
    o.append(ann_text(cx0, ny, 'Capsule buttons h %s · Live Activity %s × %s pt, pad %s, r 20' % (
        n(s.bh), n(s.la[0]), n(s.la[1]), n(s.lap)), 12, INK))
    o.append(ann_text(cx0, ny + 18, 'Back button visual Ø%s, system hit region ≥44 pt' % n(s.back), 12, INK))
    total_h = ny + 42
    total_w = max(total_w, cx0 + 400)
    head = (ann_text(30, 40, 'Waycar Watch V0 · spec · %s (%s × %s pt) · shown at 2×' % (
        '49mm Ultra 3/4' if big else '40mm SE 3', s.W, s.H), 22, LBL, None, 700) +
        ann_text(30, 62, 'Design targets; system List, toolbar, and sheets draw the real components. Glyphs are stand-ins for SF Symbols.', 13, INK))
    return svg_doc(total_w, total_h, '<rect width="%s" height="%s" fill="#f5f6f8"/>' % (n(total_w), n(total_h)) + head + ''.join(o))


# ---------------------------------------------------------------- flow board
FLOWS = [
    ('F1 Check in', [
        (la_counts, ('Baseline, system UI approx.',), 'Live Activity on the face', 'tap'),
        (w1, (), 'Agents list (all Hosts)', 'tap a row'),
        (w2, (), 'Read, then back', '')]),
    ('F2 Tell it what\'s next', [
        (n1_actions, SYS, 'Done buzz; long look', 'Open'),
        (w2, (), 'Read Latest', 'tap mic'),
        (w4a, (), 'Recorder; no live text', 'speak'),
        (w4b, (), 'Pause: ring fills (3.5 s)', 'or tap / double tap'),
        (w5a, (), 'Sending; iPhone transcribes', ''),
        (w5, (), 'Sent ✓; text appears', 'later: Done buzz')]),
    ('F3 Approve', [
        (n1_blocked, SYS, 'Blocked buzz; long look', 'Review'),
        (w3_reading, (), 'Phone reads the live prompt', ''),
        (w3, (), 'Read the whole command', 'scroll'),
        (w3_end, (), 'Allow sits below it', 'Allow; success haptic'),
        (w3_allowed, (), 'Allowed ✓ 10:10', 'status from the phone')]),
    ('F4 Quick reply from a notification', [
        (n1_actions, SYS, 'Done buzz; long look', 'Reply (opens the app)'),
        (w4a, (), 'Recorder', 'stop: tap, double tap, pause'),
        (w5a, (), 'Sending; iPhone transcribes', ''),
        (w5, (), 'Sent ✓ 10:10', '')]),
]


def flow_board():
    gap, secgap, x0 = 58, 44, 120
    o = []
    y = 130
    width = 0
    for s in (SMALL, LARGE):
        x = x0
        o.append(ann_text(30, y + s.H / 2, s.key, 18, LBL, None, 700))
        o.append(ann_text(30, y + s.H / 2 + 18, 'Ultra 3/4' if s is LARGE else 'SE 3', 12, INK))
        for fi, (label, steps) in enumerate(FLOWS):
            if fi:
                x += secgap
            o.append(ann_text(x, y - 30, label, 15, LBL, None, 700))
            for i, (fn, cap, c1, c2) in enumerate(steps):
                o.append(screen_group(s, fn, 'b%s%d%d' % (s.key[:2], fi, i), x, y, 1, caption=cap))
                cy = y + s.H + 36
                o.append('<circle cx="%s" cy="%s" r="9" fill="#8b5cf6"/>' % (n(x + 9), n(cy - 4)))
                o.append(ann_text(x + 9, cy, str(i + 1), 11, '#ffffff', 'middle', 700))
                o.append(ann_text(x + 23, cy, c1, 12, LBL, None, 600))
                if c2:
                    o.append(ann_text(x + 23, cy + 16, '→ ' + c2, 12, INK))
                if i + 1 < len(steps):
                    o.append(arrow(x + s.W + 8, y + s.H / 2, x + s.W + gap - 8))
                x += s.W + gap
        width = max(width, x)
        y += s.H + 130
    title = (ann_text(30, 40, 'Waycar Watch V0 · flow board', 22, LBL, None, 700) +
             ann_text(30, 62, 'F1 to F4 left to right; 40mm row above 49mm row. Entry points: Live Activity (F1) and '
                      'notification long look (F2 to F4).', 13, INK))
    w, h = width, y - 50
    return svg_doc(w, h, '<rect width="%s" height="%s" fill="#f5f6f8"/>' % (n(w), n(h)) + title + ''.join(o))


# ---------------------------------------------------------------- registry, gallery, main
LA_TARGET = ('Target, pending on-device spike',) + SYS
LA_BASE = ('Baseline (counts only)',) + SYS
# (gallery label, file stem, body, caption, sizes)
SCREENS = [
    ('W1 Agents list', 'w1-agents', w1, (), 2), ('W1 stale (iPhone not reachable)', 'w1-stale', w1_stale, (), 1),
    ('W2 Detail, Done', 'w2-detail-done', w2, (), 2), ('W3 Blocked, on open', 'w3-detail-blocked', w3, (), 2),
    ('W3 Blocked, scrolled to end', 'w3-detail-blocked-end', w3_end, (), 2),
    ('W3 Reading prompt', 'w3-reading', w3_reading, (), 1),
    ('W3 Read-only prompt', 'w3-detail-blocked-readonly', w3_readonly, (), 1),
    ('W4a Recorder, listening', 'w4a-reply-listening', w4a, (), 2),
    ('W4b Recorder, paused (silence timer)', 'w4b-reply-paused', w4b, (), 2),
    ('W5a Sending, transcribing', 'w5a-sending', w5a, (), 2), ('W5 Sent, waiting', 'w5-sent', w5, (), 2),
    ('W5 Not sent', 'w5-not-sent', w5_not_sent, (), 1), ('W6 Empty, first run', 'w6-empty', w6, (), 1),
    ('LA baseline (counts only)', 'la-counts-only', la_counts, LA_BASE, 1),
    ('LA target (pending on-device spike)', 'la-smart-stack', la_screen, LA_TARGET, 2),
    ('N1 Notification long look', 'n1-notification', n1, SYS, 2),
    ('N1 Notification, actions', 'n1-notification-actions', n1_actions, SYS, 2),
]


def gallery():
    """Every screen at @2x pixels: rows = screens, columns 40mm | 49mm, two blocks side by side."""
    k, pad, gap, bgap = 2, 40, 24, 80
    cw = (SMALL.W * k, LARGE.W * k)
    bw = cw[0] + gap + cw[1]
    rh = 30 + LARGE.H * k + 34
    half = (len(SCREENS) + 1) // 2
    o = []
    for i, (label, stem, fn, cap, sizes) in enumerate(SCREENS):
        bx = pad + (i // half) * (bw + bgap)
        y = 96 + (i % half) * rh
        o.append(ann_text(bx, y + 18, label, 17, '#e6e8ec', None, 700))
        if cap:
            o.append(ann_text(bx + bw, y + 18, cap[-1], 13, '#9aa1ad', 'end'))
        for j, s in enumerate((SMALL, LARGE)):
            x = bx + (0 if j == 0 else cw[0] + gap)
            if j < sizes:
                o.append(screen_group(s, fn, 'g%d%d' % (i, j), x, y + 30, k))
            else:
                o.append(ann_text(x + cw[1] / 2, y + 30 + s.H, '40mm only', 14, '#7c8597', 'middle'))
    for b in range(2):
        bx = pad + b * (bw + bgap)
        for j, (s, label) in enumerate(((SMALL, '40mm SE 3 · 324 × 394 px'), (LARGE, '49mm Ultra 3/4 · 422 × 514 px'))):
            o.append(ann_text(bx + (0 if j == 0 else cw[0] + gap), 78, label, 13, '#9aa1ad', None, 600))
    w, h = 2 * pad + 2 * bw + bgap, 96 + half * rh
    head = (ann_text(pad, 40, 'Waycar Watch V0 · all screens (Live Activity frame and notification '
                     'are approximate system UI)', 20, '#e6e8ec', None, 700))
    return svg_doc(w, h, '<rect width="%s" height="%s" fill="#2b2d33"/>' % (n(w), n(h)) + head + ''.join(o))


def main():
    svgs, pngs = {}, {}
    for _, stem, fn, cap, sizes in SCREENS:
        for s in (SMALL, LARGE)[:sizes]:
            name = '%s-%s' % (stem, s.key)
            svgs[name] = screen_file(s, fn, cap)
            pngs[name] = screen_file(s, fn)  # PNG = the screen alone at the exact Apple pixel size
    for s in (SMALL, LARGE):
        svgs['spec-' + s.key] = pngs['spec-' + s.key] = spec_sheet(s)
    svgs['flow-board'] = pngs['flow-board'] = flow_board()
    pngs['gallery'] = gallery()
    for name in sorted(svgs):
        with open(os.path.join(OUT, name + '.svg'), 'w', encoding='utf-8') as fh:
            fh.write(svgs[name])
    png_dir = os.path.join(OUT, 'png')
    os.makedirs(png_dir, exist_ok=True)
    with Renderer() as r:
        for name in sorted(pngs):
            r.render(pngs[name], os.path.join(png_dir, name + '.png'))
    print('wrote %d SVGs to %s and %d PNGs to %s' % (len(svgs), OUT, len(pngs), png_dir))


if __name__ == '__main__':
    main()
