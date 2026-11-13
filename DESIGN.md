# Waycar design

This file is how Waycar looks and sounds, on waycar.dev and in the app. Read it before you pick a color, a font, or a word.

## The one rule

Every brand value lives in `design/tokens.json`. To change one:

1. Edit `design/tokens.json`.
2. Run `scripts/generate-brand-tokens.py`.
3. Commit the JSON and every file it rewrote.

Never hard-code a brand value. No hex codes, `rgb()` literals, or `Color(red:green:blue:)` for brand colors in a component or a view. If a value you need is missing, add a token first.

The script writes these files. Do not edit them by hand.

| File | What it holds | Who reads it |
| --- | --- | --- |
| `apps/web/src/styles/tokens.css` | CSS custom properties | `global.css` imports it, so every page and component has them |
| `apps/web/src/styles/tokens.ts` | Color strings | Places CSS cannot reach, like `<meta name="theme-color">` |
| `Sources/Waycar/Design/BrandTokens.swift` | `Brand.Colors`, `Brand.Gradients`, `Brand.Fonts`, `Brand.Tracking`, `Brand.Radius`, `Brand.Spacing`, `Brand.Shadows`, `Brand.Glass`, `.brandGlass()`, `.brandShadow(_:)` | The app |
| `DESIGN.md` | The token tables below | You |

`scripts/generate-brand-tokens.py --check` fails when any of them is out of date. CI runs it in the codegen drift job (`.github/workflows/ci-node.yml`).

## Brand principles

- **Terminal-native.** Waycar is a tool for people who live in a terminal. Labels, status, pills, and code use the mono font. Show real commands and real output, not mock art.
- **Near-black.** The ground is `bg` (`#07080b`), never pure black. Depth comes from faint white tints, hairlines, and soft glows, not from heavy color.
- **Violet to cyan.** There is one brand gradient, `grad`. Use it small: one accent word in a title, the rule before a kicker, a toggle, a tag. Never on a full background or on body text. Violet glows sit behind hero art. Cyan marks what is live or focused.
- **Plain words.** Write at an 8th-grade reading level. Short sentences. Say what the thing does. No em-dashes: use a period, a comma, a colon, or parentheses. No jargon. When you need a domain word, use the one in `CONTEXT.md` (Host, Agent, Console).
- **A serious pro tool.** Calm, exact, a little quiet. No hype.

### The name and the caboose

Waycar is a quiet name, not a theme.

- The caboose logo is the only rail reference. Use it as a mark, and use it sparingly: the app icon, the site header, one mark on a branded sheet.
- The logo is a flat caboose carrying a `>_` shell prompt, brand violet on the near-black page ground (the violet palette). Settings › App Icon also offers the caboose and the bare `>_` prompt mark in other palettes. Every logo file (app icons, docs, site favicon and Open Graph image) comes from `scripts/generate-app-icons.py`; never edit the PNGs by hand.
- No train puns ("all aboard", "on track", "full steam ahead").
- No cartoon trains, no track or rail motifs, no railroad copy, in the app or in marketing.
- Never make it look like a child's toy train.
- Token names describe a role (`mark-accent`), never the picture (`caboose-red`).

## Tokens

Web names are CSS custom properties. Every opaque color also has a `-rgb` twin of bare channels, so tints stay on tokens: `rgb(var(--violet-rgb) / 0.35)`. iOS names live in `BrandTokens.swift`. The site is dark only, so each token has one value.

<!-- BEGIN GENERATED TOKENS: edit design/tokens.json, then run scripts/generate-brand-tokens.py -->

### Color

| Token | Value | Web | iOS | Use |
| --- | --- | --- | --- | --- |
| bg | `#07080b` | `--bg` | `Brand.Colors.bg` | Page ground. Near-black, never pure black. |
| bg-2 | `#0c0d12` | `--bg-2` | `Brand.Colors.bg2` | Raised ground for floating callouts. |
| panel | `#0a0b0f` | `--panel` | `Brand.Colors.panel` | Inset panels and badges that sit on the ground. |
| ink | `#0a0a0d` | `--ink` | `Brand.Colors.ink` | Deepest near-black. Terminal window ground, and text on paper. |
| surface | `#0e0f13` | `--surface` | `Brand.Colors.surface` | Form fields and the core of device bezels. |
| surface-2 | `#121318` | `--surface-2` | `Brand.Colors.surface2` | Frames around app screenshots. |
| surface-3 | `#141519` | `--surface-3` | `Brand.Colors.surface3` | Composer and other raised input panels. |
| paper | `#f5f5f7` | `--paper` | `Brand.Colors.paper` | The one light surface: primary button, skip link, QR ground. |
| white | `#ffffff` | `--white` | `Brand.Colors.white` | Neutral base for white hairlines, sheen, and tints. Use with alpha. |
| black | `#000000` | `--black` | `Brand.Colors.black` | Neutral base for drop shadows. Use with alpha. |
| line | `#ffffff at 8%` | `--line` | `Brand.Colors.line` | Default hairline and card border. |
| line-2 | `#ffffff at 14%` | `--line-2` | `Brand.Colors.line2` | Stronger hairline: buttons, windows, device frames. |
| text | `#edeef3` | `--text` | `Brand.Colors.text` | Primary text. 16.9:1 on bg. |
| text-2 | `#a1a7b5` | `--text-2` | `Brand.Colors.text2` | Secondary text and ledes. 8.2:1 on bg. |
| text-3 | `#7d8495` | `--text-3` | `Brand.Colors.text3` | Tertiary text, captions, muted title words. 5.3:1 on bg (AA). |
| title-fade | `#b4b8c5` | `--title-fade` | `Brand.Colors.titleFade` | Bottom of the hero headline fade. |
| violet | `#8b5cf6` | `--violet` | `Brand.Colors.violet` | Brand violet. Glows and shadows. |
| violet-soft | `#a78bfa` | `--violet-soft` | `Brand.Colors.violetSoft` | Readable violet for text on dark: kickers, prompts, selection. |
| accent | `#8b5cf6` / light `#7c3aed` | `--accent` | `Brand.Colors.accent` | Interactive tint in the app (AccentColor): buttons, links, selection, toggles, the New Agent button. Light mode uses the light value. The site stays violet through `violet`/`violet-soft`. |
| indigo | `#818cf8` | `--indigo` | `Brand.Colors.indigo` | Middle stop of the brand gradient only. |
| quiet-action | `#a1a7b5` / light `#6b7280` | `--quiet-action` | `Brand.Colors.quietAction` | Cancel and dismiss buttons in alerts, dialogs, sheets and menus: quiet gray, so the primary violet and destructive red stand out. App-only; the site has no quiet controls. |
| cyan | `#22d3ee` | `--cyan` | `Brand.Colors.cyan` | Brand cyan. Focus rings, live dots, links in code. |
| cyan-deep | `#0e7490` | `--cyan-deep` | `Brand.Colors.cyanDeep` | Cyan that reads on paper (the dot inside the primary button). |
| blocked | `#8ab4f8` | `--blocked` | `Brand.Colors.blocked` | Agent status: blocked. Matches herdr's TUI palette. |
| working | `#f1d98a` | `--working` | `Brand.Colors.working` | Agent status: working. |
| done | `#9bd88f` | `--done` | `Brand.Colors.done` | Agent status: done. |
| idle | `#a3aab7` | `--idle` | `Brand.Colors.idle` | Agent status: idle. |
| danger | `#f87171` | `--danger` | `Brand.Colors.danger` | Errors, strike-throughs, and the red usage tier. |
| warn | `#fb923c` | `--warn` | `Brand.Colors.warn` | Warnings and the amber usage glow. |
| term-text | `#d8dae1` | `--term-text` | `Brand.Colors.termText` | Terminal and code block text. |
| term-comment | `#8a90a0` | `--term-comment` | `Brand.Colors.termComment` | Terminal comments. |
| term-flag | `#f5c39a` | `--term-flag` | `Brand.Colors.termFlag` | Terminal flags and quoted strings. |
| term-accent | `#f0a0b8` | `--term-accent` | `Brand.Colors.termAccent` | Terminal highlights such as package names. |
| term-dot | `#2a2b31` | `--term-dot` | `Brand.Colors.termDot` | Window title bar dots. |
| mark-ground | `#07080b` | `--mark-ground` | `Brand.Colors.markGround` | App icon ground, sampled like every mark color from docs/images/waycar-icon.svg (scripts/generate-app-icons.py, violet palette). Only on surfaces that echo the icon. |
| mark-surface | `#1e1a2e` | `--mark-surface` | `Brand.Colors.markSurface` | App icon track color, for cards on mark-ground. |
| mark-accent | `#8b5cf6` | `--mark-accent` | `Brand.Colors.markAccent` | App icon body color. Badges and buttons on mark-ground; content on it is mark-ground, as the icon cuts its prompt through to the ground. |
| mark-highlight | `#ede9fe` | `--mark-highlight` | `Brand.Colors.markHighlight` | App icon cupola window. Small symbols on mark-ground. |
| mark-ink | `#edeef3` | `--mark-ink` | `Brand.Colors.markInk` | Text on mark-ground. |
| chat-user | `#5b3fb8` | `--chat-user` | `Brand.Colors.chatUser` | Chat Mode: the user's message bubble and the Console's Chat Mode badge. Violet family, deep enough for text on it. |
| chat-user-text | `#f5f3ff` | `--chat-user-text` | `Brand.Colors.chatUserText` | Chat Mode: text on the user bubble, and the badge's glyph. |
| chat-agent | `#1a1b21` | `--chat-agent` | `Brand.Colors.chatAgent` | Chat Mode: the Agent's message bubble, typing indicator, and Blocked card. Raised-surface family. |

### Status

| Hue | Statuses | Wash | Ink | App | Use |
| --- | --- | --- | --- | --- | --- |
| blue | blocked | `#89b4fa` / light `#1e66f7` | `#89b4fa` / light `#1852c6` | `StatusPaletteTokens.blue`, `.blueInk` | herdr's Catppuccin blue, the hue its sidebar paints the rows waiting on the user. The Latte ink keeps OKLCH H and C and drops L until badge text clears 4.5:1 on its 0.15-opacity wash. |
| green | done | `#a6e3a1` / light `#40a02b` | `#a6e3a1` / light `#0d7900` | `StatusPaletteTokens.green`, `.greenInk` | herdr's Catppuccin green. Latte ink darkened the same way as blue. |
| yellow | working | `#f9e2af` / light `#df8e1d` | `#f9e2af` / light `#9f5300` | `StatusPaletteTokens.yellow`, `.yellowInk` | herdr's Catppuccin yellow. Latte yellow measures 2.3:1 on its own capsule, so its ink is darkened the same way as blue. |
| red | unknown | `#f38ba8` / light `#d20f39` | `#f38ba8` / light `#c70030` | `StatusPaletteTokens.red`, `.redInk` | herdr's Catppuccin red, for herdr's unknown status: something failed. Latte ink darkened the same way as blue. |
| muted | idle, and any other status | `#7f849c` / light `#6c6f85` | `#a6adc8` / light `#5c5f77` | `StatusPaletteTokens.muted`, `.mutedInk` | herdr's muted-text role, for Idle and any status this build cannot read. Wash is Mocha overlay1 and Latte subtext0 (Mocha overlay0 is too dim for a phone label); ink is Mocha subtext0 and Latte subtext1. |

### Gradient

| Token | Web value | iOS | Use |
| --- | --- | --- | --- |
| grad | `linear-gradient(90deg, #a78bfa 0%, #818cf8 45%, #22d3ee 100%)` | `Brand.Gradients.grad` | The brand gradient, violet to cyan. Accent words, kicker rules, toggles, tags. |
| grad-title | `linear-gradient(180deg, #ffffff 30%, #b4b8c5 110%)` | `Brand.Gradients.gradTitle` | Hero headline fill, white fading to cool grey. |
| glass-fill | `linear-gradient(180deg, rgb(255 255 255 / 0.045), rgb(255 255 255 / 0.015))` | `Brand.Gradients.glassFill` | Glass card fill. |
| keycap | `linear-gradient(180deg, #1b1c22, #111216)` | `Brand.Gradients.keycap` | Keyboard key face. |
| bezel-tablet | `linear-gradient(160deg, #23242b, #0e0f13 40%, #16171c)` | `Brand.Gradients.bezelTablet` | iPad frame around screenshots. |
| bezel-phone | `linear-gradient(160deg, #2a2b33, #0e0f13 40%, #1a1b21)` | `Brand.Gradients.bezelPhone` | iPhone frame around the hero screenshot. |
| bezel-phone-flat | `linear-gradient(160deg, #26272e, #0e0f13 50%, #17181d)` | `Brand.Gradients.bezelPhoneFlat` | iPhone frame in the screenshot gallery. |

### Shadow

| Token | Web value | iOS | Use |
| --- | --- | --- | --- |
| shadow-button | `0 0 0 1px rgb(255 255 255 / 0.2), 0 8px 30px -8px rgb(167 139 250 / 0.55)` | `Brand.Shadows.button` | Primary button: white ring plus violet lift. |
| shadow-window | `0 40px 100px -30px rgb(0 0 0 / 0.9), 0 0 0 1px rgb(0 0 0 / 0.4), 0 30px 80px -40px rgb(139 92 246 / 0.5)` | `Brand.Shadows.window` | Terminal windows: deep drop plus a violet underglow. |
| shadow-device | `0 0 0 1px rgb(255 255 255 / 0.12), inset 0 0 0 1px rgb(255 255 255 / 0.04), 0 60px 120px -30px rgb(0 0 0 / 0.9), 0 30px 60px -30px rgb(139 92 246 / 0.35)` | `Brand.Shadows.device` | Device frames around screenshots. |
| shadow-glass | `inset 0 1px 0 rgb(255 255 255 / 0.05)` | web only | Glass card top sheen. |
| shadow-keycap | `inset 0 -2px 0 rgb(0 0 0 / 0.4)` | web only | Keyboard key bottom edge. |
| glow-dot | `0 0 10px #22d3ee` | `Brand.Shadows.glowDot` | Live status dot glow. |

### Radius

| Token | Value | Web | iOS | Use |
| --- | --- | --- | --- | --- |
| bubble | 18 | `--radius-bubble` | `Brand.Radius.bubble` | Chat Mode message bubbles. |
| card | 18 | `--radius-card` | `Brand.Radius.card` | Glass cards. |
| window | 16 | `--radius-window` | `Brand.Radius.window` | Terminal windows. |
| control-lg | 12 | `--radius-control-lg` | `Brand.Radius.controlLg` | Large buttons. |
| control | 10 | `--radius-control` | `Brand.Radius.control` | Buttons and the skip link. |
| keycap | 8 | `--radius-keycap` | `Brand.Radius.keycap` | Keyboard keys and small tiles. |
| chip | 6 | `--radius-chip` | `Brand.Radius.chip` | Focus rings, tiny badges. |
| code | 5 | `--radius-code` | `Brand.Radius.code` | Inline code. |
| pill | 999 | `--radius-pill` | `Brand.Radius.pill` | Pills and capsules. |

### Space

| Token | Value | Web | iOS | Use |
| --- | --- | --- | --- | --- |
| wrap | `1200px` | `--wrap` | `Brand.Spacing.wrap` | Max content width. |
| gutter | `24px, 20px compact` | `--gutter` | `Brand.Spacing.gutter` | Side padding. Compact below the compact breakpoint. |
| header-h | `64px` | `--header-h` | `Brand.Spacing.headerHeight` | Sticky header height. |
| section-pad | `clamp(80px, 11vw, 112px)` | `--section-pad` | `Brand.Spacing.sectionPadMin / Max` | Vertical padding of a page section. |

### Type

| Token | Web size | Weight, leading, tracking | iOS | Use |
| --- | --- | --- | --- | --- |
| display | `clamp(40px, 7.2vw, 84px)` | 650, leading 1.02, tracking -0.045em | `Brand.Fonts.display` (largeTitle, semibold, sans) | Hero headline. One per page. |
| title | `clamp(32px, 4.4vw, 52px)` | 620, leading 1.06, tracking -0.035em | `Brand.Fonts.title` (title, semibold, sans) | Section titles. |
| lede | `17.5px` | default | `Brand.Fonts.lede` (body, regular, sans) | Intro paragraph under a title, in text-2. |
| body | `16px` | leading 1.6 | `Brand.Fonts.body` (callout, regular, sans) | Running text. |
| button-lg | `15px` | default | `Brand.Fonts.buttonLg` (body, medium, sans) | Large buttons. |
| button | `14px` | 500, tracking -0.005em | `Brand.Fonts.button` (subheadline, medium, sans) | Buttons. |
| code | `13.5px` | leading 1.9 | `Brand.Fonts.code` (footnote, regular, mono) | Code blocks and terminal windows. |
| label | `12.5px` | 500, tracking 0.08em | `Brand.Fonts.label` (caption, medium, mono) | Kickers above titles. Uppercase, spaced out, violet-soft. |
| caption | `12px` | 500 | `Brand.Fonts.caption` (caption, medium, mono) | Pills, window titles, callouts. |

### Font

| Token | Web stack | iOS | Use |
| --- | --- | --- | --- |
| sans | `-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Geist', 'Segoe UI', system-ui, sans-serif` | `Brand.Fonts.sansDesign` | San Francisco on Apple devices, Geist elsewhere. |
| mono | `'Geist Mono', ui-monospace, 'SF Mono', 'SFMono-Regular', Menlo, Consolas, monospace` | `Brand.Fonts.monoDesign` | Geist Mono on the web, SF Mono in the app. Every label, kicker, pill, and code sample. |

<!-- END GENERATED TOKENS -->

## Using the tokens

### Web (`apps/web`)

- Read tokens with `var(--name)`. For a tint, use the `-rgb` twin: `rgb(var(--cyan-rgb) / 0.1)`.
- No color literals in components or pages. The one exception is the theme swatches in `Features.astro`: they show other people's terminal themes, so they are content.
- Layout geometry can stay local: section sizes, device screen corners, where a glow sits. Its colors cannot.
- The glass card (`.glass`) is the default container. Use `.btn-primary` (paper with ink text) for the main action and `.btn-ghost` for the rest.
- Status colors (`blocked`, `working`, `done`, `idle`) mean agent status and nothing else.
- Body copy uses `text` or `text-2`. Keep `text-3` for captions and hints.
- Something CSS cannot reach (a `<meta>` tag, an SVG attribute you cannot style) imports `color` from `src/styles/tokens.ts`.

### iOS app chrome

- Everyday screens follow the system: light and dark mode, system backgrounds, lists, and forms. Do not paint them near-black.
- Any brand value in a view comes from `Brand`. Never write a brand color as a literal.
- Use `Brand.Fonts` for brand text. They map to SwiftUI text styles, so Dynamic Type still works. Mono (`Brand.Fonts.monoDesign`) is for labels, status, and code.
- The terminal fonts (JetBrains Mono, IBM Plex Mono) are user settings, not brand fonts.
- The `mark-*` colors only belong on surfaces that echo the app icon, like the What's New sheet.
- The Apple Watch app uses pure black (`#000000`) as its ground: a watchOS/OLED exception to "never pure black", so the screen blends into the bezel and unlit pixels stay off.
- Interactive tint is the `accent` token: the app's AccentColor asset (generated), which covers `Color.accentColor` and UIKit everywhere, plus `.tint(Brand.Colors.accent)` at the app root and at the root of every sheet that holds Toggles or pickers (a sheet does not take the root's tint, and Toggles default to green). So buttons, links, selection and Toggles are violet. Never use `.blue` or other system hues for interactive elements. Red stays for destructive actions, errors and recording. Cancel and dismissive buttons — alerts, dialogs, sheet toolbars, and Agent-menu symbols — use `quiet-action` gray instead, so the primary violet and destructive red stand out. The Settings › Appearance menu picker shows its value in system secondary gray (`.tint(Color.secondary)`), like the row icons.

### Screenshots

- README and waycar.dev screenshots come from `make screenshots` (the demo fixture). Never capture or retouch them by hand.
- The demo shows real developer work: real repo names, real commands, real agent output. No joke names.
- On the site, frame them with the `bezel-*` gradients and `shadow-device`.
- Any caption or frame around a store screenshot uses the site's look: `bg` ground with the page glow, `display` or `title` type in `text`, at most one accent word in `grad`. No train imagery.

## Restyle candidates

These are not done yet. Each one would change how an existing screen looks, so it needs its own change.

- Agent status colors differ between the site (`blocked`, `working`, `done`, `idle` tokens) and the app (the `status` hues in `tokens.json`: herdr's Catppuccin Mocha and Latte, read by `AgentStatusPalette.swift` and the watch's `WatchBrand.Status`). Candidate: point the site at the `status` hues.
- The What's New sheet draws a rail with sleepers under its button (`WhatsNewSheet.swift`). That is a track motif. Candidate: a plain hairline.
- The Live Activity widget hard-codes its dark surface (`AgentLiveActivityWidget.swift`). The widget target does not compile `BrandTokens.swift` yet.
- `AgentListFieldsSettingsView.swift` hard-codes a light preview fill (`#FAFAFC`).
- Site copy still has em-dashes in most sections (`Features.astro`, `Mosh.astro`, `AIUsage.astro`, and others). Rewrite them when you touch that copy.
- The near-black ramp (`bg`, `bg-2`, `panel`, `ink`, `surface`, `surface-2`, `surface-3`) has seven steps that sit a few units apart. It could shrink to three or four.
