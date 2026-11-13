// @ts-check
import { readFile } from 'node:fs/promises';
import { satteri } from '@astrojs/markdown-satteri';
import { defineConfig } from 'astro/config';
import { imageMetadata } from 'astro/assets/utils';
import sitemap from './integrations/sitemap.mjs';

// Help page images (src/content/help/) are shown at most 640px tall
// (`.prose img` in src/components/Prose.astro) and no wider than the article column
// (72ch, under 720px). Each ships at the width it is shown at, with a 2x copy
// in its srcset, so a phone screenshot is about 300px wide rather than its
// full 1320px. (Densities rather than `widths`: the Markdown pipeline turns a
// `widths` array into strings, which makes Astro emit the 1x file twice.) The
// page's first image is near the top, so it loads eagerly at high priority.
// The content layer caches rendered pages in node_modules/.astro/data-store.json
// and does not notice edits here: delete that file after changing this plugin.
const HELP_IMAGE_MAX_HEIGHT = 640;
const HELP_COLUMN_MAX_WIDTH = 720;
/** @type {NonNullable<import('@astrojs/markdown-satteri').SatteriProcessorOptions['hastPlugins']>[number]} */
const helpImages = ({ fileURL }) => {
  if (!fileURL?.pathname.includes('/src/content/help/')) return false;
  let first = true;
  return {
    name: 'help-images',
    element: {
      filter: ['img'],
      async visit(node, ctx) {
        const src = node.properties?.src;
        if (typeof src !== 'string' || src.startsWith('/') || URL.canParse(src)) return;
        if (first) ctx.setProperty(node, 'priority', true);
        first = false;
        const file = new URL(decodeURI(src), fileURL);
        const { width, height } = await imageMetadata(await readFile(file), file.pathname);
        const shown = Math.min(HELP_COLUMN_MAX_WIDTH, Math.round((HELP_IMAGE_MAX_HEIGHT * width) / height));
        ctx.setProperty(node, 'width', shown);
        ctx.setProperty(node, 'densities', [1, 2]);
      },
    },
  };
};

// Static output, served from `dist/` by the Worker in src/worker.ts (see
// wrangler.toml). Client JavaScript is Astro-bundled same-origin modules only:
// CodeBlock's copy button, the help search palette (HelpSearch.astro), the
// help sidebar's collapse on narrow screens (HelpLayout.astro), the
// changelog's infinite scroll (src/pages/changelog/[...page].astro), and the
// PostHog analytics module in src/layouts/Layout.astro.
export default defineConfig({
  site: 'https://waycar.dev',
  build: {
    // Emit `/404.html` rather than `/404/index.html` so the Workers asset
    // router picks it up as the not-found page.
    format: 'file',
  },
  // sitemap.xml from the built pages' canonical URLs (integrations/sitemap.mjs).
  integrations: [sitemap()],
  markdown: {
    // Help pages' fenced code takes its colors from CSS variables mapped to
    // the terminal tokens (global.css), not from a bundled theme.
    shikiConfig: { theme: 'css-variables' },
    processor: satteri({ hastPlugins: [helpImages] }),
  },
  vite: {
    build: {
      // Never inline scripts: the Worker's CSP is `script-src 'self'` with no
      // 'unsafe-inline', so every script must be an external file. Other
      // assets keep Vite's default size rule.
      assetsInlineLimit: (filePath) => (filePath.endsWith('.js') ? false : undefined),
    },
  },
});
