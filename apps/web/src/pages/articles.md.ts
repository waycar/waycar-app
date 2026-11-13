// /articles.md: every published article as a Markdown link list for AI agents
// (linked from /articles's `rel="alternate"` and from /llms.txt). Each link is
// the article's own Markdown twin.
import type { APIRoute } from 'astro';
import { articleLinkLine, getArticles } from '../lib/articles';

export const GET: APIRoute = async ({ site }) => {
  const articles = (await getArticles()).map(articleLinkLine).join('\n');
  const body =
    '# Waycar Articles\n\n' +
    `Notes from the maker of Waycar, the iPhone and iPad app for coding agents in herdr and tmux. Each link is the article as Markdown; the same URL without \`.md\` is the web page. Web index: ${new URL('/articles', site).href}\n\n` +
    `${articles}\n`;
  return new Response(body, { headers: { 'Content-Type': 'text/markdown; charset=utf-8' } });
};
