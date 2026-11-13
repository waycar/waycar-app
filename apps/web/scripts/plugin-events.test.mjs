// @ts-check
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { pluginEvent } from '../src/lib/plugin-events.mjs';

const TARBALL = '/plugin/waycar-1.5.1-x86_64-unknown-linux-musl-0123456789ab.tar.gz';

/**
 * @param {string} method
 * @param {string} pathname
 * @param {string} [query]
 */
const event = (method, pathname, query = '') => pluginEvent(method, pathname, new URLSearchParams(query));

test('the package GET is logged, with no person data and no properties when the query is empty', () => {
  assert.deepEqual(event('GET', TARBALL), { event: 'plugin_package_downloaded', internal: false, properties: {} });
});

test('only the package itself counts: not its checksum file, other files, HEAD or POST', () => {
  assert.equal(event('GET', `${TARBALL}.sha256`), null);
  assert.equal(event('GET', '/plugin/'), null);
  assert.equal(event('GET', `${TARBALL}/x`), null);
  assert.equal(event('GET', '/plugin/waycar-1.5.1-x86_64-unknown-linux-musl-0123456789AB.tar.gz'), null);
  assert.equal(event('GET', '/plugin/waycar-1.5.1-x86_64-unknown-linux-musl-0123.tar.gz'), null);
  assert.equal(event('GET', '/plugin/../install.sh.tar.gz'), null);
  assert.equal(event('HEAD', TARBALL), null);
  assert.equal(event('POST', TARBALL), null);
  assert.equal(event('GET', '/help/install'), null);
});

test('a prerelease version still matches the name package-plugin.sh writes', () => {
  assert.equal(event('GET', '/plugin/waycar-1.6.0-rc.1-aarch64-apple-darwin-0123456789ab.tar.gz')?.event, 'plugin_package_downloaded');
});

test('each of the four targets matches; an unknown target and the old no-target name do not', () => {
  for (const target of [
    'x86_64-unknown-linux-musl',
    'aarch64-unknown-linux-musl',
    'aarch64-apple-darwin',
    'x86_64-apple-darwin',
  ]) {
    assert.equal(event('GET', `/plugin/waycar-1.7.0-${target}-0123456789ab.tar.gz`)?.event, 'plugin_package_downloaded');
  }
  assert.equal(event('GET', '/plugin/waycar-1.7.0-x86_64-unknown-linux-gnu-0123456789ab.tar.gz'), null);
  assert.equal(event('GET', '/plugin/waycar-1.7.0-riscv64-unknown-linux-musl-0123456789ab.tar.gz'), null);
  assert.equal(event('GET', '/plugin/waycar-1.7.0-x86_64-apple-darwin.tar.gz'), null);
  assert.equal(event('GET', '/plugin/waycar-1.7.0-0123456789ab.tar.gz'), null);
});

test('our own package downloads carry internal, other values of the flag do not', () => {
  assert.equal(event('GET', TARBALL, 'internal=1')?.internal, true);
  assert.equal(event('GET', TARBALL, 'internal=true')?.internal, false);
  assert.equal(event('GET', TARBALL, 'internal=0')?.internal, false);
  assert.equal(event('GET', '/install.sh', 'internal=1')?.internal, true);
  assert.equal(event('GET', '/install.sh')?.internal, false);
});

test('install.sh reports kind only when the caller states a valid one', () => {
  assert.deepEqual(event('GET', '/install.sh'), { event: 'plugin_install_requested', internal: false, properties: {} });
  assert.deepEqual(event('GET', '/install.sh', 'kind=update')?.properties, { kind: 'update' });
  assert.deepEqual(event('GET', '/install.sh', 'kind=install&internal=1')?.properties, { kind: 'install' });
  assert.deepEqual(event('GET', '/install.sh', 'kind=upgrade')?.properties, {});
  assert.deepEqual(event('GET', '/install.sh', 'kind=')?.properties, {});
});

test('the package reports via and kind from the script, and nothing else from the query', () => {
  assert.deepEqual(event('GET', TARBALL, 'via=install&kind=update')?.properties, { via: 'install', kind: 'update' });
  assert.deepEqual(event('GET', TARBALL, 'via=pair')?.properties, { via: 'pair' });
  assert.deepEqual(event('GET', TARBALL, 'via=ssh&kind=Install')?.properties, {});
  assert.deepEqual(event('GET', TARBALL, 'via=pair&utm_source=x&email=a%40b.c&internal=1')?.properties, { via: 'pair' });
});
