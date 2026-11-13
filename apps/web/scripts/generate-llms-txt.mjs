// @ts-check
// Replaces dist/llms.txt with a rich agent-facing overview written by an LLM
// (OpenRouter, GLM by default) from the built site itself: every indexable
// page's text, the full guide (dist/index.md), and the help index
// (dist/help.md; help pages themselves only as its titles, descriptions, and
// links, see buildSources), and the articles, compare, and solutions indexes
// (dist/articles.md, dist/compare.md, dist/solutions.md, likewise).
// Runs in the Web workflow's deploy job after `astro build`.
//
// The model's file must pass validateLlmsTxt (llmstxt.org shape; only source
// URLs, domains, emails, numbers, and code; the install command in code;
// never a link to install.sh) after at most one repair turn. Anything else
// (no key, a failed request, a file that stays invalid) is a `::warning::`
// and exit 0 with dist/llms.txt untouched, so the deploy ships the reviewed
// fallback from src/pages/llms.txt.ts and never blocks on the model.
//
//   node scripts/generate-llms-txt.mjs [--dist dist] [--model id] [--dry-run]
//                                      [--reuse <earlier llms.txt>]
//   node scripts/generate-llms-txt.mjs --plan
//
// --dry-run prints the corpus size, the result, and its validation, and
// writes nothing. The model is --model, else LLMS_TXT_MODEL, else
// DEFAULT_MODEL. The deploy job generates only when the site changed: --plan
// (needs GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA) picks the earlier deploy
// whose `llms-txt` artifact can be carried forward and writes its run id to
// GITHUB_OUTPUT (see planReuse); --reuse installs that downloaded file when it
// is still valid, and generates otherwise.
import { createHash } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, realpathSync, renameSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { htmlToText, listIndexablePages } from './site-pages.mjs';

const ENDPOINT = 'https://openrouter.ai/api/v1/chat/completions';
const DEFAULT_MODEL = 'z-ai/glm-5.3-flash';
const KEY_VARIABLE = 'OPENROUTER_API_KEY';
// OpenRouter sends headers at once and the body only when the whole reply is
// done, so this bounds the generation itself: 35-45 s for this corpus at low
// reasoning effort (default effort ran past 120 s).
const TIMEOUT_MS = 180_000;
// A reasoning model spends part of this before the file; the file itself is
// at most ~15k tokens.
const MAX_TOKENS = 32_000;
const GUIDE_URL = 'https://waycar.dev/index.md';
const HELP_INDEX_URL = 'https://waycar.dev/help.md';
const ARTICLES_INDEX_URL = 'https://waycar.dev/articles.md';
const COMPARE_INDEX_URL = 'https://waycar.dev/compare.md';
const SOLUTIONS_INDEX_URL = 'https://waycar.dev/solutions.md';
const LLMS_URL = 'https://waycar.dev/llms.txt';
const INSTALL_URL = 'https://waycar.dev/install.sh';
const INSTALL_COMMAND = `curl -fsSL ${INSTALL_URL} | sh`;
const MIN_BYTES = 3_000;
const MAX_BYTES = 60_000;

const SYSTEM_PROMPT = `You write the llms.txt file for waycar.dev, following the llms.txt standard (https://llmstxt.org). Its readers are AI agents answering questions about Waycar for their users, so it must be complete, exact, and easy to quote.

Rules for every sentence:
- Use only facts stated in the SOURCES. Never add, infer, round, or guess a fact, number, price, version, limit, platform, date, or URL. If the sources do not say it, leave it out.
- Third person, factual, plain. The sources address the reader as "you"; rewrite that as "the user", "the Host", "the phone", and so on. Never write "you" or "your". No marketing superlatives, no emoji.
- Copy numbers, versions, prices, and names exactly as the sources write them.
- State App Store availability exactly as the sources state it (for example, "coming soon" stays "coming soon").
- Never write a Markdown link to ${INSTALL_URL}. Give the install command only in a code span: \`${INSTALL_COMMAND}\`
- Every URL you write must appear in the sources.

Structure, in this order:
1. The first line is exactly: # Waycar
2. A blank line, then a blockquote of 1-3 sentences ("> ...") saying what Waycar is.
3. A body with NO headings of any level. Use bold lead-ins, bullet lists, and one table instead. It contains, in order:
   a. Key facts as bullets: what Waycar is; platforms and minimum iOS/iPadOS version; App Store availability exactly as stated; that Waycar is free and users pay for their own machines and AI providers; that Waycar is open source, with its license and repository URL; that it works with herdr and tmux, with their minimum versions; every supported agent, and which ones support Chat Mode; Host requirements; the install command in a code span and what it does (pairing QR, rerun to pair another device or update); connection and transport (mosh, fallback to SSH, Jump Host); privacy and data handling (no account, keys, cloud, notifications, analytics, AI Summaries, iCloud Sync); the contact email addresses; the company that makes it and the non-affiliation statement.
   b. "**Features**" then one bullet per feature: "- **Feature name**: 1-2 sentences." Cover every feature and section in the sources (including mosh + SSH, Chat Mode, AI Usage via CodexBar, Closed Sessions, tmux support, the agent console, terminal, prompting, workspaces and worktrees, pairing, iPad, notifications and Live Activities, attachments, controls, appearance, agents, security, CarPlay and dictation if the sources mention them).
   c. "**herdr vs tmux**" then a Markdown table comparing what Waycar can do with each, row for row as in the sources.
   d. "**Setup**" then numbered steps, with the requirements, and the manual (no install) alternative.
   e. "**FAQ**" then one bullet per question: "- **Question?** Answer." Include every FAQ question in the sources, worded as there, with a complete answer drawn from the sources.
   f. "**Troubleshooting**" then one bullet per common problem on the support page: "- **Problem or error message**: what causes it and the fix."
4. Then only H2 file-list sections. Each line under an H2 is "- [Title](URL): description" and nothing else (no prose, no blank-line paragraphs, no nested bullets).
   - "## Docs": first the product guide (${GUIDE_URL}), then the help center (https://waycar.dev/help), the CarPlay page, the support page, the privacy policy, and the iPad gallery, all as https://waycar.dev URLs from the sources. Each description says specifically what an agent finds there.
   - "## Help": first the help index (${HELP_INDEX_URL}), then one line per page it lists, in its order, linking the page's .md URL exactly as the help index does, with its description.
   - "## Articles": first the articles index (${ARTICLES_INDEX_URL}), then one line per article it lists, in its order, linking the article's .md URL exactly as the articles index does, with its description.
   - "## Compare": first the comparisons index (${COMPARE_INDEX_URL}), then one line per comparison it lists, in its order, linking the comparison's .md URL exactly as the comparisons index does, with its description.
   - "## Solutions": first the solutions index (${SOLUTIONS_INDEX_URL}), then one line per solution page it lists, in its order, linking the page's .md URL exactly as the solutions index does, with its description.
   - "## Optional": external links found in the sources, such as herdr and CodexBar, each with what it is and how it relates to Waycar.

Length: 15-45 KB. Output only the file's Markdown: no preamble, no commentary, no code fence around the file.`;

const URL_PATTERN = /https?:\/\/[^\s<>"'`()[\]{}|\\^]+/gi;
const NUMBER_PATTERN = /\d+(?:[.,]\d+)*/g;
const LINK_PATTERN = /\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
const AUTOLINK_PATTERN = /<(https?:\/\/[^>\s]+)>/gi;
const ANY_AUTOLINK_PATTERN = /<([a-z][a-z0-9+.-]{1,31}:[^>\s]*)>/gi;
const FILE_LIST_ITEM = /^- \[[^\]]+\]\([^)\s]+\)(?::\s+\S.*)?$/;

/**
 * Every URL in `text`, without trailing sentence punctuation.
 * @param {string} text
 */
function findUrls(text) {
  return [...text.matchAll(URL_PATTERN)].map((match) => match[0].replace(/[.,;:!?*_~]+$/, ''));
}

/**
 * The URL as compared by the validator: parsed and re-serialized, so
 * `https://herdr.dev` and `https://herdr.dev/` are one URL.
 * @param {string} url
 */
function normalizeUrl(url) {
  try {
    return new URL(url).href;
  } catch {
    return url;
  }
}

/**
 * The model's answer as a file: no wrapping code fence, one trailing newline.
 * @param {string} text
 */
export function normalizeModelOutput(text) {
  let body = text.replace(/\r\n?/g, '\n').trim();
  const fenced = body.match(/^```[\w-]*[ \t]*\n([\s\S]*?)\n```$/);
  if (fenced) body = fenced[1].trim();
  return `${body}\n`;
}

const EMAIL_PATTERN = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/g;
// A domain-like token (`brew.sh`, `waycar.app`) not inside a word, path, or
// email. Version numbers never match: the last label must be letters.
const HOSTNAME_PATTERN = /(?<![\w.@/-])(?:[a-z0-9-]+\.)+[a-z]{2,}(?![\w-])/gi;

/** @param {string} text */
const squash = (text) => text.replace(/\s+/g, ' ').trim();

/**
 * Code (inline spans and fenced lines) apart from the prose around it.
 * @param {string} text
 */
function splitCode(text) {
  /** @type {string[]} */
  const code = [];
  let inFence = false;
  const prose = text
    .split('\n')
    .map((line) => {
      if (/^\s*```/.test(line)) {
        inFence = !inFence;
        return '';
      }
      if (inFence) {
        if (line.trim()) code.push(line);
        return '';
      }
      return line.replace(/(`+)([^`\n]+?)\1/g, (_, _ticks, span) => {
        code.push(span);
        return ' ';
      });
    })
    .join('\n');
  return { code, prose };
}

/**
 * Problems that keep `text` from shipping as /llms.txt; empty when it is valid.
 * @param {string} text
 * @param {{ corpus: string, allowedUrls: Iterable<string>, articleUrls?: string[] }} sources
 * @returns {string[]}
 */
export function validateLlmsTxt(text, { corpus, allowedUrls, articleUrls = [] }) {
  /** @type {string[]} */
  const errors = [];
  const lines = text.split('\n');
  // Lines inside fenced code blocks are not Markdown structure.
  let inFence = false;
  const structural = lines.map((line) => {
    if (/^\s*```/.test(line)) {
      inFence = !inFence;
      return null;
    }
    return inFence ? null : line;
  });

  if (lines[0] !== '# Waycar') errors.push('The first line must be exactly "# Waycar".');
  const h1s = structural.filter((line) => line !== null && /^#\s/.test(line));
  if (h1s.length !== 1) errors.push(`There must be exactly one H1 heading; found ${h1s.length}.`);
  const afterTitle = lines.slice(1).find((line) => line.trim() !== '');
  if (!afterTitle?.startsWith('> ')) errors.push('The first non-blank line after "# Waycar" must be a "> " blockquote.');
  for (const line of structural) {
    if (line !== null && /^#{3,}\s/.test(line)) errors.push(`H3 or deeper headings are not allowed: "${line}"`);
  }

  const firstH2 = structural.findIndex((line) => line !== null && /^##\s/.test(line));
  if (firstH2 === -1) {
    errors.push('There must be at least one H2 file-list section (## Docs).');
  } else {
    lines.slice(firstH2).forEach((line, offset) => {
      if (line.trim() === '' || /^##\s/.test(line) || FILE_LIST_ITEM.test(line)) return;
      errors.push(
        `Line ${firstH2 + offset + 1} is inside an H2 section but is not "- [Title](URL): description": "${line}"`,
      );
    });
  }

  // Only plain inline links and autolinks: reference definitions, odd link
  // syntax, and script/data URLs would slip past the URL checks below.
  structural.forEach((line, index) => {
    if (line !== null && /^\s{0,3}\[[^\]]+\]:/.test(line)) {
      errors.push(`Reference-style link definitions are not allowed (line ${index + 1}): "${line}"`);
    }
  });
  if (/\]\((?:\s|<)/.test(text)) errors.push('Link targets must follow "](" directly, without spaces or "<".');
  const unsafe = text.match(/\b(?:javascript|vbscript|data):(?!\s)|\]\(\/\//i);
  if (unsafe) errors.push(`Script, data, and protocol-relative URLs are not allowed: ${unsafe[0]}`);

  const linkTargets = [
    ...[...text.matchAll(LINK_PATTERN)].map((match) => match[2]),
    ...[...text.matchAll(AUTOLINK_PATTERN)].map((match) => match[1]),
  ];
  if (!linkTargets.some((target) => normalizeUrl(target) === GUIDE_URL)) {
    errors.push(`There must be a Markdown link to the product guide, ${GUIDE_URL}.`);
  }
  // The articles index lists only articles that are live today, so a post that
  // went live on its date makes a carried-forward file fail here and regenerate.
  const linked = new Set(linkTargets.map(normalizeUrl));
  for (const url of articleUrls) {
    if (!linked.has(normalizeUrl(url))) errors.push(`The file must link every article the articles index lists; missing ${url}`);
  }
  for (const target of linkTargets) {
    let url;
    try {
      url = new URL(target);
    } catch {
      errors.push(`Link targets must be absolute URLs: ${target}`);
      continue;
    }
    if (`${url.origin}${url.pathname}` === INSTALL_URL) {
      errors.push(`Never link ${INSTALL_URL}; give the install command in a code span only.`);
    }
    if (!/^(?:https?|mailto):$/.test(url.protocol)) errors.push(`Link targets must be https or mailto URLs: ${target}`);
  }
  const allowed = new Set([...allowedUrls].map(normalizeUrl));
  const unknown = new Set(
    [...linkTargets.filter((target) => /^https?:/i.test(target)), ...findUrls(text)].filter(
      (url) => !allowed.has(normalizeUrl(url)),
    ),
  );
  for (const url of unknown) errors.push(`URL not found in the sources: ${url}`);

  const corpusEmails = new Set(corpus.match(EMAIL_PATTERN) ?? []);
  for (const email of new Set(text.match(EMAIL_PATTERN) ?? [])) {
    if (!corpusEmails.has(email)) errors.push(`Email address not found in the sources: ${email}`);
  }

  // Agents copy commands verbatim, so every code span and fenced line must be
  // one the sources show; `brew install waycar` or `| sudo sh` would not be.
  const { code, prose } = splitCode(text);
  const flatCorpus = squash(corpus);
  for (const snippet of new Set(code.map(squash))) {
    if (snippet && !flatCorpus.includes(snippet)) errors.push(`Code not found in the sources: \`${snippet}\``);
  }
  if (!code.some((snippet) => squash(snippet).includes(INSTALL_COMMAND))) {
    errors.push(`The install command must appear exactly, in a code span: \`${INSTALL_COMMAND}\``);
  }
  // Any mention of the installer outside code is a link some renderer or
  // crawler may follow.
  if (prose.includes(INSTALL_URL.replace('https://', ''))) {
    errors.push(`${INSTALL_URL} may appear only inside the install command's code span.`);
  }

  // A domain the sources never name (an invented mirror, docs site, or app
  // domain) outside links, URLs, emails, and code.
  const lowerCorpus = corpus.toLowerCase();
  const hosts = new Set([...allowed].map((url) => URL.canParse(url) ? new URL(url).hostname : '').filter(Boolean));
  const bare = prose
    .replace(LINK_PATTERN, (_, title) => ` ${title} `)
    .replace(AUTOLINK_PATTERN, ' ')
    .replace(URL_PATTERN, ' ')
    .replace(EMAIL_PATTERN, ' ');
  for (const name of new Set(bare.match(HOSTNAME_PATTERN) ?? [])) {
    if (!hosts.has(name.toLowerCase()) && !lowerCorpus.includes(name.toLowerCase())) {
      errors.push(`Domain or file name not found in the sources: ${name}`);
    }
  }

  // An invented price, version, or limit shows up as a number the sources
  // never use. URLs and ordered-list markers carry no facts.
  const corpusNumbers = new Set(corpus.match(NUMBER_PATTERN) ?? []);
  const numbersIn = text
    .replace(LINK_PATTERN, (_, title) => ` ${title} `)
    .replace(URL_PATTERN, ' ')
    .replace(/^(\s*)\d+[.)]\s/gm, '$1');
  const invented = new Set((numbersIn.match(NUMBER_PATTERN) ?? []).filter((number) => !corpusNumbers.has(number)));
  for (const number of invented) errors.push(`Number not found in the sources: ${number}`);

  if (text.includes('{{') || text.includes('}}')) errors.push('Template braces ({{ or }}) are not allowed.');
  const tag = prose.match(/<\/?[a-zA-Z][a-zA-Z0-9-]*(?:\s[^>]*)?\/?>/);
  if (tag) errors.push(`HTML tags are not allowed outside inline code: ${tag[0]}`);
  // Autolinks of any other scheme (`<ssh://…>`) would render as links.
  for (const [, target] of prose.matchAll(ANY_AUTOLINK_PATTERN)) {
    const href = normalizeUrl(target);
    const ok = href.startsWith('https://') ? allowed.has(href) : /^mailto:/i.test(target) && corpusEmails.has(target.slice(7));
    if (!ok) errors.push(`Autolinks must be allowed https URLs or source email addresses: <${target}>`);
  }

  const bytes = Buffer.byteLength(text);
  if (bytes < MIN_BYTES || bytes > MAX_BYTES) {
    errors.push(`The file is ${bytes} bytes; it must be ${MIN_BYTES}-${MAX_BYTES} bytes.`);
  }
  return errors;
}

/**
 * The model's sources, read from a built dist/: every indexable page's text,
 * the full guide, the help index, and the articles, compare, and solutions
 * indexes. Help pages
 * (/help and /help/<slug>) contribute only through dist/help.md (title,
 * description, and link per page): their full text would multiply the prompt
 * for little an overview needs. Articles (/articles and /articles/<slug>) do
 * the same through dist/articles.md, and the comparison and solution pages
 * (/compare, /solutions and their children) through dist/compare.md and
 * dist/solutions.md. Changelog pages (/changelog and
 * /changelog/<n>) stay out for the same reason, so `touchesSite` watches
 * neither their release files nor the repo-root CHANGELOG.md their Unreleased
 * part comes from. Their URLs stay
 * allowed. The reviewed llms.txt stays out, so a rerun on a dist that already
 * holds a generated file reads the same sources. `articleUrls` are the links
 * dist/articles.md lists, one per published article.
 * @param {string} distDir
 */
export function buildSources(distDir) {
  const pages = listIndexablePages(distDir);
  // The pages whose own text goes in the corpus.
  const textPages = pages.filter(
    (page) => !/^\/(?:help|changelog|articles|compare|solutions)(?:\/|$)/.test(new URL(page.url).pathname),
  );
  const sections = textPages.map((page) => `${page.url}\n${htmlToText(page.html, page.url)}`);
  sections.push(`${GUIDE_URL}\n${readFileSync(join(distDir, 'index.md'), 'utf8').trim()}`);
  sections.push(`${HELP_INDEX_URL}\n${readFileSync(join(distDir, 'help.md'), 'utf8').trim()}`);
  const articlesIndex = readFileSync(join(distDir, 'articles.md'), 'utf8').trim();
  sections.push(`${ARTICLES_INDEX_URL}\n${articlesIndex}`);
  sections.push(`${COMPARE_INDEX_URL}\n${readFileSync(join(distDir, 'compare.md'), 'utf8').trim()}`);
  sections.push(`${SOLUTIONS_INDEX_URL}\n${readFileSync(join(distDir, 'solutions.md'), 'utf8').trim()}`);
  const corpus = sections.join('\n\n----------\n\n');
  const allowedUrls = new Set([
    ...pages.map((page) => page.url),
    GUIDE_URL,
    HELP_INDEX_URL,
    ARTICLES_INDEX_URL,
    COMPARE_INDEX_URL,
    SOLUTIONS_INDEX_URL,
    LLMS_URL,
    ...findUrls(corpus),
  ]);
  // One link per published article, as dist/articles.md lists them.
  const articleUrls = articlesIndex
    .split('\n')
    .filter((line) => FILE_LIST_ITEM.test(line))
    .map((line) => [...line.matchAll(LINK_PATTERN)][0][2]);
  return { textPages, corpus, allowedUrls, articleUrls };
}

class GenerationError extends Error {}

/** @typedef {{ role: 'system' | 'user' | 'assistant', content: string }} Message */

/** @param {unknown} error */
function describe(error) {
  return `${error}${error instanceof Error && error.cause ? ` (${error.cause})` : ''}`;
}

/**
 * One chat completion's text. One retry on 429, 5xx, or a timeout; every
 * other failure is a GenerationError with the key redacted.
 * @param {string} key
 * @param {string} model
 * @param {Message[]} messages
 */
async function complete(key, model, messages) {
  const body = JSON.stringify({
    model,
    temperature: 0.2,
    max_tokens: MAX_TOKENS,
    // The task is careful copying, not problem solving; long reasoning only
    // adds minutes.
    reasoning: { effort: 'low' },
    messages,
  });
  for (let attempt = 1; ; attempt++) {
    const last = attempt === 2;
    let status;
    let text;
    try {
      const response = await fetch(ENDPOINT, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${key}`,
          'Content-Type': 'application/json',
          'X-Title': 'Waycar llms.txt',
        },
        body,
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
      status = response.status;
      if (!last && (status === 429 || status >= 500)) {
        const retryAfter = Number(response.headers.get('retry-after'));
        await response.body?.cancel();
        await sleep(Number.isFinite(retryAfter) && retryAfter > 0 ? Math.min(retryAfter, 30) * 1000 : 5000);
        continue;
      }
      // The body is server text; never let an echoed key reach the log.
      text = redact(await response.text(), key);
    } catch (error) {
      const timedOut = error instanceof DOMException && error.name === 'TimeoutError';
      if (timedOut && !last) continue;
      // fetch's own message is just "fetch failed"; the cause names the
      // DNS, TLS, or socket error.
      const detail = timedOut ? `timed out after ${TIMEOUT_MS / 1000} s` : describe(error);
      throw new GenerationError(redact(detail, key));
    }
    if (status < 200 || status >= 300) throw new GenerationError(`HTTP ${status}: ${text.slice(0, 300)}`);
    /** @type {any} */
    let payload;
    try {
      payload = JSON.parse(text);
    } catch {
      throw new GenerationError(`unexpected response: ${text.slice(0, 300)}`);
    }
    const choice = payload?.choices?.[0];
    const content = choice?.message?.content;
    if (choice?.finish_reason === 'length') throw new GenerationError(`the reply hit max_tokens (${MAX_TOKENS})`);
    // Anything but a natural stop (content filter, provider error) may be a
    // truncated or partial file.
    if (choice?.finish_reason !== 'stop') {
      throw new GenerationError(`the reply ended with finish_reason ${JSON.stringify(choice?.finish_reason ?? null)}`);
    }
    if (typeof content !== 'string' || content.trim() === '') {
      throw new GenerationError(`unexpected response: ${redact(JSON.stringify(payload).slice(0, 300), key)}`);
    }
    return content;
  }
}

/**
 * @param {string} text
 * @param {string} key
 */
function redact(text, key) {
  return text.replaceAll(key, '[redacted]');
}

/** @param {number} ms */
function sleep(ms) {
  return new Promise((done) => setTimeout(done, ms));
}

/** @param {string} message */
function warn(message) {
  // A GitHub annotation in Actions, a plain stderr line elsewhere.
  // Escaped per the workflow-command format, so a message cannot end the
  // annotation early or inject another command.
  const escaped = message.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
  console.error(`::warning::${escaped}`);
}

/**
 * Whether a change to these repo-relative paths can change what the model
 * reads. plugin/** and scripts/package-plugin.sh only change /install.sh,
 * CHANGELOG.md and apps/web/src/content/changelog/** only the changelog pages
 * (left out of the sources, see buildSources), and the workflow file only the
 * pipeline.
 * @param {Iterable<string>} paths
 */
export function touchesSite(paths) {
  return [...paths].some(
    (path) =>
      (path.startsWith('apps/web/') && !path.startsWith('apps/web/src/content/changelog/')) || path === 'PRIVACY.md',
  );
}

const GITHUB_API = 'https://api.github.com';
const FETCH_TIMEOUT_MS = 15_000;
// The compare API lists at most this many files; a diff that reaches it may
// hide a site file.
const COMPARE_FILE_CAP = 300;
// The deploy job uploads dist/llms.txt under this name after each deploy.
const ARTIFACT = 'llms-txt';

/**
 * @param {string} path
 * @param {string} token
 */
async function github(path, token) {
  const response = await fetch(`${GITHUB_API}${path}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'waycar-llms-txt',
    },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${path.split('?')[0]}: HTTP ${response.status} ${squash(text).slice(0, 200)}`);
  return JSON.parse(text);
}

/**
 * The earlier deploy whose llms.txt this one can carry forward: the newest
 * `llms-txt` artifact from main (the deploy job uploads one only after a
 * successful deploy), when nothing `touchesSite` counts (apps/web/ except the
 * changelog release files, or PRIVACY.md) changed since that run's commit.
 * Null means generate. Every doubt (a manual run, no
 * artifact, an API error, an odd history, a capped or missing file list) means
 * generate.
 * @param {NodeJS.ProcessEnv} env
 * @returns {Promise<{ runId: string, sha: string } | null>}
 */
async function planReuse(env) {
  if (env.GITHUB_EVENT_NAME === 'workflow_dispatch') {
    console.log('llms.txt: manual run (workflow_dispatch), regenerating');
    return null;
  }
  const token = env.GH_TOKEN?.trim();
  const repo = env.GITHUB_REPOSITORY;
  const sha = env.GITHUB_SHA;
  if (!token || !repo || !sha) {
    warn('--plan needs GH_TOKEN, GITHUB_REPOSITORY, and GITHUB_SHA; regenerating llms.txt.');
    return null;
  }
  try {
    const { artifacts = [] } = await github(`/repos/${repo}/actions/artifacts?name=${ARTIFACT}&per_page=20`, token);
    const candidates = artifacts
      .filter(
        (/** @type {any} */ artifact) =>
          !artifact.expired &&
          artifact.workflow_run?.head_branch === 'main' &&
          artifact.workflow_run?.head_repository_id === artifact.workflow_run?.repository_id,
      )
      .sort((/** @type {any} */ a, /** @type {any} */ b) => Date.parse(b.created_at) - Date.parse(a.created_at));
    // The artifact's summary can't prove provenance; the run itself must be a
    // push, scheduled or manual web.yml run on this repo's main.
    let newest;
    for (const candidate of candidates) {
      const run = await github(`/repos/${repo}/actions/runs/${candidate.workflow_run?.id}`, token);
      if (
        ['push', 'schedule', 'workflow_dispatch'].includes(run.event) &&
        typeof run.path === 'string' &&
        run.path.startsWith('.github/workflows/web.yml') &&
        run.head_branch === 'main' &&
        run.head_repository?.full_name === repo
      ) {
        newest = candidate;
        break;
      }
    }
    const base = newest?.workflow_run?.head_sha;
    const runId = newest?.workflow_run?.id;
    if (typeof base !== 'string' || runId === undefined) {
      console.log(`llms.txt: no unexpired ${ARTIFACT} artifact from a deploy of main, regenerating`);
      return null;
    }
    const short = base.slice(0, 7);
    // Changed files come only on the first page, so one commit per page keeps
    // the response small.
    const compare = await github(`/repos/${repo}/compare/${base}...${sha}?per_page=1`, token);
    if (compare.status !== 'ahead' && compare.status !== 'identical') {
      console.log(`llms.txt: ${sha.slice(0, 7)} is not ahead of run ${runId} (${short}): ${compare.status}, regenerating`);
      return null;
    }
    if (compare.status === 'ahead' && !Array.isArray(compare.files)) {
      console.log(`llms.txt: the comparison with ${short} lists no files, regenerating`);
      return null;
    }
    const files = compare.files ?? [];
    if (files.length >= COMPARE_FILE_CAP) {
      console.log(`llms.txt: ${COMPARE_FILE_CAP}+ files changed since ${short}, regenerating`);
      return null;
    }
    const paths = files.flatMap((/** @type {any} */ file) => [file.filename, file.previous_filename]);
    if (touchesSite(paths.filter((/** @type {unknown} */ path) => typeof path === 'string'))) {
      console.log(`llms.txt: site changed since ${short}, regenerating`);
      return null;
    }
    console.log(`llms.txt: site unchanged since ${short}, reusing the file deployed by run ${runId}`);
    return { runId: String(runId), sha: base };
  } catch (error) {
    warn(`Could not check for a reusable llms.txt (${redact(describe(error), token)}); regenerating llms.txt.`);
    return null;
  }
}

/**
 * The carried-forward file at `path` if it is still fit to ship, else null.
 * It must not be the committed fallback (that run's generation failed, so
 * try again) and must pass validation against today's sources, which includes
 * linking every article the index lists now (a post may have gone live on its
 * date since the file was made).
 * @param {string} path
 * @param {{ corpus: string, allowedUrls: Iterable<string>, articleUrls?: string[] }} sources
 * @param {Buffer} fallback the committed llms.txt in dist/
 * @returns {Buffer | null}
 */
function reusableFile(path, sources, fallback) {
  if (!existsSync(path)) {
    console.log(`llms.txt: no earlier file at ${path}, generating`);
    return null;
  }
  const carried = readFileSync(path);
  if (carried.equals(fallback)) {
    console.log('llms.txt: the earlier deploy shipped the committed fallback, regenerating');
    return null;
  }
  const errors = validateLlmsTxt(carried.toString('utf8'), sources);
  if (errors.length > 0) {
    // Validation errors quote file text; one line, no workflow commands.
    const first = squash(errors[0]).replaceAll('::', ': :');
    console.log(`llms.txt: the earlier file fails validation (${errors.length}, first: ${first}), regenerating`);
    return null;
  }
  return carried;
}

/**
 * Replace atomically so an interrupted run never leaves a half-written file.
 * @param {string} target
 * @param {string | Buffer} content
 */
function install(target, content) {
  writeFileSync(`${target}.tmp`, content);
  renameSync(`${target}.tmp`, target);
}

/**
 * Generate, validate, and (unless dry-run) install dist/llms.txt.
 * @param {string[]} argv
 * @param {NodeJS.ProcessEnv} env
 * @returns {Promise<number>} the exit code
 */
async function main(argv = process.argv.slice(2), env = process.env) {
  const { values } = parseArgs({
    args: argv,
    options: {
      dist: { type: 'string', default: 'dist' },
      model: { type: 'string' },
      'dry-run': { type: 'boolean', default: false },
      plan: { type: 'boolean', default: false },
      reuse: { type: 'string' },
    },
  });
  if (values.plan) {
    const plan = await planReuse(env);
    const outputs = `reuse_run_id=${plan?.runId ?? ''}\nreuse_sha=${plan?.sha ?? ''}\n`;
    if (env.GITHUB_OUTPUT) appendFileSync(env.GITHUB_OUTPUT, outputs);
    else process.stdout.write(outputs);
    return 0;
  }
  const distDir = resolve(values.dist ?? 'dist');
  const dryRun = values['dry-run'] ?? false;
  const model = values.model || env.LLMS_TXT_MODEL?.trim() || DEFAULT_MODEL;
  const target = join(distDir, 'llms.txt');

  const sources = buildSources(distDir);
  if (dryRun) {
    console.log(
      `corpus: ${Buffer.byteLength(sources.corpus)} bytes from ${sources.textPages.length} pages, ` +
        `index.md, help.md, articles.md, compare.md, and solutions.md; ${sources.allowedUrls.size} allowed URLs`,
    );
  }
  if (values.reuse) {
    const carried = reusableFile(values.reuse, sources, readFileSync(target));
    if (carried !== null) {
      const from = env.LLMS_REUSE_RUN_ID
        ? `run ${env.LLMS_REUSE_RUN_ID} (${env.LLMS_REUSE_SHA?.slice(0, 7) || 'unknown commit'})`
        : values.reuse;
      const digest = createHash('sha256').update(carried).digest('hex');
      console.log(`llms.txt: reused from ${from}, ${carried.length} bytes, sha256 ${digest}`);
      if (dryRun) {
        console.log('dry run: wrote nothing');
        return 0;
      }
      install(target, carried);
      if (env.GITHUB_STEP_SUMMARY) {
        appendFileSync(
          env.GITHUB_STEP_SUMMARY,
          `## llms.txt\n\nReused from ${from}: ${carried.length} bytes, sha256 \`${digest}\`.\n`,
        );
      }
      return 0;
    }
  }
  const key = env[KEY_VARIABLE]?.trim();
  if (!key) {
    warn(`${KEY_VARIABLE} is not set; keeping the committed llms.txt.`);
    return 0;
  }

  /** @type {Message[]} */
  const messages = [
    { role: 'system', content: SYSTEM_PROMPT },
    { role: 'user', content: `SOURCES (each starts with its URL):\n\n${sources.corpus}` },
  ];
  let text;
  let errors;
  try {
    text = normalizeModelOutput(await complete(key, model, messages));
    errors = validateLlmsTxt(text, sources);
    if (errors.length > 0) {
      console.log(`llms.txt from ${model} failed validation (${errors.length}); asking for one repair.`);
      messages.push(
        { role: 'assistant', content: text },
        {
          role: 'user',
          content:
            'Your file failed these checks:\n' +
            errors.map((error) => `- ${error}`).join('\n') +
            '\n\nFix every one using only the SOURCES (drop a claim rather than invent a source for it). ' +
            'Return the complete corrected file only.',
        },
      );
      text = normalizeModelOutput(await complete(key, model, messages));
      errors = validateLlmsTxt(text, sources);
    }
  } catch (error) {
    if (!(error instanceof GenerationError)) throw error;
    warn(`llms.txt generation with ${model} failed (${error.message}); keeping the committed llms.txt.`);
    return 0;
  }

  const bytes = Buffer.byteLength(text);
  if (dryRun) {
    console.log(`----- llms.txt from ${model}, ${bytes} bytes -----\n${text}-----`);
    console.log(errors.length === 0 ? 'validation: passed' : `validation: ${errors.length} errors\n- ${errors.join('\n- ')}`);
    return 0;
  }
  if (errors.length > 0) {
    warn(`llms.txt from ${model} failed validation; keeping the committed llms.txt:\n- ${errors.join('\n- ')}`);
    return 0;
  }
  install(target, text);
  console.log(`llms.txt: generated by ${model}, ${bytes} bytes`);
  if (env.GITHUB_STEP_SUMMARY) {
    const fence = '`'.repeat(Math.max(3, ...[...text.matchAll(/`+/g)].map((run) => run[0].length + 1)));
    appendFileSync(
      env.GITHUB_STEP_SUMMARY,
      `## llms.txt\n\nGenerated by \`${model}\`, ${bytes} bytes.\n\n` +
        `<details><summary>dist/llms.txt</summary>\n\n${fence}markdown\n${text}${fence}\n\n</details>\n`,
    );
  }
  return 0;
}

// Node resolves symlinks in import.meta.url (macOS /tmp → /private/tmp).
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
  process.exitCode = await main();
}
