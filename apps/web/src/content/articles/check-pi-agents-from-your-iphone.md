---
title: "Check pi agents from your iPhone"
description: "Keep pi running in tmux and check on it from an iPhone over mosh. pi does not ask before every tool call, so the phone's job is to watch, steer and tell you when a run is done."
date: 2026-10-18
keywords: [pi, pi coding agent, tmux, mosh, iphone, coding agents, remote access, monitor]
---

pi is a minimal, extensible agent harness for the terminal, from [pi.dev](https://pi.dev). It does not ask before every tool call. Its own docs say so and advise running it in a container, a VM or another sandbox. With nothing to approve, pi alone never shows Blocked, and the phone's job is different: check on a run, get an alert when it settles, read the result and send the next instruction.

This guide keeps pi running in tmux on your own machine and checks it from an iPhone over mosh. The machine side works with any mosh client. The phone side uses Waycar, the iPhone and iPad app we build. Versions checked on 2026-10-18: pi 1.3.0, tmux 3.6, mosh-server 1.4.0.

## What you need

- A Mac or Linux machine that runs pi and stays on. It has to be awake.
- Node.js 22.19 or newer. That is pi's requirement, not Waycar's: the Waycar host tools need no Node.
- tmux 3.2 or later, or herdr 0.7.5 or later.
- An SSH server your phone can reach. On a Mac, turn on Remote Login.
- Optional: `mosh-server` on the machine, with UDP open to it. Without it Waycar uses SSH only.
- An iPhone or iPad on iOS 18 or later.

## Install the current pi package

pi's npm package moved to a new name, and the old name still installs. As of 2026-10-18 `npm view` shows `@earendil-works/pi-coding-agent` at 1.3.0. The old `@mariozechner/pi-coding-agent` stops at 0.73.1 and carries the message "please use @earendil-works/pi-coding-agent instead going forward".

This matters for Waycar. pi 0.73.1 has no `agent_settled` event, which pi sends when a run is truly over, retries included. Waycar's hook uses that event to mark Done on current pi, and it has a fallback for the old package that we have not tested. This guide describes the current package:

```sh
curl -fsSL https://pi.dev/install.sh | sh
# or
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

Check the result with `pi --version`.

## Run pi in tmux and add mosh

tmux keeps pi alive when your terminal closes or your connection drops.

```sh
tmux new -As pi
cd ~/code/my-project
pi
```

`new -As pi` attaches to a session named `pi` if there is one, and creates it if not. Detach with Ctrl-b, then d.

mosh logs in over SSH, then talks to `mosh-server` over UDP, which lets a session ride out a change from Wi-Fi to cellular. Install `mosh-server` from your package manager (see [mosh.org](https://mosh.org)) and open UDP 60000 to 61000, mosh's default range, through any firewall in front of the machine. If UDP can't get through, Waycar falls back to SSH. See [mosh](/help/mosh).

Next, the Waycar host tools. Install pi first. The install command adds a hook only for agents it finds on the machine.

```sh
curl -fsSL https://waycar.dev/install.sh | sh
waycar hooks status
```

The pi line should look like this:

```text
pi: installed (/home/you/.pi/agent/extensions/waycar-agent-state.ts)
```

If you install pi later, run the install command again. When it offers a pairing QR code, say yes, then tap Scan to Pair in Waycar. See [Pair with a Pairing Code](/help/pairing).

## What the phone shows for pi

On tmux, Waycar learns pi's state from that extension file. Waycar's lab notes recorded the four events below on pi 1.1.0 with tmux 3.4 on 2026-10-12, and the installed file on pi 1.3.0 maps the same ones.

| pi event | Waycar shows |
| --- | --- |
| Session starts | Idle |
| A run starts (`agent_start`) | Working |
| The run is over (`agent_settled`) | Done |
| You quit pi (Ctrl+D) | Status cleared |

A Done alert reaches your phone a few seconds after the change. Your machine waits about 5 seconds and checks that pi is still in that state before it sends, so a quick flip sends nothing. With AI Summaries on, it also waits for the summary, which can add up to about 15 seconds. See [Notifications](/help/notifications).

The table has no Blocked row because pi has no approval step. The lab run had pi use `bash` with no prompt. The hook does turn a `waycar:blocked` or `herdr:blocked` event from another extension into Blocked, so an extension that pauses to ask you could show Blocked if it sends one. pi's own package sends none, and we have not tested an extension that does.

## Stop and steer a run

pi's [usage docs](https://pi.dev/docs/latest/usage) list the keys:

| You want to | Key in pi |
| --- | --- |
| Stop the current task | Esc |
| Adjust the current task | Type a message, press Enter |
| Add work for after the task | Type a message, press Alt+Enter |
| Get queued messages back in the editor | Alt+Up |

Esc is on Waycar's default [Toolbar](/help/toolbar), so stopping a run from the phone should take one tap. We have not tested that against pi 1.3.0. Alt+Enter is not on the default Toolbar. The Toolbar can hold an Option-Return key, and we have not tested that key against pi either.

Be careful with Ctrl+C. In pi it clears the editor, and a second press exits pi. Waycar's optional Ctrl+C key on the Toolbar is labeled Interrupt, but in pi, Esc is the interrupt.

The Composer, Waycar's draft box under the terminal, sends your text and then Enter. By pi's docs, Enter while pi is working adjusts the task.

## Nothing gates the run, so limit what it can reach

When you are not at the screen, the only limit on a run is what the account can touch. pi's [security page](https://pi.dev/docs/latest/security) says to run it inside a container, a VM or a sandbox where you can. A dedicated user account narrows permissions but still shares the machine, and watching the transcript is not a security boundary.

We have not tested Waycar's status hook with pi inside a container. If you go that way, check that Idle and Working show on the phone before you rely on them.

## Answer pi's trust dialog first

pi 1.3.0 asks "Trust project folder?" at startup when the folder has project resources, such as `.pi/settings.json`, `.pi/extensions` or `.pi/skills`. pi's [security page](https://pi.dev/docs/latest/security#project-trust) lists them. Trust is the highlighted option. We saw the dialog on 2026-10-18, and no status was set while it was open. A folder with none of those files, such as an empty one, opens straight to pi.

Waycar has no status for that pi until you answer. So when you start pi from the phone in such a folder, open the agent and answer in its terminal. Trusting a folder lets pi load the extensions that folder ships, and they run with your permissions, so answer as you would for code you are about to run.

To decide ahead of time, `pi --approve` trusts project files for one run, and `/trust` inside pi saves a decision in `~/.pi/agent/trust.json`.

## Resume and Chat Mode

pi saves each conversation as a file under `~/.pi/agent/sessions/`, grouped by working folder. These flags come from `pi --help` on 1.3.0:

```sh
pi --continue        # most recent session for this folder
pi --resume          # pick a session
pi --session <path|id>
```

In Waycar, when pi exits or its tab closes, it stays in the Console as a Closed Session for 30 days. Resume reopens the same pi session. On tmux the exact session is known when the hooks are on. On herdr it comes from herdr's integration for pi. See [Closed Sessions](/help/closed-sessions).

[Chat Mode](/help/chat-mode) works with pi. It starts pi with an appended system prompt and a pinned session id, and shows the replies as a chat. Two lab notes (pi 1.1.0, 2026-10-12): a resumed pi applies the current Chat Prompt, where Claude Code and Codex keep the one they started with. And pi does not refuse an unknown `--model`. It prints that it is using a custom model id and sends the request with it, so check a name with `pi --list-models` before you put it in Waycar's Model setting. pi has no approval prompts, so the Needs your OK card has nothing to show for it.

## If you use herdr

On herdr, status comes from herdr itself, and Waycar's hooks stay out of herdr panes. herdr's integration for pi reports each pi session to herdr, which lets Closed Sessions reopen the exact conversation:

```sh
herdr integration install pi
```

On herdr, opening an agent in Waycar takes over its terminal and disconnects your desk client. On tmux, both can watch the same window. See [Your desk and phone on one terminal](/help/take-over).

## tmux and Enter keys at your desk

pi prints this warning when tmux's extended keys are off, as they are by default. We captured it on tmux 3.6 with no config file on 2026-10-18:

```text
Warning: tmux extended-keys is off. Modified Enter keys may not work.
```

[pi's tmux page](https://pi.dev/docs/latest/tmux) explains why: tmux can report Shift+Enter, Ctrl+Enter and Enter as the same key. For tmux 3.5 or newer it says to add this to `~/.tmux.conf` and restart the tmux server:

```text
set -g extended-keys on
set -g extended-keys-format csi-u
```

For tmux 3.2 to 3.4, add only `set -g extended-keys on`. The warning is cosmetic for the Composer, which sent a message plus Enter fine in Waycar's lab (pi 1.1.0).

## Test it from cellular

1. Give pi a task that takes a few minutes, such as a test run. Check that the agent reads Working in Waycar.
2. Turn Wi-Fi off on the phone and lock it. Notifications must be on for the Host.
3. Wait for the Done alert. Tap it and read the result in pi's real terminal.
4. Send a follow-up from the Composer.
5. Check the MOSH or SSH badge beside the Host. Open the Host and tap Test Mosh Support to run a real handshake. If it says SSH, see [mosh isn't connecting](/help/mosh-not-connecting).

Over mosh, an open terminal stays attached when the phone changes networks. See [Network changes and reconnecting](/help/reconnecting).

## What this setup does not do

- It can't wake a sleeping machine. The machine has to be on and awake.
- On tmux, the Done alert says Done, or carries a one-line AI Summary if you turned that on. It does not carry pi's reply. Open the agent to read it.
- Status for pi is built for the current pi package, and the hook has to be installed after pi.
- Your phone gets mosh's redraw of the current screen, not pi's raw output. After a gap you jump to the live screen. Letters typed straight into the terminal show once the machine echoes them.
- When you leave the app, Waycar keeps running for about 20 seconds. Then the terminal session ends and re-attaches when you come back. pi keeps working in tmux the whole time.

## Without Waycar

The tmux and mosh steps work with any mosh client. From a laptop on another network:

```sh
mosh you@your-machine -- tmux new -As pi
```

You get the same running pi. You do not get status, Done alerts, Closed Sessions or Chat Mode. To build your own, pi runs with `--mode rpc` for programs and has a [TypeScript SDK](https://pi.dev/docs/latest/sdk).

## More guides

- [Keep a coding agent attached through dead zones](/articles/keep-a-coding-agent-attached-through-dead-zones): what survives a tunnel, a network switch or a locked phone.
- [Claude Code on a build server: unblock it from your phone](/articles/claude-code-on-a-build-server-from-your-phone): answering permission prompts on a headless box.
