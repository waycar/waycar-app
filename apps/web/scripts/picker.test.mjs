// @ts-check
// The Get Waycar picker, checked on the built HTML. Every store button on the
// site is a button that opens a picker (src/components/AppStoreCta.astro,
// GetPicker.astro); the picker alone names a store or a device.
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { ORGANIC_CT } from '../src/lib/ad-links.mjs';
import { buildSite } from './site-build.mjs';

const LISTING = 'https://apps.apple.com/app/id6815881853';
const BUTTON_LABELS = new Set(['Get Waycar', 'Download']);
const NAMES_A_DEVICE_OR_STORE = /iPhone|iPad|iOS|App Store|Google Play/i;

/** @param {string} dir @param {string} [base] @returns {string[]} */
function htmlFiles(dir, base = dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((item) => {
    const path = join(dir, item.name);
    if (item.isDirectory()) return htmlFiles(path, base);
    return item.name.endsWith('.html') ? [path.slice(base.length + 1)] : [];
  });
}

/** @param {string} html */
function pickers(html) {
  return [...html.matchAll(/<dialog class="picker" id="([^"]+)"[\s\S]*?<\/dialog>/g)].map((match) => ({
    id: match[1],
    html: match[0],
  }));
}

/** @param {string} html */
function buttons(html) {
  return [...html.matchAll(/<a\b([^>]*\bdata-picker-open\b[^>]*)>([\s\S]*?)<\/a>/g)].map((match) => ({
    attributes: match[1] ?? '',
    text: (match[2] ?? '').replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim(),
  }));
}

test('every store button opens a picker and names no store or device (M1, M2, M3)', { timeout: 300_000 }, (t) => {
  const { outDir, cleanup } = buildSite();
  t.after(cleanup);
  const files = htmlFiles(outDir);
  for (const required of ['index.html', 'compare.html', 'help/install.html']) assert.ok(files.includes(required), `${required} was built`);
  for (const prefix of ['articles/', 'compare/', 'solutions/']) {
    assert.ok(files.some((file) => file.startsWith(prefix)), `a page under ${prefix} was built`);
  }

  const problems = [];
  for (const file of files) {
    const html = readFileSync(join(outDir, file), 'utf8');
    const found = pickers(html);
    const triggers = buttons(html);

    // One button per picker, and each button's href names its picker; ids are unique on the page.
    const ids = found.map((picker) => picker.id);
    if (new Set(ids).size !== ids.length) problems.push(`${file}: picker ids repeat`);
    const targets = triggers.map((trigger) => /\bhref="#([^"]+)"/.exec(trigger.attributes)?.[1]);
    if (targets.slice().sort().join() !== ids.slice().sort().join()) problems.push(`${file}: buttons ${targets} do not match pickers ${ids}`);

    // M1: a button's text and its aria-label, if any, name no store or device.
    for (const trigger of triggers) {
      if (!BUTTON_LABELS.has(trigger.text)) problems.push(`${file}: button text "${trigger.text}"`);
      const label = /\baria-label="([^"]*)"/.exec(trigger.attributes)?.[1];
      if (label !== undefined && (!BUTTON_LABELS.has(label) || NAMES_A_DEVICE_OR_STORE.test(label))) problems.push(`${file}: aria-label "${label}"`);
    }

    // M2: the App Store listing is linked from a picker and from nowhere else. The ad hop page (/go)
    // keeps its own fallback link to the listing; the article's setup prompt is text, not a link.
    if (file !== 'go.html') {
      const outside = found.reduce((rest, picker) => rest.replace(picker.html, ''), html);
      if (outside.includes(`href="${LISTING}`)) problems.push(`${file}: a link to the listing outside a picker`);
    }

    for (const picker of found) {
      // M3: a tab inside the picker reaches the App Store link and Close, nothing else.
      const anchors = [...picker.html.matchAll(/<a\b([^>]*)>/g)].map((match) => match[1] ?? '');
      const focusable = anchors.filter((attributes) => !/\btabindex="-1"/.test(attributes));
      const hrefs = focusable.map((attributes) => /\bhref="([^"]*)"/.exec(attributes)?.[1] ?? '');
      if (hrefs.length !== 2 || !hrefs[0]?.startsWith(LISTING) || hrefs[1] !== '#_') problems.push(`${file}: ${picker.id} focusable links ${hrefs}`);
      if (/<button\b|<input\b|<select\b|<textarea\b|\btabindex="(?!-1)/.test(picker.html)) problems.push(`${file}: ${picker.id} has another control`);

      // The App Store link carries a campaign token from the closed organic list.
      const ct = /(?:\?|&amp;|&)ct=([^&"]+)/.exec(hrefs[0] ?? '')?.[1];
      if (!ct || !ORGANIC_CT.test(ct)) problems.push(`${file}: ${picker.id} ct "${ct}"`);

      // The Android tile is text: no link, no control, no image, no Play name, robot, price or date.
      const tile = /<li class="tile soon"[^>]*>[\s\S]*?<\/li>/.exec(picker.html)?.[0];
      if (!tile) problems.push(`${file}: ${picker.id} has no Android tile`);
      else {
        if (/<a\b|<button\b|<img\b|<svg\b|\bhref=|\btabindex=/.test(tile)) problems.push(`${file}: ${picker.id} Android tile is not plain text`);
        const text = tile.replace(/<[^>]*>/g, ' ').replace(/&trade;/g, '™').replace(/\s+/g, ' ').trim();
        if (text !== 'Android™ , Coming soon') problems.push(`${file}: ${picker.id} Android tile reads "${text}"`);
      }
      const withoutTrademarkLine = picker.html.replace(/<p class="legal"[\s\S]*?<\/p>/, '');
      if (/\bPlay\b|google|robot|\$\d/i.test(withoutTrademarkLine)) problems.push(`${file}: ${picker.id} names Google Play, a robot or a price`);
    }
  }
  assert.deepEqual(problems, []);

  // S1: the QR code is a file the build wrote, not a request to another origin, and its link is /qr/site-qr.svg.
  const qr = readFileSync(join(outDir, 'qr/site-qr.svg'), 'utf8');
  assert.ok(qr.startsWith('<svg ') && qr.includes('<path d="M'), 'the QR file is an SVG with modules');
  const home = readFileSync(join(outDir, 'index.html'), 'utf8');
  assert.ok(pickers(home).every((picker) => picker.html.includes('<img src="/qr/site-qr.svg"')), 'every picker shows the QR');
});

test('with APP_STORE_LISTING_URL emptied, buttons are plain "Coming soon" labels (M8)', { timeout: 300_000 }, (t) => {
  const { outDir, cleanup } = buildSite({ switches: { APP_STORE_LISTING_URL: '' } });
  t.after(cleanup);
  const problems = [];
  for (const file of htmlFiles(outDir)) {
    if (file === 'go.html') continue;
    const html = readFileSync(join(outDir, file), 'utf8');
    if (html.includes('class="picker"') || html.includes('data-picker-open')) problems.push(`${file}: a picker or button`);
    if (html.includes('get_picker_opened') || html.includes('app_store_clicked')) problems.push(`${file}: a store event`);
    if (/<a\b[^>]*href="https:\/\/apps\.apple\.com\/app\//.test(html)) problems.push(`${file}: a link to the listing`);
  }
  assert.deepEqual(problems, []);
  const home = readFileSync(join(outDir, 'index.html'), 'utf8');
  assert.ok(home.includes('Coming soon to the App Store'), 'the home page says it is coming soon');
  assert.ok(existsSync(join(outDir, 'compare.html')));
  assert.ok(!existsSync(join(outDir, 'qr')), 'no QR file for a listing that is not live');
});

test('with PLAY_STORE_LISTING_URL set, the Android tile links to it and the App Store badge turns black (S2)', { timeout: 300_000 }, (t) => {
  const play = 'https://play.google.com/store/apps/details?id=dev.waycar.dummy';
  const { outDir, cleanup } = buildSite({ switches: { PLAY_STORE_LISTING_URL: play } });
  t.after(cleanup);
  const home = readFileSync(join(outDir, 'index.html'), 'utf8');
  const found = pickers(home);
  assert.ok(found.length > 0, 'the home page has pickers');
  for (const picker of found) {
    assert.ok(picker.html.includes('/app-store-badge-black.svg') && !picker.html.includes('/app-store-badge.svg'), `${picker.id}: black badge`);
    assert.equal(picker.html.match(new RegExp(`href="${play.replaceAll('?', '\\?')}"`, 'g'))?.length, 1, `${picker.id}: one link to Play`);
    assert.ok(!picker.html.includes('class="tile soon"'), `${picker.id}: no "Coming soon" tile`);
  }
});
