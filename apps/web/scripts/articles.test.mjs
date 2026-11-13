// @ts-check
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  PX_PER_HEADING,
  ARTICLE_MODULE_IDS,
  DEFAULT_PICKS,
  MODULE_GAP,
  MODULE_HEIGHTS,
  PICKS,
  PICK_COUNT,
  PX_PER_WORD,
  RAIL_MODULE_IDS,
  modulesBesideArticle,
  startHereSlugs,
} from '../src/data/article-rail.ts';
import { publishToday, publishedNewestFirst } from '../src/lib/articles-list.mjs';
import { WORDS_PER_MINUTE, proseWords, readMinutes } from '../src/lib/read-time.mjs';

/**
 * @param {string} id
 * @param {string} date
 * @param {boolean} [draft]
 */
const entry = (id, date, draft) => ({ id, data: { date, ...(draft === undefined ? {} : { draft }) } });

const TODAY = '2026-10-20';

test('publishedNewestFirst sorts newest first, ties by id, and does not sort in place', () => {
  const entries = [entry('b', '2026-10-01'), entry('c', '2026-10-15'), entry('a', '2026-10-01'), entry('d', '2025-12-31')];
  assert.deepEqual(
    publishedNewestFirst(entries, TODAY).map((e) => e.id),
    ['c', 'a', 'b', 'd'],
  );
  assert.deepEqual(
    entries.map((e) => e.id),
    ['b', 'c', 'a', 'd'],
  );
});

test('publishedNewestFirst drops draft: true and keeps draft: false', () => {
  const entries = [entry('shown', '2026-10-01'), entry('hidden', '2026-10-02', true), entry('explicit', '2026-10-03', false)];
  assert.deepEqual(
    publishedNewestFirst(entries, TODAY).map((e) => e.id),
    ['explicit', 'shown'],
  );
});

test('publishedNewestFirst holds a post back until its date and shows it from that day on', () => {
  const entries = [entry('past', '2026-10-19'), entry('today', '2026-10-20'), entry('tomorrow', '2026-10-21')];
  assert.deepEqual(
    publishedNewestFirst(entries, '2026-10-20').map((e) => e.id),
    ['today', 'past'],
  );
  assert.deepEqual(
    publishedNewestFirst(entries, '2026-10-21').map((e) => e.id),
    ['tomorrow', 'today', 'past'],
  );
});

test('publishedNewestFirst refuses a malformed today instead of publishing every scheduled post', () => {
  for (const today of ['NaN-NaN-NaN', 'undefined', '', '2026-10-2']) {
    assert.throws(() => publishedNewestFirst([entry('a', '2099-01-01')], today), /YYYY-MM-DD/, today);
  }
});

test('publishToday reads the date in New York, at midnight and across the November clock change', () => {
  const cases = [
    ['2026-10-21T03:59:59Z', '2026-10-20'], // 23:59:59 EDT
    ['2026-10-21T04:00:00Z', '2026-10-21'], // midnight EDT
    ['2026-11-02T04:59:59Z', '2026-11-01'], // 23:59:59 EST, after the clocks went back
    ['2026-11-02T05:00:00Z', '2026-11-02'], // midnight EST
  ];
  for (const [instant, date] of cases) assert.equal(publishToday(new Date(instant)), date, instant);
});

const web = fileURLToPath(new URL('..', import.meta.url));

// A link to an article, in any form an article body can write one:
// `[x](/articles/slug)`, with a title, `[x](</articles/slug>)`, a
// `[x]: /articles/slug` definition, `<a href="/articles/slug">`, its `.md`
// twin, or the absolute waycar.dev URL. A file under /articles/, such as
// `figure.svg`, is an asset, not an article.
const ARTICLE_LINK = /(?<![\w.-])(?:https?:\/\/(?:www\.)?waycar\.dev)?\/articles\/([a-z0-9-]+)(?:\.md)?(?=[\s)\]>"'<#?/,;:]|\.(?:\s|$)|$)/g;

/**
 * The slug of every article that `body` links to.
 * @param {string} body
 * @returns {string[]}
 */
const articleLinkSlugs = (body) => [...body.matchAll(ARTICLE_LINK)].map((match) => match[1]);

test('articleLinkSlugs finds a link to an article in every form, and skips assets, the index and other sites', () => {
  for (const form of [
    '[x](/articles/a-b)',
    '[x](/articles/a-b "title")',
    '[x](/articles/a-b#part)',
    '[x](/articles/a-b.md)',
    '[x](</articles/a-b>)',
    '[x]: /articles/a-b',
    '<a href="/articles/a-b">x</a>',
    'See https://waycar.dev/articles/a-b.',
    'See https://www.waycar.dev/articles/a-b/',
  ]) {
    assert.deepEqual(articleLinkSlugs(form), ['a-b'], form);
  }
  for (const other of [
    '<img src="/articles/figure.svg">',
    '![x](/articles/figure-traffic.gif)',
    '[x](/articles)',
    '[x](/articles/)',
    '[x](https://example.com/articles/a-b)',
  ]) {
    assert.deepEqual(articleLinkSlugs(other), [], other);
  }
});

/**
 * The id, date, draft flag and `/articles/<slug>` link targets of every file in src/content/articles/.
 * @returns {{ id: string, date: string, draft: boolean, links: string[] }[]}
 */
function readArticles() {
  const dir = join(web, 'src/content/articles');
  return readdirSync(dir)
    .filter((file) => file.endsWith('.md'))
    .map((file) => {
      const text = readFileSync(join(dir, file), 'utf8');
      const [, front = '', body = ''] = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/.exec(text) ?? [];
      /** @param {string} name */
      const field = (name) => new RegExp(`^${name}:[ \\t]*(.+)$`, 'm').exec(front)?.[1].trim().replace(/^["']|["']$/g, '') ?? '';
      return {
        id: file.slice(0, -'.md'.length),
        date: field('date'),
        draft: field('draft') === 'true',
        links: articleLinkSlugs(body),
      };
    });
}

// A post dated for a later day is hidden until then, so a link to one from an
// article that is already live would 404. Links point back in time only.
test('a published article links only to articles that are live by its own date', () => {
  const articles = readArticles();
  // If front matter ever stops parsing (CRLF line endings, say), every date and
  // link list comes back empty and the loop below passes having checked nothing.
  assert.deepEqual(
    articles.filter(({ date }) => !/^\d{4}-\d{2}-\d{2}$/.test(date)).map(({ id }) => id),
    [],
    'articles with no YYYY-MM-DD date',
  );
  const byId = new Map(articles.map((article) => [article.id, article]));
  /** @type {string[]} */
  const problems = [];
  // A draft's own date is set when it is published, and this test runs again then.
  for (const article of articles.filter((candidate) => !candidate.draft)) {
    for (const slug of article.links) {
      const target = byId.get(slug);
      if (!target) problems.push(`${article.id} links to /articles/${slug}, which does not exist`);
      else if (target.draft) problems.push(`${article.id} links to ${slug}, which is a draft`);
      else if (target.date > article.date) problems.push(`${article.id} (${article.date}) links to ${slug}, dated ${target.date}`);
    }
  }
  assert.deepEqual(problems, []);
});

/**
 * All files under `dir`, as paths relative to `base`.
 * @param {string} dir
 * @param {string} [base]
 * @returns {string[]}
 */
function walk(dir, base = dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((/** @type {import('node:fs').Dirent} */ item) => {
    const path = join(dir, item.name);
    return item.isDirectory() ? walk(path, base) : [path.slice(base.length + 1)];
  });
}

// Two posts that must not appear: one a draft whose date has come, one not a
// draft but dated for a day that has not.
const CANARIES = [
  { slug: 'zz-draft-leak-canary', title: 'Draft leak canary title', frontmatter: 'date: 2020-01-01\ndraft: true' },
  { slug: 'zz-scheduled-leak-canary', title: 'Scheduled leak canary title', frontmatter: 'date: 2099-01-01' },
];

test('a draft: true or future-dated article never reaches the built site', { timeout: 300_000 }, () => {
  const files = CANARIES.map(({ slug }) => join(web, 'src/content/articles', `${slug}.md`));
  // Inside the project: Astro renames build assets across the output dir, which fails across devices (EXDEV) for /tmp on CI.
  mkdirSync(join(web, '.astro'), { recursive: true });
  const outDir = mkdtempSync(join(web, '.astro', 'articles-test-'));
  CANARIES.forEach(({ title, frontmatter }, index) =>
    writeFileSync(
      files[index],
      `---\ntitle: ${title}\ndescription: A post that must stay hidden everywhere, so this line is long enough to pass the schema check.\n${frontmatter}\nkeywords: [one, two, three]\n---\n\nBody text for the canary.\n`,
    ),
  );
  try {
    execFileSync(process.execPath, [join(web, 'node_modules/astro/bin/astro.mjs'), 'build', '--outDir', outDir], {
      cwd: web,
      stdio: 'pipe',
    });
    assert.ok(existsSync(join(outDir, 'articles.md')), 'the build wrote dist/articles.md');
    const built = walk(outDir);
    for (const { slug, title } of CANARIES) {
      assert.deepEqual(
        built.filter((file) => file.includes(slug)),
        [],
        `no file for ${slug} in dist/articles/`,
      );
      for (const file of ['articles.md', 'llms.txt', 'sitemap.xml', 'articles.html']) {
        if (!existsSync(join(outDir, file))) continue;
        const text = readFileSync(join(outDir, file), 'utf8');
        assert.ok(!text.includes(slug) && !text.includes(title), `${file} does not mention ${slug}`);
      }
    }
    assert.ok(readFileSync(join(outDir, 'sitemap.xml'), 'utf8').includes('/articles'), 'sitemap.xml lists the articles');
    // The gate must not hide everything: a clock or format slip would empty the list.
    assert.match(readFileSync(join(outDir, 'articles.md'), 'utf8'), /\]\(https:\/\/waycar\.dev\/articles\/[a-z0-9-]+\.md\)/);
  } finally {
    for (const file of files) rmSync(file, { force: true });
    rmSync(outDir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// The article page: read time, the rail's picks, and the built pages.
// ---------------------------------------------------------------------------

test('proseWords skips fenced code, HTML tags and bare symbols, and readMinutes never says 0', () => {
  const body = [
    'One two three.',
    '',
    '```sh',
    'a very long command that is not prose at all',
    '```',
    '',
    '~~~~text',
    '```',
    'still inside, the inner fence is shorter than the opener',
    '~~~~',
    '',
    '<img src="/x.gif" alt="not counted as words">',
    'Four five -- six',
  ].join('\n');
  assert.equal(proseWords(body), 6);
  assert.equal(proseWords('```\nnever closed\nstill code'), 0);
  assert.equal(readMinutes(''), 1);
  assert.equal(readMinutes('word '.repeat(WORDS_PER_MINUTE * 3)), 3);
  assert.equal(readMinutes('word '.repeat(WORDS_PER_MINUTE * 3 + WORDS_PER_MINUTE / 2 - 1)), 3);
  assert.equal(readMinutes('word '.repeat(WORDS_PER_MINUTE * 3 + WORDS_PER_MINUTE / 2)), 4);
});

test('startHereSlugs picks four live guides: its own first, never the page itself, defaults fill the rest', () => {
  const all = new Set([...DEFAULT_PICKS, ...Object.keys(PICKS), ...Object.values(PICKS).flat()]);
  for (const slug of Object.keys(PICKS)) {
    const picks = startHereSlugs(slug, all);
    assert.equal(picks.length, PICK_COUNT, `${slug} gets ${PICK_COUNT} guides`);
    assert.ok(!picks.includes(slug), `${slug} does not link itself`);
    assert.equal(new Set(picks).size, picks.length, `${slug} has no repeats`);
  }
  // An article with no picks of its own gets the defaults.
  assert.deepEqual(startHereSlugs('unlisted-article', all), DEFAULT_PICKS);
  // A pick that is not live (scheduled, draft) is skipped and the defaults fill in.
  const own = PICKS['run-omp-from-your-phone-over-mosh'];
  const live = new Set(all);
  live.delete(own[0]);
  const picks = startHereSlugs('run-omp-from-your-phone-over-mosh', live);
  assert.ok(!picks.includes(own[0]));
  assert.deepEqual(picks.slice(0, 3), own.slice(1, 4));
  assert.equal(picks.length, PICK_COUNT);
  // The page itself is never in the defaults' fill.
  assert.ok(!startHereSlugs(DEFAULT_PICKS[0], all).includes(DEFAULT_PICKS[0]));
});

test('modulesBesideArticle keeps the rail no taller than the article: the first modules that fit stay beside it', () => {
  /** @param {number} count */
  const stack = (count) => MODULE_HEIGHTS.slice(0, count).reduce((sum, height) => sum + height, 0) + MODULE_GAP * Math.max(0, count - 1);
  assert.equal(modulesBesideArticle(0, 0), 0, 'an empty page fits no module');
  assert.equal(modulesBesideArticle(300, 3), 2, 'a 300 word article keeps two and sends two below');
  for (const [words, headings] of [[100, 1], [300, 3], [600, 5], [861, 10], [1500, 14], [4000, 20]]) {
    const room = words * PX_PER_WORD + headings * PX_PER_HEADING;
    const count = modulesBesideArticle(words, headings);
    assert.ok(stack(count) <= room, `${words} words: ${count} modules fit`);
    if (count < MODULE_HEIGHTS.length) assert.ok(stack(count + 1) > room, `${words} words: one more would not fit`);
  }
  assert.equal(modulesBesideArticle(861, 10), MODULE_HEIGHTS.length, 'the shortest live article carries all four');
});

const HERO_PAGES = new Set(['reach-your-local-network-with-tailscale', 'reach-your-ai-harness-while-you-are-away']);

test('every built article page: TOC equals the H2 ids, rail modules are known, hero loads once and eager', { timeout: 300_000 }, () => {
  mkdirSync(join(web, '.astro'), { recursive: true });
  const outDir = mkdtempSync(join(web, '.astro', 'articles-pages-'));
  try {
    execFileSync(process.execPath, [join(web, 'node_modules/astro/bin/astro.mjs'), 'build', '--outDir', outDir], {
      cwd: web,
      stdio: 'pipe',
    });
    const slugs = readdirSync(join(outDir, 'articles'))
      .filter((file) => file.endsWith('.html') && file !== 'index.html')
      .map((file) => file.slice(0, -'.html'.length));
    assert.ok(slugs.length >= 8, `the build has the live articles (got ${slugs.length})`);
    /** @type {string[]} */
    const problems = [];
    for (const slug of slugs) {
      const html = readFileSync(join(outDir, 'articles', `${slug}.html`), 'utf8');
      const md = readFileSync(join(outDir, 'articles', `${slug}.md`), 'utf8');
      const bodyStart = html.indexOf('<div class="prose"');
      const bodyEnd = html.indexOf('<footer class="after"');
      const body = html.slice(bodyStart, bodyEnd);
      const ids = [...body.matchAll(/<h2 id="([^"]+)"/g)].map((match) => match[1]);
      if (bodyStart < 0 || bodyEnd < bodyStart || ids.length === 0) {
        problems.push(`${slug}: no H2s found in the body`);
        continue;
      }
      if (new Set(ids).size !== ids.length) problems.push(`${slug}: duplicate H2 ids`);
      // Both lists, the <details> under 1024 px and the sticky one above, hold exactly the body's H2s in order.
      const lists = [...html.matchAll(/<ol[^>]*data-toc[^>]*>([\s\S]*?)<\/ol>/g)].map((match) =>
        [...match[1].matchAll(/<a href="#([^"]+)"/g)].map((link) => link[1]),
      );
      if (lists.length !== 2) problems.push(`${slug}: expected two TOC lists, found ${lists.length}`);
      for (const list of lists) if (list.join() !== ids.join()) problems.push(`${slug}: TOC links differ from the H2 ids`);
      // Every rail and TOC card module id is one of the five, and `toc-card` appears once.
      const modules = [...html.matchAll(/data-ph-module="([^"]+)"/g)].map((match) => match[1]);
      for (const id of modules) if (!(/** @type {readonly string[]} */ (ARTICLE_MODULE_IDS)).includes(id)) problems.push(`${slug}: unknown module ${id}`);
      if (modules.filter((id) => id === 'toc-card').length !== 1) problems.push(`${slug}: toc-card must appear once`);
      for (const id of RAIL_MODULE_IDS) {
        if (id !== 'start-here' && modules.filter((candidate) => candidate === id).length !== 1) problems.push(`${slug}: module ${id} must appear once`);
      }
      // "Start here" links point at built articles, never at the page itself.
      const start = html.slice(html.indexOf('data-ph-module="start-here"'));
      const guides = [...start.slice(0, start.indexOf('</section>')).matchAll(/<a href="\/articles\/([a-z0-9-]+)"/g)].map((match) => match[1]);
      if (guides.length !== PICK_COUNT) problems.push(`${slug}: expected ${PICK_COUNT} guides, found ${guides.length}`);
      for (const guide of guides) {
        if (guide === slug) problems.push(`${slug}: guide links itself`);
        if (!existsSync(join(outDir, 'articles', `${guide}.html`))) problems.push(`${slug}: guide ${guide} is not a built page`);
      }
      // Hero: only the two graphic articles carry one. It is the page's LCP image: sized, eager, high priority; the twin keeps it.
      const hero = /<figure class="hero[^"]*"[^>]*>\s*<img([^>]*)>/.exec(html)?.[1];
      if (HERO_PAGES.has(slug)) {
        if (!hero) problems.push(`${slug}: no hero`);
        else {
          for (const attribute of ['width="1200"', 'height="720"', 'loading="eager"', 'fetchpriority="high"', 'data-zoom-src="/articles/tailscale-subnet-router.svg"']) {
            if (!hero.includes(attribute)) problems.push(`${slug}: hero lacks ${attribute}`);
          }
        }
        if ((html.match(/<img[^>]*tailscale-subnet-router-traffic\.gif/g) ?? []).length !== 1) problems.push(`${slug}: the GIF must appear once`);
        if (!/!\[A phone on cellular[^\]]*\]\(https:\/\/waycar\.dev\/articles\/tailscale-subnet-router-traffic\.gif\)/.test(md)) problems.push(`${slug}: the twin lost the hero image or its alt text`);
        if (!html.includes('"image":"https://waycar.dev/articles/tailscale-subnet-router-traffic.gif"')) problems.push(`${slug}: JSON-LD has no image`);
      } else {
        if (hero || html.includes('<figure class="hero')) problems.push(`${slug}: has a hero it should not`);
        if (/<img[^>]+\/articles\//.test(html)) problems.push(`${slug}: requests an article image`);
        if (md.includes('![')) problems.push(`${slug}: the twin gained an image`);
      }
      // Nothing in the page's rail or TOC points off the site except the App Store.
      const chrome = html.slice(html.indexOf('<div class="grid"'), html.indexOf('<div class="article"')) + html.slice(bodyEnd, html.indexOf('<dialog class="lightbox"'));
      for (const href of chrome.matchAll(/href="(https?:[^"]+)"/g)) {
        if (!/^https:\/\/apps\.apple\.com\//.test(href[1])) problems.push(`${slug}: external link ${href[1]}`);
      }
    }
    assert.deepEqual(problems, []);
  } finally {
    rmSync(outDir, { recursive: true, force: true });
  }
});
