---
title: "Run omp from your phone over mosh"
description: "Keep omp running in tmux, add mosh, and steer it from an iPhone. Covers omp's approval modes, what triggers a Blocked alert, herdr's omp integration, and what to do when UDP is blocked."
date: 2026-10-21
keywords: [omp, oh-my-pi, mosh, tmux, herdr, iphone, coding agents, remote access]
---

omp is a coding agent that runs in a terminal on your machine. This guide keeps it running there, inside tmux, and lets an iPhone check on it over mosh. When omp stops to ask you something, your phone tells you, and you can answer from the couch.

The agent never moves. omp keeps running in tmux on your machine, and the phone is a window onto it, so a dropped connection never stops a run.

The machine half of the setup works with any mosh client. The phone half uses Waycar, the iPhone and iPad app we build.

## What you need

- A Mac or Linux machine that runs omp and stays on. It has to be awake. A sleeping machine can't answer.
- tmux 3.2 or later, or herdr 0.7.5 or later.
- `curl` and `tar`, for the install command. Waycar's host tools need no Node.
- An SSH server your phone can reach. On a Mac, turn on Remote Login.
- `mosh-server` on the machine, with UDP open to it. Skip it and Waycar still works, over SSH.
- An iPhone or iPad on iOS 18 or later.

## Start omp in tmux

If omp isn't installed yet, start with [its quickstart](https://omp.sh/docs/quickstart). tmux keeps omp alive when your terminal closes or your connection drops.

```sh
tmux new -As omp
cd ~/code/my-project
omp
```

`new -As omp` attaches to a session named `omp` if one exists, and creates it if not. Detach with Ctrl-b, then d. omp keeps working while you are away.

## Add mosh

mosh logs in over SSH, starts `mosh-server` on the machine, then talks to it over UDP. That UDP link is what lets a session ride out a change from Wi-Fi to cellular.

Install it on the machine:

```sh
sudo apt install mosh   # Debian, Ubuntu
sudo dnf install mosh   # Fedora
brew install mosh       # macOS
```

Then let UDP reach it. mosh uses ports 60000 to 61000 by default. If a firewall or a cloud security group sits in front of the machine, open that range.

If UDP can't get through, Waycar notices and uses SSH instead. The terminal still works. It drops when your phone changes networks, and Waycar reconnects it.

## Install Waycar's host tools

Install omp first. The install command adds hooks only for agents it finds on the machine. Then run:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

It finds tmux, links a `waycar` command at `~/.local/bin/waycar`, and adds a small extension to omp. Check that the extension landed:

```sh
waycar hooks status
```

You should see a line like this:

```text
omp: installed (/home/you/.omp/agent/extensions/waycar-agent-state.ts)
```

If you install omp later, run the install command again.

## Pair your phone

The install command offers to draw a pairing QR code in the terminal. Say yes. In Waycar, tap Scan to Pair.

Your SSH key is made on the phone and its private half stays in the Keychain. The code carries the machine's host key, so the first connection is already verified. See [Pair with a Pairing Code](/help/pairing).

## What the phone shows for omp

The extension reports what omp is doing, and Waycar turns that into a status. We checked the first rows on omp 18.10.2 with tmux 3.4 on 2026-10-12. The `ask` and provider-error rows come from the extension's source.

| omp | Waycar shows |
| --- | --- |
| Starts | Idle |
| A turn begins | Working |
| Waits for you to approve a tool call | Blocked |
| Asks you a question with its `ask` tool | Blocked |
| Hits a provider error it will retry, such as a rate limit | Working for about 2.5 seconds, then Blocked until the retry starts |
| You answer, or a new turn starts | Working |
| The turn ends | Done |

Blocked and Done also send a push notification, once you have turned on notifications in Waycar. It arrives a few seconds after the change. Your machine waits about 5 seconds and checks that omp is still in that state before it sends, so a quick flip sends nothing. See [Notifications](/help/notifications).

## Approval prompts are off by default

By default omp does not ask before it runs a tool. Its approval mode is `yolo`, so every tool call runs and no approval prompt reaches your phone. You still get Blocked when omp asks you a question with its `ask` tool, which is on by default (`omp config get ask.enabled`), and a Done alert when a turn ends.

omp has three approval modes:

| Mode | Runs without asking | Asks first |
| --- | --- | --- |
| `yolo` (default) | Everything | Nothing |
| `write` | Reads, file edits and MCP tools | Shell commands, code execution, browser actions, subagents |
| `always-ask` | Reads | File edits, MCP tools and everything that runs code |

For phone use, `write` is a good middle. Edits go through, and anything that runs code waits for you. Set it for one run, or for good:

```sh
omp --approval-mode=write
omp config set tools.approvalMode write
omp config get tools.approvalMode
```

`omp --auto-approve` forces `yolo` for one session. A per-tool rule such as `tools.approval.bash: prompt` applies in every mode, `yolo` included. omp's page on [tool approvals](https://omp.sh/docs/approvals) covers the rules.

To answer from the phone, tap the Blocked agent. You get omp's real terminal and answer as you would at your desk. If you started omp in Chat Mode, a Needs your OK card shows the prompt: Allow sends Return and Cancel sends Esc. We have not checked those keys against omp's approval dialog or its `ask` picker, so look at the highlighted option first, and tap Show Terminal for anything else. See [Chat Mode](/help/chat-mode).

## Test it from cellular

1. Turn Wi-Fi off on the phone.
2. Open Waycar and open the omp agent.
3. Look for the MOSH or SSH badge beside the Host. Open the Host and tap Test Mosh Support to run a real mosh handshake.
4. Turn Wi-Fi on and off again with the terminal open. Over mosh it stays attached.

If the badge says SSH, work through [mosh isn't connecting](/help/mosh-not-connecting). The usual causes are a missing `mosh-server` and blocked UDP.

## If you use herdr

herdr tracks status itself, so Waycar's hooks stay out of herdr panes. For omp, herdr needs its omp integration. Without it a working omp reads Idle for its whole turn.

```sh
herdr integration status
herdr integration install omp
```

One difference from tmux: on herdr, opening an agent in Waycar takes over its terminal and disconnects your desk client. On tmux, your desk and your phone can watch the same window. See [Your desk and phone on one terminal](/help/take-over).

## Chat Mode and omp's model setting

Settings, then Chat Mode, has a Model field. Leave it blank to use omp's own default. If you fill it in, omp has to know the name. When it doesn't, omp starts with no model, prints `Error: No model selected.` and never sends your first message. We saw this on omp 18.10.2. To see the names omp accepts, run `omp models` on the machine.

## What this setup does not do

- It can't wake a sleeping machine. The machine has to be on and awake.
- It needs UDP for mosh. Without UDP you get SSH.
- Letters you type straight into the terminal show up once the machine echoes them. Waycar does not predict ahead the way the desktop mosh client can. The Composer, a draft box under the terminal, is not affected.
- Your phone gets mosh's redraw of the current screen, not omp's raw output. After a gap you jump to the live screen.
- When you leave the app, Waycar keeps running for about 20 seconds. Then the terminal session ends and re-attaches on its own when you come back. omp keeps working in tmux the whole time.

## omp's own sharing

omp has a built-in `/collab` command. Run it inside a session and omp prints a link. Anyone holding the link can open that session in another omp or in a browser, through a relay (`my.omp.sh` by default). Current omp can also host every session as it starts (`collab.autoStart`, off by default), and `omp collab list` and `omp collab link <id>` print the link for a session that is already shared, from a shell on the same machine. omp's [collab docs](https://github.com/can1357/oh-my-pi/blob/main/docs/collab.md) say each payload is sealed with AES-256-GCM before it reaches the relay, and that a full-control link can prompt and interrupt the agent, so treat the link like a password.

That works from a phone browser. Three differences matter here. A session is shared only if you turned sharing on for it, with `/collab` or `collab.autoStart`. Sharing covers that session, not the whole machine. And the terminal session passes through omp's relay. With tmux and SSH you can attach to any session on the machine at any time, and your phone connects straight to your own machine over SSH or mosh, with no relay carrying the terminal session. Only the optional push notifications and Live Activity updates pass through a relay. Your machine encrypts the agent, Host and task details first. The relay still sees delivery details and, for Live Activities, how many agents are in each status.

## Without Waycar

Everything before the pairing step works with any mosh client. From a laptop on another network, this attaches to the same session:

```sh
mosh you@your-machine -- tmux new -As omp
```

You won't get status, alerts or Chat Mode that way.

## More guides

- [Check pi agents from your iPhone](/articles/check-pi-agents-from-your-iphone): what changes when the agent never asks for approval.
- [Keep a coding agent attached through dead zones](/articles/keep-a-coding-agent-attached-through-dead-zones): what survives a tunnel, a network switch or a locked phone.
- [Claude Code on a build server: unblock it from your phone](/articles/claude-code-on-a-build-server-from-your-phone): answering permission prompts on a headless box.
