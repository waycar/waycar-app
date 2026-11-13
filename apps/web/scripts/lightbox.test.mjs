// @ts-check
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

// The article page ships a lightbox: tapping any image in the body opens it
// near fullscreen in a server-rendered <dialog>. Like setup-prompt.test.mjs,
// these checks pin the page source: the dialog, the bundled script, and the
// wiring the behavior needs.
const web = fileURLToPath(new URL('..', import.meta.url));
const page = readFileSync(join(web, 'src/pages/articles/[slug].astro'), 'utf8');

test('the article page ships a server-rendered lightbox dialog', () => {
  assert.ok(page.includes('<dialog class="lightbox" data-lightbox aria-label="Image preview">'), 'dialog');
  assert.ok(page.includes('<img data-lightbox-img'), 'image slot');
  assert.ok(page.includes('[data-lightbox-caption]'), 'caption element');
  assert.ok(page.includes('[data-lightbox-close]'), 'visible close button');
});

test('the lightbox script is a bundled module, never inline', () => {
  assert.ok(page.includes('<script>'), 'bundled module scripts');
  assert.ok(!page.includes('is:inline'), 'no inline script');
});

test('every article image becomes a button that opens the dialog', () => {
  assert.ok(page.includes("body.querySelectorAll<HTMLImageElement>('img')"), 'wraps every image');
  assert.ok(page.includes("button.className = 'zoom'"), 'button-wrapped trigger for keyboard and VoiceOver');
  assert.ok(page.includes("img.closest('a')"), 'images inside links stay links');
  assert.ok(page.includes('lightbox.showModal()'), 'opens as a modal dialog');
});

test('the dialog closes from backdrop, Close button, and Escape, and restores focus', () => {
  assert.ok(page.includes('event.target === lightbox'), 'backdrop click');
  assert.ok(page.includes("addEventListener('click', () => lightbox.close())"), 'close button');
  assert.ok(page.includes("lightbox.addEventListener('close', () => opener?.focus())"), 'focus restore');
  // Escape closes through the dialog's native cancel path, no code needed.
});

test('the dialog shows data-zoom-src when the author provides it, else the image as-is', () => {
  assert.ok(
    page.includes("img.getAttribute('data-zoom-src') || img.currentSrc || img.src"),
    'zoom source with auto-derivation fallback',
  );
});

test('the dialog takes its caption from the image alt text', () => {
  assert.ok(page.includes('lightboxCaption.textContent = alt'), 'caption from alt');
  assert.ok(page.includes("lightboxCaption.hidden = alt === '';"), 'empty alt hides the caption');
});

test('motion stays calm and the page scroll locks while open', () => {
  assert.ok(page.includes('animation: lightbox-in 0.18s ease-out'), 'transition under 200ms');
  assert.ok(page.includes('@media (prefers-reduced-motion: no-preference)'), 'reduced motion shows it without animation');
  assert.ok(page.includes('html:has(dialog.lightbox[open])'), 'scroll lock');
});

test('prose images never overflow the column, and the diagram has an intrinsic size', () => {
  const prose = readFileSync(join(web, 'src/components/Prose.astro'), 'utf8');
  assert.ok(prose.includes('max-width: 100%'), 'prose images capped at the column');
  const svg = readFileSync(join(web, 'public/articles/tailscale-subnet-router.svg'), 'utf8');
  assert.ok(svg.includes('width="1600" height="960"'), 'diagram declares its natural pixel size');
});

test('the two Tailscale articles show the animated diagram once, as their hero, and hand the lightbox its vector twin', () => {
  const alt =
    'A phone on cellular connects through an encrypted Tailscale tunnel to a subnet router. Any always-on device can be the router: a Raspberry Pi, an old Windows PC, a Linux VM, a Mac mini or a MacBook. Behind it, every machine on the home network is reachable.';
  for (const slug of [
    'reach-your-ai-harness-while-you-are-away',
    'reach-your-local-network-with-tailscale',
  ]) {
    const article = readFileSync(join(web, `src/content/articles/${slug}.md`), 'utf8');
    const [, front = '', body = ''] = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/.exec(article) ?? [];
    // The graphic is `hero` front matter, a file in public/ by absolute path:
    // astro:assets would flatten the animation. The page renders it under the
    // title band, so the body must not carry a second copy.
    const hero = /^hero:\n((?:[ \t]+.+\n?)+)/m.exec(`${front}\n`)?.[1] ?? '';
    /** @param {string} name */
    const field = (name) => new RegExp(`^[ \\t]+${name}:[ \\t]*(.+)$`, 'm').exec(hero)?.[1].trim().replace(/^"|"$/g, '');
    assert.equal(field('src'), '/articles/tailscale-subnet-router-traffic.gif', `${slug} heroes the animated GIF from public/articles`);
    assert.equal(field('zoom'), '/articles/tailscale-subnet-router.svg', `${slug} points the lightbox at the crisp vector`);
    assert.equal(field('alt'), alt, `${slug} keeps the plain-voice alt text`);
    assert.ok(!body.includes('tailscale-subnet-router'), `${slug} shows the diagram once, in the hero`);
    assert.ok(!field('alt')?.includes('—') && !field('alt')?.includes('–'), `${slug} has no dashes in the alt text`);
    // The hero's width and height reserve its box before the file loads, so they must be the GIF's own pixels.
    const gif = readFileSync(join(web, 'public/articles/tailscale-subnet-router-traffic.gif'));
    assert.deepEqual(
      [Number(field('width')), Number(field('height'))],
      [gif.readUInt16LE(6), gif.readUInt16LE(8)],
      `${slug} hero size matches the GIF`,
    );
  }
});
