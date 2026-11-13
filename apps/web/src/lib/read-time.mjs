// Read time for an article page, worked out at build from its Markdown body.
// Code is skipped: readers skim a command, they do not read it like prose.

/** Words a reader gets through in a minute. */
export const WORDS_PER_MINUTE = 220;

/**
 * The prose words in a Markdown body: fenced code blocks (``` or ~~~) and HTML
 * tags are dropped, and only tokens with a letter or digit count.
 * @param {string} markdown
 * @returns {number}
 */
export function proseWords(markdown) {
  let fence = '';
  const prose = [];
  for (const line of markdown.split('\n')) {
    const marker = /^ {0,3}(`{3,}|~{3,})/.exec(line)?.[1];
    if (fence) {
      // A closing fence uses the same character, at least as long.
      if (marker && marker[0] === fence[0] && marker.length >= fence.length) fence = '';
    } else if (marker) {
      fence = marker;
    } else {
      prose.push(line);
    }
  }
  return prose
    .join(' ')
    .replace(/<[^>]*>/g, ' ')
    .split(/\s+/)
    .filter((token) => /[\p{L}\p{N}]/u.test(token)).length;
}

/**
 * Whole minutes to read `markdown`, never less than 1.
 * @param {string} markdown
 * @returns {number}
 */
export const readMinutes = (markdown) => Math.max(1, Math.round(proseWords(markdown) / WORDS_PER_MINUTE));
