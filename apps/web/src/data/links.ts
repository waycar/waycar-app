import { appStoreCampaignUrl, organicCampaign } from '../lib/ad-links.mjs';

// The one App Store switch. Waycar is live (2026-10-14), so this is the listing
// URL and every store button (`AppStoreCta`) opens the Get Waycar picker, whose
// App Store link carries `app_store_clicked`, and availability statements (FAQ,
// footer, /llms.txt, /index.md) say it is available now. Emptying it reverts
// them all to a plain "Coming soon to the App Store" label with no picker, no
// link and no event.
export const APP_STORE_LISTING_URL = 'https://apps.apple.com/app/id6815881853';
export const ON_APP_STORE = APP_STORE_LISTING_URL.startsWith('https://');

// The Google Play switch, empty until an Android app is listed. While empty the
// picker's Android tile is plain "Coming soon" text and the App Store badge is
// Apple's white one. Set, the tile links here and the App Store badge turns
// black (Apple's rule once another platform's badge appears). Never set it
// before a Play listing exists: the site says nothing about Play until then.
export const PLAY_STORE_LISTING_URL = '';
export const ON_PLAY_STORE = PLAY_STORE_LISTING_URL.startsWith('https://');

// What the site links to: the listing tagged with Apple's campaign (`ct`), so
// App Analytics counts installs that started on the site, per surface. `section`
// is the CTA's organic token (`site-hero`, `site-closing`, `site-nav`, ...; default
// `site`); `pathname` is the page's, because a page type (`/help/*`, `/articles/*`)
// outranks the section (`organicCampaign`). A visitor who arrived
// from a paid ad (`utm_campaign` in the URL) gets that campaign's `ct` instead
// (Layout.astro), and `/go/<token>` ad links carry their own (src/lib/ad-links.mjs).
// Empty when the listing is not live.
export function appStoreUrl(pathname: string, section?: string): string {
  return ON_APP_STORE ? appStoreCampaignUrl(APP_STORE_LISTING_URL, organicCampaign(pathname, section)) : '';
}

// schema.org `@id` (resolved against the site) of the SoftwareApplication
// JSON-LD every indexable page carries (Layout.astro), so a page's own JSON-LD
// can point at the app.
export const APP_SCHEMA_ID = '/#app';
