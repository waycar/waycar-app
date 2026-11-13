// /solutions.md: every solution page as a Markdown link list for AI agents
// (linked from /solutions's `rel="alternate"` and from /llms.txt). Each link is
// the page's own Markdown twin.
import type { APIRoute } from 'astro';
import { getSolutions, solutionLinkLine } from '../lib/solutions';

export const GET: APIRoute = async ({ site }) => {
  const solutions = (await getSolutions()).map(solutionLinkLine).join('\n');
  const body =
    '# Waycar Solutions\n\n' +
    `Plain answers to what people search for when they want to reach a coding agent from an iPhone or iPad: run Claude Code from a phone, use a mosh client or tmux on iOS, check an agent remotely. Each link is the page as Markdown; the same URL without \`.md\` is the web page. Web index: ${new URL('/solutions', site).href}\n\n` +
    `${solutions}\n`;
  return new Response(body, { headers: { 'Content-Type': 'text/markdown; charset=utf-8' } });
};
