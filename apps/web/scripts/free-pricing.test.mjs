// @ts-check
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { buildSite } from './site-build.mjs';
import { listIndexablePages } from './site-pages.mjs';

test('the site has no pricing page or links and no launch metering', { timeout: 300_000 }, (t) => {
  const { outDir, cleanup } = buildSite();
  t.after(cleanup);
  assert.equal(existsSync(join(outDir, 'pricing.html')), false, 'the retired pricing page is not built');

  // No page, including noindex pages, help and release notes, may link to
  // the retired pricing page. Other products' pricing links are unaffected.
  const pricingLinks = readdirSync(outDir, { recursive: true, encoding: 'utf8' })
    .filter((file) => file.endsWith('.html'))
    .filter((file) => /\bhref=["'](?:https:\/\/(?:www\.)?waycar\.(?:dev|app))?\/pricing(?:\.html)?(?:[/?#]|["'])/i.test(readFileSync(join(outDir, file), 'utf8')));

  // Help ships with the app, and release notes keep their Pro history, but no
  // note on an old release may call a limit current. Check raw HTML too,
  // including FAQ JSON-LD.
  for (const { url, file, html } of listIndexablePages(outDir)) {
    if (/^\/changelog(?:\/|$)/.test(new URL(url).pathname)) {
      assert.doesNotMatch(html, /Current free allowance/i, file);
      continue;
    }
    if (/^\/help(?:\/|$)/.test(new URL(url).pathname)) continue;
    assert.doesNotMatch(html, /\bWaycar Pro\b|\b10 (?:free )?Launches\b|Welcome Allowance/i, file);
  }
  assert.deepEqual(pricingLinks, [], 'pages must not link to the retired pricing page');
});
