// /help/search.json: the help search index, built from the help collection
// and fetched by the search palette (src/components/HelpSearch.astro) the
// first time it opens. Ranking lives in src/lib/help-search.mjs.
import type { APIRoute } from 'astro';
import { getHelpPages, searchEntry } from '../../lib/help';

export const GET: APIRoute = async () => {
  const pages = await getHelpPages();
  return new Response(JSON.stringify(pages.map(searchEntry)), {
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
};
