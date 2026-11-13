// @ts-check
// The built site's indexable pages, read back from dist/. Shared by the sitemap
// integration (integrations/sitemap.mjs) and the llms.txt generator
// (generate-llms-txt.mjs) so both follow Layout.astro's canonical/noindex
// tags instead of a hand-kept page list. The help search index
// (src/lib/help.ts) decodes HTML entities with `decodeEntities` from here too.
import { readdirSync, readFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

/** @typedef {{ url: string, file: string, html: string }} SitePage */

/**
 * Every indexable page in `distDir`, one per canonical URL, home page first.
 * A page is indexable when it carries a canonical link and no robots noindex.
 * @param {string} distDir
 * @returns {SitePage[]}
 */
export function listIndexablePages(distDir) {
  /** @type {Map<string, SitePage & { own: boolean }>} */
  const byUrl = new Map();
  for (const path of walkHtml(distDir)) {
    const html = readFileSync(path, 'utf8');
    const tags = startTags(html.match(/<head\b[\s\S]*?<\/head>/i)?.[0] ?? html);
    const noindex = tags.some(
      (tag) =>
        tag.name === 'meta' &&
        tag.attrs.name?.toLowerCase() === 'robots' &&
        /\bnoindex\b/i.test(tag.attrs.content ?? ''),
    );
    const href = tags.find(
      (tag) => tag.name === 'link' && tag.attrs.rel?.toLowerCase().split(/\s+/).includes('canonical'),
    )?.attrs.href;
    if (noindex || !href) continue;
    const url = new URL(href).href;
    const file = relative(distDir, path).split(sep).join('/');
    // Home page B (b.html) shares `/` with index.html; the file actually
    // served at the canonical path is the one to describe.
    const own = samePath(publicPath(file), new URL(url).pathname);
    const seen = byUrl.get(url);
    if (!seen || (own && !seen.own)) byUrl.set(url, { url, file, html, own });
  }
  return [...byUrl.values()]
    .map(({ url, file, html }) => ({ url, file, html }))
    .sort((a, b) => rank(a.url) - rank(b.url) || (a.url < b.url ? -1 : a.url > b.url ? 1 : 0));
}

/**
 * sitemaps.org XML for `urls`, in the given order.
 * @param {string[]} urls
 */
export function renderSitemap(urls) {
  const entries = urls.map((url) => `  <url><loc>${escapeXml(url)}</loc></url>`).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${entries}
</urlset>
`;
}

// Elements whose content is never page text.
const DROPPED = /<(script|style|svg|noscript|template)\b[\s\S]*?<\/\1\s*>/gi;
const BLOCK = new Set(
  ('address article aside blockquote caption dd details dialog div dl dt fieldset figcaption figure ' +
    'footer form header hr main nav p section summary').split(' '),
);
// Inside <pre>, whitespace is content; these private-use stand-ins survive the
// whitespace collapse and are restored at the end.
const PRE_NEWLINE = '\uE000';
const PRE_SPACE = '\uE001';
// Sibling pills (`<span>herdr</span><span>Workspaces</span>`, the agent
// `<code>` row) sit apart only by CSS; at their edges a word break becomes a
// space when letters or digits meet.
const SOFT_BREAK = '\uE002';
const SOFT = new Set(['span', 'code']);

/**
 * Readable Markdown-ish text of a built page: its <main> (else <body>) plus the
 * site <footer>, which carries availability and company facts.
 * @param {string} html
 * @param {string} pageUrl base for relative links
 */
export function htmlToText(html, pageUrl) {
  const clean = html.replace(/<!--[\s\S]*?-->/g, '').replace(DROPPED, '');
  const main = clean.match(/<main\b[^>]*>[\s\S]*?<\/main\s*>/i)?.[0];
  const body = clean.match(/<body\b[^>]*>([\s\S]*?)<\/body\s*>/i)?.[1] ?? clean;
  const outside = main ? clean.replace(main, '') : '';
  const footer = main ? (outside.match(/<footer\b[^>]*>[\s\S]*?<\/footer\s*>/i)?.[0] ?? '') : '';
  return render(main ? `${main}\n${footer}` : body, pageUrl);
}

/**
 * @param {string} html
 * @param {string} pageUrl
 */
function render(html, pageUrl) {
  let out = '';
  /** @type {{ start: number, href: string | undefined }[]} */
  const links = [];
  let pre = 0;
  // A table cell is one line: its block children break with a space.
  let cell = 0;
  /** @param {string} breaks */
  const block = (breaks) => (cell ? ' ' : breaks);
  // The first all-<th> row of a table gets a Markdown header separator.
  let headerDone = false;
  let cells = 0;
  let headerCells = 0;
  for (const token of html.matchAll(TOKEN)) {
    const [raw, slash, rawName, attrText] = token;
    if (rawName === undefined) {
      const text = decodeEntities(raw);
      out += pre
        ? text.replaceAll('\n', PRE_NEWLINE).replace(/[ \t]/g, PRE_SPACE)
        : text.replace(/\s+/g, ' ');
      continue;
    }
    const name = rawName.toLowerCase();
    const closing = slash === '/';
    if (SOFT.has(name) && !pre) out += SOFT_BREAK;
    // CodeBlock renders each line of a <pre> as `<span class="line">`.
    if (pre && name === 'span' && !closing && !out.endsWith('```\n')) {
      if (parseAttributes(attrText).class?.split(/\s+/).includes('line')) out += PRE_NEWLINE;
    }
    if (/^h[1-6]$/.test(name)) {
      // A heading that opens a list item replaces the item's bullet.
      if (!closing && !cell) out = out.replace(/\n- [ \uE002]*$/, '\n');
      out += block(closing ? '\n\n' : `\n\n${'#'.repeat(Number(name[1]))} `);
    } else if (name === 'li') {
      if (!closing) out += block('\n- ');
    } else if (name === 'ul' || name === 'ol') {
      out += block('\n\n');
    } else if (name === 'a') {
      if (!closing) {
        links.push({ start: out.length, href: parseAttributes(attrText).href });
      } else {
        const link = links.pop();
        if (link) out = out.slice(0, link.start) + linkText(out.slice(link.start), link.href, pageUrl);
      }
    } else if (name === 'img') {
      const alt = parseAttributes(attrText).alt?.trim();
      if (alt) out += ` ${alt} `;
    } else if (name === 'br') {
      out += pre ? PRE_NEWLINE : block('\n');
    } else if (name === 'pre') {
      pre = Math.max(0, pre + (closing ? -1 : 1));
      out += block(closing ? '\n```\n\n' : '\n\n```\n');
    } else if (name === 'table') {
      headerDone = false;
      out += '\n\n';
    } else if (name === 'tr') {
      if (!closing) {
        cells = headerCells = 0;
        out += '\n|';
      } else {
        if (!headerDone && cells > 0 && headerCells === cells) out += `\n|${' --- |'.repeat(cells)}`;
        headerDone = true;
      }
    } else if (name === 'td' || name === 'th') {
      if (!closing) {
        cell++;
        cells++;
        if (name === 'th') headerCells++;
        out += ' ';
      } else {
        cell = Math.max(0, cell - 1);
        out += ' |';
      }
    } else if (name === 'p') {
      out += block('\n\n');
    } else if (BLOCK.has(name)) {
      out += block('\n');
    }
  }
  return out
    .replace(/([\p{L}\p{N}])\uE002+(?=[\p{L}\p{N}])/gu, '$1 ')
    .replaceAll(SOFT_BREAK, '')
    .split('\n')
    .map((line) => line.replace(/[ \t]+/g, ' ').trim())
    // A bullet left empty because its content was a heading or a block.
    .map((line) => (line === '-' ? '' : line))
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .replaceAll(PRE_NEWLINE, '\n')
    .replaceAll(PRE_SPACE, ' ')
    .trim();
}

/**
 * @param {string} inner rendered text between <a> and </a>
 * @param {string | undefined} href
 * @param {string} pageUrl
 */
function linkText(inner, href, pageUrl) {
  const text = inner.replaceAll(SOFT_BREAK, ' ').replace(/\s+/g, ' ').trim();
  if (!text || !href || href.startsWith('#') || /^javascript:/i.test(href)) return inner;
  let target;
  try {
    target = new URL(href, pageUrl).href;
  } catch {
    return inner;
  }
  return `[${text}](${target})`;
}

// A start or end tag (name, attributes) or a run of text.
const TOKEN =
  /<(\/?)([a-zA-Z][\w:-]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*\/?>|[^<]+|</g;

/**
 * @param {string} html
 * @returns {{ name: string, attrs: Record<string, string> }[]}
 */
function startTags(html) {
  return [...html.matchAll(TOKEN)]
    .filter((token) => token[2] !== undefined && token[1] !== '/')
    .map((token) => ({ name: token[2].toLowerCase(), attrs: parseAttributes(token[3]) }));
}

/**
 * Attribute map with lowercase names and decoded values; a bare attribute
 * (Astro's `alt` with no value) maps to ''.
 * @param {string | undefined} text
 */
function parseAttributes(text) {
  /** @type {Record<string, string>} */
  const attrs = {};
  for (const [, name, double, single, bare] of (text ?? '').matchAll(
    /([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g,
  )) {
    attrs[name.toLowerCase()] = decodeEntities(double ?? single ?? bare ?? '');
  }
  return attrs;
}

/** @type {Record<string, string>} */
const NAMED = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ensp: ' ', emsp: ' ', thinsp: ' ',
  ndash: '–', mdash: '—', hellip: '…', lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”', laquo: '«',
  raquo: '»', middot: '·', bull: '•', copy: '©', reg: '®', trade: '™', times: '×', divide: '÷',
  deg: '°', plusmn: '±', larr: '←', rarr: '→', uarr: '↑', darr: '↓', harr: '↔', check: '✓',
  euro: '€', pound: '£', yen: '¥', cent: '¢', sect: '§', para: '¶', shy: '',
};

/**
 * `text` with HTML character references decoded (named, decimal, and hex).
 * @param {string} text
 */
export function decodeEntities(text) {
  return text.replace(/&(?:#(\d+)|#[xX]([\da-fA-F]+)|([a-zA-Z][a-zA-Z\d]*));/g, (entity, dec, hex, name) => {
    if (name !== undefined) return NAMED[name] ?? NAMED[name.toLowerCase()] ?? entity;
    const code = dec !== undefined ? Number(dec) : parseInt(hex, 16);
    return code > 0 && code <= 0x10ffff && (code < 0xd800 || code > 0xdfff) ? String.fromCodePoint(code) : entity;
  });
}

/**
 * @param {string} dir
 * @returns {Generator<string>}
 */
function* walkHtml(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) yield* walkHtml(path);
    else if (entry.isFile() && entry.name.endsWith('.html')) yield path;
  }
}

/**
 * URL path a dist file is served at (`build.format: 'file'`, and the Workers
 * asset router's pretty URLs): `ipad.html` → `/ipad`, `index.html` → `/`.
 * @param {string} file posix path relative to dist
 */
function publicPath(file) {
  return `/${file.replace(/\.html$/, '').replace(/(^|\/)index$/, '$1')}`;
}

/**
 * @param {string} a
 * @param {string} b
 */
function samePath(a, b) {
  /** @param {string} path */
  const trim = (path) => (path.length > 1 ? path.replace(/\/$/, '') : path);
  return trim(a) === trim(b);
}

/** @param {string} url */
function rank(url) {
  return new URL(url).pathname === '/' ? 0 : 1;
}

/** @type {Record<string, string>} */
const XML_ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' };

/** @param {string} text */
function escapeXml(text) {
  return text.replace(/[&<>"']/g, (char) => XML_ESCAPES[char]);
}
