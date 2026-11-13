// @ts-check
// Writes dist/sitemap.xml after the build from the pages themselves: every
// page with a canonical link and no robots noindex (see Layout.astro), by its
// canonical URL. A new page joins the sitemap on its own; the 404 page and
// home page B (canonical `/`) stay out.
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { listIndexablePages, renderSitemap } from '../scripts/site-pages.mjs';

/** @returns {import('astro').AstroIntegration} */
export default function sitemap() {
  return {
    name: 'waycar-sitemap',
    hooks: {
      'astro:build:done': ({ dir, logger }) => {
        const outDir = fileURLToPath(dir);
        const urls = listIndexablePages(outDir).map((page) => page.url);
        // An empty sitemap means Layout stopped emitting canonical links;
        // fail the build rather than deploy it.
        if (urls.length === 0) throw new Error(`sitemap: no indexable pages in ${outDir}`);
        writeFileSync(join(outDir, 'sitemap.xml'), renderSitemap(urls));
        logger.info(`sitemap.xml: ${urls.length} URLs`);
      },
    },
  };
}
