---
title: "Codex CLI from your iPhone: hooks, approvals and tmux"
description: "Run OpenAI's Codex CLI in tmux and check on it from an iPhone over mosh. Covers the one-time hooks review, Codex's shared daemon, when it really asks for approval, and resuming."
date: 2026-10-28
keywords: [codex cli, openai codex, iphone, tmux, mosh, approvals, hooks, remote access]
---

Codex CLI is OpenAI's coding agent for the terminal. This guide keeps it running in tmux on your own machine and checks on it from an iPhone over mosh. Most of it covers three Codex details that trip people up: hooks that stay off until you review them, a shared background server that confuses tmux, and approvals that mostly fire outside the sandbox.

The machine half works with any mosh client. The phone half uses Waycar, the iPhone and iPad app we build. Versions below come from our checks on 2026-10-18 (Codex 0.163.0, tmux 3.6, mosh-server 1.4.0) unless the text says otherwise.

## What you need

- A Mac or Linux machine that runs Codex and stays on. It has to be awake.
- Codex, signed in. [OpenAI's README](https://github.com/openai/codex) lists the install options.
- tmux 3.2 or later, or herdr 0.7.5 or later.
- `curl` and `tar`, for the install command. Waycar's host tools need no Node.
- An SSH server your phone can reach, and `mosh-server` with UDP open (60000 to 61000 by default). Without mosh, Waycar still works over SSH.
- An iPhone or iPad on iOS 18 or later.

## Start Codex in tmux with `--no-daemon`

```sh
tmux new -As codex
cd ~/code/my-project
codex --no-daemon
```

`new -As codex` attaches to a session named `codex`, or creates it. Detach with Ctrl-b, then d.

Codex 0.163.0 keeps a shared background server, and `codex features list` shows `daemon_auto_start` as `true`. `codex --help` describes the flag as "Run without the shared background server, even if it is already running".

Waycar's repo notes add the tmux side. Hooks that run through the shared server get the environment of whichever pane started the server, so `TMUX_PANE` points at the wrong pane. In Waycar's lab on 0.162.1 (2026-10-12), a Codex started with `--no-daemon` ran every hook as a child of `codex` on the pane's own tty, and `TMUX_PANE` was correct. When Waycar starts Codex for you, it adds `--no-daemon` if `codex --help` lists it (checked in the source of app release 1.1.3). If you start Codex by hand, add it yourself, or your phone may see the wrong pane's status.

## Install the host tools, then review the hooks once

```sh
curl -fsSL https://waycar.dev/install.sh | sh
waycar hooks status
```

For Codex, the installer writes `~/.codex/hooks.json` and adds `[features] hooks = true` to `~/.codex/config.toml`. Both go under `$CODEX_HOME` if you set it. It merges into your existing hooks and never touches Codex's `notify` setting. See [Waycar hooks for tmux](/help/tmux-hooks).

Codex does not run a new hook until you trust it. Its [hooks docs](https://learn.chatgpt.com/docs/hooks) say new or changed hooks are marked for review and skipped until trusted. So after install, `waycar hooks status` prints two Codex lines. This is the output on our machine:

```text
codex: installed (/home/you/.codex/hooks.json)
codex: open Codex and run /hooks to review and trust the Waycar hooks; Codex skips them until then
```

On 0.163.0, starting Codex in a fresh folder showed a dialog like this before anything else (the hook count differs by machine):

```text
Hooks need review
9 hooks are new or changed.
Hooks can run outside the sandbox after you trust them.

› 1. Review hooks
  2. Trust all and continue
  3. Continue without trusting (hooks won't run)
```

Pick Review hooks and read them. "Trust all" trusts every new hook from every source, not only Waycar's. Each Waycar hook sets values on the tmux pane and starts `waycar notify` for alerts. While this dialog is open, the pane has no `@waycar_*` option at all (we checked with `tmux show-options -p`), so no hook has reported a status. We did not check what the card shows for this dialog.

If `config.toml` sets `hooks = false` under `[features]`, Waycar never overrides it. `waycar hooks status` says so, and the fix is to set `true` yourself. See [Codex hooks are turned off](/help/status-unknown#codex-hooks-are-turned-off).

## What the phone shows for Codex

On tmux, Waycar reads status from the hooks. Waycar's lab ran these on Codex 0.162.1 on 2026-10-12.

| Codex | Waycar shows |
| --- | --- |
| You send a prompt | Working |
| The turn ends (`Stop` hook) | Done |
| Codex exits | The pane's Waycar values are cleared |

Codex's `SessionStart` hook fires at your first turn, not when Codex launches. A Codex you open and close without ever sending a prompt has no recorded session, so there is nothing to resume.

Blocked and Done also send push notifications, once you have turned notifications on. They go through Waycar's push relay, and your machine encrypts each one first. The machine waits about 5 seconds and checks the state again before it sends, so quick flips send nothing. See [Notifications](/help/notifications).

## Codex asks mostly when it has to leave the sandbox

Codex runs commands inside an OS sandbox. OpenAI's [approvals page](https://learn.chatgpt.com/docs/agent-approvals-security) describes the default Auto setup (`--sandbox workspace-write --ask-for-approval on-request`): Codex reads files, edits and runs commands in the working directory on its own. It asks before it edits outside the workspace or runs a command that needs network access. Network is off by default.

A Codex turn that stays in the workspace usually does not block. In `codex --help`, `on-request` means the model decides when to ask. Expect Blocked when Codex wants to leave the sandbox, for example to edit outside the workspace or use the network. The hooks side matches: Codex's `PermissionRequest` hook "runs when Codex is about to ask for approval" and "doesn't run for commands that don't need approval". Waycar maps that hook to Blocked. In app release 1.1.3 Waycar also reads Codex's screen on tmux, so a question prompt or the folder-trust dialog can read Blocked even with no hook.

`codex --help` on 0.163.0 lists the options:

| Flag | Values or effect |
| --- | --- |
| `-a`, `--ask-for-approval` | `on-request` or `never` |
| `-s`, `--sandbox` | `read-only`, `workspace-write`, `danger-full-access` |
| `--approve-for-me` | Sends approval requests to automatic review, in the `workspace-write` sandbox |
| `--dangerously-bypass-approvals-and-sandbox` | No approvals and no sandbox |

The old `untrusted` policy is gone. OpenAI's page says Codex no longer supports `approval_policy = "untrusted"` and that it can stop Codex from starting. Waycar's lab saw the same error on 0.162.1.

We have not re-checked the last link in that chain on a current Codex. Waycar's lab could not produce a real Codex approval on 0.162.1, because its mock model could not ask for extra permissions and the sandbox tool could not run inside the lab's container. So the mapping from `PermissionRequest` to Blocked rests on Waycar's hook design. Before you rely on it, trigger one yourself: ask Codex to write a file outside the project, watch for Blocked on the phone, and open the agent to see Codex's own prompt. In the terminal you choose the option yourself. Chat Mode has a Needs your OK card whose Allow button sends Return and whose Cancel button sends Esc ([Chat Mode](/help/chat-mode)). Check which option is highlighted on your first prompt.

## Folder trust and other startup dialogs

Codex asks whether to trust a folder when you open it in a checkout it doesn't know. Waycar's lab saw that on 0.162.1 (2026-10-12). Project-level `.codex/` config, hooks and rules load only after you trust the project, per OpenAI's docs. User-level hooks, like Waycar's in `~/.codex`, still load.

On tmux, no hook has set a status while a startup dialog is open (Waycar's lab, 2026-10-12, and our own check of the hooks dialog above). Open the agent from the phone and answer the dialog yourself. Do this once per new folder, at your desk if you can.

## Resume

Codex's own `codex resume` opens a picker, and `codex resume --last` continues the most recent session.

On a tmux Host, Waycar keeps closed agents as [Closed Sessions](/help/closed-sessions) for 30 days. Resume picks up the exact session when the Waycar hooks are on, which is why the review above matters. On herdr, it does when herdr's Codex integration reports the session (`herdr integration install codex`). If Codex didn't save its place, you get its latest session, its resume list or a fresh start.

Chat Mode works with Codex. Waycar starts it with a profile file, `~/.codex/waycar-<uuid>.config.toml`, that holds the Chat Prompt. A resumed session keeps the developer instructions it started with. In Waycar's lab (0.162.1, 2026-10-12), a resume with an edited profile still sent the original instructions. If you change the Chat Prompt, start a new chat.

## Scrolling Codex's history

We don't promise touch scrolling of Codex history from the phone. Waycar's lab found that Codex 0.162.1 uses the alternate screen and turns on alternate-scroll but no mouse tracking. Under alternate-scroll a terminal turns the wheel into arrow keys. Codex probably uses those to recall earlier prompts instead of scrolling the transcript, but the lab did not test the wheel itself. Over mosh the phone also gets a redraw of the screen, not Codex's scrollback ([mosh](/help/mosh)).

`codex --no-alt-screen` runs inline "preserving terminal scrollback history", so tmux's own copy mode can scroll it at your desk. We haven't tested how that looks from the phone.

## Test it from cellular

1. Start `codex --no-daemon` in tmux and send a prompt that takes a minute, such as running your test suite. Review the hooks dialog first.
2. Turn Wi-Fi off on the phone and lock it. With notifications on, a Done notification should arrive a few seconds after the turn ends.
3. Open the agent in Waycar. A MOSH or SSH badge sits beside the Host. Tap Test Mosh Support on the Host's page to run a real handshake.
4. Switch Wi-Fi off and on with the terminal open. Over mosh it stays attached.

If the badge says SSH, see [mosh isn't connecting](/help/mosh-not-connecting).

## If you use herdr

herdr reports Codex's status from its screen, and works without its Codex integration. Per our source review of herdr 0.9.1, the integration's hook only reports the session. Waycar's tmux hooks stay out of herdr panes. Opening an agent on herdr takes over its terminal, while on tmux your desk and phone can both watch ([take over](/help/take-over)).

## What this does not do

- It can't wake a sleeping machine. The machine has to be on and awake.
- It needs UDP for mosh. Without UDP you get SSH.
- Typed characters show up after the machine echoes them. Waycar doesn't predict ahead the way the desktop mosh client can.
- Status on tmux depends on the hooks. Skip the review, or set `hooks = false`, and Codex has no hook status. Waycar's help says such an agent shows Unknown, and the app also reads Codex's screen for some states.
- If you start Codex without `--no-daemon` and a shared server is running, status can land on the wrong pane.

## Codex's own phone app

As of 2026-10-18, OpenAI's [Codex on mobile](https://learn.chatgpt.com/docs/mobile) lets you start, approve and review tasks from the ChatGPT app, on Cloud or on a connected computer. Its [remote connections guide](https://learn.chatgpt.com/docs/remote-connections) says the host must run the ChatGPT desktop app on macOS or Windows, signed in to your account and awake, that availability can vary by rollout, and that you can't set it up from the Codex CLI. We found nothing in those pages about attaching to a `codex` process that is already running in a tmux window.

## Without Waycar

The machine half needs nothing from us. From any laptop with mosh:

```sh
mosh you@your-machine -- tmux new -As codex
```

Inside, run `codex --no-daemon`. You get the same running Codex. You lose the Console, status, push alerts and Chat Mode.

## More guides

- [Claude Code on a build server: unblock it from your phone](/articles/claude-code-on-a-build-server-from-your-phone): answering permission prompts on a headless box.
- [Check your home lab's coding agents from your phone](/articles/coding-agents-in-your-home-lab-from-your-phone): several always-on boxes, one list.
- [Keep a coding agent attached through dead zones](/articles/keep-a-coding-agent-attached-through-dead-zones): what survives a tunnel, a network switch or a locked phone.
