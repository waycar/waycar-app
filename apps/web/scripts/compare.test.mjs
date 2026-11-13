// @ts-check
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  CAPABILITIES,
  CAPABILITY_IDS,
  bodyProblems,
  cellProblem,
  documentTitle,
  markdownTable,
  relationProblems,
  rowProblems,
  solutionProblems,
  titleProblem,
} from '../src/lib/compare-rows.mjs';

/** Every capability row, answered the way the row allows: a rating on rated rows, `info` on the rest. */
const fullRows = (/** @type {string} */ text = 'Yes') =>
  Object.fromEntries(CAPABILITIES.map((row) => [row.id, { level: row.rated ? 'yes' : 'info', text }]));

test('a rated cell must start with its level word, be one line and fit 60 characters; an info cell may say anything', () => {
  assert.equal(cellProblem({ level: 'yes', text: 'Yes, on Pro' }), undefined);
  assert.equal(cellProblem({ level: 'unknown', text: 'Not documented' }), undefined);
  assert.equal(cellProblem({ level: 'info', text: 'Your own machine' }), undefined);
  assert.match(cellProblem({ level: 'partial', text: 'Only with tmux' }) ?? '', /must start with "Partial"/);
  // "Not documented" begins with "No" but is the unknown level's phrase, not a no.
  assert.match(cellProblem({ level: 'no', text: 'Not documented' }) ?? '', /must start with "No"/);
  assert.equal(cellProblem({ level: 'no', text: 'No. Runs only through the maker service' }), undefined);
  assert.equal(cellProblem({ level: 'yes', text: `Yes ${'x'.repeat(56)}` }), undefined, 'exactly 60 characters');
  assert.match(cellProblem({ level: 'yes', text: `Yes ${'x'.repeat(57)}` }) ?? '', /must be 1 to 60/);
  assert.match(cellProblem({ level: 'maybe', text: 'Maybe' }) ?? '', /not one of/);
  // A line break would split the Markdown twin's table row in two.
  assert.match(cellProblem({ level: 'info', text: 'first\nsecond' }) ?? '', /one line/);
});

test('rowProblems names a missing row, an unknown row and a bad cell, each with where it came from', () => {
  const rows = fullRows();
  delete rows.mosh;
  rows.invented = { level: 'yes', text: 'Yes' };
  rows.push = { level: 'partial', text: 'Sometimes' };
  const problems = rowProblems(rows, 'termius.md');
  assert.equal(problems.length, 3, problems.join('\n'));
  assert.ok(problems.some((problem) => problem.startsWith('termius.md: no "mosh" row')));
  assert.ok(problems.some((problem) => problem.includes('"invented" is not a capability row')));
  assert.ok(problems.some((problem) => problem.includes('"push" a partial cell')));
  assert.deepEqual(rowProblems(fullRows(), 'ok.md'), []);
});

test('rowProblems rejects a rating on a descriptive row and no rating on a rated row', () => {
  const rows = fullRows();
  rows.price = { level: 'yes', text: 'Yes, free' };
  rows.desktop = { level: 'info', text: 'iPad app on a Mac' };
  const problems = rowProblems(rows, 'kittylitter.md');
  assert.equal(problems.length, 2, problems.join('\n'));
  assert.ok(problems.some((problem) => problem.includes('"price" is a descriptive row')));
  assert.ok(problems.some((problem) => problem.includes('"desktop" is a rated row')));
});

/**
 * @param {string} id
 * @param {number} order
 * @param {string[]} related
 * @param {string[]} solutions
 */
const comparison = (id, order, related = [], solutions = []) => ({ id, where: `${id}.md`, order, related, solutions });

test('relationProblems rejects a self link, a missing page, a missing solution and a repeated order', () => {
  const entries = [
    comparison('termius', 1, ['termius', 'blink-shell'], ['mosh-client-ios']),
    comparison('blink-shell', 2, ['nope'], ['gone']),
    comparison('shellfish', 2, ['termius'], ['mosh-client-ios']),
  ];
  const problems = relationProblems(entries, new Set(['mosh-client-ios']));
  assert.deepEqual(problems, [
    'termius.md: related lists the page itself (termius)',
    'blink-shell.md: related slug "nope" is not a comparison',
    'blink-shell.md: solutions slug "gone" is not a solution page',
    'shellfish.md: order 2 is also used by blink-shell.md',
  ]);
});

test('solutionProblems treats a help page the release switch hides as missing', () => {
  const entries = [
    { id: 'mosh-client-ios', where: 'mosh-client-ios.md', order: 1, compare: ['termius', 'ghost'], help: ['mosh', 'supported-agents'] },
    { id: 'tmux-on-iphone', where: 'tmux-on-iphone.md', order: 1, compare: ['termius'], help: ['tmux', 'mosh'] },
  ];
  const problems = solutionProblems(entries, new Set(['termius']), new Set(['mosh', 'tmux']));
  assert.deepEqual(problems, [
    'mosh-client-ios.md: compare slug "ghost" is not a comparison',
    'mosh-client-ios.md: help slug "supported-agents" is not a published help page',
    'tmux-on-iphone.md: order 1 is also used by mosh-client-ios.md',
  ]);
});

test('bodyProblems rejects an H1, /install.sh and a link to an unpublished page, however it is written, and ignores fenced code, anchors and other sites', () => {
  const routes = new Set(['/pricing', '/help/mosh', '/compare/termius']);
  const origin = 'https://waycar.dev';
  const fine = [
    '## Set it up',
    'See [pricing](/pricing#launch), [mosh](https://waycar.dev/help/mosh?from=x) and [Termius](https://termius.com).',
    '```sh',
    '# a shell comment, not a heading',
    'curl -fsSL https://waycar.dev/install.sh | sh',
    '```',
    '1. Run this:',
    '   ```sh',
    '   # also not a heading',
    '   ```',
  ].join('\n');
  assert.deepEqual(bodyProblems(fine, 'ok.md', routes, origin), []);

  const bad = [
    '# A second H1',
    'A hidden page: [agents](/help/supported-agents). A typo: [Termius](/compare/termus).',
    'The script: [install](/install.sh), or copied from the address bar: [install](https://waycar.dev/install.sh).',
    'A pasted anchor: <a href="/help/carplay">CarPlay</a>.',
    'A reference link: [the script][1].',
    '',
    '[1]: /install.sh',
  ].join('\n');
  const problems = bodyProblems(bad, 'bad.md', routes, origin);
  assert.equal(problems.length, 7, problems.join('\n'));
  assert.ok(problems.some((problem) => problem.includes('H1')));
  assert.ok(problems.some((problem) => problem.includes('/help/supported-agents is not a published page')));
  assert.ok(problems.some((problem) => problem.includes('/compare/termus is not a published page')));
  assert.ok(problems.some((problem) => problem.includes('/help/carplay is not a published page')));
  assert.equal(problems.filter((problem) => problem.includes('never link /install.sh')).length, 3);
});

test('documentTitle names the site once, and titleProblem flags a <title> over 60 characters', () => {
  assert.equal(documentTitle('Waycar vs Termius', 'Waycar vs Termius: mosh and agents'), 'Waycar vs Termius: mosh and agents');
  assert.equal(documentTitle('Run Claude Code from iPhone'), 'Run Claude Code from iPhone · Waycar');
  assert.equal(documentTitle('A long page title', 'Short'), 'Short · Waycar');
  // The suffix is 9 characters, so a title that lacks the brand may be 51.
  assert.equal(titleProblem('x'.repeat(51), undefined), undefined);
  assert.match(titleProblem('x'.repeat(52), undefined) ?? '', /61 characters/);
  assert.equal(titleProblem('Waycar vs x', `Waycar ${'x'.repeat(53)}`), undefined);
  assert.match(titleProblem('Waycar vs x', `Waycar ${'x'.repeat(54)}`) ?? '', /61 characters/);
});

test('markdownTable lists Waycar then the other product, group by group, and escapes pipes', () => {
  const waycar = fullRows('Yes');
  const other = fullRows('Yes');
  other['general-ssh'] = { level: 'yes', text: 'Yes | SFTP' };
  const lines = markdownTable(waycar, other, 'Termius').split('\n');
  assert.equal(lines[0], '| | Waycar | Termius |');
  assert.equal(lines[1], '| --- | --- | --- |');
  assert.equal(lines[2], '| **How it connects** | | |');
  // Three group rows, plus one line per capability, under the two header lines.
  assert.equal(lines.length, 2 + 3 + CAPABILITIES.length);
  assert.ok(lines.includes('| General SSH tools (SFTP, port forwarding, any server) | Yes | Yes \\| SFTP |'), lines.join('\n'));
});

test('every capability row id is unique', () => {
  assert.equal(new Set(CAPABILITY_IDS).size, CAPABILITY_IDS.length);
});
