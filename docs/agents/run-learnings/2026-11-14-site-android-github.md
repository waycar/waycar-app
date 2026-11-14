# 2026-11-14 — Site: Android mentions out, GitHub beside every download

- **Worked:** one tiny component (`SourceLink.astro`) placed by each caller,
  plus a build test that counts it against the store buttons
  (`picker.test.mjs`), instead of editing a dozen layouts by hand and hoping
  none was missed.
- **Broke:** a component that spreads the caller's attributes inherits the
  caller's scoped styles: Astro hands every child the parent's
  `data-astro-cid-*`, so the article rail's `.module a` would have painted the
  link cyan. A component that must look the same everywhere takes no caller
  attributes.
- **Broke:** `text-decoration` on an `inline-flex` link also underlines a
  child `inline-block` (flex items are blockified, not atomic inlines). Put the
  underline on a span around the words instead.
- **Watch out:** `apps/web/scripts/articles.test.mjs` allows only App Store
  links off-site in the article rail and TOC, and `MODULE_HEIGHTS` in
  `src/data/article-rail.ts` mirrors the rail boxes: a new line in a rail
  module means both. A new website analytics event also means the "This
  website" sentence and date in `PRIVACY.md`.
- **Watch out:** for 390 and 1440 px screenshots without the cookie banner,
  a throwaway `playwright-core` script outside the repo (any installed
  `playwright-core` and a system Chromium) removes `[data-consent-banner]`
  and shoots elements; a screenshot tool that
  cannot run a step first.
