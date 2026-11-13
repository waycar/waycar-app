// The solutions collection (src/content/solutions/) as the solutions routes use
// it: the pages in index order, checked across the collections, plus each
// page's Markdown twin and its line in the Markdown link lists (/solutions.md
// and /llms.txt).
import { getCollection, type CollectionEntry } from 'astro:content';
import { formatReleaseDate } from './changelog.mjs';
import { bodyProblems, solutionProblems } from './compare-rows.mjs';
import { getHelpPages } from './help';
import { SITE, bodyRoutes, byId, twinBody, twinFooter } from './landing';

export type Solution = CollectionEntry<'solutions'>;

/** Public URL of a solution page. */
export const solutionPath = (slug: string) => `/solutions/${slug}`;
/** Its Markdown twin, for agents. */
export const solutionMarkdownPath = (slug: string) => `/solutions/${slug}.md`;

/**
 * Every solution page in index order. Throws (failing the build) when a
 * `compare` slug names no comparison, a `help` slug names no published help
 * page (a page the release switch hides counts as missing), two pages share
 * an `order`, or a body has an H1, links /install.sh or links a page that does
 * not exist.
 */
export async function getSolutions(): Promise<Solution[]> {
  const entries = (await getCollection('solutions')).sort((a, b) => a.data.order - b.data.order);
  const compareIds = new Set((await getCollection('compare')).map((comparison) => comparison.id));
  const helpIds = new Set((await getHelpPages()).map((page) => page.id));
  const routes = await bodyRoutes();
  const problems = [
    ...solutionProblems(
      entries.map((entry) => ({
        id: entry.id,
        where: entry.filePath ?? entry.id,
        order: entry.data.order,
        compare: entry.data.compare,
        help: entry.data.help,
      })),
      compareIds,
      helpIds,
    ),
    ...entries.flatMap((entry) => bodyProblems(entry.body ?? '', entry.filePath ?? entry.id, routes, SITE)),
  ];
  if (problems.length > 0) throw new Error(`Solution pages failed validation:\n- ${problems.join('\n- ')}`);
  return entries;
}

/**
 * The page as standalone Markdown for agents (`/solutions/<slug>.md`): the
 * title as H1, the description as a lead, the short answer, what you need, the
 * body, the questions, and the related pages. Site links become absolute.
 */
export async function solutionMarkdown(entry: Solution): Promise<string> {
  const { title, description, answer, needs, updated, faq } = entry.data;
  const comparisons = byId(await getCollection('compare'), entry.data.compare);
  const help = byId(await getHelpPages(), entry.data.help);
  const related = [
    ...comparisons.map((comparison) => `- [${comparison.data.title}](${SITE}/compare/${comparison.id})`),
    ...help.map((page) => `- [${page.data.title}](${SITE}/help/${page.id})`),
  ];
  return (
    `# ${title}\n\n${description}\n\nUpdated ${formatReleaseDate(updated)}\n\n` +
    `**Short answer.** ${answer}\n\n` +
    `## What you need\n\n${needs.map((need) => `- ${need}`).join('\n')}\n\n` +
    `${twinBody(entry.body)}\n\n` +
    `## Questions people ask\n\n${faq.map(({ q, a }) => `### ${q}\n\n${a}`).join('\n\n')}\n\n` +
    `## Related\n\n${related.join('\n')}\n\n` +
    twinFooter('Waycar solutions', '/solutions')
  );
}

/** The page's line in the Markdown link lists: its title linking its Markdown twin, then its description. */
export const solutionLinkLine = (entry: Solution) =>
  `- [${entry.data.title}](${SITE}${solutionMarkdownPath(entry.id)}): ${entry.data.description}`;
