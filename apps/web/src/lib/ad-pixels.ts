// Ad-conversion pixels (Reddit Ads, X Ads) for waycar.dev. Called only from the
// Layout script, and only once `adsAllowed` there says the visitor has not
// opted out (see PRIVACY.md, "This website"). Both vendors' stock snippets are
// inline scripts, which the Worker's CSP forbids, so the same loaders are
// written here and bundled into /_astro. Their hosts are allowed in
// `SECURITY_HEADERS` in src/worker.ts.
//
// We pass the pixels no data of our own: no email, no hashed ID, and no event
// parameters. Each vendor's script itself reads the page URL, referrer, IP
// address, and user agent, and sets its own identifiers.

const REDDIT_PIXEL_ID = 'a2_jsoqcexpq95u';
const X_PIXEL_ID = 'rghdf';
// X "Custom" event "App Store click" (Events manager, pixel `rghdf`).
const X_APP_STORE_EVENT = 'tw-rghdf-rh8ye';

type Rdt = {
  (...args: unknown[]): void;
  sendEvent?: (...args: unknown[]) => void;
  callQueue: unknown[][];
};
type Twq = {
  (...args: unknown[]): void;
  exe?: (...args: unknown[]) => void;
  queue: unknown[][];
  version: string;
};
declare global {
  interface Window {
    rdt?: Rdt;
    twq?: Twq;
  }
}

// First-party cookies the pixels leave on waycar.dev, removed when a visitor
// declines after they loaded.
const PIXEL_COOKIES = ['_rdt_uuid', '_rdt_cid', '_rdt_em', '_rdt_pn', '_twpid', '_twclid', '_twsid'];

let loaded = false;
// Settles (never rejects) when each vendor script has loaded or failed to.
let scripts: Promise<boolean>[] = [];

/** Resolves true when the script loaded, false when it failed (blocked, offline). */
function addScript(src: string): Promise<boolean> {
  return new Promise((resolve) => {
    const script = document.createElement('script');
    script.async = true;
    script.src = src;
    script.onload = () => resolve(true);
    script.onerror = () => resolve(false);
    document.head.appendChild(script);
  });
}

export function loadAdPixels() {
  if (loaded) return;
  loaded = true;

  const rdt = (window.rdt = ((...args: unknown[]) => {
    if (rdt.sendEvent) rdt.sendEvent(...args);
    else rdt.callQueue.push(args);
  }) as Rdt);
  rdt.callQueue = [];
  const rdtLoaded = addScript('https://www.redditstatic.com/ads/pixel.js').then(
    (ok) => ok && window.rdt?.sendEvent !== undefined,
  );
  rdt('init', REDDIT_PIXEL_ID);
  rdt('track', 'PageVisit');

  const twq = (window.twq = ((...args: unknown[]) => {
    if (twq.exe) twq.exe(...args);
    else twq.queue.push(args);
  }) as Twq);
  twq.version = '1.1';
  twq.queue = [];
  const twqLoaded = addScript('https://static.ads-twitter.com/uwt.js').then(
    (ok) => ok && window.twq?.exe !== undefined,
  );
  twq('config', X_PIXEL_ID);

  scripts = [rdtLoaded, twqLoaded];
}

/**
 * For a page that is about to leave (`/go`). Resolves at once when the pixels
 * never loaded. Otherwise waits for both vendor scripts to load or fail, then,
 * only if at least one is up and ready, a short grace for it to send what is
 * queued. Never waits past `timeoutMs`, and a blocked or failed vendor does not
 * hold the page for the full time.
 */
export function pixelsSettled(timeoutMs: number): Promise<void> {
  if (!loaded) return Promise.resolve();
  const graceMs = 400;
  const started = Date.now();
  const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, Math.max(0, ms)));
  const work = Promise.all(scripts).then((ready) => {
    if (!ready.some(Boolean)) return;
    return wait(Math.min(graceMs, timeoutMs - (Date.now() - started)));
  });
  return Promise.race([work, wait(timeoutMs)]);
}

/** The visitor clicked an App Store link. A no-op until the pixels are loaded. */
export function trackAppStoreClick() {
  if (!loaded) return;
  window.rdt?.('track', 'Lead');
  window.twq?.('event', X_APP_STORE_EVENT, {});
}

/**
 * The visitor declined after the pixels loaded. Loaded vendor scripts cannot be
 * stopped, so this removes their cookies and reports whether the page needs a
 * reload to drop them.
 */
export function dropAdPixels(): boolean {
  // Each cookie may have been set host-only, on this host, or on the parent
  // domain, and a cookie only expires through the scope that set it.
  const parts = location.hostname.split('.');
  const registrable = parts.length >= 3 ? parts.slice(1).join('.') : location.hostname;
  const scopes = ['', `; Domain=${location.hostname}`, `; Domain=.${registrable}`];
  for (const name of PIXEL_COOKIES) {
    for (const scope of scopes) {
      document.cookie = `${name}=; Path=/; Max-Age=0; Secure; SameSite=Lax${scope}`;
    }
  }
  return loaded;
}
