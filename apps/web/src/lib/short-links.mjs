// @ts-check
// Short links: `https://waycar.dev/<name>` is a hand-written, human-readable
// URL for a post or a card, redirected by the Worker (src/worker.ts) to a fixed
// target. Unlike `/go/<token>` ad links (src/lib/ad-links.mjs) they log no
// event and carry no campaign. A target never comes from the request.
// Pure functions, so scripts/short-links.test.mjs can exercise them without a
// Worker.

/**
 * Path (no trailing slash, lowercase) to target. Remove an entry when its
 * campaign ends: the path then falls through to the site's 404.
 * @type {Record<string, string>}
 */
export const SHORT_LINKS = {};

/**
 * The redirect target for `pathname`, or null when it is not a short link.
 * A trailing slash and letter case are ignored.
 * @param {string} pathname
 */
export function shortLinkTarget(pathname) {
  const key = pathname.toLowerCase().replace(/\/$/, '');
  return Object.hasOwn(SHORT_LINKS, key) ? SHORT_LINKS[key] : null;
}
