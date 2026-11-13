// @ts-check
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createSearchIndex, excerpt, highlight, searchHelp } from '../src/lib/help-search.mjs';

/**
 * @param {string} slug
 * @param {Partial<import('../src/lib/help-search.mjs').HelpSearchPage>} fields
 * @returns {import('../src/lib/help-search.mjs').HelpSearchPage}
 */
const page = (slug, fields) => ({
  slug,
  title: slug,
  description: '',
  category: 'Test',
  keywords: [],
  headings: [],
  body: '',
  ...fields,
});

/**
 * @param {import('../src/lib/help-search.mjs').HelpSearchPage[]} pages
 * @param {string} query
 */
const slugs = (pages, query) => searchHelp(createSearchIndex(pages), query).map((result) => result.page.slug);

test('ranks a title match above keywords, headings, description, and body', () => {
  const pages = [
    page('in-body', { title: 'Alpha', body: 'Reconnects over mosh after a network change.' }),
    page('in-description', { title: 'Beta', description: 'Use mosh for flaky networks.' }),
    page('in-heading', { title: 'Gamma', headings: ['Turn on mosh'] }),
    page('in-keywords', { title: 'Delta', keywords: ['mosh'] }),
    page('in-title', { title: 'mosh' }),
  ];
  assert.deepEqual(slugs(pages, 'mosh'), ['in-title', 'in-keywords', 'in-heading', 'in-description', 'in-body']);
});

test('requires every term to match some field', () => {
  const pages = [
    page('chat-only', { title: 'Chat Mode' }),
    page('both', { title: 'Chat Mode troubleshooting', body: 'Notifications stay quiet until the reply.' }),
    page('notifications-only', { title: 'Notifications' }),
  ];
  assert.deepEqual(slugs(pages, 'chat notifications'), ['both']);
});

test('ranks a whole word above a word that only starts with the term', () => {
  const pages = [page('prefix', { title: 'Hosts sheet' }), page('whole', { title: 'Host keys' })];
  assert.deepEqual(slugs(pages, 'host'), ['whole', 'prefix']);
  assert.deepEqual(slugs(pages, 'hos'), ['prefix', 'whole']);
});

test('ranks a title that contains the query as a phrase above one with the same words apart', () => {
  const pages = [page('mode-for-chat', { title: 'Mode for chat' }), page('chat-mode', { title: 'Chat Mode' })];
  assert.deepEqual(slugs(pages, 'chat mode'), ['chat-mode', 'mode-for-chat']);
});

test('matches the start of a word while typing, not the middle', () => {
  const pages = [page('notifications', { title: 'Notifications' })];
  assert.deepEqual(slugs(pages, 'notif'), ['notifications']);
  assert.deepEqual(slugs(pages, 'fications'), []);
});

test('returns nothing for a query no page matches, or an empty one', () => {
  const pages = [page('mosh', { title: 'mosh', body: 'UDP ports 60000 to 61000' })];
  assert.deepEqual(slugs(pages, 'carplay'), []);
  assert.deepEqual(slugs(pages, '  ?! '), []);
});

test('ignores case and diacritics on both sides', () => {
  const pages = [page('resume', { title: 'Résumé an agent' }), page('cafe', { title: 'cafe' })];
  assert.deepEqual(slugs(pages, 'RESUME'), ['resume']);
  assert.deepEqual(slugs(pages, 'Café'), ['cafe']);
});

test('tolerates one typo in a longer term only', () => {
  const pages = [page('notifications', { title: 'Notifications' }), page('mosh', { title: 'mosh' })];
  assert.deepEqual(slugs(pages, 'notifcations'), ['notifications']);
  assert.deepEqual(slugs(pages, 'mohs'), []);
});

test('matches contractions typed with or without the apostrophe', () => {
  const pages = [
    page('cant-connect', { title: "Can't connect to a Host" }),
    page('mosh', { title: 'mosh isn’t connecting' }),
    page('notifications', { title: "Notifications don't arrive" }),
  ];
  assert.deepEqual(slugs(pages, 'cant connect'), ['cant-connect']);
  assert.deepEqual(slugs(pages, "can't connect"), ['cant-connect']);
  assert.deepEqual(slugs(pages, 'dont'), ['notifications']);
  assert.deepEqual(slugs(pages, 'isnt'), ['mosh']);
  const [result] = searchHelp(createSearchIndex(pages), 'cant');
  assert.deepEqual(highlight(result.page.title, 'cant', result.words), [
    { text: "Can't", match: true },
    { text: ' connect to a Host', match: false },
  ]);
});

test('highlights matched words in the original text', () => {
  const [result] = searchHelp(createSearchIndex([page('x', { title: 'Résumé closed sessions' })]), 'resu sess');
  assert.deepEqual(highlight(result.page.title, 'resu sess', result.words), [
    { text: 'Résumé', match: true },
    { text: ' closed ', match: false },
    { text: 'sessions', match: true },
  ]);
});

test('excerpts the body around a match the description lacks', () => {
  const body = `${'Lorem ipsum dolor sit amet. '.repeat(20)}Tap Trust New Key to accept it. ${'Sed do eiusmod. '.repeat(20)}`;
  const target = page('x', { description: 'Host keys protect connections.', body });
  assert.equal(excerpt(target, 'host'), 'Host keys protect connections.');
  const text = excerpt(target, 'trust');
  assert.ok(text.startsWith('…') && text.endsWith('…') && text.includes('Tap Trust New Key'), text);
});
