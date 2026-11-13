// /help/<slug>.md: a help page as standalone Markdown for AI agents, linked
// from the page's `rel="alternate"` and from /help.md and /llms.txt.
import type { APIRoute, GetStaticPaths } from 'astro';
import { getHelpPages, helpMarkdown, type HelpPage } from '../../lib/help';

export const getStaticPaths = (async () =>
  (await getHelpPages()).map((page) => ({ params: { slug: page.id }, props: { page } }))) satisfies GetStaticPaths;

export const GET: APIRoute<{ page: HelpPage }> = ({ props }) =>
  new Response(helpMarkdown(props.page), {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
