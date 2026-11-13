// Content loaders for the changelog (README "Changelog"). Both render through
// the site's Markdown pipeline (the loader context's `renderMarkdown`) after
// stripping issue and pull request references from the body
// (src/lib/changelog.mjs), which point into the private repository; the
// source files keep them.
//
// - `releasesLoader`: one entry per src/content/changelog/<X.Y.Z>.md, id the
//   version. The front matter goes through the collection schema; a file
//   whose name is not its `version` fails the build.
// - `unreleasedLoader`: the `## [Unreleased]` section of the repo-root
//   CHANGELOG.md as one entry, id `unreleased`, or none when it has no bullet.
//   The site reads it through the help gate (src/lib/help-loader.ts).
//
// In `astro dev` each loader watches its files and syncs again on a change,
// one sync at a time.
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import type { MarkdownHeading } from 'astro';
import type { Loader, LoaderContext } from 'astro/loaders';
import { releaseAnchor, scopeHeadingIds, stripRefs, unreleasedBody } from './changelog.mjs';

/** What the loader context's `renderMarkdown` returns (Astro's `RenderedContent`, not exported by name). */
interface Rendered {
  html: string;
  metadata?: { headings?: MarkdownHeading[]; frontmatter?: Record<string, unknown>; [key: string]: unknown };
}

type Watcher = NonNullable<LoaderContext['watcher']>;

/** A Markdown file's YAML front matter block, with its closing line break. */
const FRONTMATTER = /^---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/;

/** `rendered` with its heading ids scoped to the entry (`v1-1-3-added`). */
function scoped(rendered: Rendered, prefix: string): Rendered {
  const { html, headings } = scopeHeadingIds(rendered.html, rendered.metadata?.headings ?? [], prefix);
  return { html, metadata: { ...rendered.metadata, headings } };
}

/**
 * Runs a loader's syncs one after another and, in `astro dev`, syncs again
 * when a file under `files` changes. `load()` runs again on every content
 * config change with a fresh context, so a watcher gets its listener once and
 * a change always runs the newest `sync`.
 */
function syncRunner() {
  let latest: (() => Promise<void>) | undefined;
  let queue: Promise<void> = Promise.resolve();
  const watched = new WeakSet<Watcher>();

  const run = () => {
    const sync = latest;
    const next = queue.then(() => sync?.());
    queue = next.catch(() => undefined);
    return next;
  };

  return async ({ watcher, logger }: LoaderContext, files: string[], sync: () => Promise<void>) => {
    latest = sync;
    if (watcher && !watched.has(watcher)) {
      watched.add(watcher);
      watcher.add(files);
      const onChange = (changed: string) => {
        if (!files.some((path) => changed === path || changed.startsWith(path))) return;
        run().catch((error: unknown) => logger.error(`changelog: ${String(error)}`));
      };
      watcher.on('change', onChange);
      watcher.on('add', onChange);
      watcher.on('unlink', onChange);
    }
    await run();
  };
}

export function releasesLoader(): Loader {
  const runner = syncRunner();
  return {
    name: 'waycar-changelog-releases',
    load: async (context) => {
      const { config, store, parseData, renderMarkdown, generateDigest } = context;
      const releases = new URL('./src/content/changelog/', config.root);
      await runner(context, [fileURLToPath(releases)], async () => {
        const files = (await readdir(releases)).filter((file) => file.endsWith('.md')).sort();
        const entries = await Promise.all(
          files.map(async (file) => {
            const fileURL = new URL(file, releases);
            const filePath = fileURLToPath(fileURL);
            const contents = await readFile(fileURL, 'utf8');
            const frontmatter = FRONTMATTER.exec(contents)?.[0] ?? '';
            const body = contents.slice(frontmatter.length);
            const id = file.slice(0, -'.md'.length);
            const rendered: Rendered = await renderMarkdown(frontmatter + stripRefs(body), { fileURL });
            const data = await parseData({ id, data: rendered.metadata?.frontmatter ?? {}, filePath });
            if (data.version !== id) {
              throw new Error(`${filePath}: version ${String(data.version)} does not match the file name ${file}`);
            }
            return {
              id,
              data,
              body: body.trim(),
              filePath: `src/content/changelog/${file}`,
              digest: generateDigest(contents),
              rendered: scoped(rendered, releaseAnchor(id)),
            };
          }),
        );
        store.clear();
        for (const entry of entries) store.set(entry);
      });
    },
  };
}

export function unreleasedLoader(): Loader {
  const runner = syncRunner();
  return {
    name: 'waycar-changelog-unreleased',
    load: async (context) => {
      const { config, store, parseData, renderMarkdown, generateDigest } = context;
      const fileURL = new URL('../../CHANGELOG.md', config.root);
      await runner(context, [fileURLToPath(fileURL)], async () => {
        const body = unreleasedBody(await readFile(fileURL, 'utf8'));
        store.clear();
        if (body === null) return;
        const id = 'unreleased';
        const rendered: Rendered = await renderMarkdown(stripRefs(body), { fileURL });
        store.set({
          id,
          data: await parseData({ id, data: {} }),
          body,
          digest: generateDigest(body),
          rendered: scoped(rendered, id),
        });
      });
    },
  };
}
