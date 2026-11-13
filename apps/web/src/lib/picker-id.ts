// One id per Get Waycar picker on a page. Each button owns its picker (see
// `AppStoreCta.astro`), and the button reaches it through `href="#<id>"`, so
// the ids must be unique on the page. A page render has one `Astro.request`,
// shared by every component on it, so it keys the count.
const counts = new WeakMap<Request, number>();

export function nextPickerId(request: Request): string {
  const next = (counts.get(request) ?? 0) + 1;
  counts.set(request, next);
  return `get-waycar-${next}`;
}
