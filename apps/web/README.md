# Waycar marketing site

The site at <https://waycar.dev>. Astro, static build, served by a Cloudflare
Worker. Fonts (Geist and Geist Mono, SIL OFL 1.1, `public/fonts/`) are
served by the site itself. Client-side JavaScript is limited to the copy button on the
install command (`CodeBlock`'s `copy` prop), the help search palette and the
help sidebar's collapse on narrow screens (see [Help docs](#help-docs)), the
changelog's infinite scroll (see [Changelog](#changelog)), the article body's
image lightbox (see [Articles](#articles)),
anonymous PostHog analytics
(`posthog-js`, bundled into `/_astro` and served same-origin; no autocapture or
session replay), and the Reddit and X ad-conversion pixels (see below; their
scripts load from the vendors' hosts). Consent is regional: the Worker marks
`<html data-consent>`
`required` for the EU, EEA, UK, Switzerland, or an unknown country, and
`not-required` elsewhere. Required regions and any browser sending Global
Privacy Control start cookieless, counted by PostHog's daily server-side hash,
but only required regions see `ConsentBanner`, where Allow switches to a
first-party cookie and Decline stays cookieless. There the footer's `Cookie
settings` button (`data-consent-open`) reopens the banner to change the choice;
it shows everywhere, and "Decline" outside required regions stops PostHog too.
Elsewhere the cookie is set from the first visit. Cookieless events need the PostHog
project's cookieless tracking setting on, or PostHog drops them. The script
sends `$pageview`, `$opt_in`, `get_picker_opened`, `app_store_clicked`,
`install_command_copied`, `article_toc_clicked`, and `article_rail_clicked` to
`us.i.posthog.com`. Controls opt in with `data-ph-event` (click) or
`data-ph-copy-event` (copy) attributes; see the script in
`src/layouts/Layout.astro`. `install_command_copied` comes from the install
command in the hero, in Setup, and in the article rail. An event sent from
inside a `data-ph-module="<id>"` wrapper also carries `module: <id>` (the
article page's `get-app`, `start-here`, `host-setup`, `first-launch` and
`toc-card`; see [Articles](#articles)), so a store tap in the rail's picker reads
`app_store_clicked` with `module=get-app` and `ct=article`. The id is written
at build time, never read from element text. Every store button opens a Get
Waycar picker (see [App Store switch](#app-store-switch)): the button sends
`get_picker_opened` with the `ct` of the App Store link inside its picker (a
paid ad's `ct` after the rewrite) and its `module`; the picker's App Store link
sends `app_store_clicked` with that same `ct` and `module`. The Android tile,
Close and the backdrop send nothing. Without JavaScript the site still works: the copy button stays hidden, the header's help search is a plain link to `/help`, a store button opens its picker through `:target` (two taps to the App Store link), and no events are sent.
The Worker (`src/worker.ts`) also sends anonymous server-side events:
`plugin_install_requested` per `GET /install.sh`, `plugin_package_downloaded`
per plugin package download (see [Plugin install events](#plugin-install-events)),
and `ad_link_clicked` per browser `GET /go/<slug>` (see [Ad links](#ad-links)).

Ad-conversion pixels (Reddit Ads `a2_jsoqcexpq95u`, X Ads `rghdf`) load from
`src/lib/ad-pixels.ts`, called by the Layout script. They never load for a
browser sending Global Privacy Control; in required regions they also wait for
"Allow"; elsewhere they load from the first visit until "Decline" (which
deletes their `waycar.dev` cookies and reloads the page). Both fire a page view
on load; an App Store click (`app_store_clicked`) sends Reddit `Lead` and X's
custom event `App Store click` (`tw-rghdf-rh8ye`). Their hosts are in the Worker's
CSP (`SECURITY_HEADERS`); a new pixel endpoint must be added there or the
browser blocks it silently. The policy covers all this under "Advertising
pixels" in `PRIVACY.md`: keep them in step.

Self-contained except for two build-time inputs: `/privacy` renders the
repo-root `PRIVACY.md`, so edit the policy there, and `/changelog` shows the
`## [Unreleased]` section of the repo-root `CHANGELOG.md` (see
[Changelog](#changelog)).

## Copy for humans and for agents

The landing page stays short: every feature named, in as few words as
possible. The full detail (every feature's long description, the SSH-vs-mosh
and herdr-vs-tmux tables, setup comments, requirements, all FAQ answers) lives
in `src/llms/index.md`. When a feature changes, update both.

Two endpoints serve it to AI agents, following [llms.txt](https://llmstxt.org):
`/llms.txt` (an overview and fact list) and `/index.md`
(`src/pages/index.md.ts`, which serves `src/llms/index.md`). Every page links
`/llms.txt` with `rel="describedby"`; a page passes `Layout`'s `markdown` prop
to add a `rel="alternate" type="text/markdown"` link (the home page passes
`/index.md`). Never link `/install.sh` from them: each GET logs a
`plugin_install_requested` event.

`/llms.txt` has two sources. The build serves the short, reviewed one in
`src/pages/llms.txt.ts`. On deploy, `scripts/generate-llms-txt.mjs` asks an
LLM (`z-ai/glm-5.3-flash` via OpenRouter, using the repository secret
`OPENROUTER_API_KEY`; the repository variable `LLMS_TXT_MODEL` overrides the
model) for a much richer file, written from the built site: the text of every
indexable page except the help, changelog, article, comparison, and solution
pages, `dist/index.md`, `dist/help.md`, `dist/articles.md`, `dist/compare.md`,
and `dist/solutions.md` (every help page's, article's, comparison's, and
solution's title, description, and link; their full text, or every release's
notes, would multiply the prompt). The result replaces `dist/llms.txt` only
if it passes `validateLlmsTxt`: llmstxt.org shape (one H1, a blockquote, no
H3, only link lists under H2s), a link to `/index.md`, a link to every article
`dist/articles.md` lists, the exact install command inside a code span or code
block, `/install.sh` nowhere outside it, and no URL, domain, email address,
number, or code that the sources do not contain. A failing file gets one
repair turn. A missing key, a failed request, or a file that still fails
leaves the reviewed `llms.txt` in place, with a workflow warning, and never
blocks the deploy.

The model runs only when the site's content changed. After every successful
deploy, the deploy job uploads the `dist/llms.txt` it shipped as the
`llms-txt` artifact (kept 90 days). On the next deploy, `--plan` finds the
newest such artifact from `main` (a push, scheduled or manual run) and
compares its run's commit with the one being deployed (GitHub API, the job's
`GITHUB_TOKEN`). If only other paths changed (`plugin/**`,
`scripts/package-plugin.sh`, `scripts/build-plugin-binaries.sh`, `CHANGELOG.md`,
`apps/web/src/content/changelog/**`, the workflow), the job downloads that
artifact and `--reuse` ships it again, so the rich file survives a deploy that
skips the model, and so does the daily scheduled deploy (see Articles) on a
day with nothing new. It regenerates when anything else under `apps/web/` or
`PRIVACY.md` changed (changelog release files under `src/content/changelog/**`
never trigger it), on a manual run (`workflow_dispatch`), on the first deploy
or once the artifact has expired, and whenever reuse is in doubt: an API
error, 300 or more changed files, an earlier file that is the committed
fallback (that generation failed), or one that no longer passes validation,
which includes one that lacks an article that has gone live on its date since.
To preview a generation locally without writing anything:

```bash
npm run build && OPENROUTER_API_KEY=… npm run generate-llms-txt -- --dry-run
```

`npm run generate-llms-txt -- --plan` with `GH_TOKEN`, `GITHUB_REPOSITORY`,
and `GITHUB_SHA` set prints the deploy job's reuse decision.

`/sitemap.xml` is written after the build by `integrations/sitemap.mjs`: every
built page with a canonical link and no `robots: noindex` (see `Layout`), by
its canonical URL. A new page joins it on its own; the 404 page and home page
B (canonical `/`) stay out; `/help`, every help page, every `/changelog` page, `/articles`, every published article, `/compare`, every comparison, `/solutions`, and every solution page are in it. `public/robots.txt` allows every crawler,
declares `Content-Signal: search=yes, ai-input=yes, ai-train=yes`, points to
`/llms.txt`, `/index.md`, `/help.md`, `/articles.md`, `/compare.md`, `/solutions.md`, and the sitemap, and disallows `/install.sh` so
crawlers do not log install events.

## Help docs

`/help` holds one page per Waycar feature, written in Markdown in
`src/content/help/<slug>.md`. The iOS app bundles the same folder (pages and
`categories.json`) for in-app Help, so the pages stay plain, portable
Markdown, and a change here ships in the next app build too. A new file is a
new page: the route, the sidebar, `/help`, search, the sitemap, `/help.md`,
the reviewed `/llms.txt`, and the app all pick it up from the folder.

**Frontmatter**, checked at build time by the Zod schema in
`src/content.config.ts` (unknown fields fail the build):

```yaml
---
title: Chat Mode
description: Talk to Claude Code, Codex, omp, pi or opencode as a simple chat instead of a terminal, with replies in your notifications.
category: agents
order: 100
keywords: [conversation, transcript, allow, cancel, chat prompt, quick thinking, no reply, attach]
related: [new-chat, composer, notifications, chat-mode-troubleshooting]
---
```

- `title`: at most 60 characters, sentence case. The page's H1 and the start
  of its `<title>` (`Chat Mode · Waycar Help`).
- `description`: 70–160 characters, one sentence saying what the feature is
  or does. The meta description, the lead under the H1, and the search
  snippet. Quote it if it contains `: `.
- `category`: one of the ids in `src/content/help/categories.json`, which also
  holds the labels and their order (Get started, The Console, Start and talk
  to agents, The terminal, Hosts and connections, Notifications, iPad and
  CarPlay, Settings and account, Troubleshooting). `src/data/help.ts` reads it
  for the site and the app reads it for in-app Help: add a category there,
  nowhere else.
- `order`: a positive integer, the page's place in its category (unique per
  category; steps of 10 leave room).
- `keywords`: 3–10 lowercase search terms not already in the title:
  synonyms, UI labels, error words.
- `related`: 2–4 slugs of other help pages. The build fails on a slug that is
  not a page, or the page itself (`src/lib/help.ts`).

**Writing rules.**

- No H1 in the body. Start with a 1–3 sentence lead that answers what the
  feature is and what it does for the user (answer engines quote it), then
  `##` sections, with `###` only under them. Prefer task- or question-shaped
  headings ("Start a chat", "What happens when the network drops?"), numbered
  lists for steps, a `## herdr and tmux` section where behavior differs by
  Backend, and a short `## Troubleshooting` or `## Good to know` where useful.
- 150–900 words, second person, present tense, short sentences.
- Ground every claim in the code or existing docs (`CHANGELOG.md`,
  `CONTEXT.md`, `src/llms/index.md`, the site components, `PRIVACY.md`,
  `Sources/Waycar/`, `plugin/`, `docs/`). Never invent UI, settings, limits,
  numbers, or versions; leave out what you can't verify.
- UI labels exactly as the app shows them, in bold (tap **Closed**). Terms as
  in `CONTEXT.md`: Waycar, Host, agent (lowercase in prose), herdr, tmux,
  mosh, Pairing Code, Jump Host, Live Activities, Chat Mode, Composer,
  Toolbar, Console. "Tap" and "touch and hold" for touch, "press" for keys,
  "click" only for a trackpad or mouse.
- No em or en dashes in prose, no marketing filler, no "simply" or "just", no
  emoji. Keep pricing out of feature lists.
- Links: other help pages as `/help/<slug>` (optionally `#anchor`), site
  pages as `/privacy`, `/support`, external links only to primary
  sources (herdr.dev, github.com/steipete/CodexBar, mosh.org). Never link
  `/install.sh`; the install command appears only as the code block
  `curl -fsSL https://waycar.dev/install.sh | sh` (fenced as `sh`).
- Portable Markdown only: paragraphs, headings, lists, bold, italic, inline
  code, fenced code with a language (`sh`, `text`), links, small GFM tables,
  and a `>` blockquote for a single note. No raw HTML, MDX, footnotes, or
  custom syntax.
- At most one image, only a screen from `src/assets/screens/` that shows the
  feature, linked relative to the page with specific alt text:
  `![A Chat Mode conversation on iPhone](../../assets/screens/iphone-chat.png)`.
  On the page it ships at the width it is shown at (at most 640px tall, no
  wider than the column) with a 2x copy in its `srcset`, and loads eagerly
  since it sits near the top: the `help-images` plugin for the Sätteri
  Markdown processor (`@astrojs/markdown-satteri`) in `astro.config.mjs`
  sets this for every image under `src/content/help/`.

**Pages and routes.** `src/pages/help/[slug].astro` renders each page through
`src/layouts/HelpLayout.astro` (on top of `Layout`): breadcrumbs, title and
description, the body, related pages, "Still stuck?" pointing to `/support`,
previous and next in global order (category order, then `order`), a sidebar
of every page that collapses on narrow screens, and "On this page" from the
`##`/`###` headings on wide screens. Each page carries a canonical URL,
`og:type` `article`, and `TechArticle` plus `BreadcrumbList` JSON-LD
(`Layout`'s `schema` prop). Fenced code uses Shiki's `css-variables` theme,
colored from the terminal tokens in `global.css`.

**For agents.** `/help/<slug>.md` (`src/pages/help/[slug].md.ts`) is each
page as standalone Markdown: the title as H1, the description, the body with
absolute links and each image as a `Screenshot: <alt text>` line (linking
the image would ship its full-size original in `dist/_astro`); the
page links it with `rel="alternate"`. `/help.md` lists every page by
category, linking those twins, and the reviewed `/llms.txt` has a Help section
with the same links.

**Search.** The header on every page has a search trigger (with `⌘K` or
`Ctrl K`, detected in the browser) and a Help link; `/help` adds a large search
field. ⌘K / Ctrl+K, or `/` outside a text field, opens a `<dialog>` palette
(`src/components/HelpSearch.astro`) that fetches `/help/search.json` on first
open (slug, title, description, category, keywords, `##`/`###` headings, and
body text per page; about 160 KB, 50 KB gzipped) and ranks as you type with
`src/lib/help-search.mjs`, a dependency-free module the tests import too.
Case, diacritics, and apostrophes inside words are ignored (`cant` finds
"Can't"); every query word must match some field, as
a whole word, as the start of a word, or (5+ letters) with one typo; fields
weigh title > keywords > headings > description > body, and a whole word
beats a prefix. Results are built with DOM APIs (`textContent`, `<mark>` for
matches). The Worker's `connect-src 'self'` allows the fetch.

## Changelog

`/changelog` lists what changed in each Waycar update, newest first. The same
notes show in the iOS app's Settings. The history starts at 1.0.1
(2026-09-28) by choice; don't backfill older releases.

**Sources.** Each released version is one file,
`src/content/changelog/<X.Y.Z>.md`, with front matter checked by the Zod
schema in `src/content.config.ts` (`version` as `X.Y.Z`, matching the file
name; `date` as `YYYY-MM-DD`; nothing else) and the release's Keep a Changelog
body (`### Added`, `### Changed`, `### Fixed`, `### Removed`, then `- **Title**:
prose (#issue)` bullets):

```markdown
---
version: 1.1.3
date: 2026-10-04
---

### Added

- **Last screen while reconnecting**: ... (#105)
```

Changes not yet released are written under `## [Unreleased]` in the repo-root
`CHANGELOG.md`, as before; `make publish` moves that section into a new
release file. The site reads that section (up to the next `## ` heading or the
end of the file) at build time and shows it first, titled Unreleased with
"Coming in the next update.", only while it has a bullet. Releases follow by
version, compared numerically (`1.10.0` before `1.9.0`). The loaders are in
`src/lib/changelog-loader.ts`; ordering, paging, and the other rules are in
`src/lib/changelog.mjs`, which `scripts/changelog.test.mjs` tests along with
the real release files and `CHANGELOG.md`.

**References stay private.** Issue and pull request references in parentheses,
such as `(#161)`, `(#95, refs #90)`, or `(#151, #164; PR #174)`, point into the
private repository, so they are removed from the body before the Markdown is
rendered (the app removes the same pattern). The files keep them. A test fails
when a reference in another shape would survive, so a new format gets added to
the pattern (here and in the app) rather than published. Never link GitHub
issues, pull requests, or commits from a changelog entry.

**Routes and paging.** `/changelog` is page 1 and `/changelog/<n>` the older
pages (`src/pages/changelog/[...page].astro`). A page holds whole releases
only: it takes releases until it has at least 40 bullets (top-level list
items, `-`, `*`, or `+`, outside fenced code; Unreleased counts toward page 1),
and the last page takes what is left. Each release is an
`<article id="v1-1-3">` with "Version 1.1.3" and its date, its body in the
help pages' Markdown style (`src/components/Prose.astro`), and each page ends
with an "Older releases" link to the next page. With JavaScript, that link
loads the next page in place as it nears the viewport (the URL stays the
same): a status line tells screen readers which versions loaded, focus moves
to the first new release if the link had it, and a failed fetch leaves the
link working and tries again a few times. Without JavaScript the link is a
plain link. On wide screens, in browsers with scroll-driven animations, a
release's version and date stay in view beside it and fade out before its end.
Every page has its own canonical URL and is in the sitemap. The help index,
the help sidebar, and the footer link to `/changelog`.

**Continuous deploys.** `web.yml` deploys on a push to `main` that touches
`CHANGELOG.md` or `apps/web/**`, so a merged Unreleased entry or a new release
file is live within one deploy.

## Articles

`/articles` lists notes from the team on running coding agents, newest first.
Each article is Markdown in `src/content/articles/<slug>.md`, rendered at
`/articles/<slug>` with its title, date, and a quiet footer that links
`/help/what-is-waycar` and the App Store listing. Articles are not bundled
into the iOS app (unlike help and changelog files), so a change under
`src/content/articles/` redeploys the site through `web.yml` and never starts
the iOS CI (`ci.yml` lists only the help and changelog content folders).

**Frontmatter**, checked by the Zod schema in `src/content.config.ts`
(unknown fields fail the build):

```yaml
---
title: How we set up advisors for OMP
description: A quiet roster of reviewer models for the OMP coding harness. They speak at plan lock and before "done".
date: 2026-10-16
keywords: [omp, advisors, coding agents, reviewer models]
draft: true
hero:
  src: /articles/tailscale-subnet-router-traffic.gif
  zoom: /articles/tailscale-subnet-router.svg
  width: 1200
  height: 720
  alt: A phone on cellular connects through an encrypted tunnel to a subnet router.
---
```

- `title`: at most 90 characters. The page's H1 and the start of its `<title>`.
- `description`: 70 to 200 characters. The meta description and the lead under the H1.
- `date`: `YYYY-MM-DD`, the publish date, read in New York time. Newest first on
  `/articles`. A date after today holds the article back like `draft: true`
  (see Scheduling).
- `keywords`: 3 to 10 lowercase terms.
- `draft`: optional. `draft: true` hides the article everywhere: no page, no
  Markdown twin, no sitemap entry, and no line in `/articles.md` or
  `/llms.txt`. Leave it out (or set `false`) to publish. Unpublished work lives
  in `docs/drafts/articles/`, outside the site.
- `hero`: optional, the article's real graphic. `src` is a file in
  `public/articles/` (never `astro:assets`, which would flatten an animated
  GIF), `width` and `height` are its own pixels (a test checks them against
  the two GIF articles), `alt` is required (20 to 400 characters), and `zoom`
  is an optional sharper file the lightbox opens, such as an SVG twin of a GIF.
  The page shows it once, under the title band at container width, eager and
  high priority. Do not also put it in the body. The Markdown twin and the
  JSON-LD `image` carry it too. An article without `hero` gets the title band
  with a violet glow and loads no image; there are no mock graphics, so add
  one only when you have a real diagram or screenshot.

**Page layout.** `src/pages/articles/[slug].astro` is a 1200 px wrap with a
title band (title, lead, date, read time computed at build from the body's word
count minus code fences, `src/lib/read-time.mjs`), the hero when there is one,
and a grid of three fixed columns: "On this page" (220 px), the article
(640 px) and the rail (260 px). The TOC lists the body's H2s from `render()`'s
`headings`, twice: a closed `<details>` under 1024 px and a sticky list from
1024 px that scrolls inside itself and keeps the `toc-card` store card under it.
One bundled script marks the section being read (`aria-current="location"` on
its link in both lists); without JavaScript the links still jump and nothing is
marked. From 1280 px the rail sits beside the article and scrolls with the page;
under 1280 px it follows the article. Its four modules (`get-app`,
`start-here`, `host-setup`, `first-launch`), their copy and each article's four
hand-picked guides live in `src/data/article-rail.ts`, which also records the
claim limits (no "popular", no price, no Android link: Android stays "coming
soon"). A short article keeps only the modules that fit beside it; the rest
follow below it. A thin reading progress bar draws only where the browser
supports scroll-driven animations. All of it is same-origin: no new third-party
request, cookie or CSP change.

**Scheduling.** Dating an article for a later day publishes it on that day: it
stays out of every route, the sitemap, `/articles.md` and `/llms.txt` until
midnight New York time on its `date`, and the first build after that shows it.
`web.yml` also deploys `main` daily at 14:17 UTC (10:17 EDT, 09:17 EST), so a
scheduled article is live by mid-morning New York time without a push. The
date is the page's visible publish date and the `datePublished` and
`dateModified` of its `Article` JSON-LD, and Google reads it as the byline
date: Google's guidance (Search Central, byline dates) is to give the real
publication or update date and never a future one, so a scheduled article is
held back, not shown with a future date. A published article may link only to
non-draft articles dated on or before its own date, since any other is hidden
when it goes live (`scripts/articles.test.mjs` checks this). Set a draft's
date to the day it is published.

**Rules.** Plain voice as in `DESIGN.md`: short sentences, about an 8th-grade
reading level, no marketing filler, no em or en dashes, no emoji. No H1 in the
body (the title is the H1); start with `##` sections. Portable Markdown only,
as in the help pages. Link site pages as `/help/<slug>`, never `/install.sh`.

**Routes.** `src/pages/articles/index.astro` (`/articles`),
`src/pages/articles/[slug].astro` (`/articles/<slug>`, with `Article` and
`BreadcrumbList` JSON-LD and Open Graph and Twitter tags from `Layout`),
`src/pages/articles/[slug].md.ts` (`/articles/<slug>.md`, the article as
standalone Markdown for agents), and `src/pages/articles.md.ts`
(`/articles.md`, the link list). `src/lib/articles.ts` reads the collection
and drops drafts and articles dated for a later day, so every route,
`/llms.txt`, and the sitemap (built from the
pages) agree. The header and footer link `/articles`.

**Images.** Tapping an image in the article body opens it in a near-fullscreen
dialog, so readers can study it: a server-rendered `<dialog>` plus a bundled
module script in `src/pages/articles/[slug].astro` (no new origins, no inline
scripts). On phones the image shows at its natural pixel size inside a
pannable dialog and pinch-zoom keeps working; on wide screens it fits the
viewport at most 92vw by 92vh. The dialog takes the image's alt text as its
caption, closes on the backdrop, the Close button, or Escape, locks the page
scroll while open, and gives focus back to the image on close. The motion is a
fast fade and scale that drops out under `prefers-reduced-motion`. An image
whose inline source is an animated GIF can point the dialog at a crisp vector
twin: write that image as raw HTML with a `data-zoom-src` attribute, such as
`<img src="/articles/example.gif" data-zoom-src="/articles/example.svg" alt="...">`.
The inline image stays the animated GIF; the dialog shows the SVG. Without
`data-zoom-src` the dialog shows the image as-is. The subnet-router diagram
does this today: the articles inline `tailscale-subnet-router-traffic.gif` and
the lightbox shows `tailscale-subnet-router.svg`.

## Compare and solutions

`/compare` holds one honest comparison per product people use to reach a coding
agent from a phone, and `/solutions` one landing page per thing they search
for ("mosh client ios", "tmux on iphone"). Both are content collections: a new
page is one Markdown file, and it joins its index, the footer's Compare and
Solutions columns, the sitemap, `/llms.txt` and the Markdown twins on its own.
Like Articles they are not bundled into the iOS app, so a change under
`src/content/compare/` or `src/content/solutions/` redeploys the site through
`web.yml` and never starts the iOS CI.

**Comparisons** are `src/content/compare/<slug>.md`, served at
`/compare/<slug>`. Front matter, checked by the Zod schema in
`src/content.config.ts` (unknown fields fail the build):

- `title` (at most 70 characters, `Waycar vs {Name}`), `metaTitle` (optional: the
  `<title>`, to which the page adds " · Waycar" unless it already says Waycar;
  the result is at most 60 characters, so set one when `title` is long),
  `description` (70 to 165), `name`, `kind` (`ssh-client`, `agent-environment`,
  `agent-client` or `first-party`), `summary` (the index card and the page's
  lead), `checked` (`YYYY-MM-DD`, the day the facts were last checked), `order`
  (unique; the index and footer order), `keywords` (3 to 10 lowercase terms,
  emitted in the page's JSON-LD).
- `rows`: every row id below, each `{ level, text }`.
- `pickWaycar` and `pickThem`: 3 to 5 bullets each.
- `faq`: 3 to 6 `{ q, a }`, plain text. The page shows them and emits them as
  `FAQPage` JSON-LD, so they must match.
- `sources`: 2 to 12 `{ label, url }` (https), each a page the claims were read
  from.
- `related` (2 to 4 other comparison slugs) and `solutions` (1 to 3 solution
  slugs).
- The Markdown body is the walkthrough between the table and the questions. No
  H1; start with `##`. The build fails on an H1, a link to `/install.sh` and a
  site link that names no published page (fenced code is skipped; the fixed
  pages a body may link to are listed in `src/lib/landing.ts`).

**The table.** Every comparison answers the same rows
(`src/lib/compare-rows.mjs`: id, label, group), for Waycar
(`src/data/compare-waycar.ts`) and for the other product (`rows`). `level` is
`yes`, `partial`, `no`, `unknown` or `info`. `unknown` means the maker's own
pages say nothing either way, so the page claims nothing: the text is "Not
documented". A rated cell's text starts with its level's word as a whole word
(Yes, Partial, No, Not documented), is one line and is at most 60 characters,
so the table reads the same to a screen reader, without the mark beside it, and
in the Markdown twin. The seven descriptive rows (where the agent runs, account,
how the phone reaches the session, what the machine needs, agents, source code,
price) take `info` and any text (a `source` cell starts with "Open source" when
the code is public: the `/compare` "not the right pick" list reads that
prefix); every other row is rated and never takes `info`, so a row is not
marked on one page and plain on another. A missing or
extra row id, a bad cell, a wrong level for a row, a `related` slug that is no
comparison, a `solutions` slug that is no solution page, a repeated `order` or a
`<title>` over 60 characters fails the build (`src/lib/compare.ts` and
`src/content.config.ts`; the checks are in `compare-rows.mjs`, tested by
`scripts/compare.test.mjs`).

**Where facts come from.** Every statement about another product comes from its
own site, docs, release notes, store listing or repository, opened on the date
in `checked`, and its source is in `sources`. Never cite a rival's marketing.
Where those pages are silent, write Not documented, not No. Use No only when a
primary source says it is unsupported, or the product category makes it
impossible (a service that runs only through its maker's cloud has no mosh).
When a product changes, re-check the page and move `checked` forward; the page
shows the date. Waycar's own column describes the released App Store build, so
while the help gate holds (see [Release content
switch](#release-content-switch)) neither it nor a page may name a feature only
`main` has.

**Solutions** are `src/content/solutions/<slug>.md` at `/solutions/<slug>`:
`title`, `metaTitle`, `description`, `query` (the lowercase search phrase the
page answers), `summary` (the index card), `answer` (the short answer shown
first), `needs` (3 to 6 requirements), `order`, `updated`, `keywords`, `faq`,
`compare` (1 to 3 comparison slugs) and `help` (2 to 4 help slugs, checked
against the published help pages, so a page the release switch hides fails the
build).

**Rules.** Plain voice as in `DESIGN.md` and Articles: short sentences, about an
8th-grade reading level, no marketing filler, no em or en dashes, no emoji. Say
what Waycar cannot do: it needs herdr or tmux on the machine, the machine must
be on and awake, and it has no native desktop or web client. Write "no cloud between you and your sessions" as "for your sessions",
because the optional push relay carries notifications, encrypted on the Host so
it cannot read them, and sees how many agents are in each status for Live
Activities. Users still pay for their own machines and AI providers. Link site pages as
`/help/<slug>`, `/compare/<slug>` or `/solutions/<slug>`, never `/install.sh`.

**Routes.** `src/pages/compare/index.astro` (`/compare`: a card per comparison
and a matrix of all of them against Waycar), `src/pages/compare/[slug].astro`
(`/compare/<slug>`, with `WebPage`, `BreadcrumbList` and `FAQPage` JSON-LD),
`src/pages/compare/[slug].md.ts` and `src/pages/compare.md.ts` (the Markdown
twin and the link list), and the same four under `src/pages/solutions/` and
`src/pages/solutions.md.ts`. `src/lib/compare.ts`, `src/lib/solutions.ts` and
`src/lib/landing.ts` read the collections and build the twins and JSON-LD.
`SiteFooter` lists every page in its Compare and Solutions columns.


## App Store switch

`src/data/links.ts` holds `APP_STORE_LISTING_URL`, the listing URL
(`https://apps.apple.com/app/id6815881853`; Waycar went live on 2026-10-14),
and `appStoreUrl(pathname, section)`, the same listing tagged with the
surface's own campaign (`?pt=…&ct=<token>&mt=8`, see
[Campaign tokens](#campaign-tokens)); the picker's App Store link is the tagged one.
Every store button (header, hero, Setup step 1, Closing, the article's TOC card,
rail and footer, the site footer, compare and solutions pages)
is one component, `src/components/AppStoreCta.astro`, which follows
`ON_APP_STORE` (the listing URL starts with `https://`):

- **Live** (the shipped state): with JavaScript on an iPhone, iPad or iPod
  touch, each button links **directly to the App Store**, one tap away, sending
  `app_store_clicked`. Detection uses `isAppleHandheld` in `src/lib/ad-links.mjs`:
  an `iPhone|iPad|iPod` user agent, or iPadOS desktop mode (`MacIntel` with more
  than one touch point), not a real Mac. The bundled picker script copies the
  App Store link from that button's own picker and removes `data-picker-open`
  and `aria-haspopup`, keeping its text and `ct`. Layout's paid-campaign rewrite
  works in either script order: it updates the picker link before the copy, or
  both links after it. Layout's existing click listener reads the rewritten
  button's own `href` for `ct`; no `get_picker_opened` event is sent on this path.
  Everyone else (computers and Android included) opens the **Get Waycar picker**
  (`src/components/GetPicker.astro`), sending `get_picker_opened` with the
  picker's App Store `ct`. No button names a device or a store: the labels stay
  "Get Waycar" and "Download" (header). The picker is the one place that does.
  Tile one, "iPhone and iPad", holds
  Apple's official "Download on the App Store" badge
  (`public/app-store-badge.svg`) as the link to the listing, with
  `data-ph-event="app_store_clicked"`. Tile two, "Android™", is plain text,
  "Coming soon": not a link, not focusable, no Play name, badge or logo. A line
  below says "Android is a trademark of Google LLC." Each button owns its
  picker (a `<dialog>` right after it), so the App Store link inside keeps that
  button's `ct` (or the paid campaign's) and the `module` of the wrapper around
  both; the direct link keeps them too. Inside the picker, the QR figure is
  always shown under the badge on wide screens with a mouse
  (`@media (hover: hover) and (pointer: fine) and (min-width: 820px)`), with no
  disclosure click; elsewhere it stays hidden. It uses `/qr/site-qr.svg`,
  148 × 148 px, and the caption "Scan with your iPhone or iPad". The QR itself
  keeps `ct=site-qr`. With JavaScript outside Apple handhelds the button opens
  the picker as a modal (Esc, Close and the backdrop close it; focus moves in
  and returns; the page behind does not scroll). Without JavaScript on any
  device there are no click events; the button links to the picker's id and,
  under `@media (scripting: none)`,
  CSS shows `:target` as a fixed overlay, so the App Store link is two taps away;
  Esc and the focus trap need JavaScript, and Close is a link to `#_`. The
  header's blur is a `::before` so the header does not become the overlay's
  containing block.
- **Pulled** (`APP_STORE_LISTING_URL` emptied, e.g. if the listing is taken down):
  each button is a plain label, "Coming soon to the App Store": a quiet outline
  pill of plain text (plain text in Setup step 1), the same size as the button
  it stands in for. There is no picker. It is not a link, not focusable, and sends
  no event. Neither Apple's badge nor an Apple logo shows, since
  Apple's marketing guidelines allow them only with a live listing. On phones
  (600px and narrower) the header pill shows "Coming soon" and keeps the full
  phrase for screen readers.
- **Google Play** (`PLAY_STORE_LISTING_URL`, empty today): set, the Android tile
  links to it and the App Store badge turns black (`public/app-store-badge-black.svg`;
  Apple's rule once another platform's badge appears). Never set it before a Play
  listing exists. `scripts/picker.test.mjs` builds it once with a dummy URL.

Availability statements (FAQ, footer, `/llms.txt`, the `{{app_store}}` token in
`src/llms/index.md`) follow `ON_APP_STORE` too: "available now" while live,
"coming soon" if pulled.

Every indexable page also carries Safari's Smart App Banner,
`<meta name="apple-itunes-app" content="app-id=6815881853">`, in
`src/layouts/Layout.astro`; the 404 page (`noindex`) does not.

## Ad links

Paid ads (X, Reddit) point at `https://waycar.dev/go/<token>`, never at the App
Store directly. Any token that matches `PAID_CT` in `src/lib/ad-links.mjs` works
with no code change (see [Campaign tokens](#campaign-tokens)): `reddit-` or `x-`,
then lowercase letters, digits and single hyphens, 3 to 30 characters in all. The
token is the Apple `ct`, the `utm_campaign` and the campaign's name in the ad
platform. A path that does not match gets the site's 404, as any unknown path
does. The Worker redirects with a 302, `Cache-Control: no-store`,
`X-Robots-Tag: noindex`:

- **A new token, `<channel>-<campaign>`, and the legacy `<channel>-store`**: an
  Apple device (iPhone, iPad, iPod, or a Mac, since
  iPadOS Safari reports itself as a Mac) goes to `/go?c=<slug>`
  (`src/pages/go.astro`), not straight to the store. The Layout script loads the
  ad pixels there (same consent rules as any page), sends the App Store click
  conversion, waits for the pixels to send (`pixelsSettled`, at most 2 s), then
  `location.replace`s to the App Store with `?ct=<slug>&mt=8`. The slug is checked
  against `PAID_CT`; the URL is never taken from the query. Anything else goes
  to the site, since Waycar is iOS only. `?d=site` makes a new token a site link
  (the legacy `-site` and article tokens are fixed in `AD_LINKS` and ignore it).
- **The legacy `<channel>-site`**: always goes to `https://waycar.dev/` with
  `utm_source=<channel>&utm_medium=paid&utm_campaign=<slug>`. The page's own
  script then puts `ct=<utm_campaign>` on its App Store links, for that page
  view only (nothing is stored); other visits get the surface's own build-time `ct`.
- **`x-text`**: a `store` link for text-only X ads, listed in `AD_LINKS` only for
  its `landing`. Apple devices behave as on any new token (`/go?c=x-text`, then
  the App Store with `ct=x-text`).
  Everyone else, X's link-preview crawler included, goes to `/x`
  (`src/pages/x.astro`) with the site-link UTM tags instead of the home page.
  `/x` is `noindex` and uses the Layout's `cardless` mode: only `<title>`, no
  `og:*`, `twitter:*` or meta description, so X has nothing to unfurl and the
  post stays text-only. (Checked in X's composer on 2026-10-19: pages with only
  a `<title>` show no card; waycar.dev, through `/go/x-store`, shows the big
  image card.) An entry's `landing` field in `AD_LINKS` sets that page.
- **`x-article-advisors`**: always goes to the fixed article URL
  `https://waycar.dev/articles/how-we-set-up-advisors-for-omp` (set in `AD_LINKS`,
  never taken from the query) with the same `utm_*` tags as a site link
  (`utm_source=x&utm_medium=paid&utm_campaign=x-article-advisors`), the click IDs and
  `?internal=1` handling below. Its `ad_link_clicked` event has
  `link_destination` and `destination` both `article`.
- **`x-article-reach-agents`**: same behavior as `x-article-advisors`, with the fixed URL
  `https://waycar.dev/articles/reach-your-ai-harness-while-you-are-away`
  (`utm_campaign=x-article-reach-agents`). While that article is a draft, the
  redirect works but the article page returns 404.
- A test click with `?internal=1` carries the flag to the site redirect, so the landing page marks that browser internal.
- `twclid` (X) and `rdt_cid` (Reddit), when plain (letters, digits, `.`, `_`, `-`,
  up to 128), are copied to the redirect URL of both link types so the pixels
  can attribute the click. They are never in the `ad_link_clicked` event. The
  pixels may keep the ID in their own cookies (`_twclid`, `_rdt_cid`) where they
  are allowed; the site itself never logs or stores it, and PostHog masks it in
  `$current_url`. The hop forwards at once when the pixels are not allowed, and
  does not wait on a blocked or failed pixel script.
- An ad may add `utm_content` / `utm_term` (letters, digits, `.`, `_`, `-`),
  which pass through to the site and the event. Source, medium and campaign
  cannot be overridden.

Each click from a browser sends the anonymous PostHog event `ad_link_clicked`
(`slug` and `ct`, both the token; `link_destination` as the link type, `destination` as where it went,
`utm_*`; random id, no person profile, GeoIP off, no ad-platform
click IDs). Bots, link previews and scripted clients (`NON_BROWSER_AGENT`) get
the redirect and no event; `?internal=1` adds `internal: true`. Use the
`ad_link_clicked` count against the App Store Connect › App Analytics
campaign (`ct`) of the same name to compare clicks, page views and downloads.
Register a new token as an App Store Connect campaign link before its ad
launches (App Store Connect only lists a campaign once 5 users came through it).

### Campaign tokens

Every App Store link carries a campaign token (`ct`) so App Analytics can split
page views and downloads by where the click happened. Marketing owns the
convention and the registry (the `ct-convention` document on WAY-101); the code
enforces it in `src/lib/ad-links.mjs`:

- **Paid**: `PAID_CT`, the `/go/<token>` rule above.
- **Organic**: `ORGANIC_CT`, a closed list, never read from a URL. A CTA's token is
  built in: `<AppStoreCta ct="site-hero">` (`site-hero`, `site-hero-b`,
  `site-closing`, `site-nav`), default `site`. A page type outranks it
  (`organicCampaign`): every CTA on `/help/*` is `help`, on `/articles/*`
  `article` (header and footer included). The retired `pricing` token stays
  valid for links already shared. The article's setup
  prompt link is `setup-prompt`. An unknown `ct` throws at build time, and
  `scripts/ad-links.test.mjs` checks every literal token in `src/`.
- A visitor who arrived from a paid ad (`utm_campaign` matching `PAID_CT`) gets that
  token on every App Store link of that page view instead (Layout script).
- Off-site links (`hn`, `readme`, `producthunt`, ...) are written by hand with
  `appStoreCampaignUrl`; the registry lists them.
- `app_store_clicked` carries `ct`, the token on the link that was clicked, to join
  click, store tap and download. `get_picker_opened` carries the `ct` of the App
  Store link in the picker it opened, so an open and the tap behind it join too.

**Apple provider token.** `APPLE_PROVIDER_TOKEN` in `ad-links.mjs` is the `pt=` from App Store
Connect › App Analytics › Campaigns › Generate Link. It goes on every App Store link
(the site's CTAs and `/go/` links) so Apple reports page views and downloads per `ct`.
It is the same for every campaign and is not a secret. Empty, links carry only `ct` and `mt`.
Target iOS devices in the X and Reddit ad settings so the non-Apple fallback
rarely fires.

## Short links

`src/lib/short-links.mjs` maps a short path to a fixed target, for a URL that
is easier to type or post than the real one. There are no active short links.
The expired `/x3` giveaway link is removed. The Worker answers a `GET` or
`HEAD` with a `302`, `Cache-Control: no-store` and `X-Robots-Tag: noindex`, logs
nothing, and never takes the target from the request. Add a line to
`SHORT_LINKS` to create one and delete it when the campaign ends; the path
then falls through to the 404 page. `scripts/short-links.test.mjs` covers the
lookup.

## Plugin install events

The Worker logs two anonymous PostHog events for the plugin installer
(`src/lib/plugin-events.mjs` decides, `scripts/plugin-events.test.mjs` pins it;
random id, no person profile, GeoIP off, like every Worker event):

| Event | Request | Properties |
| --- | --- | --- |
| `plugin_install_requested` | `GET /install.sh` | `kind` (`install` or `update`) only when the caller sends `?kind=`. The script is the same either way, so a missing or unknown value leaves `kind` out; it is never guessed |
| `plugin_package_downloaded` | `GET /plugin/waycar-<version>-<target>-<sha12>.tar.gz` (not the `.sha256` file) | `via` (`install`, or `pair` for a pair-only run that installs nothing) and `kind` (`install`, or `update` when a plugin was already there), from the `?via=` and `?kind=` that `install.sh` sets |

Only a request answered 200 counts, and only those fixed values reach PostHog;
anything else in the query is dropped. `?internal=1` adds `internal: true` to
either event. Our own automation must send it on the package request too, not
only on `install.sh`: `plugin/install.sh` does so when `WAYCAR_INTERNAL` is
set, and a script that downloads the package itself adds `?internal=1` to its
URL.

`plugin_package_downloaded` means the installer reached the download. Pair-only
runs, in-app Plugin Updates and manual reruns fire it too. A later failure,
such as unsupported Node or a checksum mismatch, still counts. Normal install
mode checks for herdr/tmux before downloading; pair-only mode needs neither.

Existing apps request the plain script URL, so their script events have no
`kind`. Updating that caller belongs to the app telemetry work; this Worker
does not infer it from request headers.

## Release content switch

`main` runs ahead of the App Store build, and the site deploys from `main`, so
the site never promises what a visitor cannot get. The App Store has 1.3.0
(`APP_STORE_RELEASE` in `src/data/unreleased.ts`), and `main` adds Zellij, the
Codex and OpenCode 2 server runtimes and queueing messages to a Waiting launch.
The **help gate** handles the difference:

- **Help**: `src/content/help/` is bundled whole into the iOS app and holds
  the pages `main` ships, so no page is moved, renamed or edited for this.
  While the gate holds, `src/lib/help-loader.ts` stands in for the glob
  loader: it skips the pages in `HIDDEN_HELP_PAGES` (none today), applies
  `RELEASED_HELP_EDITS` to the text of the others (`replace`, `dropLine`,
  `setLine`, `dropSection`, `prependBody`), and removes hidden slugs from
  every `related` list. The `codex`, `opencode` and `zellij` pages stay on the
  site, each opening with "Coming in the next update of Waycar." (the
  `nextUpdateNote` edit), and the other pages keep their links to them; edits
  turn text for smaller unreleased changes back into 1.3.0's. Hidden pages
  leave `/help`, the sidebar, search, `/help.md`, `/llms.txt` and the sitemap,
  since all of them read the collection. The build fails when an edit matches
  nothing (its page changed: update the entry) and when a body link points at
  a hidden page (add an edit that drops it). A PR that adds help text for a
  feature the App Store build lacks needs a `RELEASED_HELP_EDITS` entry in the
  same PR: a note for a new page, an edit for a changed one.
- **`/changelog`**: the Unreleased section (from the repo-root `CHANGELOG.md`)
  is not shown.

**The gate lifts by itself** once `src/content/changelog/` holds a release
newer than `APP_STORE_RELEASE`, which `make publish` writes, the same moment
that release's notes reach `/changelog`. The site then shows `main`'s help and
the Unreleased section, `src/data/unreleased.ts` and the released loader sit
unused, and the gate's test in `scripts/site-pages.test.mjs` skips: delete
them, or set `APP_STORE_RELEASE` to the new release and list what `main` has
beyond it to gate again.

Not gated: the landing pages, `/index.md` (`src/llms/index.md`), `/support`,
and `src/data/compare-waycar.ts` with the pages in `src/content/compare/` and
`src/content/solutions/`. They describe `main`, naming Zellij, Codex and
OpenCode 2 beside herdr, Herdr Core and tmux, and say "in the next update"
wherever a 1.3.0 user would otherwise be misled (a requirement, a setup step, a
comparison cell); drop those words once the next release ships. Also
`/privacy` (the policy describes the app as built from `main`).

## Home page A/B test (ended)

The 2026-10 hero A/B test ended by shipping variant B (the outcome-led hero),
which is now the only home page (`src/pages/index.astro`). The Worker no
longer evaluates the PostHog flag `home-page-hero` or assigns variants; it
only deletes the test's leftover cookies (`waycar_ab`, `waycar_variant`)
wherever they turn up, and `/b`, `/b/` and `/b.html` 301-redirect to `/`.
The analytics script no longer sends `site_variant`,
`variant_assignment` or `$feature/home-page-hero`, and unregisters those
super properties from returning browsers. Historical results live in the
PostHog Experiment "Home page hero (A/B)" (shipped variant `test`). To run a
new test, see this section's history in git (`git log -p --follow README.md`,
around 2026-10) for the Worker split, the cookieless daily ID, and the
PostHog setup it used.

## Commands

```bash
npm install          # once
npm run dev          # local dev server with hot reload
npm run check        # astro check (typechecks .astro, .ts, and // @ts-check .mjs files)
npm test             # node:test suites in scripts/ (no network)
npm run build        # static build into dist/ (see below for the plugin binaries)
npm run preview      # serve dist/ locally
npm run deploy       # wrangler deploy (needs Cloudflare credentials)
```

`npm run build` runs `scripts/package-plugin.sh` first (`prebuild`), which
packages the plugin behind `/install.sh` for four targets and needs the native
`waycar` binaries. Unless `WAYCAR_PLUGIN_BINARIES` names a directory, the script
runs `scripts/build-plugin-binaries.sh` itself, which installs the pinned
Rust toolchain, zig and cargo-zigbuild into `~/.cache/waycar-build` on first use
(slow once, then cached; Linux only: on another OS the script stops unless zig
0.17.0 is already on `PATH`). To reuse binaries you already built, run
`WAYCAR_PLUGIN_BINARIES=<dir> npm run build` with `<dir>/<target>/waycar`.

`wrangler dev` runs the Worker too. It rewrites local requests to
`waycar.dev`, so they take the canonical branch (no redirect) and get the
security headers. A local `GET /install.sh` still sends
`plugin_install_requested`, with `env: debug`; only `npm run deploy` (and CI)
sets `POSTHOG_ENV=release` via `--var`. `GET /install.sh?internal=1` serves the
same script and adds `internal: true` to the event; use it for our own fetches.

## Layout

| Path | What it holds |
| --- | --- |
| `src/pages/` | `index` (landing, home page A), `b` (home page B, served at `/`), `support`, `privacy`, `ipad` (screenshot gallery), `404`, `help/` (`/help`, `/help/<slug>`, `/help/<slug>.md`, `/help/search.json`), `changelog/` (`/changelog`, `/changelog/<n>`), `articles/`, `compare/` (`/compare`, `/compare/<slug>`, `/compare/<slug>.md`), `solutions/` (`/solutions`, `/solutions/<slug>`, `/solutions/<slug>.md`), plus the `llms.txt` (reviewed fallback), `index.md`, `help.md`, `articles.md`, `compare.md`, and `solutions.md` endpoints |
| `src/content/help/` | Help pages, one Markdown file per feature (see [Help docs](#help-docs)); schema in `src/content.config.ts` |
| `src/content/changelog/` | Released versions, one Markdown file per version (see [Changelog](#changelog)); schema in `src/content.config.ts` |
| `src/content/compare/`, `src/content/solutions/` | Comparisons and solution pages, one Markdown file each (see [Compare and solutions](#compare-and-solutions)); schemas in `src/content.config.ts` |
| `src/data/help.ts` | Help categories (ids, labels, order) from `src/content/help/categories.json`, and help URLs (`help-paths.ts` holds the URL helpers the help search script imports) |
| `src/data/links.ts`, `src/data/unreleased.ts` | The App Store URL; the help gate, what it hides and the release it holds for (see [Release content switch](#release-content-switch)) |
| `src/data/compare-waycar.ts` | Waycar's column of every comparison table, as `main` behaves, with what 1.3.0 lacks marked as the next update |
| `src/lib/` | `help.ts` (the help collection in order, cross-page checks, Markdown twins, search entries), `help-loader.ts` (the help collection and the Unreleased changelog section through the help gate), `help-search.mjs` (search ranking), `changelog.mjs` (changelog order, reference stripping, paging), `changelog-loader.ts` (the changelog's content loaders), `changelog-entries.ts` (the changelog pages from the collections), `compare.ts` and `solutions.ts` (the comparison and solution collections, their checks and Markdown twins), `compare-rows.mjs` (the table rows and the checks, plain JavaScript so the tests import it), and `landing.ts` (what both share: twins, JSON-LD, the paths a body may link to) |
| `src/layouts/` | `Layout` (every page's head, header, footer, analytics) and `HelpLayout` (a help page) |
| `src/llms/index.md` | Full landing-page content for AI agents, served at `/index.md` |
| `src/components/` | One component per landing section, plus `TermWindow`, `CodeBlock`, `SiteHeader`, `SiteFooter`, `AppStoreCta`, `HelpSearch`, `Prose` (rendered Markdown on help and changelog pages), and `CompareTable`, `CompareMatrix`, `CompareCell`, `CompareLegend`, `LevelMark` and `ComparisonLinks` (the comparison tables and their parts) |
| `src/styles/global.css` | Design tokens and shared building blocks |
| `src/data/screens.ts` | Screenshot imports, alt text, captions |
| `src/assets/` | Logo and screenshots, resized to WebP at build time |
| `src/worker.ts` | The Worker: host redirect, retired page redirects, then static assets, with security headers on all of them |
| `integrations/sitemap.mjs` | Astro integration that writes `dist/sitemap.xml` from the built pages' canonical URLs |
| `scripts/` | `site-pages.mjs` (indexable pages and their text, read back from `dist/`), `generate-llms-txt.mjs` (the deploy-time llms.txt generator and its validator), their tests, `help-search.test.mjs` (search ranking), `changelog.test.mjs` (changelog rules), and `compare.test.mjs` (the comparison and solution checks) |

Screenshots are copies of `docs/images/screenshots/{iphone,ipad}/` at the repo
root (generated by `make screenshots`); refresh them here when those change.
`src/assets/hero/` holds the dictation hero animation (`dictation-hero.webp`,
`dictation-hero-660.webp`) and its still (`dictation-hero-still.png`), also
generated by `make screenshots` (`scripts/record-dictation-hero.sh`).
The logo is `src/assets/logo.png`; `public/` holds the favicon and touch icon.
All of them, and `docs/images/logo.png`, are generated by
`scripts/generate-app-icons.py` at the repo root; rerun it rather than editing them.

The share cards are `public/og.png` (every page's default) and
`public/og-ipad.png` (`/ipad`), 1200x630. Their sources are the HTML pages in
`og/`, which use the site's fonts, the screenshots in `src/assets/screens/`,
and `docs/images/waycar-icon.svg`. After changing any of those, run
`og/render.sh` (needs Google Chrome) and commit the PNGs. A page picks its card
with `Layout`'s `image` and `imageAlt` props.

## Domains and deployment

`wrangler.toml` deploys the `waycar-web` Worker with custom-domain routes for
`waycar.dev`, `www.waycar.dev`, `waycar.app`, and `www.waycar.app`. The Worker
runs before asset lookup: any host other than `waycar.dev` gets a `301` to
`https://waycar.dev` with the same path and query string; `waycar.dev` is served
from `dist/`, with `dist/404.html` for unmatched paths. Retired pricing URLs
redirect to `/` with their query string intact. Every response, redirects
included, gets a strict `Content-Security-Policy` (scripts from this origin
only, never inline, plus `https://www.redditstatic.com` and
`https://static.ads-twitter.com` for the ad pixels; no workers; `connect-src`
limited to this origin, for `/help/search.json` and the changelog's older
pages, `https://us.i.posthog.com`, and the pixels' hosts
`https://pixel-config.reddit.com`, `https://alb.reddit.com`,
`https://analytics.twitter.com`, and `https://t.co`; `img-src` limited to this
origin plus `https://alb.reddit.com`, `https://analytics.twitter.com`, and
`https://t.co`; same-origin fonts, styles, and web manifest; no framing),
`X-Content-Type-Options: nosniff`,
`Referrer-Policy: strict-origin-when-cross-origin`, and a `Permissions-Policy`
that denies camera, microphone, and geolocation. `astro.config.mjs` stops Vite
from inlining small scripts, so every `<script>` ships as a file under
`/_astro/` and `script-src 'self'` covers it (the two pixel script hosts are
the exception). Anything that loads a new kind
of resource (an inline script, a third-party asset, a `data:` image) must update
the policy in `src/worker.ts`.

Both zones, `waycar.dev` and `waycar.app`, must be in the Cloudflare account
before the first deploy; Cloudflare creates the DNS records when the
custom-domain routes are first deployed.

`.github/workflows/web.yml` builds, typechecks, and tests pull requests and
deploys on a push to `main` that touches `apps/web/**`, `PRIVACY.md`,
`CHANGELOG.md`, `plugin/**`, `scripts/package-plugin.sh`,
`scripts/build-plugin-binaries.sh`, or
`.github/workflows/web.yml`. It
needs two repository secrets:

- `CLOUDFLARE_API_TOKEN` — Workers Scripts:Edit on the account owning both zones
- `CLOUDFLARE_ACCOUNT_ID`

and uses `OPENROUTER_API_KEY` (shared with `testflight.yml`) to generate
`/llms.txt`; without it the reviewed fallback ships.

For a manual deploy, `wrangler login` once, then `npm run build && npm run
deploy` (which ships the reviewed `/llms.txt` unless you run
`npm run generate-llms-txt` in between).
