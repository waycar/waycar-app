// The right rail of an article page (/articles/<slug>): copy, links and the
// per-article guide picks. Copy and claim limits are WAY-302's rail-content
// document. Rules that hold for every module:
//   - Never "popular", "most read" or ranked: the picks are editorial.
//   - No price, no open source or herdr affiliation claim, and never "no
//     servers" or "nothing leaves your device" (the push relay carries
//     encrypted notifications).
//   - Setup and Launch steps are labeled "For iPhone and iPad"; there is no
//     platform detection. The Get Waycar picker (GetPicker.astro) is where
//     Android readers see "Coming soon".
// Module ids go out as the `module` property of the analytics events (see
// README "Events"); they come from here, never from element text.

export const RAIL_MODULE_IDS = ['get-app', 'start-here', 'host-setup', 'first-launch'] as const;
export type RailModuleId = (typeof RAIL_MODULE_IDS)[number];

/** Every id an article page may send as `module`: the rail's, and the TOC card's. */
export const ARTICLE_MODULE_IDS = [...RAIL_MODULE_IDS, 'toc-card'] as const;

export const GET_APP = {
  heading: 'Check your coding agents from your phone',
  body: 'Waycar connects to herdr or tmux on your own machines. For iPhone and iPad.',
  note: 'No Waycar account. No cloud relay for sessions. Your machine must stay on, awake and reachable.',
};

/** The card pinned under the table of contents. Same App Store link as `get-app`. */
export const TOC_CARD = {
  heading: 'Your agents, away from your desk',
  body: 'Check herdr and tmux sessions on your own machine. For iPhone and iPad.',
};

export const START_HERE = {
  heading: 'Start here',
  body: 'Pick a guide for the machine and agent you use.',
};

export const INSTALL_COMMAND = 'curl -fsSL https://waycar.dev/install.sh | sh';

export const HOST_SETUP = {
  heading: 'Have Waycar on your phone? Set up your Host',
  label: 'For iPhone and iPad',
  body: 'On your Mac or Linux machine, check the requirements. Then run:',
  links: [
    { href: '/help/requirements', text: 'Check requirements' },
    { href: '/help/install', text: 'Read the install steps' },
  ],
  pair: 'Keep the Pairing Code open on your Host. In Waycar, tap Scan to Pair.',
  pairLink: { href: '/help/pairing', text: 'Pair your Host' },
};

export const FIRST_LAUNCH = {
  heading: 'Start an agent from your phone',
  label: 'For iPhone and iPad',
  body: 'Once paired, tap + in the Console. Pick your Host, Workspace and installed agent. Tap Start.',
  link: { href: '/help/new-agent', text: 'Start your first agent' },
  note: 'Starting an agent or shell from Waycar counts as a Launch. Opening an already running session does not.',
};

/** Four guides for an article with no picks of its own, and the fill for one with fewer than four live. */
export const DEFAULT_PICKS = [
  'claude-code-on-a-build-server-from-your-phone',
  'run-omp-from-your-phone-over-mosh',
  'coding-agents-in-your-home-lab-from-your-phone',
  'reach-your-local-network-with-tailscale',
];

export const PICK_COUNT = 4;

// Hand-picked per article, in this order: the same agent first, the same
// machine scenario next, then networking, then roaming. A slug that is the
// page itself, not live, or repeated is skipped, and the defaults fill the gap.
export const PICKS: Record<string, string[]> = {
  'claude-code-on-a-build-server-from-your-phone': [
    'coding-agents-in-your-home-lab-from-your-phone',
    'reach-your-local-network-with-tailscale',
    'keep-a-coding-agent-attached-through-dead-zones',
    'run-omp-from-your-phone-over-mosh',
  ],
  'run-omp-from-your-phone-over-mosh': [
    'how-we-set-up-advisors-for-omp',
    'claude-code-on-a-build-server-from-your-phone',
    'reach-your-local-network-with-tailscale',
    'keep-a-coding-agent-attached-through-dead-zones',
  ],
  'how-we-set-up-advisors-for-omp': [
    'run-omp-from-your-phone-over-mosh',
    'claude-code-on-a-build-server-from-your-phone',
    'reach-your-local-network-with-tailscale',
    'keep-a-coding-agent-attached-through-dead-zones',
  ],
  'coding-agents-in-your-home-lab-from-your-phone': [
    'claude-code-on-a-build-server-from-your-phone',
    'reach-your-local-network-with-tailscale',
    'keep-a-coding-agent-attached-through-dead-zones',
    'run-omp-from-your-phone-over-mosh',
  ],
  'reach-your-local-network-with-tailscale': [
    'reach-your-ai-harness-while-you-are-away',
    'coding-agents-in-your-home-lab-from-your-phone',
    'claude-code-on-a-build-server-from-your-phone',
    'keep-a-coding-agent-attached-through-dead-zones',
  ],
  'reach-your-ai-harness-while-you-are-away': [
    'reach-your-local-network-with-tailscale',
    'claude-code-on-a-build-server-from-your-phone',
    'keep-a-coding-agent-attached-through-dead-zones',
    'run-omp-from-your-phone-over-mosh',
  ],
  'keep-a-coding-agent-attached-through-dead-zones': [
    'run-omp-from-your-phone-over-mosh',
    'claude-code-on-a-build-server-from-your-phone',
    'reach-your-local-network-with-tailscale',
    'coding-agents-in-your-home-lab-from-your-phone',
  ],
  'check-pi-agents-from-your-iphone': [
    'run-omp-from-your-phone-over-mosh',
    'coding-agents-in-your-home-lab-from-your-phone',
    'reach-your-local-network-with-tailscale',
    'keep-a-coding-agent-attached-through-dead-zones',
  ],
  'codex-cli-from-your-iphone': [
    'claude-code-on-a-build-server-from-your-phone',
    'coding-agents-in-your-home-lab-from-your-phone',
    'reach-your-local-network-with-tailscale',
    'keep-a-coding-agent-attached-through-dead-zones',
  ],
  'opencode-from-your-iphone': [
    'claude-code-on-a-build-server-from-your-phone',
    'coding-agents-in-your-home-lab-from-your-phone',
    'reach-your-local-network-with-tailscale',
    'keep-a-coding-agent-attached-through-dead-zones',
  ],
};

/**
 * The slugs of the "Start here" guides for the article `slug`: its own picks
 * (else the defaults) that are live, then the defaults to fill, never the page
 * itself and never twice.
 */
export function startHereSlugs(slug: string, live: ReadonlySet<string>): string[] {
  const picked: string[] = [];
  for (const candidate of [...(PICKS[slug] ?? []), ...DEFAULT_PICKS]) {
    if (picked.length === PICK_COUNT) break;
    if (candidate !== slug && live.has(candidate) && !picked.includes(candidate)) picked.push(candidate);
  }
  return picked;
}

/**
 * How many rail modules fit beside an article of `words` prose words under
 * `headings` H2s. A module is a fixed height and the rail does not stretch, so
 * a short article gets the first few and the rest follow below it, instead of
 * a rail taller than the text. The estimate is a floor: 2 px a word is what
 * plain prose takes on the 640 px column, plus 150 px a heading, with nothing
 * for tables and code. Measured at 1440 px (2026-10-26) the 8 live articles run
 * 4,600 to 8,200 px, the estimate puts the shortest at 3,200, and the four
 * modules with their gaps stack 1,584: all four sit beside every live article.
 * (The "Get Waycar" module lost its Android notice and got a shorter button
 * label when the picker landed: 377 px became 288 at 1440 px.)
 */
export const MODULE_HEIGHTS = [290, 360, 500, 290];
export const MODULE_GAP = 48;
export const PX_PER_WORD = 2;
export const PX_PER_HEADING = 150;

export function modulesBesideArticle(words: number, headings: number): number {
  const room = words * PX_PER_WORD + headings * PX_PER_HEADING;
  let used = 0;
  let count = 0;
  for (const height of MODULE_HEIGHTS) {
    const next = used + height + (count > 0 ? MODULE_GAP : 0);
    if (next > room) break;
    used = next;
    count += 1;
  }
  return count;
}
