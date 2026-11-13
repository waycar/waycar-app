---
title: Agent Skills
description: Browse the Skills and custom commands an agent has on your Host, read one, and insert its command into your message without sending.
category: agents
order: 70
keywords: [slash commands, custom commands, skill.md, catalogue, insert, suggestions]
related: [composer, snippets, supported-agents]
---

Waycar reads the Skills and custom commands an agent has on your Host and lists them for you. Pick one and Waycar inserts its command into your message. It never sends on its own, so you can add more before you send.

## Insert a Skill

1. Open an agent.
2. Open **Skills** from the [Composer](/help/composer)'s **More** menu, the [Toolbar](/help/toolbar), or the **Skills** pane of the tools keyboard (tap **Tools Keyboard** on the Toolbar).
3. Find the Skill. Use **Search Skills** in a long list.
4. Tap the Skill to insert it.

To read what a Skill does first, touch and hold it, then tap **View Content**. **Insert** is in the same menu. From the tools keyboard, a Skill goes straight into the terminal; from **More** or the Toolbar, it goes into your Composer draft.

## Suggestions as you type

When you start typing a Skill's command at the end of your draft, for example `/rev`, the Composer suggests matching Skills. Tap one to insert it. Waycar uses the prefix each agent expects: `/` for most, `$` for Codex, and `/skill:` for omp, pi and Kimi CLI.

## Where does Waycar look?

Waycar looks in the folders each agent documents for its Skills and commands, both in the project (marked **Project**) and in your home folder on the Host (marked **Global**). For example, Claude Code's come from `.claude/skills`. A project Skill wins over a global one with the same command.

## Which agents have Skills?

Claude Code, Codex, omp, pi, opencode, Antigravity, Cline, Cursor Agent, Devin CLI, Droid, GitHub Copilot CLI, Grok Build, Hermes Agent, Kilo Code, Kimi CLI, Kiro CLI, Muse, Qoder CLI and Qwen Code.

Gemini CLI, Amp, Mastra Code and Maki have no Skills list in Waycar. Their skills either have no typed command or aren't stored as files Waycar can read.

## Troubleshooting

- **"No skills found for this agent."**: the agent has no Skills in the folders Waycar checks. Add one on the Host, then tap **Refresh** in the tools keyboard's **Skills** pane, or close and reopen the Skills list.
- **Skills Unavailable**: the Host may not be connected. Tap **Retry** when it is back.
