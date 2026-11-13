// The compare collection (src/content/compare/) as the compare routes use it:
// the comparisons in index order, checked across the collections, plus each
// page's Markdown twin and its line in the Markdown link lists (/compare.md and
// /llms.txt). Waycar's side of every table is src/data/compare-waycar.ts.
import { getCollection, type CollectionEntry } from 'astro:content';
import { WAYCAR_ROWS } from '../data/compare-waycar';
import { formatReleaseDate } from './changelog.mjs';
import { bodyProblems, markdownTable, relationProblems, rowProblems } from './compare-rows.mjs';
import { SITE, bodyRoutes, byId, twinBody, twinFooter } from './landing';

export type Comparison = CollectionEntry<'compare'>;

/** Public URL of a comparison. */
export const comparePath = (slug: string) => `/compare/${slug}`;
/** Its Markdown twin, for agents. */
export const compareMarkdownPath = (slug: string) => `/compare/${slug}.md`;

/**
 * Every comparison in index order. Throws (failing the build) when Waycar's
 * column misses a row or breaks a cell rule, a `related` slug names no
 * comparison or the page itself, a `solutions` slug names no solution page,
 * two comparisons share an `order`, or a body has an H1, links /install.sh or
 * links a page that does not exist. Each comparison's own rows are checked by
 * the schema in src/content.config.ts.
 */
export async function getComparisons(): Promise<Comparison[]> {
  const entries = (await getCollection('compare')).sort((a, b) => a.data.order - b.data.order);
  const solutionIds = new Set((await getCollection('solutions')).map((solution) => solution.id));
  const routes = await bodyRoutes();
  const problems = [
    ...rowProblems(WAYCAR_ROWS, 'src/data/compare-waycar.ts'),
    ...relationProblems(
      entries.map((entry) => ({
        id: entry.id,
        where: entry.filePath ?? entry.id,
        order: entry.data.order,
        related: entry.data.related,
        solutions: entry.data.solutions,
      })),
      solutionIds,
    ),
    ...entries.flatMap((entry) => bodyProblems(entry.body ?? '', entry.filePath ?? entry.id, routes, SITE)),
  ];
  if (problems.length > 0) throw new Error(`Comparison pages failed validation:\n- ${problems.join('\n- ')}`);
  return entries;
}

/**
 * The comparison as standalone Markdown for agents (`/compare/<slug>.md`): the
 * title as H1, the description as a lead, the short version, the side-by-side
 * table, the body, the questions, the sources, and the related pages. Site
 * links become absolute.
 */
export async function comparisonMarkdown(entry: Comparison): Promise<string> {
  const { title, description, name, checked, pickWaycar, pickThem, faq, sources, rows } = entry.data;
  const bullets = (items: string[]) => items.map((item) => `- ${item}`).join('\n');
  const others = byId(await getComparisons(), entry.data.related);
  const solutions = byId(await getCollection('solutions'), entry.data.solutions);
  const related = [
    ...others.map((other) => `- [${other.data.title}](${SITE}${comparePath(other.id)})`),
    ...solutions.map((solution) => `- [${solution.data.title}](${SITE}/solutions/${solution.id})`),
  ];
  return (
    `# ${title}\n\n${description}\n\n` +
    `Facts checked ${formatReleaseDate(checked)} against the sources listed at the end. Products change. "Not documented" means the maker's own pages say nothing either way, so we claim nothing. It does not mean No.\n\n` +
    `## The short version\n\n**Pick Waycar if:**\n\n${bullets(pickWaycar)}\n\n**Pick ${name} if:**\n\n${bullets(pickThem)}\n\n` +
    `## Side by side\n\n${markdownTable(WAYCAR_ROWS, rows, name)}\n\n` +
    `${twinBody(entry.body)}\n\n` +
    `## Questions people ask\n\n${faq.map(({ q, a }) => `### ${q}\n\n${a}`).join('\n\n')}\n\n` +
    `## Sources\n\n${sources.map(({ label, url }) => `- [${label}](${url})`).join('\n')}\n\n` +
    `Product names are trademarks of their owners. Waycar is an independent app from OTREVA, LLC. It is not affiliated with or endorsed by ${name}.\n\n` +
    `## Related\n\n${related.join('\n')}\n\n` +
    twinFooter('Waycar comparisons', '/compare')
  );
}

/** The comparison's line in the Markdown link lists: its title linking its Markdown twin, then its description. */
export const comparisonLinkLine = (entry: Comparison) =>
  `- [${entry.data.title}](${SITE}${compareMarkdownPath(entry.id)}): ${entry.data.description}`;
