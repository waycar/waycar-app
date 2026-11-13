// @ts-check
// Help search ranking, shared by the search palette (src/components/HelpSearch.astro)
// and its tests (scripts/help-search.test.mjs). Pure and dependency-free.
//
// Text is compared as tokens: lowercased, diacritics removed, split on
// anything that is not a letter or digit, except that an apostrophe inside a
// word is dropped rather than split on (`Can't` → `cant`). Every query term
// must match some field of a page, as a whole word, as the start of a word
// (search as you type), or, for terms of 5+ characters, as a word one edit
// away (insert, delete, substitute, or swap two neighbors). A term scores its
// best field weight times its match quality; a page scores the sum over its
// terms, plus a bonus when the whole query appears in its title. Ties keep
// index order (the help pages' global order).

/**
 * One page of /help/search.json (built by src/pages/help/search.json.ts).
 * @typedef {{ slug: string, title: string, description: string, category: string,
 *   keywords: string[], headings: string[], body: string }} HelpSearchPage
 */

/** @typedef {'title' | 'keywords' | 'headings' | 'description' | 'body'} Field */

/** Field weights, strongest first. @type {[Field, number][]} */
const FIELDS = [
  ['title', 10],
  ['keywords', 6],
  ['headings', 4],
  ['description', 3],
  ['body', 1],
];
const WHOLE_WORD = 1;
const PREFIX = 0.5;
const TYPO = 0.3;
const TYPO_MIN_LENGTH = 5;
const TITLE_PHRASE_BONUS = 8;

/**
 * Lowercase without diacritics: `Résumé` → `resume`.
 * @param {string} text
 */
export function normalize(text) {
  return text.normalize('NFKD').replace(/\p{M}+/gu, '').toLowerCase();
}

// A word: letters and digits, with any apostrophes inside it (`can't`).
// Combining marks count too, so a word in text that is not normalized yet
// (`highlight`, `excerpt`) matches whole.
const WORD = /[\p{L}\p{N}\p{M}]+(?:['’][\p{L}\p{N}\p{M}]+)*/gu;
const APOSTROPHES = /['’]/g;

/**
 * Normalized words of `text`, apostrophes dropped.
 * @param {string} text
 */
export function tokenize(text) {
  return normalize(text).match(WORD)?.map((word) => word.replace(APOSTROPHES, '')) ?? [];
}

/**
 * The query's distinct terms.
 * @param {string} query
 */
export function queryTerms(query) {
  return [...new Set(tokenize(query))];
}

/**
 * @typedef {{ page: HelpSearchPage, fields: Record<Field, string[]>, title: string }} IndexedPage
 * @typedef {{ pages: IndexedPage[], vocabulary: string[] }} HelpSearchIndex
 */

/**
 * Tokenize every page once; search with `searchHelp`.
 * @param {HelpSearchPage[]} pages
 * @returns {HelpSearchIndex}
 */
export function createSearchIndex(pages) {
  /** @type {Set<string>} */
  const vocabulary = new Set();
  /** @param {string} text */
  const words = (text) => {
    const tokens = [...new Set(tokenize(text))];
    for (const token of tokens) vocabulary.add(token);
    return tokens;
  };
  const indexed = pages.map((page) => ({
    page,
    title: tokenize(page.title).join(' '),
    fields: {
      title: words(page.title),
      keywords: words(page.keywords.join(' ')),
      headings: words(page.headings.join(' ')),
      description: words(page.description),
      body: words(page.body),
    },
  }));
  return { pages: indexed, vocabulary: [...vocabulary] };
}

/**
 * Optimal string alignment distance between `a` and `b`, or `max + 1` once
 * it exceeds `max`.
 * @param {string} a
 * @param {string} b
 * @param {number} max
 */
function editDistance(a, b, max) {
  if (Math.abs(a.length - b.length) > max) return max + 1;
  /** @type {number[][]} */
  const rows = [];
  for (let i = 0; i <= a.length; i++) {
    rows.push([i]);
    let best = i;
    for (let j = 1; j <= b.length; j++) {
      if (i === 0) {
        rows[0].push(j);
        continue;
      }
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let value = Math.min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        value = Math.min(value, rows[i - 2][j - 2] + 1);
      }
      rows[i].push(value);
      best = Math.min(best, value);
    }
    if (i > 0 && best > max) return max + 1;
  }
  return rows[a.length][b.length];
}

/**
 * How well each vocabulary word matches `term`: whole word, prefix, or typo.
 * @param {string} term
 * @param {string[]} vocabulary
 * @returns {Map<string, number>}
 */
function termMatches(term, vocabulary) {
  /** @type {Map<string, number>} */
  const matches = new Map();
  for (const word of vocabulary) {
    if (word === term) matches.set(word, WHOLE_WORD);
    else if (word.startsWith(term)) matches.set(word, PREFIX);
    else if (term.length >= TYPO_MIN_LENGTH && editDistance(term, word, 1) <= 1) matches.set(word, TYPO);
  }
  return matches;
}

/**
 * Pages matching every term of `query`, best first.
 * @param {HelpSearchIndex} index
 * @param {string} query
 * @param {{ limit?: number }} [options]
 * @returns {{ page: HelpSearchPage, score: number, words: Map<string, number> }[]} `words`: every
 *   indexed word some term matched, for `highlight` and `excerpt`
 */
export function searchHelp(index, query, { limit = Infinity } = {}) {
  const terms = queryTerms(query);
  if (terms.length === 0) return [];
  const perTerm = terms.map((term) => termMatches(term, index.vocabulary));
  if (perTerm.some((matches) => matches.size === 0)) return [];
  /** @type {Map<string, number>} every matched word, for highlighting */
  const matchedWords = new Map();
  for (const matches of perTerm) {
    for (const [word, quality] of matches) matchedWords.set(word, Math.max(quality, matchedWords.get(word) ?? 0));
  }
  const phrase = terms.join(' ');

  /** @type {{ page: HelpSearchPage, score: number, words: Map<string, number>, position: number }[]} */
  const results = [];
  index.pages.forEach((entry, position) => {
    let score = 0;
    for (const matches of perTerm) {
      let best = 0;
      for (const [field, weight] of FIELDS) {
        if (weight <= best) break;
        for (const word of entry.fields[field]) {
          const quality = matches.get(word);
          if (quality !== undefined) best = Math.max(best, weight * quality);
        }
      }
      if (best === 0) return;
      score += best;
    }
    if (` ${entry.title}`.includes(` ${phrase}`)) score += TITLE_PHRASE_BONUS;
    results.push({ page: entry.page, score, words: matchedWords, position });
  });
  results.sort((a, b) => b.score - a.score || a.position - b.position);
  return results.slice(0, limit).map(({ page, score, words }) => ({ page, score, words }));
}

/**
 * `text` split into plain and matched runs for highlighting; a word matches
 * when it is one of `words` (from a `searchHelp` result) or starts with a
 * query term.
 * @param {string} text
 * @param {string} query
 * @param {Map<string, number>} [words]
 * @returns {{ text: string, match: boolean }[]}
 */
export function highlight(text, query, words = new Map()) {
  const terms = queryTerms(query);
  /** @type {{ text: string, match: boolean }[]} */
  const parts = [];
  let last = 0;
  for (const found of text.matchAll(WORD)) {
    const word = normalize(found[0]).replace(APOSTROPHES, '');
    if (!words.has(word) && !terms.some((term) => word.startsWith(term))) continue;
    const start = found.index ?? 0;
    if (start > last) parts.push({ text: text.slice(last, start), match: false });
    parts.push({ text: found[0], match: true });
    last = start + found[0].length;
  }
  if (last < text.length) parts.push({ text: text.slice(last), match: false });
  return parts;
}

/**
 * A short excerpt for a result: the description when every query term
 * matches in it, else up to `length` characters of the body around the first
 * word matching a term the description lacks (the description again if only
 * the title or keywords have that term).
 * @param {HelpSearchPage} page
 * @param {string} query
 * @param {Map<string, number>} [words] from the `searchHelp` result, for typos
 * @param {number} [length]
 */
export function excerpt(page, query, words = new Map(), length = 160) {
  /**
   * @param {string} word
   * @param {string} term
   */
  const matches = (word, term) =>
    word.startsWith(term) || (term.length >= TYPO_MIN_LENGTH && words.has(word) && editDistance(term, word, 1) <= 1);
  const description = tokenize(page.description);
  const missing = queryTerms(query).find((term) => !description.some((word) => matches(word, term)));
  if (missing === undefined) return page.description;
  const hit = [...page.body.matchAll(WORD)].find((found) =>
    matches(normalize(found[0]).replace(APOSTROPHES, ''), missing),
  );
  if (!hit || hit.index === undefined) return page.description;
  let start = Math.max(0, hit.index - Math.floor(length / 3));
  if (start > 0) start = page.body.indexOf(' ', start) + 1 || start;
  let end = Math.min(page.body.length, start + length);
  if (end < page.body.length) end = page.body.lastIndexOf(' ', end) > hit.index ? page.body.lastIndexOf(' ', end) : end;
  return `${start > 0 ? '…' : ''}${page.body.slice(start, end).trim()}${end < page.body.length ? '…' : ''}`;
}
