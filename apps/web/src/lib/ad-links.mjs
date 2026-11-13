// @ts-check
// Paid-ad links: `https://waycar.dev/go/<token>` is the URL an X or Reddit ad
// points at. The Worker (src/worker.ts) logs the click and redirects to the App
// Store listing via the `/go` hop page that fires the ad pixels (a `store`
// link) or to the site with UTM tags (a `site` link). Any token that matches
// `PAID_CT` is accepted, so a new campaign needs no code change; the token is
// the Apple campaign (`ct`), `utm_campaign` and the campaign's name in the ad
// platform. Marketing's convention: the `ct-convention` document on WAY-101.
// Pure functions, so scripts/ad-links.test.mjs can exercise them without a Worker.

/**
 * Apple's provider token (`pt`), the same for every campaign, from App Store
 * Connect › App Analytics › Campaigns › Generate Link. With it, App Analytics
 * attributes page views and downloads to each `ct`; empty, the links carry only
 * `ct` and `mt`, which App Analytics cannot report on.
 */
export const APPLE_PROVIDER_TOKEN = '102524811';

/**
 * A paid token, `/go/<token>`: `reddit` or `x`, then one or more hyphen-joined
 * lowercase alphanumeric words, 3 to 30 characters in total. It is the Apple
 * campaign (`ct`), `utm_campaign` and the campaign name in the ad platform, so
 * the platform's spend joins to App Store downloads. No `m` flag: `$` must not
 * match before a trailing newline.
 */
export const PAID_CT = /^(?=.{3,30}$)(?:reddit|x)(?:-[a-z0-9]+)+$/;

/**
 * The organic tokens, a closed list that is never read from a URL. Each is the
 * page type or section a store click happened on, or an off-site surface
 * (`hn`, `readme`, ...) whose link is written by hand. A paid token is never in
 * this list, so an organic link cannot be sent through `/go` as paid. The
 * retired `pricing` token remains valid for links already shared.
 */
export const ORGANIC_CT = /^(?:site|site-hero|site-hero-b|site-closing|site-nav|site-qr|pricing|help|article|setup-prompt|readme|hn|producthunt|ref|social-x|social-reddit|press)$/;

/** The organic token of a site CTA that no section names. */
export const DEFAULT_ORGANIC_CT = 'site';

/**
 * The organic token for an App Store CTA on `pathname`. A page type outranks the
 * CTA's own section, so every CTA on `/help/*` and `/articles/*`
 * (header and footer too) carries that page's token; elsewhere the CTA's
 * `section` token applies, then `site`. Throws on a `section` outside
 * `ORGANIC_CT`, so a typo fails the build instead of shipping a stray `ct`.
 * @param {string} pathname
 * @param {string} [section]
 */
export function organicCampaign(pathname, section = DEFAULT_ORGANIC_CT) {
  if (!ORGANIC_CT.test(section)) throw new Error(`Not an organic campaign token: ${section}`);
  // The static build writes `help.html`, so a path may end in `.html`.
  const page = /^\/(help|articles)(?:[/.]|$)/.exec(pathname)?.[1];
  if (page === 'help') return page;
  return page === 'articles' ? 'article' : section;
}

/**
 * Where a paid token's click goes when no table entry says: `store` sends Apple
 * devices to the App Store (anything else goes to the site, since Waycar is iOS
 * only), `site` always sends the visitor to the site, `article` always sends the
 * visitor to the fixed `url` (an article page; never taken from the request).
 * `source` becomes `utm_source`. `landing`, a path on the site, replaces the home
 * page as the page a non-Apple visitor lands on: link-preview crawlers, which
 * are never Apple devices, read that page for the post's card.
 * @typedef {{ source: string, destination: 'store' | 'site' | 'article', url?: string, landing?: string }} AdLink
 */

/**
 * The tokens whose click goes somewhere fixed or lands somewhere other than the
 * home page: a site-only link (a legacy `-site` token), an article, or a token
 * with its own `landing`. Every other `PAID_CT` token is a `store` link, or a
 * `site` link with `?d=site` (`paidLink`). The destination is never encoded in
 * the token.
 * @type {Record<string, AdLink>}
 */
export const AD_LINKS = {
  // Text-only X ads: `/x` carries no social metadata, so X has nothing to unfurl.
  'x-text': { source: 'x', destination: 'store', landing: '/x' },
  'x-site': { source: 'x', destination: 'site' },
  'reddit-site': { source: 'reddit', destination: 'site' },
  'x-article-advisors': {
    source: 'x',
    destination: 'article',
    url: 'https://waycar.dev/articles/how-we-set-up-advisors-for-omp',
  },
  'x-article-reach-agents': {
    source: 'x',
    destination: 'article',
    url: 'https://waycar.dev/articles/reach-your-ai-harness-while-you-are-away',
  },
};

/** Free-form UTM values an ad may add (`utm_content`, `utm_term`). */
const UTM_VALUE_PATTERN = /^[A-Za-z0-9._-]{1,64}$/;
const PASS_THROUGH_UTM = ['utm_content', 'utm_term'];

/**
 * Ad-platform click IDs (X `twclid`, Reddit `rdt_cid`). They ride on the
 * redirect URL only, so the pixels on the landing page can attribute the click.
 * They are never logged: not in `properties`, not in the event.
 */
const CLICK_ID_PARAMS = ['twclid', 'rdt_cid'];
const CLICK_ID_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;

/**
 * iPadOS Safari and the in-app browsers built on it send a Mac user agent, so a
 * Mac counts as an Apple device: its click goes to the App Store as well.
 * @param {string | null | undefined} userAgent
 */
export function isAppleDevice(userAgent) {
  return /iPhone|iPad|iPod|Macintosh|Mac OS X/.test(userAgent ?? '');
}

/**
 * The token of a `/go/<token>` path, or null when the path is not an ad link
 * (the request then gets the site's own answer, a 404 for an unknown path).
 * @param {string} pathname
 */
export function adLinkSlug(pathname) {
  const match = /^\/go\/([a-z0-9-]+)\/?$/.exec(pathname);
  const slug = match?.[1];
  return slug !== undefined && PAID_CT.test(slug) ? slug : null;
}

/**
 * A campaign name taken from a page URL (`utm_campaign`), or null when it is
 * absent or not a paid token: another campaign's tags (a newsletter, a shared
 * link) must not create `ct` values in App Analytics.
 * @param {string} search
 */
export function campaignFromSearch(search) {
  const value = new URLSearchParams(search).get('utm_campaign');
  return value !== null && PAID_CT.test(value) ? value : null;
}

/**
 * The link for a paid token: its table entry, or a `store` link for the token's
 * platform prefix (`?d=site` makes it a `site` link). Null for a non-token.
 * @param {string} slug
 * @param {URLSearchParams} searchParams
 * @returns {AdLink | null}
 */
function paidLink(slug, searchParams) {
  if (!PAID_CT.test(slug)) return null;
  if (Object.hasOwn(AD_LINKS, slug)) return AD_LINKS[slug] ?? null;
  const source = slug.slice(0, slug.indexOf('-'));
  return { source, destination: searchParams.get('d') === 'site' ? 'site' : 'store' };
}

/**
 * `storeUrl` with Apple's campaign parameters.
 * @param {string} storeUrl
 * @param {string} campaign
 * @param {string} [providerToken]
 */
export function appStoreCampaignUrl(storeUrl, campaign, providerToken = APPLE_PROVIDER_TOKEN) {
  const url = new URL(storeUrl);
  if (providerToken) url.searchParams.set('pt', providerToken);
  url.searchParams.set('ct', campaign);
  url.searchParams.set('mt', '8');
  return url.toString();
}

/**
 * Where a click on `/go/<slug>` goes, and what to log about it.
 * @param {{
 *   slug: string,
 *   userAgent: string | null | undefined,
 *   searchParams: URLSearchParams,
 *   storeUrl: string,
 *   siteUrl: string,
 * }} input
 * @returns {{ location: string, destination: 'store' | 'site' | 'article', properties: Record<string, string> } | null}
 */
export function resolveAdLink({ slug, userAgent, searchParams, storeUrl, siteUrl }) {
  const link = paidLink(slug, searchParams);
  if (link === null) return null;
  const destination =
    link.destination === 'article'
      ? 'article'
      : link.destination === 'store' && storeUrl !== '' && isAppleDevice(userAgent)
        ? 'store'
        : 'site';

  /** @type {Record<string, string>} */
  const utm = { utm_source: link.source, utm_medium: 'paid', utm_campaign: slug };
  for (const name of PASS_THROUGH_UTM) {
    const value = searchParams.get(name);
    if (value !== null && UTM_VALUE_PATTERN.test(value)) utm[name] = value;
  }

  /** @type {Record<string, string>} */
  const clickIds = {};
  for (const name of CLICK_ID_PARAMS) {
    const value = searchParams.get(name);
    if (value !== null && CLICK_ID_PATTERN.test(value)) clickIds[name] = value;
  }

  let location;
  if (destination === 'store') {
    // Not straight to the App Store: `/go` (src/pages/go.astro) loads the ad
    // pixels, where the visitor allows them, then forwards to the listing with
    // `appStoreCampaignUrl`.
    const hop = new URL('/go', siteUrl);
    hop.searchParams.set('c', slug);
    for (const [name, value] of Object.entries(clickIds)) hop.searchParams.set(name, value);
    location = hop.toString();
  } else {
    const base = destination === 'article' && link.url ? link.url : new URL(link.landing ?? '/', siteUrl).toString();
    const site = new URL(base);
    for (const [name, value] of Object.entries(utm)) site.searchParams.set(name, value);
    for (const [name, value] of Object.entries(clickIds)) site.searchParams.set(name, value);
    // Our own test clicks mark the browser they land in as internal, so the
    // landing pageview and App Store button clicks stay out of the campaign numbers.
    if (searchParams.get('internal') === '1') site.searchParams.set('internal', '1');
    location = site.toString();
  }
  return {
    location,
    destination,
    properties: { slug, ct: slug, link_destination: link.destination, destination, ...utm },
  };
}
