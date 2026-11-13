// @ts-check
// Builds the site for a script test and hands back the output folder.
//
// The output goes inside the project: Astro renames build assets across the
// output dir, which fails across devices (EXDEV) for /tmp on CI. With
// `switches`, the build runs from a copy of the site whose store switches
// (`APP_STORE_LISTING_URL`, `PLAY_STORE_LISTING_URL` in src/data/links.ts) have
// those values, so a test can build the "listing taken down" or "Play listing
// set" state without editing the real source. The
// copy sits beside `apps/web` because two files read the repo root by relative
// path (`CHANGELOG.md`, `PRIVACY.md`). It shares `node_modules` and `public`
// by symlink, so builds must not run at the same time (`npm test` runs files
// one after another: `--test-concurrency=1`).
import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const web = fileURLToPath(new URL('..', import.meta.url));
const apps = join(web, '..');

/**
 * @param {{ switches?: Partial<Record<'APP_STORE_LISTING_URL' | 'PLAY_STORE_LISTING_URL', string>> }} [options]
 * @returns {{ outDir: string, cleanup: () => void }}
 */
export function buildSite({ switches } = {}) {
  /** @type {string} */
  let root = web;
  /** @type {string} */
  let outDir;
  /** @type {() => void} */
  let cleanup;
  if (!switches) {
    mkdirSync(join(web, '.astro'), { recursive: true });
    outDir = mkdtempSync(join(web, '.astro', 'site-build-'));
    cleanup = () => rmSync(outDir, { recursive: true, force: true });
  } else {
    root = mkdtempSync(join(apps, '.web-build-'));
    cleanup = () => rmSync(root, { recursive: true, force: true });
    for (const name of ['src', 'integrations', 'scripts']) cpSync(join(web, name), join(root, name), { recursive: true });
    for (const name of ['astro.config.mjs', 'tsconfig.json', 'package.json']) cpSync(join(web, name), join(root, name));
    for (const name of ['node_modules', 'public']) symlinkSync(join(web, name), join(root, name));
    const links = join(root, 'src/data/links.ts');
    let source = readFileSync(links, 'utf8');
    for (const [name, value] of Object.entries(switches)) {
      const line = new RegExp(`^export const ${name} = '[^']*';$`, 'm');
      if (!line.test(source)) {
        cleanup();
        throw new Error(`src/data/links.ts no longer has the ${name} line this helper rewrites`);
      }
      source = source.replace(line, `export const ${name} = '${value}';`);
    }
    writeFileSync(links, source);
    outDir = join(root, 'out');
  }
  try {
    execFileSync(process.execPath, [join(web, 'node_modules/astro/bin/astro.mjs'), 'build', '--outDir', outDir], {
      cwd: root,
      stdio: 'pipe',
    });
  } catch (error) {
    cleanup();
    throw error;
  }
  return { outDir, cleanup };
}
