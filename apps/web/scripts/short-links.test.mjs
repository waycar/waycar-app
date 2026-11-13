// @ts-check
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { SHORT_LINKS, shortLinkTarget } from '../src/lib/short-links.mjs';

test('the retired offer link no longer resolves', () => {
  for (const path of ['/x3', '/x3/', '/X3']) assert.equal(shortLinkTarget(path), null, path);
});

test('other paths are not short links', () => {
  for (const path of ['/', '/x', '/x33', '/x3/extra', '/go/x3', '/constructor', '/__proto__', '/toString']) {
    assert.equal(shortLinkTarget(path), null, path);
  }
});

test('every target is an https URL on a fixed host', () => {
  for (const target of Object.values(SHORT_LINKS)) {
    assert.match(target, /^https:\/\/(?:apps\.apple\.com|waycar\.dev)\//);
  }
});
