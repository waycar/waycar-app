// Help page URLs. Kept apart from src/data/help.ts so the help search's client
// script can import them without bundling the category list.

/** Public URL of a help page. */
export const helpPath = (slug: string) => `/help/${slug}`;
/** Its Markdown twin, for agents. */
export const helpMarkdownPath = (slug: string) => `/help/${slug}.md`;
