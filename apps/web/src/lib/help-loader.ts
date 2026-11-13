// The help gate's loaders (src/data/unreleased.ts). While the gate holds,
// `helpLoader` gives the pages of src/content/help/ as the App Store build
// (`APP_STORE_RELEASE`) has them: same pipeline as the glob loader (Markdown
// through the context's `renderMarkdown`, as in src/lib/changelog-loader.ts),
// but a page in `HIDDEN_HELP_PAGES` is left out, `RELEASED_HELP_EDITS` are
// applied to the others, and hidden slugs leave each `related` list. The
// source pages are never touched. Once a newer release file exists, it is the
// plain glob loader and `unreleasedChangelogLoader` shows the Unreleased section.
import { readFile, readdir } from 'node:fs/promises';
import { basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { glob, type Loader, type LoaderContext } from 'astro/loaders';
import { APP_STORE_RELEASE, HIDDEN_HELP_PAGES, RELEASED_HELP_EDITS, type HelpEdit } from '../data/unreleased';
import { unreleasedLoader } from './changelog-loader';
import { hasNewerRelease } from './changelog.mjs';

/** True while no release file in src/content/changelog/ is newer than `APP_STORE_RELEASE`. */
async function gateHolds(root: URL): Promise<boolean> {
  const files = await readdir(new URL('./src/content/changelog/', root));
  const versions = files.filter((file) => file.endsWith('.md')).map((file) => file.slice(0, -'.md'.length));
  if (!versions.includes(APP_STORE_RELEASE)) {
    throw new Error(`src/data/unreleased.ts: APP_STORE_RELEASE ${APP_STORE_RELEASE} has no file in src/content/changelog/.`);
  }
  return !hasNewerRelease(versions, APP_STORE_RELEASE);
}

const FRONTMATTER = /^---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/;
const HEADING = /^(#{1,6})\s/;
const FENCE = /^\s*(```|~~~)/;

/** `lines` without the heading line `heading` and what follows it up to the next heading of the same or a higher level (fenced code is not scanned for headings). */
function dropSection(lines: string[], heading: string): string[] | undefined {
  const start = lines.findIndex((line) => line === heading);
  if (start < 0) return undefined;
  const level = heading.match(HEADING)?.[1].length ?? 1;
  let fenced = false;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (FENCE.test(lines[i])) fenced = !fenced;
    const marks = fenced ? undefined : lines[i].match(HEADING)?.[1].length;
    if (marks !== undefined && marks <= level) {
      end = i;
      break;
    }
  }
  return [...lines.slice(0, start), ...lines.slice(end)];
}

/** Applies `edits` to a page's text; an edit that matches nothing throws, naming the page. */
export function applyHelpEdits(slug: string, text: string, edits: readonly HelpEdit[]): string {
  let current = text;
  for (const edit of edits) {
    if ('replace' in edit) {
      if (!current.includes(edit.replace)) throw new Error(unmatched(slug, edit.replace));
      current = current.replaceAll(edit.replace, () => edit.with);
      continue;
    }
    let lines = current.split('\n');
    if ('dropSection' in edit) {
      const next = dropSection(lines, edit.dropSection);
      if (!next) throw new Error(unmatched(slug, edit.dropSection));
      lines = next;
    } else {
      const needle = 'dropLine' in edit ? edit.dropLine : edit.setLine;
      if (!lines.some((line) => line.includes(needle))) throw new Error(unmatched(slug, needle));
      lines =
        'dropLine' in edit
          ? lines.filter((line) => !line.includes(needle))
          : lines.map((line) => (line.includes(needle) ? edit.to : line));
    }
    current = lines.join('\n');
  }
  return current;
}

const unmatched = (slug: string, text: string) =>
  `src/data/unreleased.ts: an edit for help page "${slug}" matches nothing (${JSON.stringify(text.slice(0, 80))}). ` +
  'The page changed: update its entry in RELEASED_HELP_EDITS.';

/** 1.3.0 has no Codex or OpenCode 2 server runtime. */
const UNRELEASED_TERMS = /Codex server|Codex thread|OpenCode 2|OpenCode server/;

/** A released page that names the Codex or OpenCode server runtime promises what 1.3.0 lacks. */
function checkUnreleasedTerms(slug: string, text: string): void {
  const found = UNRELEASED_TERMS.exec(text)?.[0];
  if (found) {
    throw new Error(
      `src/content/help/${slug}.md still says "${found}" after RELEASED_HELP_EDITS (the help gate holds): add an edit for it in src/data/unreleased.ts.`,
    );
  }
}

/** A body link to a hidden page would be a 404 on the released site. */
function checkLinks(slug: string, text: string): void {
  for (const hidden of HIDDEN_HELP_PAGES) {
    if (new RegExp(`\\]\\(/help/${hidden}(?:[)#.])`).test(text)) {
      throw new Error(
        `src/content/help/${slug}.md links the hidden help page "${hidden}" (the help gate holds): add an edit for it in RELEASED_HELP_EDITS.`,
      );
    }
  }
}

/** The help collection: as released while the gate holds, else the glob loader. */
export function helpLoader(): Loader {
  const all = glob({ base: './src/content/help', pattern: '*.md' });
  return {
    name: 'waycar-help',
    load: async (context) => ((await gateHolds(context.config.root)) ? loadReleased(context) : all.load(context)),
  };
}

/** The changelog's Unreleased section, empty while the gate holds. */
export function unreleasedChangelogLoader(): Loader {
  const unreleased = unreleasedLoader();
  return {
    name: 'waycar-changelog-unreleased-gated',
    load: async (context) => ((await gateHolds(context.config.root)) ? context.store.clear() : unreleased.load(context)),
  };
}

async function loadReleased({ config, store, parseData, renderMarkdown, generateDigest }: LoaderContext): Promise<void> {
  const dir = new URL('./src/content/help/', config.root);
  const files = (await readdir(dir)).filter((file) => file.endsWith('.md')).sort().map((file) => `src/content/help/${file}`);
  const known = new Set(files.map((file) => basename(file, '.md')));
  for (const edited of Object.keys(RELEASED_HELP_EDITS)) {
    if (!known.has(edited)) throw new Error(`src/data/unreleased.ts: RELEASED_HELP_EDITS names "${edited}", which is not a help page.`);
  }
  for (const hidden of HIDDEN_HELP_PAGES) {
    if (!known.has(hidden)) throw new Error(`src/data/unreleased.ts: HIDDEN_HELP_PAGES names "${hidden}", which is not a help page.`);
  }
  const hidden = new Set(HIDDEN_HELP_PAGES);
  store.clear();
  await Promise.all(
    files.map(async (file) => {
      const id = basename(file, '.md');
      if (hidden.has(id)) return;
      const fileURL = new URL(file, config.root);
      const original = await readFile(fileURL, 'utf8');
      const text = applyHelpEdits(id, original, RELEASED_HELP_EDITS[id] ?? []);
      checkLinks(id, text);
      checkUnreleasedTerms(id, text);
      const frontmatter = FRONTMATTER.exec(text)?.[0] ?? '';
      const rendered = await renderMarkdown(text, { fileURL });
      const data = { ...(rendered.metadata?.frontmatter ?? {}) } as Record<string, unknown>;
      if (Array.isArray(data.related)) data.related = data.related.filter((slug) => !hidden.has(String(slug)));
      store.set({
        id,
        data: await parseData({ id, data, filePath: fileURLToPath(fileURL) }),
        body: text.slice(frontmatter.length),
        filePath: file,
        digest: generateDigest(text),
        rendered,
        assetImports: rendered.metadata?.imagePaths,
      });
    }),
  );
}
