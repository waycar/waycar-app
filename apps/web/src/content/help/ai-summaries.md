---
title: AI Summaries
description: AI Summaries add one AI-written sentence to each agent card and notification, saying what the agent is doing or what it needs.
category: console
order: 90
keywords: [agent summary, one-line summary, notification text, anthropic, openai, openrouter, privacy, opt in]
related: [console, agent-progress, privacy, agent-card-fields]
---

AI Summaries put one short sentence under each agent card saying what the agent is doing, where it ended up, or what it needs from you. Notifications carry the same sentence, such as "Done: fixed 14 missing VoiceOver labels…". They're off until you turn them on, and the text is written by an AI model your Host already has access to.

## Turn on AI Summaries

1. Open **Settings**.
2. Turn on **AI Summaries**.
3. Read the **Turn on AI Summaries?** message and tap **Turn On**.

**Not Now** keeps them off. If you haven't chosen yet, Waycar also asks when you turn on notifications for a Host. Turn the switch off at any time to stop both the card lines and the model calls on your Hosts.

## What does a summary look like?

Each card shows one sentence of at most 100 characters, with how old it is, for example "1m". When the agent has moved on to another status, or the line is more than three minutes old, the sentence dims, and the age under the status stays visible. While an agent's first summary is on its way, the card shows a placeholder.

## When are summaries written?

- When an agent turns Blocked or Done, for the notification.
- While Waycar is open, about once a minute and when an agent changes status.

Only agents whose screen changed since their last summary are summarized, so idle agents cost nothing.

For a Working agent, the same call also names the phase of its work, such as exploring or verifying, for [Agent Progress](/help/agent-progress). An agent's plan steps are read from its own session file on the Host and are sent to no model.

## What is sent, and to whom?

Each Host sends up to the last 60 lines of an agent's screen to an AI provider, using the AI accounts already set up on that Host:

- Anthropic (Claude, through Claude Code, omp, or an API key)
- OpenAI (ChatGPT, through Codex, omp, or an API key)
- OpenRouter, which passes it to Google or OpenAI models
- Whatever model pi, Qwen Code, Gemini CLI, GitHub Copilot CLI, opencode, Kilo Code, Hermes Agent or Muse is set up with, asked through that agent with its tools turned off

The cheapest available model is used first. The request goes from your Host straight to that provider. It never passes through Waycar, the push relay, or us.

> The screen can include secrets, such as tokens or file contents. Leave AI Summaries off if that's a concern.

See [Privacy and analytics](/help/privacy) and the full [privacy policy](/privacy).

## What does the Host need?

Summaries run on each Host with whichever of these it already has:

- `claude` signed in, or `ANTHROPIC_API_KEY` set
- omp signed in to Anthropic or OpenAI
- `codex` signed in, or `OPENAI_API_KEY` set
- `OPENROUTER_API_KEY` set
- pi with a default provider it's signed in to
- Qwen Code or Gemini CLI with a sign-in method chosen in its settings (or `GEMINI_API_KEY` set)
- GitHub Copilot CLI with `GH_TOKEN`, `GITHUB_TOKEN`, `COPILOT_GITHUB_TOKEN` or its own provider set in the environment
- opencode or Kilo Code with your own model or provider configured
- Hermes Agent with a provider in its `config.yaml`
- Muse with an API key in the environment or a stored sign-in (`muse auth set` or `muse login`)

The Host checks which providers it can use once, then remembers the answer for an hour in `summary-provider.json`, in Waycar's config directory on the Host (`waycar status` prints the folder). After you sign in or add a key, summaries can take up to an hour to start. Delete that file to make the Host check again now.

To use your own tool instead, set `summary_command` in `notify.json` in the same folder to a list of program and arguments, such as `["llm", "-m", "gpt-4o-mini"]`. It gets the instruction as its last argument and the screen on standard input, and nothing else is tried if it fails.

## herdr and tmux

On herdr the Waycar herdr plugin writes the summaries; on tmux, Waycar's tools on the Host do the same job. Update Waycar on each Host to get them. See [Update Waycar on your Host](/help/update-host-tools).

## Troubleshooting

- **No summary under a card.** Check that **AI Summaries** is on, and that the Host has one of the sign-ins or keys above. A sign-in made in the last hour may not be picked up yet. With no model available, or if the model fails or times out, notifications keep their usual wording.
- **A Host was offline when you changed the switch.** It picks up the change the next time it connects.
