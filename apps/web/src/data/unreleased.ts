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
// Pages for a feature only `main` has can stay on the site with a note that it
// comes in the next update (`nextUpdateNote`), instead of being hidden.
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

/** Help pages the site leaves out while the gate holds. */
export const HIDDEN_HELP_PAGES: readonly string[] = [];

export type HelpEdit =
  /** Replace every occurrence of `replace` with `with`. */
  | { replace: string; with: string }
  /** Delete each line that contains the text. */
  | { dropLine: string }
  /** Replace each line that contains `setLine` with `to`. */
  | { setLine: string; to: string }
  /** Delete the heading line and everything under it up to the next heading of the same or a higher level. */
  | { dropSection: string }
  /** Insert a paragraph at the top of the body, right after the front matter. */
  | { prependBody: string };

const dropLine = (text: string): HelpEdit => ({ dropLine: text });
const setLine = (text: string, to: string): HelpEdit => ({ setLine: text, to });
/** For a page about a feature 1.3.0 lacks: shown on the site until the next release lifts the gate. */
const nextUpdateNote: HelpEdit = { prependBody: '> Coming in the next update of Waycar.' };

/** Edits that turn the pages that stay into 1.3.0's text, by slug, applied to the whole file (front matter included). */
export const RELEASED_HELP_EDITS: Readonly<Record<string, readonly HelpEdit[]>> = {
  'add-host-manually': [
    dropLine('/help/find-computers'),
    setLine(
      'In the Hosts sheet, tap **Add Host**, then **Add Manually**.',
      '   - In the Hosts sheet, tap **Add Host**.',
    ),
  ],
  'ai-usage': [dropLine('**"Claude timed out"**')],
  'codex': [nextUpdateNote],
  'find-computers': [nextUpdateNote],
  'new-agent': [
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
  'opencode': [nextUpdateNote],
  'zellij': [nextUpdateNote],
};
