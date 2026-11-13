// /compare.md: every comparison as a Markdown link list for AI agents (linked
// from /compare's `rel="alternate"` and from /llms.txt). Each link is the
// comparison's own Markdown twin.
import type { APIRoute } from 'astro';
import { comparisonLinkLine, getComparisons } from '../lib/compare';

export const GET: APIRoute = async ({ site }) => {
  const comparisons = (await getComparisons()).map(comparisonLinkLine).join('\n');
  const body =
    '# Waycar Comparisons\n\n' +
    `How Waycar, the iPhone and iPad app for coding agents in herdr and tmux, compares with the tools people use to reach coding agents from a phone. Each page lists where Waycar is the better fit, where the other product is, and its sources. Each link is the comparison as Markdown; the same URL without \`.md\` is the web page. Web index: ${new URL('/compare', site).href}\n\n` +
    `${comparisons}\n`;
  return new Response(body, { headers: { 'Content-Type': 'text/markdown; charset=utf-8' } });
};
