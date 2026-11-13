---
title: Shells and busy shells
description: Plain shells show up in the Console as cards like agents, and a busy shell shows Running and the command it's running.
category: console
order: 70
keywords: [shell, default shell, terminal, running, command, open terminal, new terminal]
related: [console, new-agent, terminal, agent-status]
---

Plain shell panes on your Hosts appear in the Console next to your agents. A shell card reads **Shell**, or **Running** with the command, such as `sudo apt update`, while a command runs. Open one to type commands on the same screen you use for agents.

## Where do shells come from?

- **Default Shell** in the New Agent sheet starts a plain shell instead of an agent. See [Start a new agent](/help/new-agent).
- **Open Terminal** in an agent's menu opens a shell in that agent's Workspace, offering a choice when there are several. **New Terminal** starts a fresh one.
- Any other shell pane already open on your Host shows up too.

## How does a shell behave in the Console?

A shell card works like an agent card. Search finds it, and you can swipe to close it, pin it, move it to another Workspace, or rename it. Its name is its tab name.

Shells have no agent status. They sort with the last group, after Idle agents, and only show under the **All** pill. They never count toward the app icon badge, and never raise notifications or Live Activities.

## What does Running mean?

While a command runs in the shell, its card shows **Running** and the command. When the shell is back at its prompt, the card reads **Shell** again. Running shows only on the shell's card. It never changes the sort, the Status pills, or notifications.

Some commands read Running for as long as they're open: `ssh`, `tmux attach`, editors, and REPLs.

## Type into a shell

Opening a shell shows the same screen as an agent, with the Composer or direct input. In the Composer, **Send** runs the command. Opening a shell takes over its terminal from another client, as opening an agent does.

## What happens when an agent starts or exits in a shell?

If you start an agent in a shell, the agent replaces the shell's card. When the agent exits back to its shell, the card turns back into a shell.

## herdr and tmux

- On herdr, Waycar checks each shell about every 3 seconds while the app is open, so a command shorter than that may never show as Running.
- On tmux, a command under about a second may never show, and a script run through a shell interpreter (`./deploy.sh` with a bash shebang, or `sh -c`) reads as not running.

## Good to know

Shells that Waycar starts carry `WAYCAR_SHELL=1` in their environment. If your shell startup file launches an agent in every new pane, check for it to skip that.
