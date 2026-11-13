// @ts-check
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import {
  adLinkSlug,
  appStoreCampaignUrl,
  campaignFromSearch,
  isAppleDevice,
  isAppleHandheld,
  organicCampaign,
  ORGANIC_CT,
  PAID_CT,
  resolveAdLink,
} from '../src/lib/ad-links.mjs';

const STORE = 'https://apps.apple.com/app/id6815881853';
const SITE = 'https://waycar.dev/';
const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148';
const IPAD_AS_MAC = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15';
const ANDROID = 'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/130.0 Mobile Safari/537.36';
const WINDOWS = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36';

/**
 * @param {string} slug
 * @param {string | null} userAgent
 * @param {string} [query]
 */
const resolve = (slug, userAgent, query = '') =>
  resolveAdLink({ slug, userAgent, searchParams: new URLSearchParams(query), storeUrl: STORE, siteUrl: SITE });

test('a store link sends iPhone, and an iPad that reports a Mac, to the /go hop page with its campaign', () => {
  for (const userAgent of [IPHONE, IPAD_AS_MAC]) {
    const result = resolve('x-store', userAgent);
    assert.equal(result?.destination, 'store');
    assert.equal(result?.location, 'https://waycar.dev/go?c=x-store');
  }
});

test('X and Reddit click IDs ride on the redirect URL for both link types, and never into the event', () => {
  const store = resolve('x-store', IPHONE, 'twclid=2-abc.D_e&rdt_cid=r-9');
  assert.equal(store?.location, 'https://waycar.dev/go?c=x-store&twclid=2-abc.D_e&rdt_cid=r-9');
  const site = resolve('reddit-site', IPHONE, 'rdt_cid=r-9');
  assert.match(site?.location ?? '', /[?&]rdt_cid=r-9(&|$)/);
  for (const result of [store, site]) {
    assert.doesNotMatch(JSON.stringify(result?.properties), /twclid|rdt_cid|r-9|2-abc/);
  }
});

test('a click ID that is not plain, or too long, is dropped', () => {
  for (const bad of ['a b', 'a%26b%3D1', 'x'.repeat(129), '']) {
    const result = resolve('x-site', IPHONE, `twclid=${bad}`);
    assert.doesNotMatch(result?.location ?? '', /twclid/);
  }
});

test('a store link sends everything else, including a missing user agent, to the site with UTM tags', () => {
  for (const userAgent of [ANDROID, WINDOWS, null]) {
    const result = resolve('reddit-store', userAgent);
    assert.equal(result?.destination, 'site');
    assert.equal(
      result?.location,
      `${SITE}?utm_source=reddit&utm_medium=paid&utm_campaign=reddit-store`,
    );
  }
});

const TWITTERBOT = 'Mozilla/5.0 (compatible; Twitterbot/1.0)';

test('the text-ad link sends Apple devices to the /go hop and everyone else, X\'s link preview included, to the /x landing page', () => {
  assert.equal(resolve('x-text', IPHONE, 'utm_content=xt-01')?.location, 'https://waycar.dev/go?c=x-text');
  for (const userAgent of [TWITTERBOT, ANDROID, WINDOWS, null]) {
    const result = resolve('x-text', userAgent, 'utm_content=xt-01&twclid=2-abc');
    assert.equal(result?.destination, 'site');
    assert.equal(
      result?.location,
      'https://waycar.dev/x?utm_source=x&utm_medium=paid&utm_campaign=x-text&utm_content=xt-01&twclid=2-abc',
    );
  }
});

test('an emptied store URL sends the text-ad link to its landing page, not the home page', () => {
  const result = resolveAdLink({
    slug: 'x-text',
    userAgent: IPHONE,
    searchParams: new URLSearchParams(),
    storeUrl: '',
    siteUrl: SITE,
  });
  assert.match(result?.location ?? '', /^https:\/\/waycar\.dev\/x\?/);
});

test('a site link goes to the site even on an iPhone, and says the store was not the link type', () => {
  const result = resolve('x-site', IPHONE);
  assert.equal(result?.destination, 'site');
  assert.equal(result?.properties.link_destination, 'site');
  assert.equal(result?.properties.utm_campaign, 'x-site');
});

test('the provider token joins the store URL only when there is one', () => {
  assert.equal(appStoreCampaignUrl(STORE, 'x-store', 'abc123'), `${STORE}?pt=abc123&ct=x-store&mt=8`);
  assert.doesNotMatch(appStoreCampaignUrl(STORE, 'x-store', ''), /pt=/);
});

test('only plain utm_content and utm_term pass through, and a click cannot rewrite source, medium or campaign', () => {
  const result = resolve(
    'x-site',
    IPHONE,
    'utm_content=video-a&utm_term=a%20b&utm_source=evil&utm_medium=email&utm_campaign=other&twclid=123',
  );
  assert.equal(
    result?.location,
    `${SITE}?utm_source=x&utm_medium=paid&utm_campaign=x-site&utm_content=video-a&twclid=123`,
  );
  assert.deepEqual(Object.keys(result?.properties ?? {}).sort(), [
    'ct',
    'destination',
    'link_destination',
    'slug',
    'utm_campaign',
    'utm_content',
    'utm_medium',
    'utm_source',
  ]);
});

test('an emptied store URL turns every store link into a site link', () => {
  const result = resolveAdLink({
    slug: 'x-store',
    userAgent: IPHONE,
    searchParams: new URLSearchParams(),
    storeUrl: '',
    siteUrl: SITE,
  });
  assert.equal(result?.destination, 'site');
});

test('unknown slugs resolve to nothing, including object prototype names', () => {
  assert.equal(resolve('nope', IPHONE), null);
  assert.equal(resolve('constructor', IPHONE), null);
  assert.equal(adLinkSlug('/go/constructor'), null);
  assert.equal(adLinkSlug('/go/site-hero'), null);
  assert.equal(adLinkSlug('/go/x-store'), 'x-store');
  assert.equal(adLinkSlug('/go/x-store/'), 'x-store');
  assert.equal(adLinkSlug('/go/x-store/extra'), null);
  assert.equal(adLinkSlug('/gone/x-store'), null);
});

test('Apple devices are iPhone, iPad, iPod and Mac user agents', () => {
  assert.equal(isAppleDevice(IPHONE), true);
  assert.equal(isAppleDevice(IPAD_AS_MAC), true);
  assert.equal(isAppleDevice(ANDROID), false);
  assert.equal(isAppleDevice(undefined), false);
});

test('Apple handhelds include iPadOS desktop mode but not real Macs or other platforms', () => {
  const ipad = 'Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148';
  const ipod = 'Mozilla/5.0 (iPod touch; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148';
  for (const userAgent of [IPHONE, ipad, ipod]) assert.equal(isAppleHandheld({ userAgent }), true, userAgent);
  assert.equal(isAppleHandheld({ userAgent: IPAD_AS_MAC, platform: 'MacIntel', maxTouchPoints: 5 }), true);
  assert.equal(isAppleHandheld({ userAgent: IPAD_AS_MAC, platform: 'MacIntel', maxTouchPoints: 0 }), false);
  for (const userAgent of [ANDROID, WINDOWS, 'Mozilla/5.0 (X11; Linux x86_64)']) {
    assert.equal(isAppleHandheld({ userAgent }), false, userAgent);
  }
  assert.equal(isAppleHandheld({}), false);
  assert.equal(isAppleHandheld(), false);
});

test('a page campaign is read from utm_campaign only when it is a paid token', () => {
  assert.equal(campaignFromSearch('?utm_campaign=x-site&utm_content=a'), 'x-site');
  assert.equal(campaignFromSearch('?utm_campaign=reddit-core-cli-agents'), 'reddit-core-cli-agents');
  assert.equal(campaignFromSearch(''), null);
  assert.equal(campaignFromSearch('?utm_campaign=newsletter'), null);
  assert.equal(campaignFromSearch('?utm_campaign=constructor'), null);
  assert.equal(campaignFromSearch('?utm_campaign=site-hero'), null);
});

const VALID_PAID = [
  'reddit-core-cli-agents',
  'x-article-advisors',
  'x-article-reach-agents',
  'reddit-store',
  'reddit-site',
  'x-store',
  'x-site',
  'x-a',
  'reddit-adjacent-devtools',
  'x-' + 'a'.repeat(28),
];
const INVALID_PAID = [
  'x',
  'x-',
  'x--a',
  'X-foo',
  'reddit-core_cli',
  'x-' + 'a'.repeat(29),
  'x-' + 'a'.repeat(33),
  'apple-brand',
  'xx-foo',
  'x-foo-',
  '-x-foo',
  'site-hero',
  'x-a b',
  'reddit-core-cli-agents\n',
  '',
];

test('PAID_CT accepts the convention\'s paid tokens and rejects everything else', () => {
  for (const token of VALID_PAID) assert.ok(PAID_CT.test(token), token);
  for (const token of INVALID_PAID) assert.ok(!PAID_CT.test(token), JSON.stringify(token));
  assert.equal(VALID_PAID.at(-1)?.length, 30);
});

test('a new valid token is a store link with its platform as source, and logs its token as slug and ct', () => {
  const result = resolve('reddit-core-cli-agents', IPHONE, 'utm_content=cr-01&utm_term=senior-devs');
  assert.equal(result?.destination, 'store');
  assert.equal(result?.location, 'https://waycar.dev/go?c=reddit-core-cli-agents');
  assert.deepEqual(result?.properties, {
    slug: 'reddit-core-cli-agents',
    ct: 'reddit-core-cli-agents',
    link_destination: 'store',
    destination: 'store',
    utm_source: 'reddit',
    utm_medium: 'paid',
    utm_campaign: 'reddit-core-cli-agents',
    utm_content: 'cr-01',
    utm_term: 'senior-devs',
  });
  assert.equal(resolve('x-launch-week', WINDOWS)?.location, `${SITE}?utm_source=x&utm_medium=paid&utm_campaign=x-launch-week`);
  assert.equal(adLinkSlug('/go/reddit-core-cli-agents'), 'reddit-core-cli-agents');
});

test('?d=site makes a new token a site link, and cannot redirect a fixed legacy link', () => {
  const site = resolve('reddit-core-cli-agents', IPHONE, 'd=site');
  assert.equal(site?.destination, 'site');
  assert.equal(site?.properties.link_destination, 'site');
  assert.match(site?.location ?? '', /^https:\/\/waycar\.dev\/\?utm_source=reddit&utm_medium=paid&utm_campaign=reddit-core-cli-agents/);
  assert.equal(resolve('x-article-advisors', IPHONE, 'd=site')?.destination, 'article');
  assert.equal(resolve('x-store', IPHONE, 'd=other')?.destination, 'store');
});

test('a token that is not a paid token resolves to nothing, so the Worker answers as it did before', () => {
  for (const token of INVALID_PAID.filter((t) => t !== '')) {
    assert.equal(resolve(token, IPHONE), null, token);
  }
  for (const path of ['/go/X-foo', '/go/x', '/go/reddit_core', `/go/x-${'a'.repeat(29)}`, '/go/apple-brand']) {
    assert.equal(adLinkSlug(path), null, path);
  }
});

test('an organic CTA takes the page type\'s token, then its section\'s, then site', () => {
  for (const path of ['/pricing', '/pricing/', '/pricing.html']) {
    assert.equal(organicCampaign(path), 'site');
    assert.equal(organicCampaign(path, 'site-nav'), 'site-nav');
  }
  assert.equal(organicCampaign('/', 'pricing'), 'pricing', 'legacy campaign tokens still validate');
  assert.equal(organicCampaign('/help.html', 'site-nav'), 'help');
  assert.equal(organicCampaign('/help/accessibility.html', 'site-nav'), 'help');
  assert.equal(organicCampaign('/articles/a.html', 'site-nav'), 'article');
  assert.equal(organicCampaign('/help/', 'site-nav'), 'help');
  assert.equal(organicCampaign('/help/setup/', 'site-nav'), 'help');
  assert.equal(organicCampaign('/articles/how-we-set-up-advisors-for-omp/', 'site-nav'), 'article');
  assert.equal(organicCampaign('/', 'site-hero'), 'site-hero');
  assert.equal(organicCampaign('/b/', 'site-hero-b'), 'site-hero-b');
  assert.equal(organicCampaign('/', 'site-closing'), 'site-closing');
  assert.equal(organicCampaign('/ipad/', 'site-nav'), 'site-nav');
  assert.equal(organicCampaign('/support/'), 'site');
  assert.equal(organicCampaign('/helpdesk/'), 'site');
});

test('a section outside the organic list, or a paid token, is refused at build time', () => {
  for (const section of ['reddit-core-cli-agents', 'x-store', 'Site', 'article-foo', '']) {
    assert.throws(() => organicCampaign('/', section), /Not an organic campaign token/);
  }
  assert.ok(ORGANIC_CT.test('setup-prompt'));
  assert.ok(!ORGANIC_CT.test('site-hero '));
});

test('campaign parameters replace any the URL already carries', () => {
  assert.equal(appStoreCampaignUrl(`${STORE}?ct=site&mt=8`, 'x-site', ''), `${STORE}?ct=x-site&mt=8`);
});

test('a test click marked internal carries the flag to the site, and a normal click does not', () => {
  assert.match(resolve('x-site', IPHONE, 'internal=1')?.location ?? '', /[?&]internal=1(&|$)/);
  assert.doesNotMatch(resolve('x-site', IPHONE)?.location ?? '', /internal/);
  assert.doesNotMatch(resolve('x-store', IPHONE, 'internal=1')?.location ?? '', /internal/);
});

test('the advisors article link always goes to its fixed article URL with UTM tags, on any device', () => {
  const ARTICLE = 'https://waycar.dev/articles/how-we-set-up-advisors-for-omp';
  for (const userAgent of [IPHONE, ANDROID, WINDOWS, null]) {
    const result = resolve('x-article-advisors', userAgent);
    assert.equal(result?.destination, 'article');
    assert.equal(
      result?.location,
      `${ARTICLE}?utm_source=x&utm_medium=paid&utm_campaign=x-article-advisors`,
    );
    assert.equal(result?.properties.link_destination, 'article');
    assert.equal(result?.properties.slug, 'x-article-advisors');
  }
  assert.equal(adLinkSlug('/go/x-article-advisors'), 'x-article-advisors');
});

test('the reach-agents article link always goes to its fixed article URL with UTM tags, on any device', () => {
  const ARTICLE = 'https://waycar.dev/articles/reach-your-ai-harness-while-you-are-away';
  for (const userAgent of [IPHONE, ANDROID, WINDOWS, null]) {
    const result = resolve('x-article-reach-agents', userAgent);
    assert.equal(result?.destination, 'article');
    assert.equal(
      result?.location,
      `${ARTICLE}?utm_source=x&utm_medium=paid&utm_campaign=x-article-reach-agents`,
    );
    assert.equal(result?.properties.link_destination, 'article');
    assert.equal(result?.properties.slug, 'x-article-reach-agents');
  }
  assert.equal(adLinkSlug('/go/x-article-reach-agents'), 'x-article-reach-agents');
});

test('the advisors article link takes click IDs, utm_content and internal, but never a destination from the query', () => {
  const result = resolve(
    'x-article-advisors',
    IPHONE,
    'twclid=9&utm_content=a&internal=1&url=https://evil.example/&to=https://evil.example/&utm_source=evil',
  );
  const location = new URL(result?.location ?? '');
  assert.equal(location.origin + location.pathname, 'https://waycar.dev/articles/how-we-set-up-advisors-for-omp');
  assert.equal(location.searchParams.get('utm_source'), 'x');
  assert.equal(location.searchParams.get('twclid'), '9');
  assert.equal(location.searchParams.get('utm_content'), 'a');
  assert.equal(location.searchParams.get('internal'), '1');
  assert.doesNotMatch(result?.location ?? '', /evil/);
});

/** @param {string} dir @returns {string[]} */
const sourceFiles = (dir) =>
  readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory()
      ? sourceFiles(join(dir, entry.name))
      : /\.(astro|ts|mjs)$/.test(entry.name)
        ? [join(dir, entry.name)]
        : [],
  );

test('every App Store link in the site source names a token from the organic list', () => {
  const found = [];
  for (const file of sourceFiles(new URL('../src', import.meta.url).pathname)) {
    if (file.endsWith('lib/ad-links.mjs')) continue;
    const source = readFileSync(file, 'utf8');
    for (const [, token] of source.matchAll(/<AppStoreCta\b[^>]*?\bct="([^"]*)"/gs)) found.push([file, token]);
    for (const [, token] of source.matchAll(/\bappStoreUrl\([^,)]+,\s*'([^']*)'\)/g)) found.push([file, token]);
    for (const [, token] of source.matchAll(/\bappStoreCampaignUrl\([^,)]+,\s*'([^']*)'/g)) found.push([file, token]);
  }
  assert.ok(found.length >= 8, `found only ${found.length} literal tokens`);
  for (const [file, token] of found) {
    assert.ok(ORGANIC_CT.test(token ?? '') || PAID_CT.test(token ?? ''), `${file}: ${token}`);
  }
});
