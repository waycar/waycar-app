// @ts-check
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { test } from 'node:test';
import {
  MIN_PAGE_BULLETS,
  changelogPath,
  compareVersionsDescending,
  countBullets,
  formatReleaseDate,
  hasNewerRelease,
  orderEntries,
  paginate,
  releaseAnchor,
  scopeHeadingIds,
  stripRefs,
  unreleasedBody,
} from '../src/lib/changelog.mjs';

const HEADER = `# Changelog

All notable changes to Waycar are documented in this file.

`;

test('orders Unreleased first, then versions numerically newest first', () => {
  const entries = ['1.9.0', '0.1.10', null, '1.10.0', '0.1.9', '1.1.3', '10.0.0'].map((version) => ({ version }));
  assert.deepEqual(
    orderEntries(entries).map((entry) => entry.version),
    [null, '10.0.0', '1.10.0', '1.9.0', '1.1.3', '0.1.10', '0.1.9'],
  );
  assert.equal(entries[0].version, '1.9.0', 'orderEntries does not sort in place');
});

test('compareVersionsDescending compares each part as a number and rejects non-versions', () => {
  assert.ok(compareVersionsDescending('1.10.0', '1.9.0') < 0);
  assert.ok(compareVersionsDescending('1.9.0', '1.10.0') > 0);
  assert.equal(compareVersionsDescending('2.0.0', '2.0.0'), 0);
  assert.throws(() => compareVersionsDescending('1.2', '1.0.0'), /X\.Y\.Z/);
  assert.throws(() => compareVersionsDescending('v1.0.0', '1.0.0'), /X\.Y\.Z/);
});

test('unreleasedBody takes the section up to the next release heading', () => {
  const changelog = `${HEADER}## [Unreleased]

### Added

- **New thing**: does it. (#1)

### Fixed

- **Old thing**: works again.

## [1.1.3] - 2026-10-04

### Added

- **Released thing**: shipped.
`;
  assert.equal(
    unreleasedBody(changelog),
    '### Added\n\n- **New thing**: does it. (#1)\n\n### Fixed\n\n- **Old thing**: works again.',
  );
});

test('unreleasedBody runs to the end of the file when no release follows', () => {
  assert.equal(unreleasedBody(`${HEADER}## [Unreleased]\r\n\r\n### Added\r\n\r\n- Last.\r\n`), '### Added\n\n- Last.');
});

test('unreleasedBody is null for an empty or bullet-less section', () => {
  // Right after `make publish`: the file ends at the heading line.
  assert.equal(unreleasedBody(`${HEADER}## [Unreleased]\n`), null);
  assert.equal(unreleasedBody(`${HEADER}## [Unreleased]`), null);
  assert.equal(unreleasedBody(`${HEADER}## [Unreleased]\n\n### Added\n\n## [1.0.0] - 2026-09-01\n\n- Old.\n`), null);
  assert.equal(unreleasedBody(`${HEADER}## [Unreleased]\n\nNothing yet.\n`), null);
});

test('unreleasedBody is null when the section is missing', () => {
  assert.equal(unreleasedBody(HEADER), null);
  assert.equal(unreleasedBody(`${HEADER}## [1.0.0] - 2026-09-01\n\n- Released.\n`), null);
});

test('unreleasedBody counts * and + items but not bullets inside fenced code', () => {
  assert.equal(unreleasedBody(`${HEADER}## [Unreleased]\n\n### Fixed\n\n* Star item.\n`), '### Fixed\n\n* Star item.');
  assert.equal(unreleasedBody(`${HEADER}## [Unreleased]\n\n+ Plus item.\n`), '+ Plus item.');
  assert.equal(unreleasedBody(`${HEADER}## [Unreleased]\n\n\`\`\`text\n- not an item\n\`\`\`\n`), null);
});

test('stripRefs removes every reference variant and keeps the text', () => {
  const cases = [
    ['- **Help**: offline. (#161)', '- **Help**: offline.'],
    ['works again (#95, refs #90).', 'works again.'],
    ['instead of a blank screen (#105, refs #27)', 'instead of a blank screen'],
    ['now redacted (PR #302)', 'now redacted'],
    ['fewer retries (#320; PR #321)', 'fewer retries'],
    ['in one place (#151, #164; PR #174)', 'in one place'],
    ['on every Host (#101, #102, #103, #104; PR #105)', 'on every Host'],
    ['the live terminal draws. (#105, refs\n  #27)\n- **Next**: item', 'the live terminal draws.\n- **Next**: item'],
    ['spans lines\n  (#128)\n', 'spans lines\n'],
  ];
  for (const [input, expected] of cases) assert.equal(stripRefs(input), expected, JSON.stringify(input));
});

test('stripRefs leaves other parentheses and number signs alone', () => {
  for (const text of [
    'Speaking Speed (0.75× to 1.5×)',
    'e.g. "Blocked: approve merge of PR #512"',
    'the #2 choice (see Settings)',
    '(refs #)',
    '(#12 more)',
  ]) {
    assert.equal(stripRefs(text), text);
  }
});

test('countBullets counts top-level -, *, and + list items', () => {
  assert.equal(countBullets('### Added\n\n- One\n  continues\n* Two\n+ Three\n\n  - nested\n\nText - not a bullet'), 3);
  assert.equal(countBullets('**Bold** line\n-not a bullet\n- \tTab after the marker'), 1);
  assert.equal(countBullets(''), 0);
});

test('countBullets skips fenced code blocks and thematic breaks', () => {
  const body = [
    '- Before',
    '```sh',
    '- inside backticks',
    '```',
    '~~~~text',
    '* inside tildes',
    '~~~',
    '+ still inside: a shorter fence does not close it',
    '~~~~',
    '* * *',
    '- - -',
    '+ After',
  ].join('\n');
  assert.equal(countBullets(body), 2);
});

test('scopeHeadingIds gives every release on a page its own heading ids', () => {
  // As the Markdown renderer emits them: unique within one release only.
  const release = (/** @type {string} */ prefix) =>
    scopeHeadingIds(
      '<h3 id="added">Added</h3><ul><li>a</li></ul><h3 class="x" id="added-1">Added</h3><h3 id="fixed">Fixed</h3>',
      [{ depth: 3, slug: 'added', text: 'Added' }, { depth: 3, slug: 'added-1', text: 'Added' }, { depth: 3, slug: 'fixed', text: 'Fixed' }],
      prefix,
    );
  const pages = [release('unreleased'), release(releaseAnchor('1.1.3')), release(releaseAnchor('1.1.2'))];
  const ids = pages.flatMap((page) => [...page.html.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]));
  assert.equal(new Set(ids).size, ids.length, ids.join(' '));
  assert.deepEqual(ids.slice(3, 6), ['v1-1-3-added', 'v1-1-3-added-1', 'v1-1-3-fixed']);
  assert.deepEqual(
    pages[1].headings.map((heading) => heading.slug),
    ['v1-1-3-added', 'v1-1-3-added-1', 'v1-1-3-fixed'],
  );
  assert.ok(pages[1].html.includes('<h3 class="x" id="v1-1-3-added-1">'), pages[1].html);
  assert.ok(pages[1].html.includes('<ul><li>a</li></ul>'), 'leaves other markup alone');
});

test('no issue or pull request reference survives in the published changelog', () => {
  // Anything left in this shape would publish a pointer into the private
  // repository: extend the pattern in src/lib/changelog.mjs (and the app's).
  const leftover = /\(\s*(?:(?:refs|PR)\s+)?#\d/;
  const dir = new URL('../src/content/changelog/', import.meta.url);
  const files = readdirSync(dir).filter((file) => file.endsWith('.md'));
  assert.ok(files.length > 0, 'no release files found');
  const sources = [
    ...files.map((file) => ({ name: file, text: readFileSync(new URL(file, dir), 'utf8') })),
    { name: 'CHANGELOG.md', text: readFileSync(new URL('../../../CHANGELOG.md', import.meta.url), 'utf8') },
  ];
  for (const { name, text } of sources) {
    const published = stripRefs(text);
    const match = leftover.exec(published);
    assert.equal(match, null, `${name}: ${published.slice(Math.max(0, (match?.index ?? 0) - 40), (match?.index ?? 0) + 40)}`);
  }
});

/** @param {number[]} counts */
const entries = (counts) => counts.map((bullets, index) => ({ id: index, bullets }));
/** @param {{ id: number }[][]} pages */
const ids = (pages) => pages.map((page) => page.map((entry) => entry.id));

test('paginate fills each page until it holds at least the minimum, keeping releases whole', () => {
  // 15 + 11 + 17 = 43 closes page 1; 29 + 3 + 29 = 61 closes page 2.
  const pages = paginate(entries([15, 11, 17, 29, 3, 29, 2, 38]));
  assert.deepEqual(ids(pages), [[0, 1, 2], [3, 4, 5], [6, 7]]);
});

test('paginate closes a page exactly at the minimum', () => {
  assert.deepEqual(ids(paginate(entries([20, 20, 1]))), [[0, 1], [2]]);
  assert.deepEqual(ids(paginate(entries([39, 1, 39]))), [[0, 1], [2]]);
});

test('paginate gives one big release its own page', () => {
  assert.deepEqual(ids(paginate(entries([2, 74, 5]))), [[0, 1], [2]]);
  assert.deepEqual(ids(paginate(entries([74]))), [[0]]);
});

test('paginate counts Unreleased toward page 1', () => {
  const list = [{ id: 'unreleased', bullets: 30 }, { id: '1.1.3', bullets: 15 }, { id: '1.1.2', bullets: 11 }];
  assert.deepEqual(
    paginate(list).map((page) => page.map((entry) => entry.id)),
    [['unreleased', '1.1.3'], ['1.1.2']],
  );
});

test('paginate never leaves an empty last page and returns one page for nothing', () => {
  assert.deepEqual(ids(paginate(entries([MIN_PAGE_BULLETS, MIN_PAGE_BULLETS]))), [[0], [1]]);
  assert.deepEqual(paginate([]), [[]]);
  assert.deepEqual(ids(paginate(entries([1, 2, 3]))), [[0, 1, 2]]);
});

test('the help gate lifts once a release newer than the App Store one exists', () => {
  assert.equal(hasNewerRelease(['1.2.3', '1.3.0', '1.10.0'], '1.3.0'), true);
  assert.equal(hasNewerRelease(['1.3.1'], '1.3.0'), true);
  assert.equal(hasNewerRelease(['1.0.1', '1.2.3', '1.3.0'], '1.3.0'), false);
});

test('paths, anchors, and dates', () => {
  assert.equal(changelogPath(1), '/changelog');
  assert.equal(changelogPath(3), '/changelog/3');
  assert.equal(releaseAnchor('1.1.3'), 'v1-1-3');
  assert.equal(releaseAnchor('0.10.0'), 'v0-10-0');
  assert.equal(formatReleaseDate('2026-10-04'), 'October 4, 2026');
  assert.equal(formatReleaseDate('2026-01-01'), 'January 1, 2026');
});
