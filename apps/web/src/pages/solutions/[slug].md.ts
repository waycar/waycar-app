// /solutions/<slug>.md: a solution page as standalone Markdown for AI agents,
// linked from the page's `rel="alternate"` and from /solutions.md and /llms.txt.
import type { APIRoute, GetStaticPaths } from 'astro';
import { getSolutions, solutionMarkdown, type Solution } from '../../lib/solutions';

export const getStaticPaths = (async () =>
  (await getSolutions()).map((entry) => ({ params: { slug: entry.id }, props: { entry } }))) satisfies GetStaticPaths;

export const GET: APIRoute<{ entry: Solution }> = async ({ props }) =>
  new Response(await solutionMarkdown(props.entry), {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
