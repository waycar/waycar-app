// /llms.txt (https://llmstxt.org): a short map of the site for AI agents, and
// the reviewed fallback. The deploy job replaces dist/llms.txt with a richer
// file generated from the built site (scripts/generate-llms-txt.mjs) when
// generation succeeds and passes validation; otherwise this one ships. The
// full product detail lives in /index.md (src/llms/index.md). Never link
// /install.sh here: every GET of it logs a `plugin_install_requested` event.
// The Help section lists every help page's Markdown twin from the collection,
// so a new page joins it on its own. The Articles section does the same for
// published articles (drafts never appear). The Compare and Solutions sections
// do the same for the comparison and solution pages.
import type { APIRoute } from 'astro';
import { APP_STORE_LISTING_URL, ON_APP_STORE } from '../data/links';
import { articleLinkLine, getArticles } from '../lib/articles';
import { comparisonLinkLine, getComparisons } from '../lib/compare';
import { getHelpPages, helpLinkLine } from '../lib/help';
import { getSolutions, solutionLinkLine } from '../lib/solutions';

export const GET: APIRoute = async () => {
  // One line per help page, linking its Markdown twin, as /help.md lists it.
  const help = (await getHelpPages()).map(helpLinkLine).join('\n');
  const articles = (await getArticles()).map(articleLinkLine).join('\n');
  const compare = (await getComparisons()).map(comparisonLinkLine).join('\n');
  const solutions = (await getSolutions()).map(solutionLinkLine).join('\n');
  const availability = ON_APP_STORE
    ? `On the App Store for iPhone and iPad: ${APP_STORE_LISTING_URL}. Android app coming soon.`
    : 'Coming soon to the App Store for iPhone and iPad. Android app coming soon.';
  const body = `# Waycar

> Waycar is a native iPhone and iPad app for checking on your coding agents (Claude Code, Codex, omp, Gemini, opencode, pi and more) running in herdr, tmux, Herdr Core or Zellij, or as Codex and OpenCode 2 server chats, on your own Mac or Linux machine. Agent terminals run over mosh and fall back to SSH. No account, no cloud between you and your sessions. An Android app is coming next.

- Availability: ${availability}
- Price: Waycar is free. Users pay for their own machines and AI providers.
- Install on each machine: \`curl -fsSL https://waycar.dev/install.sh | sh\`, then scan the pairing QR in Waycar.
- Requirements: iOS/iPadOS 18+; herdr 0.7.5+, tmux 3.2+ or Herdr Core 0.1.10+ on the Host (no Node needed); Zellij 0.46+, Codex 0.167+ and OpenCode 2.2+ in the next app update; OpenSSH on the Host (stream-local forwarding on, for herdr; on macOS, Remote Login on); mosh-server and open UDP for mosh.
- Made by OTREVA, LLC. Not affiliated with or endorsed by herdr, CodexBar, Anthropic, OpenAI, or Google.

## Docs

- [Waycar product guide](https://waycar.dev/index.md): every feature, mosh vs SSH, herdr vs tmux, setup, requirements, full FAQ
- [Waycar in CarPlay](https://waycar.dev/carplay): hear and answer your agents by voice in CarPlay on iPhone (iOS 26.4 or later)
- [Support](https://waycar.dev/support): help and contact
- [Privacy policy](https://waycar.dev/privacy): what data Waycar handles

## Help

- [Waycar Help](https://waycar.dev/help.md): every help page by category, as Markdown
${help}

## Articles

- [Waycar Articles](https://waycar.dev/articles.md): every article, as Markdown
${articles}

## Compare

- [Waycar Comparisons](https://waycar.dev/compare.md): how Waycar compares with Termius, Blink Shell, Claude Code Remote Control and more, as Markdown
${compare}

## Solutions

- [Waycar Solutions](https://waycar.dev/solutions.md): plain answers for reaching a coding agent from an iPhone or iPad, as Markdown
${solutions}

## Optional

- [iPad gallery](https://waycar.dev/ipad): screenshots of the iPad app
- [herdr](https://herdr.dev): the terminal workspace manager Waycar works with
- [CodexBar](https://github.com/steipete/CodexBar): optional tool behind the AI Usage view
`;
  return new Response(body, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
