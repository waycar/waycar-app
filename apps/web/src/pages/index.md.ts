// /index.md: the full landing-page content as Markdown, for AI agents (linked
// from /llms.txt and the home page's `rel="alternate"`). The source is
// src/llms/index.md; its one `{{app_store}}` token (the opening clause of the
// "How do I get Waycar?" answer) follows the App Store switch.
import type { APIRoute } from 'astro';
import { APP_STORE_LISTING_URL, ON_APP_STORE } from '../data/links';
import guide from '../llms/index.md?raw';

export const GET: APIRoute = () => {
  const availability = ON_APP_STORE
    ? `Download it from the App Store (${APP_STORE_LISTING_URL})`
    : 'Waycar is coming soon to the App Store. Once it is out, download it';
  const text = guide.replaceAll('{{app_store}}', availability);
  return new Response(text, {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
};
