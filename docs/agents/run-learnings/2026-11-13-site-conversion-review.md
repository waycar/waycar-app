# 2026-11-13 — Home page rebuilt for App Store downloads

- **Worked:** measure before deciding. PostHog said 60% of visitors are on
  phones and a script said the hero button sat at y=866 on a 390x700 screen;
  that pair ranked the work better than reading the page did. Keep the old
  build (`cp -r dist /tmp/<slug>-before`) so the same script and screenshots
  run against before and after.
- **Worked:** one commit of shared data and markup first (`src/data/supported.ts`,
  the section order), then three children with disjoint files: a designer for
  the hero and two workers for the picker and the copy. No merge conflicts.
- **Broke:** round 1 made the download easier (button on the first screen,
  one tap on iPhone, a QR on desktop) and moved the dictation clip down the
  page. The owner turned it down: he wanted more people to want the app, and
  he sells it on two ideas, one list of every agent and talking to it. Before
  restructuring a hero, ask which ideas sell the product and keep each one on
  the first screen; less friction is not a reason to download.
- **Worked:** round 2 put both ideas in the hero (headline, a lede that starts
  with the problem, the Console beside the dictation clip) and answered the
  audience's first objection in its own section, a four-row table against
  plain SSH and tmux attach, with a download button under it.
- **Watch out:** an animated WebP on the first load costs every phone visitor
  its whole size. Give `sizes` a smaller width than the picture draws on
  phones so a 3x screen takes the 660px file (292 KB against 525 KB), and
  measure first-load bytes per viewport before and after.
- **Broke:** a product claim written into a worker's brief was wrong ("the app
  opens with a Sample"; the first screen offers a Sample row). The worker was
  told to use the copy verbatim and did. Check each claim in fixed copy
  against the release tag (`git show v<version>:<file>`) before briefing.
- **Broke:** the brief said "ten FAQ questions"; the home page shows twelve,
  because `index.astro` passes two more through `<Faq extra>`. Read how a page
  calls a component before pinning a count on it.
- **Broke:** callouts laid over the hero screenshot covered the rows they
  described on phones and tablets. A label goes beside a screenshot or not at
  all; look at 390, 768 and 1024 px wide, not only the sizes in the brief.
- **Watch out:** `subagent land` refuses once the parent merged `main` after
  starting the child ("Target moved or diverged"). Merge the child's branch
  with `git merge ultimate/<id>` instead, or merge `main` only after landing
  the children, then rerun the checks on the merged tree.
- **Watch out:** stop a server by the PID you saved, never `pkill -f <pattern>`:
  the pattern also matches the shell that runs the command.
- **Watch out:** `og/render.sh` on Linux needs `CHROME` pointed at a wrapper
  that execs `/usr/bin/chromium --no-sandbox "$@"`; keep the wrapper outside
  the repository. The default share card repeats the home page's headline, so
  a new H1 means `og/home.html`, `public/og.png` and `Layout`'s default
  `imageAlt` together.
- **Watch out:** `npm run build` in `apps/web` needs the plugin binaries;
  `npx astro build` checks the site without them. Serve `dist/` with
  `python3 -m http.server` for screenshots: PostHog tags any host but
  waycar.dev as `debug`, so local views stay out of the release numbers.
