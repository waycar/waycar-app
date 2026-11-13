// @ts-check
// The rows every comparison page answers, and the checks the comparison and
// solution data must pass. Plain JavaScript so scripts/compare.test.mjs can run
// it under `node --test`, like articles-list.mjs. The Astro side is
// src/lib/compare.ts and src/lib/solutions.ts (the collections, Markdown
// twins) and the schemas in src/content.config.ts.

/**
 * `yes`, `partial`, `no` and `unknown` rate a capability; `unknown` means the
 * maker documents nothing either way, so the page claims nothing. `info` rows
 * are descriptive (where an agent runs, what it costs) and carry no rating.
 * @typedef {'yes' | 'partial' | 'no' | 'unknown' | 'info'} Level
 * @typedef {{ level: Level, text: string }} Cell
 */

export const LEVELS = /** @type {const} */ (['yes', 'partial', 'no', 'unknown', 'info']);

/**
 * What a rated cell's text must start with, so the cell reads the same in the
 * table, to a screen reader, and in the Markdown twin, with no color or mark
 * needed. `info` cells have no required start.
 * @type {Record<Level, string>}
 */
export const LEVEL_WORDS = { yes: 'Yes', partial: 'Partial', no: 'No', unknown: 'Not documented', info: '' };

/** A table cell's text stays short enough to scan. */
export const CELL_MAX = 60;

/**
 * What kind of product a comparison is about, and the label the index and the
 * page show for it.
 * @type {Record<'ssh-client' | 'agent-environment' | 'agent-client' | 'first-party', string>}
 */
export const KIND_LABELS = {
  'ssh-client': 'SSH client',
  'agent-environment': 'Agent environment',
  'agent-client': 'Agent client',
  'first-party': 'First-party feature',
};

export const KINDS = /** @type {const} */ (['ssh-client', 'agent-environment', 'agent-client', 'first-party']);

export const GROUPS = /** @type {const} */ ([
  { id: 'connect', label: 'How it connects' },
  { id: 'agents', label: 'Watching and steering agents' },
  { id: 'reach', label: 'Platforms, price and fit' },
]);

/**
 * The rows, in table order. Each comparison page answers every one, for
 * Waycar (src/data/compare-waycar.ts) and for the other product (its
 * front matter), so the pages and the index matrix line up. A `rated` row takes
 * a yes, partial, no or unknown cell; the others describe, with `info`.
 */
export const CAPABILITIES = /** @type {const} */ ([
  { id: 'runs-where', group: 'connect', label: 'Where the agent runs', rated: false },
  { id: 'account', group: 'connect', label: 'Account needed', rated: false },
  { id: 'path', group: 'connect', label: 'How your phone reaches the session', rated: false },
  { id: 'mosh', group: 'connect', label: 'mosh', rated: true },
  { id: 'persistent', group: 'connect', label: 'Agent keeps running when your phone drops', rated: true },
  { id: 'host-setup', group: 'connect', label: 'What your machine needs', rated: false },
  { id: 'agents', group: 'agents', label: 'Agents it works with', rated: false },
  { id: 'status', group: 'agents', label: 'Agent status list', rated: true },
  { id: 'push', group: 'agents', label: 'Push alerts when blocked or done', rated: true },
  { id: 'approve', group: 'agents', label: 'Answer a blocked agent from the phone', rated: true },
  { id: 'chat', group: 'agents', label: 'Chat view of the agent', rated: true },
  { id: 'terminal', group: 'agents', label: 'Full terminal', rated: true },
  { id: 'live-activity', group: 'agents', label: 'Lock Screen Live Activity', rated: true },
  { id: 'attach', group: 'agents', label: 'Send images and files to the agent', rated: true },
  { id: 'voice', group: 'agents', label: 'Voice input', rated: true },
  { id: 'usage', group: 'agents', label: 'Usage and rate limits', rated: true },
  { id: 'resume', group: 'agents', label: 'Resume a closed agent', rated: true },
  { id: 'ios', group: 'reach', label: 'iPhone and iPad app', rated: true },
  { id: 'android', group: 'reach', label: 'Android app', rated: true },
  { id: 'desktop', group: 'reach', label: 'Desktop or web client', rated: true },
  { id: 'source', group: 'reach', label: 'Source code', rated: false },
  { id: 'price', group: 'reach', label: 'Price', rated: false },
  { id: 'general-ssh', group: 'reach', label: 'General SSH tools (SFTP, port forwarding, any server)', rated: true },
]);

/** @typedef {typeof CAPABILITIES[number]['id']} CapabilityId */

export const CAPABILITY_IDS = /** @type {CapabilityId[]} */ (CAPABILITIES.map((row) => row.id));

/**
 * What is wrong with one table cell, or `undefined` when it is fine.
 * @param {{ level: string, text: string }} cell
 * @returns {string | undefined}
 */
export function cellProblem(cell) {
  const level = /** @type {Level} */ (cell.level);
  if (!(level in LEVEL_WORDS)) return `level "${cell.level}" is not one of ${LEVELS.join(', ')}`;
  if (cell.text.length === 0 || cell.text.length > CELL_MAX) {
    return `text is ${cell.text.length} characters, must be 1 to ${CELL_MAX}: "${cell.text}"`;
  }
  if (/[\r\n]/.test(cell.text)) return `text must be one line: "${cell.text}"`;
  const word = LEVEL_WORDS[level];
  // A whole word: "Not documented" must not pass for a `no` cell.
  if (word && !(cell.text.startsWith(word) && !/\w/.test(cell.text.charAt(word.length)))) {
    return `a ${level} cell's text must start with "${word}": "${cell.text}"`;
  }
  return undefined;
}

/**
 * What is wrong with the level a row's cell uses, or `undefined` when it is
 * fine: a rated row takes yes, partial, no or unknown, and a descriptive row
 * takes `info`, so a row never shows a mark on one page and none on another.
 * @param {string} id
 * @param {{ level: string }} cell
 * @returns {string | undefined}
 */
export function levelProblem(id, cell) {
  const row = CAPABILITIES.find((candidate) => candidate.id === id);
  if (row?.rated && cell.level === 'info') return 'is a rated row: use yes, partial, no or unknown';
  if (row && !row.rated && cell.level !== 'info') return 'is a descriptive row: use info';
  return undefined;
}

/**
 * Every problem in a comparison's rows: a missing or unknown capability id, or
 * a bad cell. Empty when the rows are fine.
 * @param {Record<string, { level: string, text: string }>} rows
 * @param {string} where
 * @returns {string[]}
 */
export function rowProblems(rows, where) {
  /** @type {string[]} */
  const problems = [];
  for (const id of CAPABILITY_IDS) {
    if (!(id in rows)) problems.push(`${where}: no "${id}" row`);
  }
  for (const [id, cell] of Object.entries(rows)) {
    if (!CAPABILITY_IDS.includes(/** @type {CapabilityId} */ (id))) {
      problems.push(`${where}: "${id}" is not a capability row`);
      continue;
    }
    const problem = cellProblem(cell) ?? levelProblem(id, cell);
    if (problem) problems.push(`${where}: "${id}" ${problem}`);
  }
  return problems;
}

/**
 * Checks that need the whole collection: another comparison a page links
 * (`related`) or a solution it links exists and is not the page itself, and no
 * two comparisons share an `order`. Empty when the set is fine.
 * @param {readonly { id: string, where: string, order: number, related: readonly string[], solutions: readonly string[] }[]} entries
 * @param {ReadonlySet<string>} solutionIds
 * @returns {string[]}
 */
export function relationProblems(entries, solutionIds) {
  /** @type {string[]} */
  const problems = [];
  const ids = new Set(entries.map((entry) => entry.id));
  /** @type {Map<number, string>} */
  const orders = new Map();
  for (const entry of entries) {
    for (const slug of entry.related) {
      if (slug === entry.id) problems.push(`${entry.where}: related lists the page itself (${slug})`);
      else if (!ids.has(slug)) problems.push(`${entry.where}: related slug "${slug}" is not a comparison`);
    }
    for (const slug of entry.solutions) {
      if (!solutionIds.has(slug)) problems.push(`${entry.where}: solutions slug "${slug}" is not a solution page`);
    }
    const other = orders.get(entry.order);
    if (other) problems.push(`${entry.where}: order ${entry.order} is also used by ${other}`);
    orders.set(entry.order, entry.where);
  }
  return problems;
}

/**
 * The capability table as Markdown: Waycar beside one other product, rows
 * grouped under a bold group row. Pipes in a cell are escaped.
 * @param {Record<string, { text: string }>} waycar
 * @param {Record<string, { text: string }>} other
 * @param {string} otherName
 * @returns {string}
 */
export function markdownTable(waycar, other, otherName) {
  /** @param {string} text */
  const cell = (text) => text.replaceAll('|', '\\|');
  const lines = [`| | Waycar | ${cell(otherName)} |`, '| --- | --- | --- |'];
  for (const group of GROUPS) {
    lines.push(`| **${group.label}** | | |`);
    for (const row of CAPABILITIES.filter((candidate) => candidate.group === group.id)) {
      lines.push(`| ${row.label} | ${cell(waycar[row.id].text)} | ${cell(other[row.id].text)} |`);
    }
  }
  return lines.join('\n');
}

/**
 * The same cross-collection checks for the solution pages: every comparison and
 * help page a solution links exists, and no two solutions share an `order`.
 * Empty when the set is fine.
 * @param {readonly { id: string, where: string, order: number, compare: readonly string[], help: readonly string[] }[]} entries
 * @param {ReadonlySet<string>} compareIds
 * @param {ReadonlySet<string>} helpIds
 * @returns {string[]}
 */
export function solutionProblems(entries, compareIds, helpIds) {
  /** @type {string[]} */
  const problems = [];
  /** @type {Map<number, string>} */
  const orders = new Map();
  for (const entry of entries) {
    for (const slug of entry.compare) {
      if (!compareIds.has(slug)) problems.push(`${entry.where}: compare slug "${slug}" is not a comparison`);
    }
    for (const slug of entry.help) {
      if (!helpIds.has(slug)) problems.push(`${entry.where}: help slug "${slug}" is not a published help page`);
    }
    const other = orders.get(entry.order);
    if (other) problems.push(`${entry.where}: order ${entry.order} is also used by ${other}`);
    orders.set(entry.order, entry.where);
  }
  return problems;
}

/**
 * Problems in a page's Markdown body: an H1 (the template already renders the
 * page title as one), a link to /install.sh (every GET of it logs an install
 * event) or a site link that names no published page. A link counts whether it
 * is written `[x](/path)`, `[x](https://<origin>/path)`, `<a href="/path">` or
 * as a reference definition (`[1]: /path`). Fenced code is skipped, because a
 * shell comment starts with "# ".
 * @param {string} body
 * @param {string} where
 * @param {ReadonlySet<string>} routes  every path a body may link to
 * @param {string} origin  the site's own origin, such as https://waycar.dev
 * @returns {string[]}
 */
export function bodyProblems(body, where, routes, origin) {
  const text = body.replace(/^[ \t]*```[\s\S]*?^[ \t]*```/gm, '').replaceAll(origin, '');
  /** @type {string[]} */
  const problems = [];
  if (/^# /m.test(text)) problems.push(`${where}: the body must not contain an H1 (the page title is the H1)`);
  for (const [, href] of text.matchAll(/(?:\]\(|href="|^\[[^\]]+\]:\s*)(\/[^)\s"#?]*)/gm)) {
    if (href === '/install.sh') problems.push(`${where}: never link /install.sh (each GET of it logs an install event)`);
    else if (!routes.has(href)) problems.push(`${where}: link ${href} is not a published page`);
  }
  return problems;
}

/** The longest <title> a search result shows whole. */
export const TITLE_MAX = 60;

/**
 * The page's <title>: the short title when the page has one, with " · Waycar"
 * after it unless the title already says Waycar.
 * @param {string} title
 * @param {string} [metaTitle]
 * @returns {string}
 */
export function documentTitle(title, metaTitle) {
  const text = metaTitle ?? title;
  return /\bwaycar\b/i.test(text) ? text : `${text} · Waycar`;
}

/**
 * What is wrong with the <title> a page would get, or `undefined` when it fits
 * a search result.
 * @param {string} title
 * @param {string} [metaTitle]
 * @returns {string | undefined}
 */
export function titleProblem(title, metaTitle) {
  const full = documentTitle(title, metaTitle);
  return full.length > TITLE_MAX ? `the <title> "${full}" is ${full.length} characters, over ${TITLE_MAX}: set a shorter metaTitle` : undefined;
}
