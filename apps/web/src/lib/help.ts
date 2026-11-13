// The help collection (src/content/help/) as the help routes use it: pages in
// global order (category order from src/content/help/categories.json, then
// `order`), checked across the collection, plus the Markdown twin and the
// search index entry built from each page.
import type { MarkdownHeading } from 'astro';
import { getCollection, type CollectionEntry } from 'astro:content';
import { decodeEntities } from '../../scripts/site-pages.mjs';
import { HELP_CATEGORIES, helpCategory, helpMarkdownPath, helpPath, type HelpCategory } from '../data/help';
import type { HelpSearchPage } from './help-search.mjs';

export type HelpPage = CollectionEntry<'help'>;
export type HelpSection = { category: HelpCategory; pages: HelpPage[] };

/**
 * Every help page in global order. Throws (failing the build) when a `related`
 * slug names no page or the page itself, or two pages in one category share
 * an `order`.
 */
export async function getHelpPages(): Promise<HelpPage[]> {
  const pages = await getCollection('help');
  const rank = (page: HelpPage) => HELP_CATEGORIES.findIndex((category) => category.id === page.data.category);
  pages.sort((a, b) => rank(a) - rank(b) || a.data.order - b.data.order);

  const ids = new Set(pages.map((page) => page.id));
  const problems: string[] = [];
  const orders = new Map<string, string>();
  for (const page of pages) {
    const where = page.filePath ?? page.id;
    for (const slug of page.data.related) {
      if (slug === page.id) problems.push(`${where}: related lists the page itself (${slug})`);
      else if (!ids.has(slug)) problems.push(`${where}: related slug "${slug}" is not a help page`);
    }
    const key = `${page.data.category}/${page.data.order}`;
    const other = orders.get(key);
    if (other) problems.push(`${where}: order ${page.data.order} in ${page.data.category} is also used by ${other}`);
    orders.set(key, where);
  }
  if (problems.length > 0) throw new Error(`Help pages failed validation:\n- ${problems.join('\n- ')}`);
  return pages;
}

/** Categories in display order with their pages; empty categories left out. */
export function helpSections(pages: HelpPage[]): HelpSection[] {
  return HELP_CATEGORIES.map((category) => ({
    category,
    pages: pages.filter((page) => page.data.category === category.id),
  })).filter((section) => section.pages.length > 0);
}

export const categoryLabel = (page: HelpPage) => helpCategory(page.data.category).label;

// `site` in astro.config.mjs, without the trailing slash.
const SITE = import.meta.env.SITE.replace(/\/$/, '');

const IMAGE_PATTERN = /!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
const LINK_PATTERN = /(?<!!)\[([^\]]*)\]\((\/[^)\s]*)\)/g;

/**
 * The page as standalone Markdown for agents (`/help/<slug>.md`): the title as
 * H1, the description as a lead, then the body. Site-relative links become
 * absolute. Each image becomes a `Screenshot: <alt text>` line: linking an
 * optimized copy would mean importing the screen here, and an imported image
 * no page transforms ships its full-size original in dist/_astro.
 */
export function helpMarkdown(page: HelpPage): string {
  const text = (page.body ?? '')
    .trim()
    .replace(IMAGE_PATTERN, (_, alt: string) => (alt.trim() ? `Screenshot: ${alt.trim()}` : ''))
    .replace(LINK_PATTERN, (_, text: string, href: string) => `[${text}](${SITE}${href})`)
    .replace(/\n{3,}/g, '\n\n');
  const category = categoryLabel(page);
  return (
    `# ${page.data.title}\n\n${page.data.description}\n\n${text}\n\n` +
    `---\n\nWaycar Help › ${category}: ${SITE}${helpPath(page.id)}\n`
  );
}

/**
 * The page's line in the Markdown link lists (/help.md and /llms.txt): its
 * title linking its Markdown twin, then its description.
 */
export const helpLinkLine = (page: HelpPage) =>
  `- [${page.data.title}](${SITE}${helpMarkdownPath(page.id)}): ${page.data.description}`;

/** Page text without markup, from the rendered HTML (code included). */
export function plainText(html: string): string {
  return decodeEntities(
    html
      .replace(/<(script|style|svg)\b[\s\S]*?<\/\1\s*>/gi, ' ')
      .replace(/<\/?(?:p|h[1-6]|li|ul|ol|pre|blockquote|table|tr|td|th|div|br)\b[^>]*>/gi, ' ')
      .replace(/<[^>]+>/g, ''),
  )
    .replace(/\s+/g, ' ')
    .trim();
}

/** The page's entry in /help/search.json (ranked by src/lib/help-search.mjs). */
export function searchEntry(page: HelpPage): HelpSearchPage {
  // The glob loader renders Markdown at sync time; `metadata` is untyped.
  const headings = ((page.rendered?.metadata?.headings ?? []) as MarkdownHeading[])
    .filter((heading) => heading.depth === 2 || heading.depth === 3)
    .map((heading) => heading.text);
  return {
    slug: page.id,
    title: page.data.title,
    description: page.data.description,
    category: categoryLabel(page),
    keywords: page.data.keywords,
    headings,
    body: plainText(page.rendered?.html ?? ''),
  };
}
