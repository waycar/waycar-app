// @ts-check
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { buildSync } from 'esbuild';

// Bundle the production Worker, including its TypeScript imports, as Wrangler
// does. Redirects need no Cloudflare runtime or network access.
const { outputFiles } = buildSync({
  entryPoints: [fileURLToPath(new URL('../src/worker.ts', import.meta.url))],
  bundle: true,
  format: 'esm',
  platform: 'node',
  write: false,
});
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(outputFiles[0].text).toString('base64')}`);

test('retired pricing paths permanently redirect home with their query string', async () => {
  let assetRequests = 0;
  const env = {
    ASSETS: {
      async fetch() {
        assetRequests++;
        return new Response('Not found', { status: 404 });
      },
    },
  };
  const ctx = { waitUntil() { assert.fail('a pricing redirect must not send analytics'); } };

  for (const path of ['/pricing', '/pricing/', '/pricing.html']) {
    for (const method of ['GET', 'HEAD']) {
      for (const query of ['', '?utm_source=shared&from=old%20link&variant=b']) {
        const response = await worker.fetch(new Request(`https://waycar.dev${path}${query}`, { method }), env, ctx);
        assert.equal(response.status, 301, `${method} ${path}${query}`);
        assert.equal(response.headers.get('Location'), `https://waycar.dev/${query}`);
        assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
      }
    }
  }
  assert.equal(assetRequests, 0, 'redirects do not reach the asset server');
});
