// The changelog collections (src/content.config.ts) as the /changelog routes
// use them: Unreleased (when it has a bullet), then releases newest first,
// split into pages of whole releases (rules in src/lib/changelog.mjs).
import { getCollection, type CollectionEntry } from 'astro:content';
import { countBullets, orderEntries, paginate } from './changelog.mjs';

export type ChangelogEntry =
  | { version: null; bullets: number; entry: CollectionEntry<'changelogUnreleased'> }
  | { version: string; date: string; bullets: number; entry: CollectionEntry<'changelog'> };

/** Every changelog page (index 0 is /changelog), each a list of whole entries in display order. */
export async function getChangelogPages(): Promise<ChangelogEntry[][]> {
  const [unreleased, releases] = await Promise.all([getCollection('changelogUnreleased'), getCollection('changelog')]);
  const entries: ChangelogEntry[] = [
    ...unreleased.map((entry) => ({ version: null, bullets: countBullets(entry.body ?? ''), entry })),
    ...releases.map((entry) => ({
      version: entry.data.version,
      date: entry.data.date,
      bullets: countBullets(entry.body ?? ''),
      entry,
    })),
  ];
  return paginate(orderEntries(entries));
}
