// @ts-check
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { buildSite } from './site-build.mjs';
import { htmlToText, listIndexablePages } from './site-pages.mjs';

test('site-only pages and product summaries describe Waycar as free without launch metering', { timeout: 300_000 }, (t) => {
  const { outDir, cleanup } = buildSite();
  t.after(cleanup);

  // Help ships with the app, and release notes keep their Pro history, but no
  // note on an old release may call a limit current. Check raw HTML too,
  // including FAQ JSON-LD.
  for (const { url, file } of listIndexablePages(outDir)) {
    const html = readFileSync(join(outDir, file), 'utf8');
    if (/^\/changelog(?:\/|$)/.test(new URL(url).pathname)) {
      assert.doesNotMatch(html, /Current free allowance/i, file);
      continue;
    }
    if (/^\/help(?:\/|$)/.test(new URL(url).pathname)) continue;
    assert.doesNotMatch(html, /\bWaycar Pro\b|\b10 (?:free )?Launches\b|Welcome Allowance/i, file);
  }

  const pricing = htmlToText(readFileSync(join(outDir, 'pricing.html'), 'utf8'), 'https://waycar.dev/pricing');
  assert.match(pricing, /Waycar is free\./);
  assert.match(pricing, /Everything included\. No account\. No subscription\./);
  assert.match(pricing, /Start and resume agents and shells with no limit\./);
  assert.match(pricing, /Is it really free\?/);
  assert.match(pricing, /Usage analytics are opt-in/);
  assert.match(pricing, /\[privacy policy\]\(https:\/\/waycar.dev\/privacy\)/);

  const guide = readFileSync(join(outDir, 'index.md'), 'utf8');
  const overview = readFileSync(join(outDir, 'llms.txt'), 'utf8');
  assert.match(guide, /Waycar is free\. Every feature is included, with no limit on starting or resuming agents and shells\./);
  assert.match(overview, /- Pricing: free\. Every feature included, unlimited agent and shell launches, no account or subscription\./);
});
