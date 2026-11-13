// /help.md: every help page by category, as a Markdown link list for AI
// agents (linked from /help's `rel="alternate"` and from /llms.txt). Each
// link is the page's own Markdown twin.
import type { APIRoute } from 'astro';
import { getHelpPages, helpLinkLine, helpSections } from '../lib/help';

export const GET: APIRoute = async ({ site }) => {
  const url = (path: string) => new URL(path, site).href;
  const sections = helpSections(await getHelpPages()).map(
    ({ category, pages }) => `## ${category.label}\n\n${pages.map(helpLinkLine).join('\n')}`,
  );
  const body =
    '# Waycar Help\n\n' +
    `How to set up and use Waycar, the iPhone and iPad app for coding agents in herdr and tmux. One page per feature. Each link is the page as Markdown; the same URL without \`.md\` is the web page. Web index: ${url('/help')}\n\n` +
    `${sections.join('\n\n')}\n`;
  return new Response(body, { headers: { 'Content-Type': 'text/markdown; charset=utf-8' } });
};
