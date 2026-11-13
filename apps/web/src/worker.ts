// Cloudflare Worker in front of the static build (wrangler.toml sets
// `run_worker_first = true`). Astro never imports this file, so it is not part
// of the site build; wrangler bundles it on deploy.
//
// waycar.dev is canonical. Every other hostname routed here (www.waycar.dev,
// waycar.app, www.waycar.app) gets a permanent redirect to the same path and
// query on https://waycar.dev. Every response carries the security headers
// below.
//
// Registered short links redirect to a fixed target
// (src/lib/short-links.mjs).

import { APP_STORE_LISTING_URL } from './data/links';
import { adLinkSlug, resolveAdLink } from './lib/ad-links.mjs';
import { shortLinkTarget } from './lib/short-links.mjs';
import { pluginEvent } from './lib/plugin-events.mjs';

const CANONICAL_HOST = 'waycar.dev';

// The site has no forms and loads nothing third-party except anonymous usage
// analytics and, for visitors who have not opted out (see the Layout script),
// the Reddit and X ad-conversion pixels, so the policy is strict. Its scripts (CodeBlock's copy button, the
// help search palette and sidebar, and the PostHog `no-external` build, which
// never loads scripts from PostHog's asset hosts) are Astro's same-origin
// bundles under /_astro, hence `script-src 'self'` with no inline scripts and
// no workers; the pixel loaders are bundled too (src/lib/ad-pixels.ts) and
// fetch only the two vendors' scripts, redditstatic.com and ads-twitter.com.
// Their network destinations are this origin, for the help search
// index the palette fetches (/help/search.json) and the older changelog pages
// the changelog's infinite scroll fetches (/changelog/<n>), event capture at
// us.i.posthog.com (remote config and feature flags are disabled), and the
// pixels' own endpoints, hence `connect-src 'self'` plus those hosts, and
// `img-src` for the pixels' tracking-image fallbacks. `'unsafe-inline'` styles cover
// Astro's inlined <style> blocks, the theme swatches' style attributes, and
// the color variables on help pages' highlighted code.
const SECURITY_HEADERS: Record<string, string> = {
  'Content-Security-Policy':
    "default-src 'none'; script-src 'self' https://www.redditstatic.com https://static.ads-twitter.com; worker-src 'none'; connect-src 'self' https://us.i.posthog.com https://pixel-config.reddit.com https://alb.reddit.com https://analytics.twitter.com https://t.co; img-src 'self' https://alb.reddit.com https://analytics.twitter.com https://t.co; font-src 'self'; manifest-src 'self'; style-src 'self' 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
};

interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> };
  // Set to `release` only by `wrangler deploy --var POSTHOG_ENV:release`;
  // absent under `wrangler dev`, so local fetches report `debug`.
  POSTHOG_ENV?: string;
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
}

// Public, write-only project key; the same one the page script uses.
const POSTHOG_KEY = 'phc_DmYrhynP2Ly3k9pdY8bkbQH3isw4PzLovDsDXRbbQsQV';

// One anonymous PostHog event, sent from the Worker for traffic that never
// passes through a page. Anonymous by construction: a fresh random id per
// request, no person profile, and no request headers or client IP forwarded by
// this code. PostHog receives the request from Cloudflare's network, and
// Cloudflare may add headers (such as CF-Connecting-IP) that this code cannot
// control; the PostHog project discards IP addresses, and the event also
// disables GeoIP. Our own automation adds `internal=1` to the URL it fetches,
// which adds `internal: true` to the event and leaves the response unchanged.
function capturePostHogEvent(
  env: Env,
  event: string,
  internal: boolean,
  properties: Record<string, string> = {},
): Promise<unknown> {
  return fetch('https://us.i.posthog.com/i/v0/e/', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      api_key: POSTHOG_KEY,
      event,
      distinct_id: crypto.randomUUID(),
      properties: {
        ...properties,
        env: env.POSTHOG_ENV ?? 'debug',
        ...(internal ? { internal: true } : {}),
        $process_person_profile: false,
        $geoip_disable: true,
      },
    }),
  }).catch(() => undefined);
}

// The plugin install signals, `curl https://waycar.dev/install.sh` and the
// package it downloads, are counted with `capturePostHogEvent` where the fetch
// is served: neither passes through a page. `src/lib/plugin-events.mjs` says
// which requests count and which properties they carry.

// Paid ads point at `/go/<slug>` (src/lib/ad-links.mjs). The click is logged as
// `ad_link_clicked` with the slug, where it went, and the UTM tags (no country,
// no ad-platform click IDs, no IP). Browsers only:
// link previews, ad-review crawlers, and scripted clients get the redirect and
// no event. Apple devices on a `store` link go to the `/go` hop page, which
// fires the ad pixels and then forwards to the App Store with `ct`; everything
// else goes to the site with UTM tags.
function adLinkResponse(request: Request, env: Env, ctx: ExecutionContext, url: URL, slug: string): Response | null {
  const resolved = resolveAdLink({
    slug,
    userAgent: request.headers.get('User-Agent'),
    searchParams: url.searchParams,
    storeUrl: APP_STORE_LISTING_URL,
    siteUrl: `https://${CANONICAL_HOST}/`,
  });
  if (!resolved) return null;
  const userAgent = request.headers.get('User-Agent') ?? '';
  if (request.method === 'GET' && userAgent !== '' && !NON_BROWSER_AGENT.test(userAgent)) {
    ctx.waitUntil(
      capturePostHogEvent(env, 'ad_link_clicked', url.searchParams.get('internal') === '1', resolved.properties),
    );
  }
  const response = new Response(null, {
    status: 302,
    headers: { Location: resolved.location, 'Cache-Control': 'no-store', 'X-Robots-Tag': 'noindex' },
  });
  return withSecurityHeaders(response);
}


// Where analytics cookies need opt-in first (GDPR / ePrivacy): the EU, the
// rest of the EEA, the UK, and Switzerland. Visitors there get
// `<html data-consent="required">`, which makes the page script start
// cookieless and show the consent banner; everyone else gets a first-party
// analytics cookie without a banner. An unknown country counts as required,
// as do Cloudflare's `XX` (unknown) and `T1` (Tor) codes. EU outermost
// regions and Åland have their own ISO codes but are part of the EU: French
// Guiana, Guadeloupe, Martinique, Réunion, Mayotte, Saint Martin, and Åland.
const CONSENT_REQUIRED_COUNTRIES: Record<string, true> = {
  AT: true, BE: true, BG: true, HR: true, CY: true, CZ: true, DK: true, EE: true, FI: true, FR: true,
  DE: true, GR: true, HU: true, IE: true, IT: true, LV: true, LT: true, LU: true, MT: true, NL: true,
  PL: true, PT: true, RO: true, SK: true, SI: true, ES: true, SE: true, IS: true, LI: true, NO: true,
  GB: true, CH: true,
  GF: true, GP: true, MQ: true, RE: true, YT: true, MF: true, AX: true,
  XX: true, T1: true,
};

interface ElementHandler {
  element(element: { setAttribute(name: string, value: string): void }): void;
}
declare const HTMLRewriter: {
  new (): { on(selector: string, handler: ElementHandler): { transform(response: Response): Response } };
};

function consentRequired(request: Request): boolean {
  const country = (request as Request & { cf?: { country?: string } }).cf?.country;
  return !country || CONSENT_REQUIRED_COUNTRIES[country] === true;
}

// Cookies left behind by the retired home page A/B tests (the hero test ended
// 2026-10 by shipping B). Nothing reads them any more, so they are deleted
// wherever they turn up.
const AB_COOKIE = 'waycar_ab';
const AB_COOKIE_PATTERN = new RegExp(`(?:^|;\\s*)${AB_COOKIE}=`);
const LEGACY_COOKIE = 'waycar_variant';
const LEGACY_COOKIE_PATTERN = new RegExp(`(?:^|;\\s*)${LEGACY_COOKIE}=`);
// Same name, path, and flags as the stored cookies, so the browser replaces
// them and drops them at once.
const EXPIRED_AB_COOKIE = `${AB_COOKIE}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax`;
const EXPIRED_LEGACY_COOKIE = `${LEGACY_COOKIE}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax`;

// `/b` was variant B's asset path while the test ran; keep old links working.
const VARIANT_B_PATHS: Record<string, true> = { '/b': true, '/b/': true, '/b.html': true };

// The pricing page is retired; keep old bookmarks and shared links working.
const PRICING_PATHS: Record<string, true> = { '/pricing': true, '/pricing/': true, '/pricing.html': true };

// Set-Cookie values that delete the retired test cookies. Only cookies the
// request carries are deleted, so a visitor without one gets no Set-Cookie at
// all.
function cookieDeletions(cookies: string): string[] {
  const deletions: string[] = [];
  if (LEGACY_COOKIE_PATTERN.test(cookies)) deletions.push(EXPIRED_LEGACY_COOKIE);
  if (AB_COOKIE_PATTERN.test(cookies)) deletions.push(EXPIRED_AB_COOKIE);
  return deletions;
}

// User agents of bots, crawlers, link unfurlers, uptime monitors, headless
// browsers, and scripted HTTP clients, matched case-insensitively against
// `User-Agent`.
const NON_BROWSER_AGENT = /bot|crawl|spider|slurp|preview|monitor|uptime|headless|curl|wget|python|httpclient|go-http|okhttp|java\//i;

// The HTML body varies by country, so a rewritten page must never be
// revalidated into a cached copy built for another visitor: drop the
// validators and make the browser refetch every time. The cookie deletions
// ride only on pages, never on assets, each as its own Set-Cookie header.
function withPageAttributes(request: Request, response: Response, setCookies: string[]): Response {
  if (!response.headers.get('Content-Type')?.includes('text/html')) return response;
  const consent = consentRequired(request) ? 'required' : 'not-required';
  // The page script also reads `navigator.globalPrivacyControl`, but some
  // browsers send `Sec-GPC: 1` without exposing it to scripts, so the header
  // is passed on as `data-gpc` and the script treats either as GPC.
  const gpc = request.headers.get('Sec-GPC') === '1';
  const rewritten = new HTMLRewriter()
    .on('html', {
      element: (html) => {
        html.setAttribute('data-consent', consent);
        if (gpc) html.setAttribute('data-gpc', '1');
      },
    })
    .transform(response);
  const headers = new Headers(rewritten.headers);
  headers.delete('ETag');
  headers.delete('Last-Modified');
  headers.set('Cache-Control', 'private, no-cache');
  for (const cookie of setCookies) headers.append('Set-Cookie', cookie);
  return new Response(rewritten.body, { status: rewritten.status, statusText: rewritten.statusText, headers });
}

// Conditional requests would let the asset server answer 304 for HTML, and the
// browser would then reuse a page it cached with another region's consent
// mode.
function withoutValidatorsForHtml(request: Request): Request {
  if (!request.headers.get('Accept')?.includes('text/html')) return request;
  if (!request.headers.has('If-None-Match') && !request.headers.has('If-Modified-Since')) return request;
  const headers = new Headers(request.headers);
  headers.delete('If-None-Match');
  headers.delete('If-Modified-Since');
  return new Request(request, { headers });
}

// The asset server may send llms.txt and the Markdown files (index.md, help.md,
// help/<slug>.md) without a charset (they have non-ASCII text; RFC 7763
// requires one for text/markdown) and install.sh as a shell type. Serve them
// all as UTF-8 text.
const TEXT_CONTENT_TYPES: Record<string, string> = {
  '/install.sh': 'text/plain; charset=utf-8',
  '/llms.txt': 'text/plain; charset=utf-8',
};
const MARKDOWN_CONTENT_TYPE = 'text/markdown; charset=utf-8';

function withSecurityHeaders(response: Response, pathname = ''): Response {
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) headers.set(name, value);
  const contentType = TEXT_CONTENT_TYPES[pathname] ?? (pathname.endsWith('.md') ? MARKDOWN_CONTENT_TYPE : undefined);
  if (contentType && response.ok) headers.set('Content-Type', contentType);
  // install.sh names the current plugin tarball, so it must never be served
  // stale after a deploy; the versioned tarball itself may cache normally.
  if (pathname === '/install.sh' && response.ok) headers.set('Cache-Control', 'no-cache');
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.hostname !== CANONICAL_HOST) {
      return withSecurityHeaders(Response.redirect(`https://${CANONICAL_HOST}${url.pathname}${url.search}`, 301));
    }
    const adSlug = request.method === 'GET' || request.method === 'HEAD' ? adLinkSlug(url.pathname) : null;
    if (adSlug !== null) {
      const adResponse = adLinkResponse(request, env, ctx, url, adSlug);
      if (adResponse) return adResponse;
    }
    const shortTarget = request.method === 'GET' || request.method === 'HEAD' ? shortLinkTarget(url.pathname) : null;
    if (shortTarget !== null) {
      // `no-store`: the entry is removed when its campaign ends, and a cached
      // redirect would keep sending people to the stale target.
      return withSecurityHeaders(
        new Response(null, {
          status: 302,
          headers: { Location: shortTarget, 'Cache-Control': 'no-store', 'X-Robots-Tag': 'noindex' },
        }),
      );
    }
    if (PRICING_PATHS[url.pathname] === true) {
      const target = new URL(url);
      target.pathname = '/';
      return withSecurityHeaders(Response.redirect(target.href, 301));
    }
    if (VARIANT_B_PATHS[url.pathname] === true) {
      const target = new URL(url);
      target.pathname = '/';
      target.searchParams.delete('variant');
      return withSecurityHeaders(Response.redirect(target.href, 301));
    }
    const setCookies = cookieDeletions(request.headers.get('Cookie') ?? '');
    const response = await env.ASSETS.fetch(withoutValidatorsForHtml(request));
    if (response.ok) {
      const logged = pluginEvent(request.method, url.pathname, url.searchParams);
      if (logged) {
        ctx.waitUntil(capturePostHogEvent(env, logged.event, logged.internal, logged.properties));
      }
    }
    return withSecurityHeaders(withPageAttributes(request, response, setCookies), url.pathname);
  },
};
