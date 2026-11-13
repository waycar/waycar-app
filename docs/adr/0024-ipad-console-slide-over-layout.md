---
status: accepted
---

# iPad Console uses a slide-over layout instead of NavigationSplitView

On iPad at regular width the Console no longer uses `NavigationSplitView`. A
custom slide-over layout puts the Agent list in a layer under the Agent, and
the Agent slides over it: left to hide the list, right to show it, while the
list stays where it is. The choice is `usesSlideOver` in
`ConsoleSplitPresentation`: regular width and the `.pad` idiom. Every iPhone
keeps `NavigationSplitView` at any width, so a Plus or Pro Max in landscape
(regular width) still shows the list beside the Agent with the system
toggle, and iPhone push navigation and its swipe back are unchanged. iPad at
compact width (Split View, a narrow Stage Manager window) keeps it too.

This amends ADR 0022's description of the terminal's leading-edge strip: on
iPad at regular width it opens and closes the list instead of swiping back.

The approved design (issue #15):

- **One toggle, fixed top-left.** A 44 pt circular button with
  `sidebar.left` sits at the top-leading corner above both layers, in the same
  place whether the list is open or closed. It is Liquid Glass on iOS 26 and
  later and a material circle before. Its row also holds the search capsule
  and the Status pills, so the list starts about 50 pt higher.
- **The list recedes under the Agent.** As the Agent covers it, the list
  scales down (to 0.94) and dims. The Agent's leading edge gets rounded
  corners while it is out, a hairline, and an edge shadow cast onto the list.
  The shadow is a gradient view: a `.shadow()` on the Agent layer would
  render the live terminal offscreen on every frame of the slide.
- **Landscape reveals beside, portrait pushes.** In landscape
  (`ConsoleSidebarReveal.beside`) the open Agent sits beside the list,
  narrowed to the width the list leaves. In portrait (`.push`) it keeps its
  full width and slides partly off screen; while the list is open, a tap on
  the visible Agent, a leftward drag on it, or choosing an Agent (the open
  one included) closes the list. The tap also focuses the Agent's terminal,
  as a tap on the terminal would, unless the Agent is locked or Message
  Agent is open. A Workspace Move that re-targets the open
  Agent to its new pane is not a choice and leaves the list open. A portrait
  pick skips the window crossfade (`DetailCrossfade`), which would otherwise
  hide the slide.
- **One reflow per toggle.** The Agent stays full width while it slides (its
  right edge runs off screen) and changes width only at rest: opening slides
  first and narrows after the animation (landscape only), closing widens first
  and then slides. Every width change resizes the terminal grid and makes the
  remote program redraw, so a slide that resized on every frame would reflow
  the terminal dozens of times.
  Rotation delivers the new visibility, width and reveal in one pass, so the
  layout snaps to its new rest in one reflow instead of animating through
  intermediate widths.

## Why

iPadOS owns the system split view's sidebar toggle. It moves the toggle
between columns (top-right of an open sidebar, top-left of the detail when the
sidebar is hidden), offers no way to put the search and filter row on the
toggle's row, and slides the sidebar in beside or over the detail. The
approved design needs the reverse layering, the detail moving over a
stationary list, and a toggle that never moves. Split view styles
(`.balanced`, `.prominentDetail`) only choose between beside and over; none
puts the sidebar underneath.

## Considered Options

- **Keep `NavigationSplitView` and remove its toggle** (`.toolbar(removing:
  .sidebarToggle)` and a toolbar button of our own): rejected. It fixes the
  toggle's position but not the layering or the header row, and the column
  animation stays the system's.
- **Overlay the list on the Agent**: rejected. It is the system's
  `.prominentDetail` look, the one the design moves away from.

## Consequences

- Waycar now owns what the split view gave for free on iPad:
  - the toggle, and its placement clear of the iPadOS window controls;
  - its VoiceOver labels, "Hide Sidebar" while the list is open and "Show
    Sidebar" while it is closed;
  - Control-Command-S, set on the toggle;
  - the left-edge swipe that opens the list with the Agent following the
    finger, and the drag on the Agent's edge that closes it. Both come from
    the Agent terminal's 24 pt leading-edge strip (`AgentEdgeBackGesture`),
    which on iPhone is swipe back. The layout hands it a
    `ConsoleSidebarRevealDrag` through the environment and does all of the
    math; the strip only forwards translations and the velocity. While the
    list is out, a `UIScreenEdgePanGestureRecognizer` on the layout also
    closes it from the screen's right edge (#30); portrait's catcher drag
    and plain pans under the touch wait for it to fail, while presses, taps
    and buttons on that edge (the terminal's selection handle, the
    message-jump tab) do not, and the layout defers the system's
    trailing-edge gestures meanwhile. Every drag settles on where its fling
    would coast under a scroll view's deceleration, not SwiftUI's
    quarter-second `predictedEndTranslation`, which let short flicks spring
    back;
  - hiding the covered layer from accessibility, so VoiceOver does not read a
    list the Agent is lying over;
  - pausing the covered list's per-frame animations: the layout sets
    `consoleListIsCovered` on the list while the Agent covers it at rest;
  - resigning search focus when the list hides, so the keyboard does not
    stay up for a field the Agent covers;
  - stopping the covered Agent's input: while the portrait list covers the
    Agent, `consoleDetailIsCovered` resigns its terminal or Composer keyboard
    and takes its keyboard commands off stage, keeping its Attach running;
  - Command-F with the list hidden, which shows the list first and focuses
    search once it is out, rather than focusing a field nobody can see;
  - Reduce Motion: state changes apply without the slide and scale.
- A size-class change (Stage Manager, Split View) swaps between the two
  layouts and rebuilds that subtree. `ConsoleView`'s state and the router
  live above it and survive the swap.
- The list's visibility intent keeps `ConsoleSplitVisibilityState`'s
  semantics: it is open by default in landscape and closed in portrait, and a
  user's choice that differs from the default survives rotation.
- The README screenshot run (`ReadmeScreenshots.swift`) finds the toggle by
  its "Hide Sidebar" label, which is now Waycar's own string rather than the
  system's; renaming it breaks that run.
