---
title: Run Claude Code from your iPhone
metaTitle: "Run Claude Code from iPhone: check and answer it"
description: "Claude Code runs on a computer, not on your phone. Waycar lets your iPhone check on it, answer it and unblock it over mosh or SSH on your own Mac or Linux box."
query: run claude code from iphone
summary: Claude Code does not run on a phone. Here is how to check on it, answer it and unblock it from an iPhone with Waycar.
answer: Claude Code does not run on the phone. It runs on a computer, either your own or Anthropic's cloud. Waycar is the iPhone app for the first case. You see when Claude Code is Blocked or Done, open its real terminal or a chat view, and tap Allow or Cancel. Your machine needs tmux, herdr or herdr-core, and it must be on and awake.
needs:
  - "An iPhone or iPad on iOS or iPadOS 18 or later."
  - "A Mac or Linux machine that is on and awake, with Claude Code installed and signed in."
  - "tmux 3.2 or later, herdr 0.7.5 or later, or Herdr Core 0.1.10 or later on that machine, or Zellij 0.46+ from the next update. Claude Code runs inside one."
  - "SSH access to it: Remote Login on a Mac, or an SSH server on Linux. herdr also needs AllowTcpForwarding set to local or yes."
  - "`curl` and `tar` on the machine, for the install command that sets up the Waycar host tools. No Node needed."
  - "Optional: mosh-server on the machine, so the terminal keeps going when your network changes."
order: 1
updated: 2026-11-12
keywords: [run claude code from iphone, claude code on iphone, claude code mobile, claude code remote, approve claude code from phone, claude code tmux iphone]
faq:
  - q: Can I run Claude Code from my iPhone?
    a: You can steer it from your iPhone. Claude Code itself runs on a computer, not on the phone. Waycar connects your iPhone to a Claude Code session that runs on your own Mac or Linux machine, so you can watch it and answer it from anywhere. Anthropic's own Remote Control and cloud sessions are other ways.
  - q: Do I need a Claude plan or API key to use Waycar?
    a: Waycar has no Claude login of its own. Claude Code signs in on your machine as it always does, with whatever it already uses. Waycar is free.
  - q: Can I approve Claude Code permission requests from my phone?
    a: Yes. In Chat Mode, tap Allow or Cancel on the card that shows the request. In the terminal, answer with the toolbar keys. On tmux, Allow and Cancel need the Waycar hooks that the install command adds.
  - q: Does it work when my laptop is asleep?
    a: No. The agent runs on your machine, and Waycar has no cloud copy of it. The machine has to be on, awake and reachable over SSH. Keep it plugged in and set to stay awake if you want to check in while you are out.
  - q: Should I use Waycar or Claude Code Remote Control?
    a: Remote Control is built in, works with Claude Code only, and needs no SSH setup. Waycar works with many agents, opens the real terminal, and connects straight to your machine. The comparison page has the details and sources.
compare: [claude-code-remote-control, happy, termius]
help: [chat-mode, install, new-agent, requirements]
---

## Claude Code runs on a computer, not your phone

When you "run Claude Code from your iPhone", Claude Code does not run on the phone. It runs on a computer, in a terminal. That computer can be your own Mac or Linux machine, or Anthropic's cloud. The phone is a window into the session.

Waycar is that window for your own machine. It attaches to the tmux or herdr session where Claude Code runs. Your phone connects straight to your machine over mosh, with SSH as the fallback. There is no Waycar account, and no Waycar server sits in the path of your session.

Waycar has an optional push relay. Your machine encrypts each notification first, so the relay cannot read what it says. For Live Activities it does see how many agents are in each status.

## Set it up in four steps

1. **Run Claude Code in tmux or herdr.** If you start Claude Code from Waycar, it does this for you. In New Agent, pick Claude Code and turn on Chat Mode if you want a chat view.
2. **Install the Waycar host tools.** Run this once on the machine:

   ```sh
   curl -fsSL https://waycar.dev/install.sh | sh
   ```

   On a fresh machine it first asks whether to install or only pair this computer. Press Return to install. It then offers to show a pairing QR code to scan in Waycar. On tmux it also adds Waycar's status hooks, which is how Waycar knows when an agent is Blocked or Done. Waycar has [Status Hooks for 17 agents](/help/tmux-hooks), including Claude Code.
3. **Scan the code in Waycar.** Waycar makes your key on the phone and pins your machine's host key, so the first connection is already checked.
4. **Open the Console.** Claude Code shows up in the list, sorted by who needs you.

## What you can do from the phone

- **See when it needs you.** Blocked agents come first in the Console, after any you pinned. You get a push when Claude Code is Blocked or Done, and a Live Activity can keep a machine on your Lock Screen.
- **Answer permission requests.** In Chat Mode, a "Needs your OK" card shows the request. Tap Allow or Cancel. For anything else, tap Show Terminal.
- **Use the real terminal.** You see exactly what Claude Code draws, with a toolbar for Esc, Tab, arrows and Ctrl.
- **Send photos and files.** Attach up to 10 per message. Files can be up to 64 MiB each. Photos are resized to fit 16 MiB. The file lands in a private folder on your machine, and its path is added to your message when you send it.
- **Dictate a prompt.** On iOS 26 or later, dictation runs on your phone.
- **Answer it in the car.** In CarPlay, on an iPhone with iOS 26.4 or later, Waycar reads a Claude Code command approval out loud and you say "allow" or "deny". It holds risky or long commands until you're stopped. See [Approve commands by voice](/help/carplay-voice).
- **Bring back a closed session.** Closed Sessions keep an agent for 30 days. Tap it to reopen it in the same folder.

## What Waycar cannot do

- Claude Code runs on your machine, not in the app, and Waycar keeps no cloud copy. Your machine must be on and awake.
- Its agent terminals need tmux, herdr or Herdr Core, or Zellij from the next update. It cannot open an arbitrary SSH server.
- Waycar supports Mac and Linux machines. Claude Code also runs on Windows, which Waycar does not support.
- It is an iPhone and iPad app with no native desktop or web client. An Android app is coming soon.
- Chat Mode covers 14 agents; see [Chat Mode](/help/chat-mode).
- The terminal session ends about 20 seconds after you leave the app and re-attaches on its own when you come back. Claude Code keeps running on your machine the whole time.

## If you only use Claude Code

Anthropic's Remote Control is the built-in way to steer a Claude Code session from the Claude app. It needs a paid Claude plan and no SSH. Anthropic also runs Claude Code sessions in its cloud, which you can start from the Claude app, and those do not need your machine to be on.

Waycar is the better fit when you also run Codex, omp, pi or opencode, want the agent's real terminal, or want your session to go straight to your machine. See [Waycar vs Claude Code Remote Control](/compare/claude-code-remote-control) for the side-by-side and the sources. For the same need on tmux, see [tmux on your iPhone](/solutions/tmux-on-iphone).
