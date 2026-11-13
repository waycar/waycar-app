// What the /compare and /solutions pages share: Markdown twins for agents (site
// links made absolute, the FAQ as a section, the closing lines), each page's
// schema.org JSON-LD, and the paths a page body may link to. The collections
// themselves are src/lib/compare.ts and src/lib/solutions.ts.
import { getCollection } from 'astro:content';
import { APP_SCHEMA_ID, APP_STORE_LISTING_URL, ON_APP_STORE } from '../data/links';
import { articlePath, getArticles } from './articles';
import { getHelpPages } from './help';

// `site` in astro.config.mjs, without the trailing slash.
export const SITE = import.meta.env.SITE.replace(/\/$/, '');

const LINK_PATTERN = /(?<!!)\[([^\]]*)\]\((\/[^)\s]*)\)/g;

export type Faq = { q: string; a: string };

/** A page body for a Markdown twin: site-relative links become absolute, and blank-line runs collapse. */
export function twinBody(body: string | undefined): string {
  return (body ?? '')
    .trim()
    .replace(LINK_PATTERN, (_, label: string, href: string) => `[${label}](${SITE}${href})`)
    .replace(/\n{3,}/g, '\n\n');
}

/** The closing lines of a twin: what Waycar is, where to get it, and the section the page belongs to. */
export function twinFooter(section: string, sectionPath: string): string {
  const about = ON_APP_STORE
    ? `Waycar: ${SITE}/help/what-is-waycar. On the App Store: ${APP_STORE_LISTING_URL}`
    : `Waycar: ${SITE}/help/what-is-waycar`;
  return `---\n\n${about}\n\n${section}: ${SITE}${sectionPath}\n`;
}

/**
 * JSON-LD for one landing page: a `WebPage` about the app, the page in its
 * section's breadcrumb, and its questions as a `FAQPage`. The questions are the
 * ones the page shows, word for word.
 */
export function landingSchema(page: {
  path: string;
  name: string;
  /** The page's last breadcrumb: the visible text, which can be shorter than `name`. */
  crumb: string;
  description: string;
  keywords: readonly string[];
  modified: string;
  section: { name: string; path: string };
  faq: readonly Faq[];
}): Record<string, unknown>[] {
  const url = `${SITE}${page.path}`;
  return [
    {
      '@context': 'https://schema.org',
      '@type': 'WebPage',
      name: page.name,
      keywords: page.keywords.join(', '),
      description: page.description,
      url,
      inLanguage: 'en',
      dateModified: page.modified,
      about: { '@id': `${SITE}${APP_SCHEMA_ID}` },
      isPartOf: { '@type': 'WebSite', name: 'Waycar', url: `${SITE}/` },
    },
    {
      '@context': 'https://schema.org',
      '@type': 'BreadcrumbList',
      itemListElement: [
        { '@type': 'ListItem', position: 1, name: page.section.name, item: `${SITE}${page.section.path}` },
        { '@type': 'ListItem', position: 2, name: page.crumb, item: url },
      ],
    },
    {
      '@context': 'https://schema.org',
      '@type': 'FAQPage',
      mainEntity: page.faq.map(({ q, a }) => ({
        '@type': 'Question',
        name: q,
        acceptedAnswer: { '@type': 'Answer', text: a },
      })),
    },
  ];
}

/** The items `ids` names, in the order `ids` lists them: the order a page's front matter chose. */
export const byId = <T extends { id: string }>(items: readonly T[], ids: readonly string[]): T[] =>
  ids.flatMap((id) => items.filter((item) => item.id === id));

// Pages that are not collection entries. A page body may link to any of them.
const FIXED_ROUTES = ['/', '/ipad', '/pricing', '/privacy', '/support', '/articles', '/changelog', '/compare', '/help', '/solutions'];

/** Every path a page body may link to: the fixed pages, plus each comparison, solution, published help page and article. */
export async function bodyRoutes(): Promise<Set<string>> {
  const [comparisons, solutions, help, articles] = await Promise.all([
    getCollection('compare'),
    getCollection('solutions'),
    getHelpPages(),
    getArticles(),
  ]);
  return new Set([
    ...FIXED_ROUTES,
    ...comparisons.map((entry) => `/compare/${entry.id}`),
    ...solutions.map((entry) => `/solutions/${entry.id}`),
    ...help.map((page) => `/help/${page.id}`),
    ...articles.map((article) => articlePath(article.id)),
  ]);
}
