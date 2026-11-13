// @ts-check
// Worker-only download events. Query values are fixed enums; never forward
// arbitrary query text to PostHog.
// Script fetches cannot reveal install versus update. `kind` is optional on
// plugin_install_requested until a caller explicitly supplies it. The
// installer knows whether a plugin exists and sends `kind` on its package
// request, plus `via=pair` for pair-only runs and `internal=1` for our tooling.

const KINDS = new Set(['install', 'update']);
const VIAS = new Set(['install', 'pair']);

/**
 * `/plugin/waycar-<version>-<target>-<sha12>.tar.gz`, the name
 * scripts/package-plugin.sh writes for each of the four release targets: a
 * semver, the target triple, then the first 12 hex digits of the tarball's
 * SHA-256. The `.sha256` file next to it does not match.
 */
const PACKAGE_PATH =
  /^\/plugin\/waycar-\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?-(?:x86_64-unknown-linux-musl|aarch64-unknown-linux-musl|aarch64-apple-darwin|x86_64-apple-darwin)-[0-9a-f]{12}\.tar\.gz$/;

/**
 * @param {URLSearchParams} searchParams
 * @param {string} key
 * @param {Set<string>} allowed
 * @returns {string | undefined}
 */
function enumParam(searchParams, key, allowed) {
  const value = searchParams.get(key);
  return value !== null && allowed.has(value) ? value : undefined;
}

/**
 * The event a successful request logs, or null for any other request.
 *
 * @param {string} method
 * @param {string} pathname
 * @param {URLSearchParams} searchParams
 * @returns {{ event: string, internal: boolean, properties: Record<string, string> } | null}
 */
export function pluginEvent(method, pathname, searchParams) {
  if (method !== 'GET') return null;
  const internal = searchParams.get('internal') === '1';
  if (pathname === '/install.sh') {
    const kind = enumParam(searchParams, 'kind', KINDS);
    return { event: 'plugin_install_requested', internal, properties: kind ? { kind } : {} };
  }
  if (PACKAGE_PATH.test(pathname)) {
    const via = enumParam(searchParams, 'via', VIAS);
    const kind = enumParam(searchParams, 'kind', KINDS);
    return {
      event: 'plugin_package_downloaded',
      internal,
      properties: { ...(via ? { via } : {}), ...(kind ? { kind } : {}) },
    };
  }
  return null;
}
