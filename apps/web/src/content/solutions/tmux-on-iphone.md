---
title: tmux on your iPhone and iPad
metaTitle: "tmux on iPhone: attach to your sessions"
description: "Any SSH client can run tmux. Waycar shows your tmux sessions as Workspaces and opens each pane in a real terminal on iPhone, with agent status, push and chat."
query: tmux on iphone
summary: Attach to the tmux sessions you already run from an iPhone or iPad, see which panes need you, and keep your desk and phone on one window.
answer: Any SSH client can run tmux on a phone. Waycar is for coding agents in tmux. Run its install command on the machine that runs tmux 3.2 or later, then scan the pairing QR code. Your tmux sessions appear as Workspaces, and their windows and panes appear as agents or shells. Opening one shares the window with your desk.
needs:
  - "An iPhone or iPad on iOS or iPadOS 18 or later."
  - "A Mac or Linux machine you can reach over SSH (Remote Login on a Mac), running tmux 3.2 or later."
  - "`curl` and `tar` on that machine, for the install command that sets up the Waycar host tools. No Node needed."
  - "Your coding agents installed before you run the install command, so it can add their status hooks."
  - "Optional: mosh-server on the machine, so the terminal keeps going when your network changes."
order: 3
updated: 2026-11-12
keywords: [tmux on iphone, tmux iphone app, tmux ipad, attach tmux from phone, tmux session from iphone, tmux coding agents mobile]
faq:
  - q: Can I use tmux from my iPhone?
    a: Yes. Any SSH client can run tmux on your machine. Waycar attaches to your tmux sessions on a Mac or Linux machine and opens a pane in a real terminal. It is built for coding agents in tmux, so it lists agents and shells, not a general SSH host list.
  - q: Do I need herdr as well as tmux?
    a: No. Waycar works with tmux 3.2 or later on its own, and the same install command sets it up. herdr still gives you more. It knows the status of more agents, and for now only herdr puts a Chat Mode reply in a notification.
  - q: Does opening a pane on my phone kick me out at my desk?
    a: No. On tmux nothing is taken over. Your desk and your phone can both watch and type in the same window. The window takes the size of whichever device opened it or typed last. When you open a pane on your phone, your desk window shrinks to the phone's size until you type at your desk.
  - q: Which agents show their status on tmux?
    a: Claude Code, Codex, Gemini CLI and 14 more, through small hooks that the install command adds. Other agents show Unknown. Install the agent first, then run the install command, or run it again afterwards.
  - q: What tmux version do I need?
    a: tmux 3.2 or later. Update tmux on the Host if it is older.
compare: [shellfish, termius, blink-shell]
help: [tmux, herdr-vs-tmux, tmux-hooks, take-over]
---

## How tmux shows up in Waycar

Waycar reads your tmux sessions and shows them in the Console. A tmux session becomes a Workspace. A window and its panes become an agent or a shell.

| tmux | Waycar |
| --- | --- |
| Session | Workspace |
| Window and pane | Agent or shell |

When tmux has no sessions running, tap Start Session in the Console to open one. A new agent on a fresh worktree opens as a new tmux session, and it needs git on your machine.

## What you can do

- **Start, open and message.** Start an agent or shell, open one in a live terminal, send it a message from the Composer, rename it and close it.
- **See who needs you.** The Console sorts agents Blocked, Done, Working, Idle. You get a push when one is Blocked or Done.
- **Watch the same window as your desk.** Opening a pane shares its tmux window. Nothing is taken over.
- **Use Chat Mode.** Start one of 14 supported agents in Waycar with Chat Mode on, and it opens as a chat. Allow and Cancel need Waycar's hooks on tmux. See [Chat Mode](/help/chat-mode).
- **Bring back a closed agent.** Closed Sessions keep one for 30 days. Resume reopens the exact session when the hooks are on.
- **Stay on mosh.** Terminals run over mosh when mosh-server is on the machine, with SSH as the fallback.

## Why status needs hooks on tmux

tmux does not know what an agent is doing. Waycar gets Working, Blocked and Done from small hooks inside the agent. When an agent starts working, stops to ask you something or finishes, its hook tells tmux, and Waycar reads it. Waycar has [Status Hooks for 17 agents](/help/tmux-hooks), including Claude Code, Codex and Gemini CLI. Other agents show Unknown.

The install command adds the hooks to the agents it finds on the machine. Installed an agent later? Run the command again. Codex asks you to review new hooks once, on its `/hooks` screen, before they turn on.

## Set it up

1. Run this on the machine that runs tmux:

   ```sh
   curl -fsSL https://waycar.dev/install.sh | sh
   ```

2. On a fresh machine it first asks whether to install or only pair this computer. Press Return to install. When it offers to show a pairing QR code, press Return again. The code draws right in the terminal.
3. Scan the code in Waycar. Your tmux sessions appear in the Console.

If the machine also has herdr, add `--tmux` to set Waycar up for tmux:

```sh
curl -fsSL https://waycar.dev/install.sh | sh -s -- --tmux
```

## What to know

- Waycar is not a general terminal for any server. Its agent terminals need tmux, herdr or herdr-core on the machine.
- Chat Mode replies in notifications work on herdr only for now.
- Waycar has no predictive local echo on mosh. Typed characters appear when your machine echoes them.
- The terminal session ends about 20 seconds after you leave the app and re-attaches when you return. Your tmux session keeps running.

Any SSH client, such as [Secure ShellFish](/compare/shellfish), [Termius](/compare/termius) or [Blink Shell](/compare/blink-shell), can run tmux for you. Waycar adds agent status, push and chat on top of tmux. If you run Claude Code in tmux, see [run Claude Code from your iPhone](/solutions/run-claude-code-from-iphone).
