// The articles collection (src/content/articles/) as the article routes use
// it: published posts newest first, plus each one's Markdown twin and its line
// in the Markdown link lists (/articles.md and /llms.txt). A post with
// `draft: true`, or dated after today, is not returned here, so it never
// reaches a page, the sitemap (built from the pages), or /llms.txt.
import { getCollection, type CollectionEntry } from 'astro:content';
import { APP_STORE_LISTING_URL, ON_APP_STORE } from '../data/links';
import { publishToday, publishedNewestFirst } from './articles-list.mjs';

export type Article = CollectionEntry<'articles'>;

/** Public URL of an article. */
export const articlePath = (slug: string) => `/articles/${slug}`;
/** Its Markdown twin, for agents. */
export const articleMarkdownPath = (slug: string) => `/articles/${slug}.md`;

/** Published articles, newest first (ties by slug). */
export async function getArticles(): Promise<Article[]> {
  return publishedNewestFirst(await getCollection('articles'), publishToday());
}

// `site` in astro.config.mjs, without the trailing slash.
const SITE = import.meta.env.SITE.replace(/\/$/, '');

const LINK_PATTERN = /(?<!!)\[([^\]]*)\]\((\/[^)\s]*)\)/g;

/**
 * The article as standalone Markdown for agents (`/articles/<slug>.md`): the
 * title as H1, the description as a lead, the date, the hero image (with its
 * alt text) when the article has one, then the body. Site-relative links
 * become absolute.
 */
export function articleMarkdown(article: Article): string {
  const text = (article.body ?? '')
    .trim()
    .replace(LINK_PATTERN, (_, label: string, href: string) => `[${label}](${SITE}${href})`)
    .replace(/\n{3,}/g, '\n\n');
  const about = ON_APP_STORE
    ? `Waycar: ${SITE}/help/what-is-waycar. On the App Store: ${APP_STORE_LISTING_URL}`
    : `Waycar: ${SITE}/help/what-is-waycar`;
  const { hero } = article.data;
  const image = hero ? `![${hero.alt}](${SITE}${hero.src})\n\n` : '';
  return (
    `# ${article.data.title}\n\n${article.data.description}\n\nPublished ${article.data.date}\n\n${image}${text}\n\n` +
    `---\n\n${about}\n\nWaycar Articles: ${SITE}${articlePath(article.id)}\n`
  );
}

/** The article's line in the Markdown link lists: its title linking its Markdown twin, then its description. */
export const articleLinkLine = (article: Article) =>
  `- [${article.data.title}](${SITE}${articleMarkdownPath(article.id)}): ${article.data.description}`;
