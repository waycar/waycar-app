// Content collections. `help`: one Markdown page per Waycar feature in
// src/content/help/<slug>.md, served at /help/<slug> (README "Help docs").
// Checks that need the whole collection (every `related` slug exists and is
// not the page itself, one page per category order) run in src/lib/help.ts.
// `changelog`: one released version per src/content/changelog/<X.Y.Z>.md, and
// `changelogUnreleased`: the `## [Unreleased]` section of the repo-root
// CHANGELOG.md, both shown at /changelog (README "Changelog"; loaders in
// src/lib/changelog-loader.ts).
// `articles`: thought-leadership posts in src/content/articles/<slug>.md,
// served at /articles/<slug> (README "Articles"); `draft: true`, or a `date`
// that has not come yet, hides one from every route, the sitemap, and
// /llms.txt (src/lib/articles.ts).
// `compare`: one honest comparison per product in src/content/compare/<slug>.md,
// served at /compare/<slug>, and `solutions`: one landing page per search
// intent in src/content/solutions/<slug>.md, served at /solutions/<slug>
// (README "Compare and solutions"). The comparison rows are src/lib/compare-rows.mjs;
// checks across the collections run in src/lib/compare.ts and src/lib/solutions.ts.
import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';
import { HELP_CATEGORY_IDS } from './data/help';
import { isVersion } from './lib/changelog.mjs';
import { CAPABILITY_IDS, CELL_MAX, KINDS, LEVELS, TITLE_MAX, cellProblem, levelProblem, titleProblem } from './lib/compare-rows.mjs';
import { releasesLoader } from './lib/changelog-loader';
import { helpLoader, unreleasedChangelogLoader } from './lib/help-loader';

const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

// While the help gate holds (src/data/unreleased.ts) the help pages are the
// App Store build's and the Unreleased changelog section is hidden.
const help = defineCollection({
  loader: helpLoader(),
  schema: z.strictObject({
    title: z.string().trim().min(1).max(60),
    description: z.string().trim().min(70).max(160),
    category: z.enum(HELP_CATEGORY_IDS),
    order: z.number().int().positive(),
    keywords: z
      .array(
        z
          .string()
          .trim()
          .min(1)
          .refine((keyword) => keyword === keyword.toLowerCase(), 'keywords must be lowercase'),
      )
      .min(3)
      .max(10),
    related: z
      .array(z.string().regex(SLUG, 'related entries must be help page slugs'))
      .min(2)
      .max(4)
      .refine((slugs) => new Set(slugs).size === slugs.length, 'related slugs must be unique'),
  }),
});

// YAML reads an unquoted `date: 2026-10-04` as a Date; either way the entry
// keeps the date as `YYYY-MM-DD`, and a time of day fails the build.
const releaseDate = z.union([
  z.iso.date(),
  z
    .date()
    .refine((date) => date.getTime() % 86_400_000 === 0, 'date must be YYYY-MM-DD, without a time')
    .transform((date) => date.toISOString().slice(0, 10)),
]);

const changelog = defineCollection({
  loader: releasesLoader(),
  schema: z.strictObject({
    version: z.string().refine(isVersion, 'version must be X.Y.Z'),
    date: releaseDate,
  }),
});

const articles = defineCollection({
  loader: glob({ base: './src/content/articles', pattern: '*.md' }),
  schema: z.strictObject({
    title: z.string().trim().min(1).max(90),
    description: z.string().trim().min(70).max(200),
    date: releaseDate,
    draft: z.boolean().optional(),
    setupPrompt: z.boolean().optional(),
    // The real graphic under the title band (README "Articles"). A file in
    // public/articles/, shown once at container width; a page without one gets
    // the text band with a glow. `zoom` is the lightbox's sharper twin of an
    // animated GIF. `width` and `height` are the file's pixels, so the image
    // reserves its box before it loads.
    hero: z
      .strictObject({
        src: z.string().regex(/^\/articles\/[\w.-]+$/, 'hero src is a file in public/articles/'),
        alt: z.string().trim().min(20).max(400),
        width: z.number().int().positive(),
        height: z.number().int().positive(),
        zoom: z.string().regex(/^\/articles\/[\w.-]+$/, 'hero zoom is a file in public/articles/').optional(),
      })
      .optional(),
    keywords: z
      .array(
        z
          .string()
          .trim()
          .min(1)
          .refine((keyword) => keyword === keyword.toLowerCase(), 'keywords must be lowercase'),
      )
      .min(3)
      .max(10),
  }),
});

// What `compare` and `solutions` share: the same keyword rule as `articles`,
// lists of page slugs (checked against the collections in src/lib/compare.ts
// and src/lib/solutions.ts), and a question and answer list shown on the page
// and in its Markdown twin.
const keywords = z
  .array(
    z
      .string()
      .trim()
      .min(1)
      .refine((keyword) => keyword === keyword.toLowerCase(), 'keywords must be lowercase'),
  )
  .min(3)
  .max(10);

const slugList = (min: number, max: number) =>
  z
    .array(z.string().regex(SLUG, 'entries must be page slugs'))
    .min(min)
    .max(max)
    .refine((slugs) => new Set(slugs).size === slugs.length, 'slugs must be unique');

const faq = z
  .array(
    z.strictObject({
      q: z.string().trim().min(10).max(120),
      a: z.string().trim().min(40).max(600),
    }),
  )
  .min(3)
  .max(6);

const httpsUrl = z.url().refine((url) => url.startsWith('https://'), 'must be an https URL');

// One cell of a comparison table: a level and a short text that starts with
// the level's word (src/lib/compare-rows.mjs).
const cell = z.strictObject({ level: z.enum(LEVELS), text: z.string().trim().min(1).max(CELL_MAX) }).superRefine((value, ctx) => {
  const problem = cellProblem(value);
  if (problem) ctx.addIssue({ code: 'custom', message: problem });
});

const compare = defineCollection({
  loader: glob({ base: './src/content/compare', pattern: '*.md' }),
  schema: z.strictObject({
    title: z.string().trim().min(1).max(70),
    // The <title>, without " · Waycar" (added unless it already says Waycar). Set it
    // when `title` makes a <title> too long for a search result.
    metaTitle: z.string().trim().min(1).max(TITLE_MAX).optional(),
    description: z.string().trim().min(70).max(165),
    name: z.string().trim().min(1).max(40),
    kind: z.enum(KINDS),
    summary: z.string().trim().min(40).max(200),
    // The day the facts below were last checked against the sources.
    checked: releaseDate,
    order: z.number().int().positive(),
    keywords,
    // Every capability row, by id: a missing or extra id fails the build, and so
    // does a rating on a descriptive row or none on a rated one.
    rows: z.strictObject(Object.fromEntries(CAPABILITY_IDS.map((id) => [id, cell]))).superRefine((rows, ctx) => {
      for (const [id, value] of Object.entries(rows)) {
        const problem = levelProblem(id, value);
        if (problem) ctx.addIssue({ code: 'custom', path: [id], message: `"${id}" ${problem}` });
      }
    }),
    pickWaycar: z.array(z.string().trim().min(10).max(200)).min(3).max(5),
    pickThem: z.array(z.string().trim().min(10).max(200)).min(3).max(5),
    faq,
    sources: z.array(z.strictObject({ label: z.string().trim().min(1).max(90), url: httpsUrl })).min(2).max(12),
    related: slugList(2, 4),
    solutions: slugList(1, 3),
  }).superRefine((page, ctx) => {
    const problem = titleProblem(page.title, page.metaTitle);
    if (problem) ctx.addIssue({ code: 'custom', path: ['metaTitle'], message: problem });
  }),
});

const solutions = defineCollection({
  loader: glob({ base: './src/content/solutions', pattern: '*.md' }),
  schema: z.strictObject({
    title: z.string().trim().min(1).max(70),
    metaTitle: z.string().trim().min(1).max(TITLE_MAX).optional(),
    description: z.string().trim().min(70).max(165),
    // The search phrase the page answers.
    query: z
      .string()
      .trim()
      .min(3)
      .max(60)
      .refine((query) => query === query.toLowerCase(), 'query must be lowercase'),
    summary: z.string().trim().min(40).max(200),
    // The short answer, shown first.
    answer: z.string().trim().min(60).max(420),
    needs: z.array(z.string().trim().min(10).max(160)).min(3).max(6),
    order: z.number().int().positive(),
    updated: releaseDate,
    keywords,
    faq,
    compare: slugList(1, 3),
    help: slugList(2, 4),
  }).superRefine((page, ctx) => {
    const problem = titleProblem(page.title, page.metaTitle);
    if (problem) ctx.addIssue({ code: 'custom', path: ['metaTitle'], message: problem });
  }),
});

const changelogUnreleased = defineCollection({
  loader: unreleasedChangelogLoader(),
  schema: z.strictObject({}),
});

export const collections = { help, changelog, changelogUnreleased, articles, compare, solutions };
