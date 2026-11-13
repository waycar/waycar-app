// The help gate: what the site hides of `main`'s help while the App Store has
// `APP_STORE_RELEASE`. `main` runs ahead of the App Store build and the site
// deploys from `main`, so help for features the listed app lacks stays off
// the site, and so does the changelog's Unreleased section
// (src/content.config.ts).
//
// The gate lifts by itself: once src/content/changelog/ holds a release newer
// than `APP_STORE_RELEASE` (`make publish` writes it), the site shows `main`'s
// help and the Unreleased section, and this file and src/lib/help-loader.ts
// are dormant. To gate a later release, set `APP_STORE_RELEASE` to it and list
// what `main` has beyond it below. README "Release content switch".
//
// The help folder (src/content/help/) is bundled whole into the iOS app, so no
// page is moved, renamed or edited for this. `src/lib/help-loader.ts` instead
// reads each page, drops the pages in `HIDDEN_HELP_PAGES`, applies
// `RELEASED_HELP_EDITS` to the text, and removes hidden slugs from `related`.
// A hidden page's slug left in a body link, or an edit that no longer matches
// its page, fails the build, so a change to a help page cannot quietly leak a
// hidden feature or break a link.

/** The version the App Store has; a release file newer than it lifts the gate. */
export const APP_STORE_RELEASE = '1.3.0';

/** Help pages for features 1.3.0 does not have. */
export const HIDDEN_HELP_PAGES: readonly string[] = ['codex', 'opencode', 'zellij'];

export type HelpEdit =
  /** Replace every occurrence of `replace` with `with`. */
  | { replace: string; with: string }
  /** Delete each line that contains the text. */
  | { dropLine: string }
  /** Replace each line that contains `setLine` with `to`. */
  | { setLine: string; to: string }
  /** Delete the heading line and everything under it up to the next heading of the same or a higher level. */
  | { dropSection: string };

const dropLine = (text: string): HelpEdit => ({ dropLine: text });
const setLine = (text: string, to: string): HelpEdit => ({ setLine: text, to });
const CODEX_NOTE = dropLine('/help/codex');
const OPENCODE_NOTE = dropLine('/help/opencode');

/** Edits that turn the pages that stay into 1.3.0's text, by slug, applied to the whole file (front matter included). */
export const RELEASED_HELP_EDITS: Readonly<Record<string, readonly HelpEdit[]>> = {
  'ai-usage': [dropLine('**"Claude timed out"**')],
  'closed-sessions': [CODEX_NOTE, OPENCODE_NOTE],
  'host-page': [CODEX_NOTE, OPENCODE_NOTE],
  'new-agent': [
    CODEX_NOTE,
    OPENCODE_NOTE,
    dropLine('On herdr, Waycar adds a suffix'),
    setLine(
      'Tap **Start** and the sheet closes.',
      "Tap **Start** and the sheet closes. Nothing is sent yet: the launch is kept on your device, and its card at the top of the Console reads **Waiting**. The next time Waycar is open and the Host connects, the agent starts on its own and its first message goes out once it's ready. To drop it, swipe the card or touch and hold it, then tap **Delete**.",
    ),
    dropLine('If Waycar closes or loses the answer while the agent is starting'),
    setLine(
      'Other failures still say why on the card',
      'If the start fails, the card says why: tap **Retry** or **Delete**. **Interrupted** means Waycar closed or lost the connection while the agent was starting, so it may already be running. Check the Console before you tap **Retry**.',
    ),
  ],
  'notifications': [CODEX_NOTE],
};
