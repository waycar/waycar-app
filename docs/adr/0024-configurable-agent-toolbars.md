---
status: accepted
---

# One configurable Toolbar under every Agent

Agent detail shows one bar at the bottom, the **Toolbar**, and the user
configures it in Settings → Toolbar (#16). It looks the same whether the
Composer is open, the terminal keyboard is up, or neither is:

- On the left are the user's **Toolbar Items**. They scroll horizontally,
  and the edge fades when more items are hidden.
- On the right are three fixed buttons. They are not part of the stored
  layout and cannot be removed:
  - 💬 **Message Agent** opens the Composer card (ADR 0013). The keyboard
    stays down until the user taps the text field. A second tap closes the
    card.
  - ⌨ **Terminal Keyboard** raises or dismisses the system keyboard that
    types into Attach (Direct Input, ADR 0016).
  - 🎤 **Dictate to Agent** dictates a message and sends it on stop, the way
    Direct Input dictation already does (see Dictation). While recording it
    shows a red circle with a stop square. It does not close the Composer
    or the keyboard.

💬 and ⌨ exclude each other. Tapping ⌨ while the Composer is open closes the
Composer and raises the terminal keyboard. Tapping 💬 while the terminal
keyboard is up dismisses it and opens the Composer, keyboard down.

The Toolbar is the only bar in the Agent view; nothing sits below it. The
in-view Agent chips row (the old Agent switcher strip) is removed. The user
switches Agents with the back button or back swipe on iPhone, and with the
sidebar on iPad.

The Composer card keeps its own fixed row, as it was before this change:
`+`, More, …, then the Composer mic and Send. That mic dictates into the
draft, as before. The row is not configurable.

## Toolbar Items

The stored layout is one ordered list of Toolbar Items. A Toolbar Item can
be:

- a Key: any non-character Terminal Keyboard key (Esc, Tab, arrows, Home,
  End, PgUp, PgDn and so on), F1–F12 included behind a chip in the picker. A
  character key needs a one-step Custom Key;
- a Combo: one key plus Ctrl, Alt and/or Shift, with presets such as ⌃C;
- a sticky modifier chip;
- an app action: Paste, More, Tools keyboard, Add Image, Add File, Open
  Terminal, New Agent, Skills, Snippets, Worktree Details, Rename Agent or
  Rename Workspace;
- a specific Snippet;
- a **Custom Key**.

The default is Esc, Tab, ⇧Tab, ↑, ↓, ←, →, ⌫, ⇧Enter, Paste, Enter, More and
Tools keyboard. Nothing is stored for a user who never customizes, so
improved defaults reach them automatically. Every user item can be removed,
More and Enter included: More is also on the Composer row, and the system
Return key and the tools keyboard also send Enter.

A Custom Key is something the user builds and stores once in a synced
library. Like the layout and spacing, the library is part of the per-device-type
catalog, so a Custom Key built on iPhone does not appear on iPad. It is
either a sequence of one to eight key presses, or one text
with an optional Enter after it. The layout points to it by ID, the same way
it points to a Snippet. A new Custom Key is added to the Toolbar unless the
user switches off "Add to bar" in the builder. An item appears at most once.
Its identity is the thing it refers to (a chord, an action, a Snippet, a
Custom Key), not the row. A deleted Custom Key is removed from the layout. A
deleted Snippet stays in the stored layout: the Toolbar hides it, and the
editor lists it as a missing Snippet until the user removes it.

Some things are never items:

- Close Agent stays in More only. A destructive action should not be one tap
  away.
- The tools keyboard's 3×3 quick-key pad stays fixed. It replaces the
  keyboard; it is not a bar.
- Attach Links are never items. They surface in the status row's strip,
  beside the files the terminal printed, and in its Files & Links list:
  status, not an action.

## Delivery

Every item goes to the owner that already handles that kind of input:

With Message Agent closed, the terminal takes local input (the idle Toolbar
view is not display-only); while Message Agent is open, Attach is display-only
and authored text stays in the draft (ADR 0013).

- **Keys** go to Attach and take any armed sticky modifier, as the Terminal
  Keyboard does.
- **Combos** and Custom Key key steps send exactly their chord and ignore
  armed modifiers, the way the ⌃C interrupt already does, so the chord on the
  cap is the chord sent. They reach Attach even while the Composer is open.
  They are explicit controls, like the tools keyboard's own keys.
- **Text items** (Paste, a Snippet, a Custom Key's text without Enter) go
  into the draft while the Composer is open, and otherwise into Attach
  without Enter. Snippets only insert (ADR 0009).
- **A Custom Key's text with Enter** always goes through Send's delivery
  owner, never a raw PTY write, whether or not the Composer is open. An
  Agent gets one `agent.prompt`. A Shell gets one `pane.send_input` carrying
  the text and Enter. It follows Send's rules:
  - While the Agent is Blocked, the text is inserted without Enter.
  - During `launch_pending`, it waits out the launch the way Send does. If
    the launch never clears, the text is inserted into Attach without Enter.
- The text is normalised like a Snippet's: CR and CRLF become LF, and other
  control characters are refused. So only the explicit Enter setting can
  submit.
- Every item whose `submits` flag is set, whether text + Enter or a key step
  that encodes CR, shows a ⏎ on its cap, a "Sends" tag in Settings, a
  warning in the builder, and "sends" in its VoiceOver label.
- Actions that open menus or sheets use the existing action-menu dispatch.

An action the current Agent cannot run is hidden, not shown broken. Skills
and 🎤 are hidden on a Shell, and 🎤 before iOS 26. Add Image and Add File
are disabled while an attachment cannot start.

This **supersedes ADR 0009 in part**. ADR 0009 rejected any submit on the
user's behalf, and a per-Snippet `autoSubmit` flag. Both still hold for
Snippets: tapping a Snippet never sends anything. A Custom Key that submits
is a different kind of thing. The user builds it to submit and switches
Enter on deliberately, and it is marked as sending everywhere it appears. It
cannot do more than Send can: a Blocked prompt gets an insert, not a
keystroke. **ADR 0013 is unchanged.** With the Composer open, text items go
into the draft or through Send, so authored input still never reaches the
PTY as raw text.

## Settings and sync

Settings → Toolbar is one editor: a live preview of the bar, the "Your
items" list (remove, drag to reorder, and Move Up / Move Down for
VoiceOver), Add Item…, locked rows for Message Agent, Terminal Keyboard and
Dictate to Agent, a footer explaining that 💬 and ⌨ exclude each other, and
Reset. The Custom Keys section and builder sit below it. Reset keeps the
Custom Key library.

There is one layout per device type: iPhone and iPad each keep their own
(Mac Catalyst uses the iPad one). Each is stored as one versioned JSON
catalog, `{"version":1,"layout":{"items":[…]},"customKeys":[…]}`, under
`agent-toolbar-layouts.phone` or `agent-toolbar-layouts.pad`, and syncs
through ADR 0019's `PreferenceSync` with a `canRead` check, so a reinstall
restores it. A device registers only its own key: the iPhone layout is never
shared with the iPad, and the same holds for spacing and Custom Keys: the
whole catalog is per device type. The pre-split shared key
`agent-toolbar-layouts` is adopted once into an empty device-type key and
then removed. An older
build never adopts or overwrites a catalog with a newer `version`. New item
kinds and actions do not bump the version; older builds skip what they do
not know. While the catalog is unreadable, the app shows the default layout
and refuses edits until the user confirms a Reset, as Agent List Fields
does. Syncing is whole-value, and the last writer on the same device type wins.
The catalog also carries an optional `itemSpacing` (points between the
scrolling items: the whole drawn gap between caps, 1…24 in steps of 1, default 12; tap areas overhang into the gap by up to 4 pt a side but never past half of it, so they reach 44 pt at 8 pt or more and never overlap); missing or unreadable means the default, and Reset restores it.

## Considered Options

- **Two bars, a Shortcut Bar per input mode above an Agent Bar with
  extras** — rejected after mockups. Three layouts and two bars that
  changed with the mode were hard to explain, extras had to fold into More
  when they did not fit, and the stack covered too much terminal. One bar
  that looks the same in every state is easier to learn.
- **Configurable Composer row (More moved next to Send)** — rejected. The
  Composer row stays as it was; the Toolbar is the one place to customize.
- **Device-local layouts** — rejected. A reinstall would lose the bar and
  the user would set it up again.
- **One layout shared by iPhone and iPad** — rejected. The two screens are
  different widths and used differently, so a bar tuned for one fits the
  other badly.
- **Per-Host or per-agent-kind layouts** — rejected for now. The scrolling
  list already fits any width.
- **Custom Keys that never submit** — rejected. Commands such as `/compact`
  are the main reason to build one, and Send's owner already knows how to
  submit safely.
- **Sending text + Enter as a PTY write with CR after a short delay** —
  rejected. It skips `agent.prompt`, the Blocked rule and the launch wait,
  and it bets on timing to keep a paste and a CR apart.
- **A free-form macro string** (tmux-style `C-a` syntax) — rejected. The
  builder is structured (modifier chips, a key grid, steps), so there is
  nothing to parse and nothing invalid to store. No multiplexer-prefix
  presets ship.
- **A palette editor you drag tiles from** — rejected. It is weaker for
  VoiceOver and cannot show subtitles that explain what a Custom Key does.

## Consequences

- Glossary gains **Toolbar**, **Message Agent**, **Toolbar Item** and
  **Custom Key**. The Agent switcher strip, later the Agent Bar, is gone
  from Agent detail; switching Agents is back navigation or the iPad sidebar.
- ADR 0016's fixed shortcut row is replaced by the Toolbar, whose default
  starts with the old row. ADR 0009 gets a "superseded in part" status line.
- Key caps size to their label (at most 12 characters, one line) instead of
  fixed per-key widths. A Custom Key's cap shows its Label, or its keys or
  text when it has none.
- Tests check behaviour (default order, filtering, Custom Key delivery, how
  a Combo ignores armed modifiers, 💬/⌨ exclusivity, text routing), not a
  list of keys pinned in place.
