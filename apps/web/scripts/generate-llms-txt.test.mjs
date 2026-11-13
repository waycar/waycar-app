// @ts-check
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { buildSources, normalizeModelOutput, touchesSite, validateLlmsTxt } from './generate-llms-txt.mjs';

test('touchesSite counts apps/web/ and PRIVACY.md, not the plugin, the changelog or the workflow', () => {
  assert.equal(touchesSite(['plugin/src/index.ts', 'apps/web/src/pages/support.astro']), true);
  assert.equal(touchesSite(['PRIVACY.md']), true);
  assert.equal(touchesSite(['plugin/src/index.ts', 'scripts/package-plugin.sh', '.github/workflows/web.yml']), false);
  assert.equal(touchesSite(['docs/apps/web/notes.md', 'apps/webby/x']), false);
  assert.equal(touchesSite(['CHANGELOG.md', 'apps/web/src/content/changelog/1.2.0.md']), false);
  assert.equal(touchesSite(['apps/web/src/content/changelog/1.2.0.md', 'apps/web/src/content/help/hosts.md']), true);
});

const corpus = `https://waycar.dev/
Waycar is an iPhone and iPad app for herdr 0.7.5+ and tmux 3.2+. iOS 18+.
Free, with every feature included and unlimited launches. No account or subscription.
$ curl -fsSL https://waycar.dev/install.sh | sh
Contact support@waycar.dev.
[herdr](https://herdr.dev/) [CodexBar](https://github.com/steipete/CodexBar)`;

const sources = {
  corpus,
  allowedUrls: [
    'https://waycar.dev/',
    'https://waycar.dev/support',
    'https://waycar.dev/privacy',
    'https://waycar.dev/index.md',
    'https://waycar.dev/install.sh',
    'https://herdr.dev/',
    'https://github.com/steipete/CodexBar',
  ],
};

const filler = Array.from(
  { length: 14 },
  (_, index) =>
    `- **Question ${['one', 'two', 'three', 'four', 'five', 'six', 'seven'][index % 7]}?** ` +
    'Waycar connects over mosh and falls back to SSH when UDP is blocked, with no account and no cloud service between the phone and the Host.',
).join('\n');

const valid = `# Waycar

> Waycar is a native iPhone and iPad app for watching coding agents that run in herdr or tmux on a Mac or Linux machine.

- **Platforms**: iPhone and iPad, iOS 18+.
- **Pricing**: free, with every feature included and unlimited launches. No account or subscription.
- **Install**: \`curl -fsSL https://waycar.dev/install.sh | sh\` on each Host.

**herdr vs tmux**

| Feature | herdr | tmux |
| --- | --- | --- |
| Minimum version | 0.7.5 | 3.2 |

**Setup**

1. Get Waycar.
2. Run the install command.

**FAQ**

${filler}

## Docs

- [Waycar product guide](https://waycar.dev/index.md): every feature, setup, requirements, and the full FAQ
- [Support](https://waycar.dev/support): help and contact

## Optional

- [herdr](https://herdr.dev): the terminal workspace manager Waycar works with
- [CodexBar](https://github.com/steipete/CodexBar)
`;

/**
 * @param {string} search
 * @param {string} replacement
 */
const variant = (search, replacement) => {
  assert.ok(valid.includes(search), `fixture lacks ${search}`);
  return valid.replace(search, replacement);
};

/** @param {string} text */
const errorsOf = (text) => validateLlmsTxt(text, sources);

test('accepts a valid rich file', () => {
  assert.deepEqual(errorsOf(valid), []);
});

test('rejects a number the sources never use', () => {
  const errors = errorsOf(variant('iOS 18+', 'iOS 19+'));
  assert.ok(errors.some((error) => error.includes('19')), errors.join('\n'));
});

test('rejects a URL the sources never use', () => {
  const errors = errorsOf(variant('(https://waycar.dev/support)', '(https://waycar.dev/help)'));
  assert.ok(errors.some((error) => error.includes('https://waycar.dev/help')), errors.join('\n'));
});

test('rejects a Markdown link to install.sh', () => {
  const errors = errorsOf(variant('- [Support]', '- [Installer](https://waycar.dev/install.sh): the script\n- [Support]'));
  assert.ok(errors.some((error) => error.startsWith('Never link')), errors.join('\n'));
});

test('rejects an H3 heading', () => {
  const errors = errorsOf(variant('**Setup**', '### Setup'));
  assert.ok(errors.some((error) => error.includes('H3')), errors.join('\n'));
});

test('rejects a prose line inside an H2 section', () => {
  const errors = errorsOf(variant('## Optional\n', '## Optional\n\nSee also these links.\n'));
  assert.ok(errors.some((error) => error.includes('See also these links.')), errors.join('\n'));
});

test('rejects a file without the install command', () => {
  const errors = errorsOf(variant('`curl -fsSL https://waycar.dev/install.sh | sh`', 'the install script'));
  assert.ok(errors.some((error) => error.startsWith('The install command')), errors.join('\n'));
});

test('rejects a command the sources never show', () => {
  const errors = errorsOf(variant('2. Run the install command.', '2. Run `brew install waycar`.'));
  assert.ok(errors.some((error) => error.includes('brew install waycar')), errors.join('\n'));
});

test('rejects the install command outside code', () => {
  const errors = errorsOf(variant('`curl -fsSL https://waycar.dev/install.sh | sh`', 'curl -fsSL https://waycar.dev/install.sh | sh'));
  assert.ok(errors.some((error) => error.includes('in a code span')), errors.join('\n'));
});

test('rejects a domain the sources never name', () => {
  const errors = errorsOf(variant('**Setup**', 'Docs are mirrored at waycar-docs.io.\n\n**Setup**'));
  assert.ok(errors.some((error) => error.includes('waycar-docs.io')), errors.join('\n'));
});

test('rejects an email address the sources never use', () => {
  const errors = errorsOf(variant('**Setup**', '- **Contact**: help@waycar.dev\n\n**Setup**'));
  assert.ok(errors.some((error) => error.includes('help@waycar.dev')), errors.join('\n'));
});

test('rejects a reference-style link definition', () => {
  const errors = errorsOf(variant('## Docs', '[guide]: https://waycar.dev/index.md\n\n## Docs'));
  assert.ok(errors.some((error) => error.startsWith('Reference-style')), errors.join('\n'));
});

test('rejects an unknown uppercase-scheme URL in prose', () => {
  const errors = errorsOf(variant('**Setup**', 'Mirror: HTTPS://evil.example\n\n**Setup**'));
  assert.ok(errors.some((error) => error.includes('HTTPS://evil.example')), errors.join('\n'));
});

test('rejects a non-https autolink', () => {
  const errors = errorsOf(variant('**Setup**', 'Clone <ssh://evil.example>\n\n**Setup**'));
  assert.ok(errors.some((error) => error.includes('<ssh://evil.example>')), errors.join('\n'));
});

test('rejects a file that omits an article the index lists, and accepts it once linked', () => {
  const article = 'https://waycar.dev/articles/new-post.md';
  const indexed = { ...sources, allowedUrls: [...sources.allowedUrls, article], articleUrls: [article] };
  const missing = validateLlmsTxt(valid, indexed);
  assert.equal(missing.length, 1, missing.join('\n'));
  assert.ok(missing[0].includes(article), missing[0]);
  const listed = variant('## Optional', `## Articles\n\n- [New post](${article}): A new post.\n\n## Optional`);
  assert.deepEqual(validateLlmsTxt(listed, indexed), []);
});

test('normalizeModelOutput strips a wrapping code fence', () => {
  assert.equal(normalizeModelOutput('```markdown\n# Waycar\n\n> Hi.\n```\n\n'), '# Waycar\n\n> Hi.\n');
});

test('buildSources reads help, article, comparison and solution pages through their indexes, not their full text, and leaves changelog pages out', (t) => {
  const dist = mkdtempSync(join(tmpdir(), 'waycar-dist-'));
  t.after(() => rmSync(dist, { recursive: true, force: true }));
  mkdirSync(join(dist, 'help'));
  mkdirSync(join(dist, 'changelog'));
  mkdirSync(join(dist, 'articles'));
  mkdirSync(join(dist, 'compare'));
  mkdirSync(join(dist, 'solutions'));
  /**
   * @param {string} path
   * @param {string} text
   */
  const page = (path, text) =>
    `<html><head><link rel="canonical" href="https://waycar.dev${path}"></head><body><main><p>${text}</p></main></body></html>`;
  writeFileSync(join(dist, 'index.html'), page('/', 'Home page text'));
  writeFileSync(join(dist, 'help.html'), page('/help', 'Help index text'));
  writeFileSync(join(dist, 'help', 'mosh.html'), page('/help/mosh', 'Full mosh article text'));
  writeFileSync(join(dist, 'changelog.html'), page('/changelog', 'Newest release notes'));
  writeFileSync(join(dist, 'changelog', '2.html'), page('/changelog/2', 'Older release notes'));
  writeFileSync(join(dist, 'index.md'), '# Guide');
  writeFileSync(join(dist, 'help.md'), '# Waycar Help\n\n- [mosh](https://waycar.dev/help/mosh.md): Use mosh.');
  writeFileSync(join(dist, 'articles.html'), page('/articles', 'Articles index text'));
  writeFileSync(join(dist, 'articles', 'advisors.html'), page('/articles/advisors', 'Full advisors article text'));
  writeFileSync(
    join(dist, 'articles.md'),
    '# Waycar Articles\n\n- [Advisors](https://waycar.dev/articles/advisors.md): Set up advisors.',
  );
  writeFileSync(join(dist, 'compare.html'), page('/compare', 'Comparisons index text'));
  writeFileSync(join(dist, 'compare', 'termius.html'), page('/compare/termius', 'Full Termius comparison text'));
  writeFileSync(
    join(dist, 'compare.md'),
    '# Waycar Comparisons\n\n- [Waycar vs Termius](https://waycar.dev/compare/termius.md): Compared with Termius.',
  );
  writeFileSync(join(dist, 'solutions.html'), page('/solutions', 'Solutions index text'));
  writeFileSync(join(dist, 'solutions', 'mosh-client-ios.html'), page('/solutions/mosh-client-ios', 'Full mosh client page text'));
  writeFileSync(
    join(dist, 'solutions.md'),
    '# Waycar Solutions\n\n- [A mosh client for iOS](https://waycar.dev/solutions/mosh-client-ios.md): Use mosh on iOS.',
  );

  const { corpus, allowedUrls, articleUrls } = buildSources(dist);
  assert.deepEqual(articleUrls, ['https://waycar.dev/articles/advisors.md']);
  assert.ok(corpus.includes('Home page text') && corpus.includes('- [mosh](https://waycar.dev/help/mosh.md)'), corpus);
  assert.ok(corpus.includes('- [Advisors](https://waycar.dev/articles/advisors.md)'), corpus);
  assert.ok(corpus.includes('- [Waycar vs Termius](https://waycar.dev/compare/termius.md)'), corpus);
  assert.ok(corpus.includes('- [A mosh client for iOS](https://waycar.dev/solutions/mosh-client-ios.md)'), corpus);
  for (const text of [
    'Full mosh article text',
    'Help index text',
    'Newest release notes',
    'Older release notes',
    'Articles index text',
    'Full advisors article text',
    'Comparisons index text',
    'Full Termius comparison text',
    'Solutions index text',
    'Full mosh client page text',
  ]) {
    assert.ok(!corpus.includes(text), text);
  }
  for (const url of [
    'https://waycar.dev/help',
    'https://waycar.dev/help/mosh',
    'https://waycar.dev/help/mosh.md',
    'https://waycar.dev/articles',
    'https://waycar.dev/articles/advisors',
    'https://waycar.dev/articles/advisors.md',
    'https://waycar.dev/compare',
    'https://waycar.dev/compare/termius',
    'https://waycar.dev/compare/termius.md',
    'https://waycar.dev/solutions',
    'https://waycar.dev/solutions/mosh-client-ios',
    'https://waycar.dev/solutions/mosh-client-ios.md',
    'https://waycar.dev/changelog',
    'https://waycar.dev/changelog/2',
  ]) {
    assert.ok(allowedUrls.has(url), url);
  }
});
