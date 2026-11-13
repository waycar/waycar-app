---
title: Waycar with herdr-core
description: What works on a Host that runs herdr-core, the runtime under the Herdr app, with notifications from Waycar Host Tools, and what is still missing.
category: hosts
order: 75
keywords: [herdr-core, herdr app, backend, runtime, host tools, notifications, status unknown, too old, herdr runtime, new agent]
related: [herdr-vs-tmux, host-page, status-unknown, notifications]
---

herdr-core is the runtime under the new Herdr desktop app. Waycar works with it as a third Backend, next to the Herdr TUI (the original `herdr` program) and tmux. Everywhere else in this help, "herdr" means the Herdr TUI.

Waycar isn't affiliated with herdr.

## What works

- **The Console.** Every terminal herdr-core runs shows up, agents and plain shells alike.
- **Status.** An agent shows Working, Blocked, Done or Idle only if it reports its status to herdr-core. Claude Code and Pi do. Every other agent reads Unknown. See [Status shows Unknown](#status-shows-unknown).
- **Fast updates.** A status change reaches its row in about 2 seconds.
- **The Composer.** Send prompts and keys to a terminal.
- **Attach.** Tap a row to open its terminal. See [Attach and your desk](#attach-and-your-desk).
- **New Agent.** Start an agent in a folder on the Host. See [Start an agent](#start-an-agent).
- **Close.** Ends the terminal. herdr-core keeps the finished record for a while.
- **Restarts.** If herdr-core restarts, Waycar reconnects and the rows stay.

## Host Tools on herdr-core

Waycar Host Tools are the `waycar` command and the agent hooks the install command puts on a Host. On a herdr-core Host they add what herdr-core doesn't do itself:

- **Notifications.** An in-app banner and a push notification when an agent is Blocked or Done. See [Notifications](/help/notifications).
- **Live Activities.** The Lock Screen and Dynamic Island show the Host's agents. See [Live Activities](/help/live-activities).
- **Agent Summaries.** One sentence on each agent card and in its notifications, if you turned [AI Summaries](/help/ai-summaries) on.
- **Chat Mode.** It works for an agent that reports through the hooks and has a Chat Marker. See [Chat Mode](/help/chat-mode).

Install them from the app: Waycar offers **Install** on the Host, and **Update** when they're out of date (see [Update Waycar on your Host](/help/update-host-tools)). Or run this on the Host:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

A Host that has only herdr-core gets the standalone Host Tools, with no herdr plugin to link. Waycar isn't affiliated with herdr.

Notifications and Live Activities need the agent to report its status to herdr-core with OSC 7501. An agent that never does has no push and no Live Activity row, as in [Status shows Unknown](#status-shows-unknown).

## Not available on herdr-core yet

- Worktrees and new Workspaces.
- Renaming, and **Move to Workspace**.
- Chat Mode's push with the agent's final reply.
- Named sessions.
- mosh.
- Hosts that run herdr-core on Windows.

## Workspaces and Tabs

herdr-core has terminals, not Workspaces. Waycar builds them:

- A Workspace for each folder, or for each `herdr.space` label the Herdr app sets.
- A Tab for each terminal, or for each `herdr.tab` label.

## Start an agent

On a herdr-core Host, **New Agent** asks for the agent and a folder. Waycar starts the agent as a new terminal in that folder.

- **Folder.** Pick one from the list of folders that already have terminals, or choose **Other Folder…** to browse the Host. There's no Workspace name, because a herdr-core Workspace is its folder.
- **First message.** If you gave the agent a message, Waycar sends it when the agent says it is ready. An agent that never reports its status is checked first, and gets the message only when it shows its input.
- **Closed sessions.** Resuming one starts a new terminal of the same agent in the same folder. herdr-core doesn't give Waycar a session id, so the agent picks what to resume on its own.

Not there yet: a plain shell and worktrees.

## Attach and your desk

Attach opens the terminal and takes nothing over. There is no Take Over and no **Live in Another Window**.

- Several Waycar windows can attach to the same terminal. Your desk keeps typing.
- The terminal's size follows whoever typed last. While your phone types, your desk can see the phone's size.
- If a connection drops, the Host can keep your old connection for a while, until sshd drops it. It can hold the size of a screen that's gone. Typing at the desk or on the phone takes the size back.

See [Your desk and phone on one terminal](/help/take-over) for the other Backends.

## What the Host needs

- herdr-core 0.1.10 or later. Update it on the Host with `herdr-core update`.
- If the Host's login prints extra text, Waycar skips it.
- A herdr-core that Waycar starts gets the Host's login PATH, so the agents it runs see the tools your login shell does.
- Waycar uses the Host's default session only. **Session name** on a Host is for the Herdr TUI.

## A Host with the Herdr TUI and herdr-core

Both runtimes' Agents appear together in the Console; they don't share agents.

- In **New Agent**, choose a new Workspace to see one **Runtime** picker with every Backend on the Host: **Herdr TUI**, **Herdr Core**, **tmux**, in that order. It appears when at least two are present and remembers your choice per Host.
- An existing Workspace keeps its own Backend, with no runtime picker.
- The Host's **Backends** section only has visibility toggles. Hiding Herdr Core also stops its notifications; hiding Herdr TUI does not silence its notifications. Hiding tmux stops its notifications too.
- To see which Backend owns each Agent, add the `runtime` field to a card row in [Agent card fields](/help/agent-card-fields): it shows **Herdr TUI**, **Herdr Core** or **tmux**.

A Host with only one Backend shows no runtime picker.

## Troubleshooting

### "herdr-core is not installed on this Host"

Waycar didn't find `herdr-core` on the Host. On iPhone and iPad, a Host with no Backend offers **Install Herdr Core**. Or install it yourself, so `herdr-core` runs from the Host's login shell. See [Install tmux or herdr on your Host](/help/install-tmux-or-herdr#install-herdr-core). Then tap **Run Checks Again** on the Host's page.

### "…is not installed on this Host, or is not on its PATH"

You asked for an agent and herdr-core couldn't find its program. Waycar gives it the PATH from the Host's login shell, so a program in `~/.local/bin`, nvm or cargo is found even when a plain SSH login wouldn't see it. If it still says this, the agent isn't installed for that user, or only an interactive shell's startup file adds its folder. Install it where a login shell finds it, then try again.

### "…is not a folder on this Host"

The folder you picked, or one you typed, isn't there. Pick another with **Other Folder…**.

### "Too old"

The Host runs a herdr-core older than 0.1.10. Run `herdr-core update` on the Host, then run the checks again.

### Extra text on login

Waycar skips text that a Host's login prints, such as a banner or a message from a shell startup file, and reads the output that follows. If it still can't connect, run the checks again from the Host's page. Text printed only for interactive shells is the usual source.

### Status shows Unknown

herdr-core only knows what an agent tells it. Claude Code and Pi report their status. Other agents don't, so their rows read Unknown while the terminal works as usual. That isn't a Waycar fault, and Waycar's hooks don't change it on this Backend. Those agents have no push and no Live Activity row. See [Agent status shows Unknown](/help/status-unknown).

### The terminal at my desk changed size

That's the newest typing viewer's size. See [Attach and your desk](#attach-and-your-desk).
