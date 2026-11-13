// /qr/site-qr.svg: the QR code in the Get Waycar picker's iPhone and iPad tile,
// for a visitor on a wide screen with a mouse who scans it with the phone.
// It encodes the App Store listing with Apple's campaign token `site-qr`
// (`ORGANIC_CT` in src/lib/ad-links.mjs), so App Analytics counts installs that
// started at a desktop picker apart from the buttons'. The token is fixed at
// build time: unlike the picker's link, the image cannot take a paid ad's `ct`.
// With `APP_STORE_LISTING_URL` emptied there is no picker and no file.
import type { APIRoute, GetStaticPaths } from 'astro';
import { APP_STORE_LISTING_URL, ON_APP_STORE } from '../../data/links';
import { appStoreCampaignUrl } from '../../lib/ad-links.mjs';
import { qrSvg } from '../../lib/qr';

export const getStaticPaths = (() => (ON_APP_STORE ? [{ params: { token: 'site-qr' } }] : [])) satisfies GetStaticPaths;

export const GET: APIRoute = ({ params }) =>
  new Response(qrSvg(appStoreCampaignUrl(APP_STORE_LISTING_URL, params.token ?? 'site-qr')), {
    headers: { 'Content-Type': 'image/svg+xml' },
  });
