---
title: "opencode from your iPhone: plugin, permissions and tmux"
description: "Run opencode in tmux, watch it from an iPhone over mosh, and answer its permission prompts. Covers install order, the plugin, ask rules, the slow input box, and opencode web."
date: 2026-10-30
keywords: [opencode, opencode from iphone, tmux, mosh, permissions, coding agents, remote access, plugins]
---

opencode is an open source coding agent with a terminal interface. This guide keeps it running in tmux on your own machine and lets an iPhone check on it over mosh. Three things are specific to opencode: the order you install things, permissions that mostly allow by default, and an input box that ignores your first keystrokes.

The machine setup works with any mosh client. The phone side uses Waycar, the iPhone and iPad app we build. The CLI details were checked on opencode 1.18.34 on 2026-10-18. The status table and the input-box timings come from Waycar's lab notes on opencode 1.19.0 (2026-10-12) and 1.18.34. One slower figure comes from an earlier run on a small test host (2026-10-03, opencode version not recorded).

## What you need

- A Mac or Linux machine that runs opencode and stays on and awake.
- tmux 3.2 or later (herdr 0.7.5 or later also works, see the end).
- `curl` and `tar`, for the install command. Waycar's host tools need no Node.
- An SSH server your phone can reach, and `mosh-server` with UDP open if you want mosh. Without mosh, Waycar uses SSH.
- An iPhone or iPad on iOS 18 or later.

One version note. opencode's docs say OpenCode 1 and OpenCode 2 both use the `opencode` command and can't be installed side by side under it. This guide is about OpenCode 1. More on 2 under the limits.

## Install opencode first

opencode reports status and takes Chat Mode's prompt through plugins, which are JavaScript files in `~/.config/opencode/plugins/` (opencode's [plugin docs](https://opencode.ai/docs/plugins) list that folder). Waycar's install command adds two of them, `waycar-agent-state.js` and `waycar-chat-prompt.js`, but only when opencode is already on the PATH.

So the order is: install opencode, then run Waycar's command.

```sh
curl -fsSL https://opencode.ai/install | bash
curl -fsSL https://waycar.dev/install.sh | sh
```

If opencode came later, or you used `--no-hooks`, run the second command again. Then check:

```sh
waycar hooks status
```

```text
opencode: installed (/home/you/.config/opencode/plugins/waycar-agent-state.js)
```

That line is from a Linux test machine with the home folder changed. The paths follow `$XDG_CONFIG_HOME` if you set it. See [Waycar hooks for tmux](/help/tmux-hooks) and [Install Waycar on your Host](/help/install).

## Start it in tmux

```sh
tmux new -As opencode
cd ~/code/my-project
opencode
```

`new -As opencode` attaches to a session named `opencode`, or creates it. Detach with Ctrl-b, then d. opencode keeps working. For mosh, install `mosh-server` (`apt install mosh`, `dnf install mosh` or `brew install mosh`) and let UDP 60000 to 61000 through any firewall. If UDP is blocked, Waycar falls back to SSH. Pair the phone with the QR code the install command offers. See [mosh](/help/mosh) and [Pair with a Pairing Code](/help/pairing).

## Wait for the input box

opencode's terminal interface can ignore typing for the first few seconds. It drops typed or pasted text until its input box is drawn, a row with a `┃` border on the alternate screen. Waycar's lab saw the box appear at 3.0 and 4.4 seconds on two warm starts of opencode 1.19.0, and the first paste to land came at about 5.9 seconds on a first launch. On Linux test hosts running 1.18.34, input started working 6 to 24 seconds after launch. On a slow 2-vCPU host in an earlier run (2026-10-03), the box took 11 to 42 seconds. Text typed before the box exists is usually lost, though in one lab run a paste landed up to half a second before the box drew.

When Waycar sends a prompt for you, it waits for that row first. If you type into the terminal yourself, you have to do the waiting. Open the agent from your phone, wait for the box, then type.

Waycar has to read the screen because a plugin can't. In 1.18.34, opencode runs the terminal interface in its main thread and plugins in a worker, so a plugin sees nothing the interface draws.

## What the phone shows

The status plugin turns opencode's events into a Waycar status. This is from the 1.19.0 lab run.

| opencode | Waycar shows |
| --- | --- |
| Started, no prompt yet | No status. The plugin sets nothing until the first prompt. |
| First prompt | Working |
| `session.idle` after a turn | Done |
| `permission.asked` | Blocked |
| `question.asked` or `session.error` | Blocked |
| You answer the prompt or question | Working, then Done |
| You exit with Ctrl+C | Status cleared |

The first rows come from the 1.19.0 lab run. The `question.asked` and `session.error` rows come from the source of Waycar's opencode plugin (host tools 1.4.1). `question.asked` is opencode's `question` tool, where the agent asks you something.

Blocked and Done send a push notification, once you have turned notifications on. They go through Waycar's push relay, and your machine encrypts each one first. Your machine holds each one for about 5 seconds and checks the state again, so a quick flip sends nothing. See [Agent status](/help/agent-status) and [Notifications](/help/notifications).

## opencode mostly allows by default

opencode's [permissions docs](https://opencode.ai/docs/permissions) say that with no config, most permissions default to `allow`. Only `doom_loop` and `external_directory` default to `ask`, so a command that reaches outside the project folder can still block. In Waycar's lab on 1.19.0, a `bash` tool call ran without stopping until the config said `ask`. With the default rules opencode seldom asks for permission, so you see fewer Blocked alerts. A question from the agent or an error can still report Blocked. For permissions alone, you get Done and nothing in between.

To make it ask, put a `permission` block in `~/.config/opencode/opencode.json`, or in an `opencode.json` in the project:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "bash": "ask",
    "edit": "ask"
  }
}
```

Each rule is `allow`, `ask` or `deny`. The docs also take an object per tool, where the last matching pattern wins, so `"bash": { "*": "ask", "git status *": "allow" }` asks for everything except `git status`. For a quick test without touching files, the lab set the config through the environment:

```sh
OPENCODE_CONFIG_CONTENT='{"permission":{"bash":"ask"}}' opencode
```

`opencode --auto` is the opposite of ask. Its help (1.18.34) says "auto-approve permissions that are not explicitly denied (dangerous!)". And when the prompt appears, opencode offers once, always or reject. The docs say `always` lasts for the current opencode session.

To answer from the phone, tap the Blocked agent. You land in opencode's real terminal with its permission dialog, and you answer it the way you would at your desk. In Chat Mode, a Needs your OK card shows the prompt, and Allow sends Return. We haven't recorded which choice Return lands on in opencode's dialog, so look at the highlighted option first (Show Terminal opens the real screen). See [Chat Mode](/help/chat-mode).

## Test it from cellular

1. Set `"bash": "ask"` as above and start opencode in tmux on the machine.
2. On the phone, turn Wi-Fi off and open the agent in Waycar. Look for the MOSH or SSH badge by the Host. Tap Test Mosh Support on the Host's page if you want a real handshake.
3. Wait for the input box, then ask opencode to run `ls`.
4. Lock the phone, with notifications turned on. A Blocked notification should arrive a few seconds later. Open it, answer the prompt, and watch the status go to Working, then Done.

If the badge says SSH, see [mosh isn't connecting](/help/mosh-not-connecting).

## Resume and models

opencode's `--session <id>` (`-s`) reopens a session with its history. `--continue` (`-c`) picks the last one. When you quit, opencode prints its own hint, `opencode -s <id>`. Waycar's Closed Sessions use that same flag to reopen a session with one tap. See [Closed Sessions](/help/closed-sessions).

opencode writes models as `provider/model`, and `opencode models` lists the ones you can use. Chat Mode's Model setting takes the same form. Chat Mode's Quick thinking setting does nothing for opencode.

## opencode's own web interface

opencode ships its own remote pieces, and they are a fair choice for some setups. `opencode serve` starts a headless server. `opencode web` starts the server and a browser interface. `opencode attach <url>` connects a terminal interface to a running server. opencode's [web docs](https://opencode.ai/docs/web) as of 2026-10-18 say:

- It binds to `127.0.0.1` by default. `--hostname 0.0.0.0` opens it to your network.
- Without `OPENCODE_SERVER_PASSWORD`, the server is unsecured. With it, you get HTTP basic auth, username `opencode`.
- The CLI docs' own example calls this "web/mobile access".

That fits when you want a browser view, don't use tmux, or want one server shared by several clients. It needs a port your phone can reach, so keep it on a private network. Our [Tailscale guide](/articles/reach-your-local-network-with-tailscale) covers that. The docs' own caution is that without `OPENCODE_SERVER_PASSWORD` the server is unsecured, and that you should set it for network access. We haven't used the web interface from a phone.

tmux plus SSH or mosh is the other route. Your phone shows the terminal opencode already runs in, so you see the same screen as at your desk. Plain SSH exposes one TCP port. mosh adds UDP 60000 to 61000, and Waycar falls back to SSH without it. tmux keeps the session alive when the connection drops.

## What this setup does not do

- It can't wake a sleeping machine.
- Status starts at the first prompt. A fresh opencode with no prompt yet has no status.
- We haven't run OpenCode 2. The plugin file Waycar installs says that under 2 it reports nothing, because the shared server can't tell which pane a session belongs to. Treat status as unavailable there.
- Typed characters show once the machine echoes them. Waycar doesn't predict ahead like the desktop mosh client.
- Replies in notifications from Chat Mode work on herdr Hosts only for now, not tmux.

## If you use herdr

herdr tracks status itself, and Waycar's hooks stay out of herdr panes. herdr 0.9.5 lists an opencode integration in `herdr integration status`, shown as not installed on the Linux test machine. We haven't tested whether installing it changes what opencode shows. See [herdr vs tmux](/help/herdr-vs-tmux).

## Without Waycar

The tmux half needs nothing from us. From any machine with mosh:

```sh
mosh you@your-machine -- tmux new -As opencode
```

You get the same running opencode. You don't get status, push alerts, Chat Mode, or the input-box wait done for you.

## More guides

- [Codex CLI from your iPhone: hooks, approvals and tmux](/articles/codex-cli-from-your-iphone): the hooks review, `--no-daemon` and sandbox approvals.
- [Check your home lab's coding agents from your phone](/articles/coding-agents-in-your-home-lab-from-your-phone): several always-on boxes, one list.
- [Run omp from your phone over mosh](/articles/run-omp-from-your-phone-over-mosh): approval modes and what triggers Blocked.
