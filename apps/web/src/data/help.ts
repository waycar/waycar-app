// Help docs categories (/help, src/content/help/). The one list of category
// ids, their labels, and their display order lives in
// src/content/help/categories.json, shared with the iOS app (which bundles
// the help folder for in-app Help). The content schema
// (src/content.config.ts) accepts only these ids, and every help page, nav,
// index, and search result reads its label from here. The glob loader reads
// only `*.md`, so the JSON never becomes a page.
import categories from '../content/help/categories.json';

export type HelpCategory = { readonly id: string; readonly label: string };
export type HelpCategoryId = HelpCategory['id'];

export const HELP_CATEGORIES: readonly HelpCategory[] = categories;

const ids = HELP_CATEGORIES.map((category) => category.id);
if (ids.length === 0) throw new Error('src/content/help/categories.json lists no categories');
if (new Set(ids).size !== ids.length) throw new Error('src/content/help/categories.json repeats a category id');

export const HELP_CATEGORY_IDS = ids as [HelpCategoryId, ...HelpCategoryId[]];

export function helpCategory(id: HelpCategoryId): HelpCategory {
  const category = HELP_CATEGORIES.find((candidate) => candidate.id === id);
  if (!category) throw new Error(`Unknown help category: ${id}`);
  return category;
}

export { helpMarkdownPath, helpPath } from './help-paths';
