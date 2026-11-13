// /articles/<slug>.md: an article as standalone Markdown for AI agents, linked
// from the page's `rel="alternate"` and from /articles.md and /llms.txt.
import type { APIRoute, GetStaticPaths } from 'astro';
import { articleMarkdown, getArticles, type Article } from '../../lib/articles';

export const getStaticPaths = (async () =>
  (await getArticles()).map((article) => ({ params: { slug: article.id }, props: { article } }))) satisfies GetStaticPaths;

export const GET: APIRoute<{ article: Article }> = ({ props }) =>
  new Response(articleMarkdown(props.article), {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
