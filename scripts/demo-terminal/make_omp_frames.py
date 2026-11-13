#!/usr/bin/env python3
"""Generates the OMP-styled terminal frames the screenshot demo fixture serves.

Every demo Agent pane (`--demo-screenshots`) shows an omp session reviewing the
checkout flow, drawn with omp 18.3.2's default `dark` theme colors. Like a real
TUI, the demo transport repaints on every resize with the widest frame that
fits the pane, so each frame here is as wide as a pane the README screenshots
capture. Every frame is ROWS tall, more than any of those panes: painting it
scrolls the surplus history into scrollback and leaves the prompt on the
pane's bottom row, whatever height the Agent view's chrome leaves it. This
script writes them as Swift string literals to
`Sources/Waycar/Demo/DemoTerminalFrames.swift`; edit the frames here, never the
generated file or the PNGs.

Usage: scripts/demo-terminal/make_omp_frames.py [--ans-dir DIR | --check]
  --check        exit 1 if the committed Swift file is out of date; write nothing.
  --ans-dir DIR  also write DIR/omp-<name>.ans for previewing in a terminal of
                 the same size (`cat DIR/omp-ipadFull.ans`).
"""
import argparse
import pathlib
import re
import sys
import unicodedata

REPO = pathlib.Path(__file__).resolve().parents[2]
SWIFT_OUT = REPO / 'Sources/Waycar/Demo/DemoTerminalFrames.swift'
# (Swift name, columns, narrow layout, pane). Columns are the width the app's
# terminal reports on the screenshot simulators (fresh default font and zoom);
# remeasure them if the terminal font or side chrome changes.
FRAMES = [
    ('iphone', 68, True, 'iPhone 17 Pro Max Agent pane'),
    ('ipadSplit', 150, False, 'iPad Pro 13-inch landscape detail beside the sidebar'),
    ('ipadFull', 210, False, 'iPad Pro 13-inch landscape with the sidebar hidden'),
]
# Taller than any captured pane (a full-height iPad Pro 13-inch landscape
# screen is ~73 rows of the default font), so no pane shows a blank band
# under the prompt.
ROWS = 80

SGR = re.compile(r'\x1b\[[0-9;:]*m')


def vis(s):
    s = SGR.sub('', s)
    return sum(2 if unicodedata.east_asian_width(ch) in 'WF' else 1 for ch in s)


def fg(r, g, b): return f'\x1b[38;2;{r};{g};{b}m'
def bg(r, g, b): return f'\x1b[48;2;{r};{g};{b}m'


R, FG0, BG0 = '\x1b[0m', '\x1b[39m', '\x1b[49m'
DIM, MUTED, ACC = fg(95, 102, 115), fg(119, 125, 136), fg(254, 188, 56)
CODE, TXT, CMD = fg(229, 193, 255), fg(229, 229, 231), fg(220, 220, 170)
GREEN, RED, TEAL = fg(137, 210, 129), fg(240, 113, 120), fg(0, 175, 175)
BOXBG, USERBG = bg(22, 26, 31), bg(34, 29, 26)
BOLD, UNBOLD = '\x1b[1m', '\x1b[22m'
BULLET = f' {ACC}- {FG0}'


def c(s): return f'{CODE}{s}{FG0}'


def user(lines, W):
    out = [USERBG + ' ' * W]
    out += [f'{USERBG} {TXT}{l}{FG0}' + ' ' * (W - 1 - vis(l)) for l in lines]
    out += [' ' * W + BG0]
    return out


def box(cmd, body, footer, W):
    inner = W - 2
    def row(s): return f'{DIM}│{FG0} {s}' + ' ' * (inner - 1 - vis(s)) + f'{DIM}│'
    top = f'{DIM}{BOXBG}╭' + '─' * inner + '╮'
    mid = f'├───{FG0} Output {DIM}' + '─' * (inner - 11) + '┤'
    out = [top, row(f'{DIM}$ {CMD}{cmd}{FG0}'), mid]
    out += [row(b) for b in body]
    out += [row(f'{DIM}{footer}{FG0}'), '╰' + '─' * inner + f'╯{FG0}{BG0}']
    return out


def status(W, title=None):
    left = (f'{fg(242,80,159)}╭──{FG0}{bg(18,18,18)} {DIM}π{FG0} \x1b[38;5;244m>{FG0} '
            f'{fg(242,80,159)}◑ Opus 5.5{FG0} \x1b[38;5;244m>{FG0} {TEAL}🗑 storefront{FG0} '
            f'\x1b[38;5;244m>{FG0} {fg(95,175,95)}⑂ checkout/retry{FG0} {fg(18,18,18)}{BG0}▶'
            f'{fg(242,80,159)}─12%{fg(23,143,185)}')
    right = f'{MUTED}╎{fg(181,96,138)}┃{fg(23,143,185)}──{fg(181,96,138)}1M{fg(23,143,185)}─'
    if title:
        right += f'{fg(242,80,159)}◀ {TXT}{title}{fg(242,80,159)} ──╮'
    else:
        right += f'{fg(242,80,159)}──╮'
    fill = W - vis(left) - vis(right)
    top = left + '─' * fill + right
    bot = f'{fg(242,80,159)}╰─ {FG0}' + ' ' * (W - 6) + f'{fg(242,80,159)} ─╯{FG0}'
    return [top, bot]


def earlier_turns(W):
    """Exchanges scrolled above the current turn, oldest first, so the frame
    reads as a live session all the way to its top row."""
    return (
        user(['Is the simulator still booted?'], W) + [
            '', f' ● Bash {CMD}xcrun simctl list devices booted{FG0}',
            f'{BULLET}Yes, iPhone 17 Pro is booted with Storefront installed.', '']
        + user(['What landed on main since yesterday?'], W) + [
            '', f' ● Bash {CMD}git fetch origin main{FG0}',
            f' ● Bash {CMD}git log --oneline HEAD..origin/main{FG0}',
            f'{BULLET}4 commits: pricing copy, tax rounding, two dependency bumps.',
            f'{BULLET}None of them touch {c("Sources/Checkout")}.', '']
        + user(['Rebase onto it and rebuild.'], W) + [
            '', f' ● Bash {CMD}git rebase origin/main{FG0}',
            f' ● Bash {CMD}swift build{FG0}',
            f'{BULLET}Rebased cleanly; the build is green.', '']
        + user(['Any open issues tagged checkout?'], W) + [
            '', f' ● Bash {CMD}gh issue list --label checkout{FG0}',
            f'{BULLET}{c("#412")} Cart empties after a declined card.',
            f'{BULLET}{c("#398")} Apple Pay sheet flickers on retry.', '']
        + user(['Which branch am I on?'], W) + [
            '', f' ● Bash {CMD}git status --short --branch{FG0}',
            f' ● Bash {CMD}git log --oneline main..HEAD{FG0}',
            f'{BULLET}On {c("checkout/retry")}, 3 commits ahead of {c("main")}.',
            f'{BULLET}The working tree is clean.', '']
        + user(['Where does checkout live in this repo?'], W) + [
            '', f' ● Read {ACC}Sources/Checkout/Cart.swift{FG0}', '',
            f'{BULLET}Checkout lives in {c("Sources/Checkout")}; {c("Cart")} is a value type.', ''])


def frame(W, narrow):
    L = []
    if narrow:
        L += user(['Review the checkout flow. Keep the cart when a payment',
                   'retry fails, then run the checkout tests.'], W)
    else:
        L += user(['Review the checkout flow. Keep the cart when a payment retry fails, then run the checkout tests.'], W)
    L += ['',
          f' ● Read {ACC}Sources/Checkout/CheckoutView.swift{FG0}',
          f' ● Read {ACC}Sources/Checkout/PaymentCoordinator.swift{FG0}',
          '',
          f' 🔍 Grep: {MUTED}clearCart{FG0} {DIM}2 matches · 1 file{FG0}',
          f' {DIM}└─{FG0} {MUTED} 58│        cart.clear()  // on every failure{FG0}',
          '',
          f' ● Edit {ACC}PaymentCoordinator.swift{FG0} {GREEN}+6{FG0} {RED}-2{FG0}',
          f' {DIM}  57│{FG0}     {DIM}case .failure(let error):{FG0}',
          f' {RED}- 58│         cart.clear(){FG0}',
          f' {GREEN}+ 58│         state = .retry(cart, reason: error.message){FG0}',
          '']
    tests = ['cartSurvivesRetry', 'errorsStayInline', 'retryIsIdempotent',
             'declinedCardInline', 'applePayFallback', 'noCustomerDataLogged']
    if not narrow:
        tests = ['totalsRecompute', 'couponApplies', 'taxRounding', 'shippingQuote',
                 'guestCheckout', 'savedCard'] + tests
    body = [f'{DIM}… ({18 - len(tests)} earlier lines) ⟦Ctrl+O: Expand⟧{FG0}']
    body += [f'{MUTED}  {GREEN}✓{MUTED} CheckoutFlowTests.{t}{FG0}' for t in tests]
    body += [f'{GREEN}{BOLD}18 tests passed{UNBOLD}{MUTED} in 4.2s{FG0}']
    L += box('swift test --filter CheckoutFlowTests', body, '⟦Wall: 4.2s | Timeout: 300s⟧', W)
    L += ['']
    b = BULLET
    if narrow:
        L += [f'{b}Cart survives a failed retry. {c("PaymentCoordinator")} now',
              f'   keeps it in {c(".retry")} instead of calling {c("cart.clear()")}.',
              f'{b}Card errors stay inline on {c("CheckoutView")}.',
              f'{b}No customer data is logged. All 18 tests pass.']
    else:
        L += [f'{b}Cart survives a failed retry. {c("PaymentCoordinator")} now keeps it in {c(".retry")} instead of calling {c("cart.clear()")}.',
              f'{b}Card errors stay inline on {c("CheckoutView")}, next to the pay button.',
              f'{b}No customer data is logged. All 18 {c("CheckoutFlowTests")} pass.']
    L += ['', f' {BOLD}Run the UI test before commit?{UNBOLD}', '']
    L += status(W, None if narrow else 'Checkout review')
    earlier = earlier_turns(W)
    need = ROWS - len(L)
    assert 0 <= need <= len(earlier), f'{W}x{ROWS}: {need} rows above the turn, {len(earlier)} of history'
    L = (earlier[-need:] if need else []) + L
    for l in L:
        assert vis(l) <= W, (vis(l), SGR.sub('', l))
    assert len(L) == ROWS, len(L)
    return L


def ansi(lines):
    # omp draws its own cursor in the editor, so the terminal's stays hidden.
    return '\x1b[?25l\x1b[2J\x1b[H\x1b[0m' + '\r\n'.join(lines)


def swift_escape(s):
    out = []
    for ch in s:
        if ch == '\\':
            out.append('\\\\')
        elif ch == '"':
            out.append('\\"')
        elif ord(ch) < 0x20 or ord(ch) == 0x7f:
            out.append(f'\\u{{{ord(ch):X}}}')
        else:
            out.append(ch)
    return ''.join(out)


def swift_literal(text, indent):
    rows = text.split('\r\n')
    body = [indent + swift_escape(r) + ('\\r' if i < len(rows) - 1 else '')
            for i, r in enumerate(rows)]
    return '"""\n' + '\n'.join(body) + '\n' + indent + '"""'


def swift_file(frames):
    pad = ' ' * 16
    decls = '\n\n'.join(
        f'        /// {pane}: {W} columns by {ROWS} rows.\n'
        f'        static let {name} = DemoTerminalFrame(\n'
        f'            cols: {W},\n'
        f'            text: {swift_literal(text, pad)})'
        for name, W, pane, text in frames)
    names = ', '.join(name for name, *_ in frames)
    return f'''// Generated by scripts/demo-terminal/make_omp_frames.py; edit the frames
// there and rerun it rather than changing this file.
#if DEBUG && targetEnvironment(simulator)
    /// The OMP-styled terminal frames demo Agent panes show, one per pane
    /// width the README screenshots capture. Each is taller than any pane,
    /// so painting it scrolls to the prompt on the pane's bottom row.
    enum DemoTerminalFrames {{
{decls}

        /// Narrowest first.
        static let all = [{names}]
    }}
#endif
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--ans-dir', type=pathlib.Path)
    parser.add_argument('--check', action='store_true',
                        help='fail if the committed Swift file is out of date; write nothing')
    args = parser.parse_args()
    frames = [(name, W, pane, ansi(frame(W, narrow)))
              for name, W, narrow, pane in FRAMES]
    assert [f[1] for f in frames] == sorted(f[1] for f in frames), 'FRAMES must be narrowest first'
    generated = swift_file(frames)
    if args.check:
        current = SWIFT_OUT.read_text(encoding='utf-8') if SWIFT_OUT.exists() else ''
        if current != generated:
            sys.exit(f'{SWIFT_OUT.relative_to(REPO)} is out of date; run {pathlib.Path(__file__).relative_to(REPO)}')
        print(f'{SWIFT_OUT.relative_to(REPO)} is up to date')
        return
    SWIFT_OUT.write_text(generated, encoding='utf-8')
    print(f'wrote {SWIFT_OUT.relative_to(REPO)}')
    if args.ans_dir:
        args.ans_dir.mkdir(parents=True, exist_ok=True)
        for name, *_, text in frames:
            path = args.ans_dir / f'omp-{name}.ans'
            path.write_bytes(text.encode('utf-8'))
            print(f'wrote {path}')


if __name__ == '__main__':
    main()
