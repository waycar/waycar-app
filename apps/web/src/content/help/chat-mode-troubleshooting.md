---
title: Chat Mode won't start or send
description: Fix a Chat Mode chat that won't load, won't send, or shows no replies, from an outdated Waycar plugin to herdr integrations, sign-in and trust prompts.
category: troubleshooting
order: 40
keywords: [plugin, update the waycar plugin, opencode, kilo, still starting, sign in, trust folder, can't refresh, integration]
related: [chat-mode, update-host-tools, tmux-hooks, notifications]
---

Most Chat Mode problems come from an older Waycar plugin on the Host, a missing herdr integration, or a question the agent is waiting on in its terminal. Chat Mode works with Claude Code, Codex, omp, pi, opencode, GitHub Copilot CLI, Qwen Code, Gemini CLI, Grok Build, Antigravity, Hermes Agent, Kilo Code, Cline and Muse. Other agents open in the terminal as usual. See [Supported agents](/help/supported-agents).

## "Update the Waycar plugin"

Chat Mode needs the latest Waycar plugin on your Host. If a chat shows **Update the Waycar plugin on … to see replies here**, tap **Update Waycar on <Host>…** under the notice and follow the steps. When the update finishes, the chat reloads by itself.

If the Host has no Waycar plugin yet, or the chat shows **Update the Waycar plugin** without a button, run the install command on that Host:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

Then open the chat again. See [Update Waycar on your Host](/help/update-host-tools).

## The agent is waiting on a question

A fresh folder can make the agent ask a question before it takes your message, such as Claude Code asking whether you trust the folder. While it's asking, Waycar won't send. On tmux, Waycar also holds a message to a just-started GitHub Copilot CLI, Codex, Antigravity or Kiro CLI while a choice box is on its screen, so your Return doesn't answer it. Tap **Show Terminal**, answer the question, then send your message again.

## "… asks whether to trust this folder"

Gemini CLI asks this in a new folder, Qwen Code only with folder trust turned on in its settings, and Grok Build in a folder with its own project setup, such as an `AGENTS.md` file. Your message would answer the question, so Waycar doesn't send it, on herdr or tmux. On tmux, Grok Build and Gemini CLI show as Blocked until you answer. Tap **Show Terminal**, answer the question, then send again.

## "… is still starting. Try again in a moment."

The agent hasn't finished starting. Wait a moment and send again. opencode and Kilo Code ignore typing until their input box appears, and Cline until its prompt row does, so Waycar waits for it before sending. GitHub Copilot CLI, Qwen Code and Gemini CLI drop typing for a few seconds after they start, so Waycar waits those out too. If the agent never gets there, you see **… is still starting** and your message isn't lost.

## "Sign in to … on the Host first."

Cursor Agent, Devin CLI, Kiro CLI, Antigravity and Muse show a sign-in screen until you sign in. Waycar doesn't type into it, because your message would start the sign-in. Tap **Show Terminal**, or use the Host's own terminal, and sign in. Then send again.

## opencode or Kilo Code replies ignore the Chat Prompt

opencode and Kilo Code get the Chat Prompt only through a Waycar extension, which the install command adds when the agent is already installed. Install the agent first, then run the install command. If you installed it after Waycar, or used `--no-hooks`, run the install command again without it.

## Antigravity chats stay empty

Waycar finds an Antigravity chat through its session. On herdr, run this once on the Host:

```sh
herdr integration install antigravity-cli
```

On tmux, the Waycar hooks report it. See below.

## "Can't refresh"

The chat header shows **Can't refresh** when Waycar can't read the conversation. The chat may also say:

| Message | What to do |
| --- | --- |
| "This Agent can't show a chat." | Tap **Show Terminal** to use the agent in its terminal. |
| "The conversation couldn't be read." | Wait for Waycar to try again, or reopen the chat. Tap **Show Terminal** to keep working meanwhile. |

## The chat won't launch

| Message | What to do |
| --- | --- |
| "Waycar couldn't write the Chat Prompt to …" or "…the first message to …" | Check that the Host has free disk space and that your user can write files there, then try again. |
| "The launch command is … bytes, more than the 1000 a new pane can take." | Shorten New Agent's **Arguments**, the **Model**, or the **Chat Prompt** in **Settings › Chat Mode**. |

## On tmux: Allow and Cancel do nothing

On tmux, Allow and Cancel, and Antigravity chats, need Waycar hooks. Run the install command again after installing your agents. See [Waycar hooks for tmux](/help/tmux-hooks).

## Replies don't show up in notifications

Chat Mode replies in notifications work with herdr only for now, not tmux. On herdr, make sure notifications are on for that Host. See [Notifications don't arrive](/help/notifications-not-arriving).

## Good to know

- Chat Mode is chosen when you start an agent. Turn on Chat Mode in the New Agent sheet, or start one from the Home Screen with **New Chat**.
- You can always tap **Show Terminal** to see exactly what the agent is doing.
