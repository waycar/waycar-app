# 2026-11-14 — Site: header links only to pages, footer trimmed

- **Worked:** measuring the header at a dozen widths in one browser step:
  same-origin iframes of each width, `getBoundingClientRect` on brand, links
  and buttons. It found the 320 px overlap and the right link-row breakpoint
  (799 px) before any screenshot.
- **Worked:** the screenshot tool with `selector` and a viewport taller than
  the page: the fixed cookie banner then sits below the footer, so the
  element shot is clean without a script.
- **Broke:** `pkill -f "astro dev --port N"` matched the bash running it and
  killed the tool call (exit 143). Match something only the server's command
  line has, or kill by pid.
- **Watch out:** below 800 px the header shows no page links (no menu), so
  the footer is a phone's only path to CarPlay, Help and Articles: keep them
  there when trimming.
- **Watch out:** the footer's Compare and Solutions columns now list picked
  ids (`SiteFooter.astro`, a missing id fails the build); a new page reaches
  its index, not the footer. Apple's trademark credit and the third-party
  notices link live under the policy on `/privacy`.
