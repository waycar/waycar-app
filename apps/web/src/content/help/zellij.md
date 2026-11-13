---
title: Waycar with Zellij
description: Use Waycar with Zellij 0.46 or later. Your Zellij sessions show up as Workspaces, and you open, message and start agents from your phone.
category: hosts
order: 65
keywords: [zellij, sessions, tabs, panes, backend, runtime, show zellij sessions, resurrect, too old]
related: [tmux, closed-sessions, new-agent, notifications]
---

Waycar works with Zellij 0.46 or later. Your Zellij sessions show up in the Console as Workspaces, each tab as a Tab, and each pane as an agent or a shell. You open, message, rename and close them from your phone, and start new ones. Waycar only needs SSH and Zellij on the Host.

## How Zellij maps to Waycar

| Zellij | Waycar |
| --- | --- |
| Session | Workspace |
| Tab | Tab |
| Pane | Agent or shell |

Zellij's own bars and plugins are not rows.

## Status

- **Agents that report it.** Claude Code and Pi tell Zellij what they are doing. Waycar reads that, so they show Working, Blocked, Done or Idle with nothing else installed.
- **Other agents.** With the Waycar hooks installed, an agent's hooks report its status. Without them, Waycar reads the agent's screen, or shows Unknown. See [Agent status shows Unknown](/help/status-unknown).
- **Updates.** While Waycar is open, the Host checks Zellij every second (every two seconds with more than four sessions running) and sends only what changed.

## Open an agent

Tap a row to open the agent's pane. Waycar joins the session as one more Zellij client and moves only the phone to that tab and pane. Your desk stays where it is, at its size.

- On the phone, Zellij starts in its locked mode, so every key you type goes to the agent.
- If you type at the desk in the same instant the phone opens, Waycar can't be sure which screen moved. It puts your desk back and shows the whole session on the phone instead.
- While the phone and the desk show the same tab, Zellij sizes that tab to the smaller screen. Another tab keeps your desk's size.

## Start an agent

In **New Agent**, pick **Zellij** as the runtime when the Host has more than one.

- **In a session.** The agent starts in a new tab of that session, named after the agent.
- **No one attached.** Zellij can't open a tab in a session nobody is looking at, so Waycar starts the agent in a new background session instead, named after the agent.
- **New Workspace.** A new background session in the folder you choose.

If Waycar loses the answer while an agent starts, it finds the agent again by a tag in its command line, so a retry never starts a second one.

## Closed sessions

When a Zellij session ends, Zellij saves it so you can bring it back. Waycar lists those in **Closed Sessions**.

- **Resume** opens the session again. Only your tap does this; Waycar never restarts a session on its own. Zellij shows each saved command waiting for Enter, and agents whose hooks saved their conversation come back in it.
- **Delete** asks first, then removes the saved session from the Host.

## Notifications

The Waycar hooks send Blocked and Done notifications for agents in Zellij panes, and Live Activities include them. Install or update them on the Host with:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

Zellij needs Host Tools 2.6.0 or later. To stop Zellij's notifications on a Host, turn off **Show Zellij sessions** on the Host's page; that also hides its sessions.

## Good to know

- **Zellij 0.46 or later.** An older Zellij reads "Zellij on this Host is too old". Update it on the Host, then run the checks again.
- **One Zellij version.** After you update Zellij, sessions started by the old version stay invisible until you restart them.
- **Renaming a session at the desk.** Agents that report their own status keep it. Hook status for agents already running in that session stops until they restart.
- **Long messages.** A message to a Zellij agent can be up to 100 KiB.
- **Not available on Zellij yet:** worktrees, **Move to Workspace**, renaming a Workspace, Chat Mode and AI Summaries. A Codex or OpenCode chat you start from Waycar doesn't open a desk terminal in Zellij; on a Host with only Zellij it stays a chat.
