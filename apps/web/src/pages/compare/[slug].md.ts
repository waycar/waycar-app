// /compare/<slug>.md: a comparison as standalone Markdown for AI agents, linked
// from the page's `rel="alternate"` and from /compare.md and /llms.txt.
import type { APIRoute, GetStaticPaths } from 'astro';
import { comparisonMarkdown, getComparisons, type Comparison } from '../../lib/compare';

export const getStaticPaths = (async () =>
  (await getComparisons()).map((entry) => ({ params: { slug: entry.id }, props: { entry } }))) satisfies GetStaticPaths;

export const GET: APIRoute<{ entry: Comparison }> = async ({ props }) =>
  new Response(await comparisonMarkdown(props.entry), {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
