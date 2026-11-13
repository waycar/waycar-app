// @ts-check
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { hasNewerRelease } from '../src/lib/changelog.mjs';
import { htmlToText, listIndexablePages } from './site-pages.mjs';
import { buildSite } from './site-build.mjs';

/**
 * @param {string} head
 * @param {string} [main]
 */
const page = (head, main = '<p>Hello</p>') =>
  `<!DOCTYPE html><html><head>${head}</head><body><main id="main">${main}</main></body></html>`;

test('listIndexablePages keeps one page per canonical URL, home first, no noindex', (t) => {
  const dist = mkdtempSync(join(tmpdir(), 'waycar-dist-'));
  t.after(() => rmSync(dist, { recursive: true, force: true }));
  mkdirSync(join(dist, 'docs'));
  // b.html sorts before index.html, so index.html must win on merit.
  writeFileSync(join(dist, 'b.html'), page('<link rel="canonical" href="https://waycar.dev/">', 'B'));
  writeFileSync(join(dist, 'index.html'), page('<link rel="canonical" href="https://waycar.dev/">', 'A'));
  writeFileSync(join(dist, 'about.html'), page('<link href="https://waycar.dev/about" rel="canonical">'));
  writeFileSync(join(dist, 'docs', 'guide.html'), page('<link rel="canonical" href="https://waycar.dev/docs/guide">'));
  writeFileSync(join(dist, '404.html'), page('<meta content="noindex" name="robots">'));
  writeFileSync(join(dist, 'draft.html'), page('<title>No canonical</title>'));

  const pages = listIndexablePages(dist);
  assert.deepEqual(
    pages.map((p) => [p.url, p.file]),
    [
      ['https://waycar.dev/', 'index.html'],
      ['https://waycar.dev/about', 'about.html'],
      ['https://waycar.dev/docs/guide', 'docs/guide.html'],
    ],
  );
});

// The help gate (src/data/unreleased.ts); delete with it once a release newer than 1.3.0 lifts it.
test('while 1.3.0 is the newest release, the site marks newer help and hides Unreleased but shows 1.3.0', { timeout: 300_000 }, (t) => {
  const gate = readFileSync(new URL('../src/data/unreleased.ts', import.meta.url), 'utf8');
  const appStoreRelease = /APP_STORE_RELEASE = '([\d.]+)'/.exec(gate)?.[1] ?? '';
  assert.equal(appStoreRelease, '1.3.0');
  const releases = readdirSync(new URL('../src/content/changelog/', import.meta.url)).map((file) => file.replace(/\.md$/, ''));
  if (hasNewerRelease(releases, appStoreRelease)) {
    t.skip('a newer release lifted the help gate: delete it (README "Release content switch") and this test');
    return;
  }
  const { outDir, cleanup } = buildSite();
  t.after(cleanup);
  const note = 'Coming in the next update of Waycar.';
  for (const slug of ['codex', 'opencode', 'zellij']) {
    const source = readFileSync(new URL(`../src/content/help/${slug}.md`, import.meta.url), 'utf8');
    assert.ok(!source.includes(note), `the note must not reach the app's bundled help: ${slug}.md`);
    const html = readFileSync(join(outDir, `help/${slug}.html`), 'utf8');
    const article = html.slice(html.indexOf('<main'));
    assert.match(article, new RegExp(`<blockquote>\\s*<p>${note}</p>`), slug);
    const markdown = readFileSync(join(outDir, `help/${slug}.md`), 'utf8');
    const body = markdown.split('\n').filter((line) => line && !line.startsWith('#'));
    assert.equal(body[1], `> ${note}`, `${slug}.md: the note follows the lead`);
  }
  for (const file of ['help.html', 'help.md', 'help/search.json', 'llms.txt', 'sitemap.xml']) {
    const text = readFileSync(join(outDir, file), 'utf8');
    for (const slug of ['codex', 'opencode', 'zellij']) {
      assert.ok(text.includes(`/help/${slug}`) || text.includes(`"slug":"${slug}"`), `${file} lists ${slug}`);
    }
  }
  for (const slug of ['new-agent', 'host-page', 'closed-sessions', 'notifications', 'requirements']) {
    assert.ok(!readFileSync(join(outDir, `help/${slug}.html`), 'utf8').includes(note), slug);
  }
  const index = readFileSync(join(outDir, 'changelog.html'), 'utf8');
  assert.ok(index.includes('id="v1-3-0"'));
  assert.ok(index.includes('Waycar is free'));
  assert.ok(!index.includes('id="unreleased"'));
  assert.ok(!index.includes('Codex chats'));
});

test('htmlToText resolves links, decodes entities, and drops scripts and SVG', () => {
  const html = page(
    '',
    `<h2>Plans &amp; pricing</h2>
     <script>var leaked = 1;</script>
     <p>Read the <a href="/privacy">privacy&nbsp;policy</a>, the <a href="#faq">FAQ</a>, or
     <a href="guide">the guide</a>.<svg><text>icon text</text></svg> &#36;5.00 &#x2014; &rsquo;yes&rsquo;</p>
     <ul><li>one</li><li>two</li></ul>
     <table><tr><th>Feature</th><th>herdr</th></tr><tr><td>Alerts</td><td>Yes</td></tr></table>`,
  );
  const text = htmlToText(html, 'https://waycar.dev/docs/page');
  assert.ok(text.includes('## Plans & pricing'), text);
  assert.ok(text.includes('[privacy policy](https://waycar.dev/privacy)'), text);
  assert.ok(text.includes('[the guide](https://waycar.dev/docs/guide)'), text);
  assert.ok(text.includes('the FAQ, or'), text);
  assert.ok(text.includes('$5.00 — ’yes’'), text);
  assert.ok(text.includes('- one\n- two'), text);
  assert.ok(text.includes('| Feature | herdr |\n| --- | --- |\n| Alerts | Yes |'), text);
  assert.ok(!text.includes('leaked') && !text.includes('icon text'), text);
});
