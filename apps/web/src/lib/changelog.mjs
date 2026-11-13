// @ts-check
// The changelog as /changelog shows it, shared by the content loaders
// (src/lib/changelog-loader.ts), the routes (src/pages/changelog/), and the
// tests (scripts/changelog.test.mjs). Pure and dependency-free.
//
// Releases are src/content/changelog/<X.Y.Z>.md; the coming release is the
// `## [Unreleased]` section of the repo-root CHANGELOG.md. Display order is
// Unreleased (only when it has a bullet), then releases by version, newest
// first. Issue and pull request references point into the private repository,
// so they are stripped before the Markdown is rendered (the iOS app strips the
// same pattern); the source files keep them.

/**
 * Issue and pull request references in parentheses, with the space before
 * them: `(#161)`, `(#95, refs #90)`, `(PR #302)`, `(#151, #164; PR #174)`,
 * also when a Markdown line break falls inside. Keep in sync with the app's
 * copy of this pattern.
 */
const REFS = /\s*\((?:(?:refs|PR)\s+)?#\d+(?:\s*[,;]\s*(?:(?:refs|PR)\s+)?#\d+)*\)/g;

/**
 * A top-level list item: a `-`, `*`, or `+` marker at the start of the line,
 * then a space (the app treats the same markers as list items).
 */
const LIST_ITEM = /^[-*+][ \t]/;
/** A thematic break such as `* * *` or `- - -`, which is not a list item. */
const THEMATIC_BREAK = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
/** The opening line of a fenced code block: its fence in group 1. */
const FENCE_OPEN = /^ {0,3}(`{3,}|~{3,})/;

const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

/** The fewest bullets a page holds before it closes (the last page may hold fewer). */
export const MIN_PAGE_BULLETS = 40;

/** Public path of changelog page `n` (1-based): `/changelog`, `/changelog/2`, ... */
export const changelogPath = (/** @type {number} */ n) => (n === 1 ? '/changelog' : `/changelog/${n}`);

/**
 * `markdown` without issue and pull request references.
 * @param {string} markdown
 */
export const stripRefs = (markdown) => markdown.replace(REFS, '');

/**
 * Number of top-level list items in a changelog body (`-`, `*`, or `+`
 * bullets at the start of a line), not counting lines inside fenced code
 * blocks or thematic breaks such as `* * *`.
 * @param {string} markdown
 */
export function countBullets(markdown) {
  let count = 0;
  /** @type {string | null} The open fence, or null outside a code block. */
  let fence = null;
  for (const line of markdown.split(/\r\n?|\n/)) {
    if (fence !== null) {
      // Closed by a line of only the same character, at least as many.
      const close = line.trim();
      if (close.length >= fence.length && close === fence[0].repeat(close.length)) fence = null;
      continue;
    }
    const open = FENCE_OPEN.exec(line)?.[1];
    if (open) fence = open;
    else if (LIST_ITEM.test(line) && !THEMATIC_BREAK.test(line)) count += 1;
  }
  return count;
}

/**
 * The body of `## [Unreleased]` in a Keep a Changelog file, up to the next
 * `## ` heading or the end, trimmed. Null when the section is missing or has
 * no top-level bullet (right after a release). The app's check is looser (it
 * also counts indented and fenced items); `[Unreleased]` holds plain
 * top-level bullets, so the two agree in practice.
 * @param {string} changelog
 * @returns {string | null}
 */
export function unreleasedBody(changelog) {
  const lines = changelog.split(/\r\n?|\n/);
  const start = lines.findIndex((line) => line.trim() === '## [Unreleased]');
  if (start === -1) return null;
  const rest = lines.slice(start + 1);
  const end = rest.findIndex((line) => line.startsWith('## ') || line.trim() === '##');
  const body = (end === -1 ? rest : rest.slice(0, end)).join('\n').trim();
  return countBullets(body) > 0 ? body : null;
}

/**
 * Whether `version` is a plain `X.Y.Z` release version.
 * @param {string} version
 */
export const isVersion = (version) => SEMVER.test(version);

/**
 * Compares two `X.Y.Z` versions numerically for a newest-first sort
 * (`1.10.0` before `1.9.0`).
 * @param {string} a
 * @param {string} b
 */
export function compareVersionsDescending(a, b) {
  const parse = (/** @type {string} */ version) => {
    const match = SEMVER.exec(version);
    if (!match) throw new Error(`Not an X.Y.Z version: ${version}`);
    return match.slice(1).map(Number);
  };
  const [x, y] = [parse(a), parse(b)];
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return y[i] - x[i];
  return 0;
}

/**
 * Whether `versions` holds one newer than `version`: the help gate
 * (src/data/unreleased.ts) lifts once a newer release file exists.
 * @param {readonly string[]} versions
 * @param {string} version
 */
export const hasNewerRelease = (versions, version) =>
  versions.some((candidate) => compareVersionsDescending(candidate, version) < 0);

/**
 * Entries in display order: the Unreleased entry (`version` null) first, then
 * releases newest first. Does not modify `entries`.
 * @template {{ version: string | null }} T
 * @param {readonly T[]} entries
 * @returns {T[]}
 */
export function orderEntries(entries) {
  return [...entries].sort((a, b) => {
    if (a.version === null || b.version === null) return (a.version === null ? 0 : 1) - (b.version === null ? 0 : 1);
    return compareVersionsDescending(a.version, b.version);
  });
}

/**
 * Splits entries (already in display order) into pages of whole entries: each
 * page takes entries until it holds at least `minBullets` bullets, and the
 * last page takes what is left. Always at least one page.
 * @template {{ bullets: number }} T
 * @param {readonly T[]} entries
 * @param {number} [minBullets]
 * @returns {T[][]}
 */
export function paginate(entries, minBullets = MIN_PAGE_BULLETS) {
  /** @type {T[][]} */
  const pages = [];
  /** @type {T[]} */
  let page = [];
  let bullets = 0;
  for (const entry of entries) {
    page.push(entry);
    bullets += entry.bullets;
    if (bullets >= minBullets) {
      pages.push(page);
      page = [];
      bullets = 0;
    }
  }
  if (page.length > 0 || pages.length === 0) pages.push(page);
  return pages;
}

/**
 * Element id of a release's section: `v1-1-3` for 1.1.3.
 * @param {string} version
 */
export const releaseAnchor = (version) => `v${version.replaceAll('.', '-')}`;

/**
 * Rendered HTML and heading list with every heading id prefixed by the entry's
 * anchor (`v1-1-3-added`), so the `### Added` of each release on a page gets
 * its own id. The Markdown renderer already keeps ids unique within one entry.
 * @template {{ slug: string }} H
 * @param {string} html
 * @param {readonly H[]} headings
 * @param {string} prefix
 * @returns {{ html: string, headings: H[] }}
 */
export function scopeHeadingIds(html, headings, prefix) {
  return {
    html: html.replace(/(<h[1-6]\b[^>]*?\sid=")([^"]+)"/g, (_, start, id) => `${start}${prefix}-${id}"`),
    headings: headings.map((heading) => ({ ...heading, slug: `${prefix}-${heading.slug}` })),
  };
}

const LONG_DATE = new Intl.DateTimeFormat('en-US', { dateStyle: 'long', timeZone: 'UTC' });

/**
 * A `YYYY-MM-DD` date as `October 4, 2026`, independent of the build's time zone.
 * @param {string} date
 */
export const formatReleaseDate = (date) => LONG_DATE.format(new Date(`${date}T00:00:00Z`));
