// Which articles are public and in what order. Plain JavaScript so
// scripts/articles.test.mjs can run it under `node --test`.

// The zone an article's `date` is read in: the maker's, so a post dated D is
// due from midnight on D there, not from 8 pm the evening before. The site
// changes at the first deploy after that.
const PUBLISH_TIME_ZONE = 'America/New_York';

/**
 * Today's date as `YYYY-MM-DD` in the zone article dates are read in.
 * @param {Date} [now]
 * @returns {string}
 */
export function publishToday(now = new Date()) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', {
      timeZone: PUBLISH_TIME_ZONE,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    })
      .formatToParts(now)
      .map(({ type, value }) => [type, value]),
  );
  return `${parts.year}-${parts.month}-${parts.day}`;
}

/**
 * Published articles, newest first (ties by id). An article with
 * `draft: true`, or with a `date` after `today`, is dropped, so it never
 * reaches a page, the sitemap, or /llms.txt. A post dated for a later day
 * therefore goes live on the first build on or after that day; the daily
 * deploy in .github/workflows/web.yml makes that the same morning. Does not
 * sort `entries` in place.
 * @template {{ id: string, data: { date: string, draft?: boolean } }} T
 * @param {readonly T[]} entries
 * @param {string} today `YYYY-MM-DD`, from publishToday
 * @returns {T[]}
 */
export function publishedNewestFirst(entries, today) {
  // A malformed `today` (say `NaN-NaN-NaN`) sorts after every date and would
  // publish every scheduled post, so stop the build instead.
  if (!/^\d{4}-\d{2}-\d{2}$/.test(today)) {
    throw new Error(`publishedNewestFirst: today must be YYYY-MM-DD, got "${today}"`);
  }
  return entries
    .filter(({ data }) => data.draft !== true && data.date <= today)
    .sort((a, b) => b.data.date.localeCompare(a.data.date) || a.id.localeCompare(b.id));
}
