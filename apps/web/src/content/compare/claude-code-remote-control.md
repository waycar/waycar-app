---
title: Waycar vs Claude Code Remote Control
metaTitle: "Waycar vs Claude Code Remote Control for iPhone"
description: "Remote Control steers one Claude Code session from the Claude app. Waycar opens any agent in tmux or herdr in a real terminal over mosh or SSH."
name: Claude Code Remote Control
kind: first-party
summary: Remote Control is Anthropic's built-in way to steer a Claude Code session on your computer from the Claude app. Waycar works with many agents in tmux or herdr.
checked: 2026-10-18
order: 4
keywords: [claude code remote control, run claude code from iphone, claude code remote control alternative, claude code on iphone, claude code remote control vs waycar]
rows:
  runs-where: { level: info, text: "Your own machine (terminal, Desktop app or VS Code)" }
  account: { level: info, text: "A paid claude.ai plan: Pro, Max, Team or Enterprise" }
  path: { level: info, text: "Through Anthropic's service over outbound HTTPS" }
  mosh: { level: no, text: "No. Uses Anthropic's HTTPS service, not mosh" }
  persistent: { level: yes, text: "Yes, while the machine is on and claude keeps running" }
  host-setup: { level: info, text: "Claude Code CLI signed in to claude.ai. Run /remote-control" }
  agents: { level: info, text: "Claude Code only" }
  status: { level: partial, text: "Partial: a session list with an online dot" }
  push: { level: yes, text: "Yes, set in /config: proactive or when action needed" }
  approve: { level: yes, text: "Yes, permission prompts and questions reach the app" }
  chat: { level: yes, text: "Yes, a chat view synced with the terminal" }
  terminal: { level: no, text: "No. A chat window into the session, no shell" }
  live-activity: { level: unknown, text: "Not documented" }
  attach: { level: yes, text: "Yes, photos and files go into the session" }
  voice: { level: unknown, text: "Not documented for Remote Control sessions" }
  carplay: { level: unknown, text: "Not documented" }
  usage: { level: partial, text: "Partial: /usage and /context text output only" }
  resume: { level: partial, text: "Partial: from the machine only, about 4 hours" }
  ios: { level: yes, text: "Yes, the Claude app on iPhone and iPad, iOS 18 or later" }
  android: { level: yes, text: "Yes, the Claude app on Google Play" }
  desktop: { level: yes, text: "Yes, claude.ai/code in any browser" }
  source: { level: info, text: "Closed source, proprietary license" }
  price: { level: info, text: "Included in paid Claude plans. Pro is $20 a month" }
  general-ssh: { level: no, text: "No. Not an SSH tool" }
pickWaycar:
  - You use Codex, omp, pi or opencode as well as Claude Code and want one list for all of them.
  - You want the agent's real terminal, not only a chat window.
  - You want your sessions to go straight from your phone to your machine, with no Anthropic server in the path.
  - You sign in to Claude Code with an API key, a cloud provider or an LLM gateway, which Remote Control does not support.
pickThem:
  - You only use Claude Code and already pay for a Claude plan.
  - You want no SSH setup and no extra price.
  - You want an Android app or a browser view of the session today.
  - You want to reach a machine that you cannot reach over SSH.
  - Your agent machine runs Windows. Claude Code supports it, and Waycar's host tools do not.
faq:
  - q: Can I run Claude Code from my iPhone?
    a: You can steer it from your iPhone. Claude Code itself runs on a computer, or in Anthropic's cloud, not on the phone. Remote Control lets the Claude app steer a session on your own computer. Waycar opens the real terminal of an agent running in tmux or herdr on your computer, and it works with other agents too.
  - q: What plan do I need for Claude Code Remote Control?
    a: A claude.ai Pro, Max, Team or Enterprise plan. API keys, Amazon Bedrock, Google Cloud, Microsoft Foundry and a custom ANTHROPIC_BASE_URL, such as an LLM gateway, are not supported. On Team and Enterprise, an Owner has to turn it on first.
  - q: Does Remote Control keep working when my laptop sleeps?
    a: Anthropic's docs say your computer has to stay on and the claude process has to keep running. Claude Code reconnects when the machine comes back online after sleep or a network drop. If the machine is awake but offline, server mode gives up after about ten minutes and the process exits. Waycar also needs your machine on and awake.
  - q: Is Remote Control the same as Claude Code on the web?
    a: No. Claude Code on the web runs on cloud infrastructure, Anthropic's by default. Remote Control runs on your own machine, and the Claude app is a window into that session.
  - q: Does Remote Control use SSH or mosh?
    a: No. Your session makes outbound HTTPS requests to Anthropic's service, and the phone talks to the same service. Waycar connects straight to your machine over mosh or SSH.
sources:
  - { label: "Claude Code docs: Remote Control", url: "https://code.claude.com/docs/en/remote-control" }
  - { label: "Claude Code docs: Claude Code on mobile", url: "https://code.claude.com/docs/en/mobile" }
  - { label: Claude pricing, url: "https://claude.com/pricing" }
  - { label: Claude on the App Store, url: "https://apps.apple.com/us/app/claude-by-anthropic/id6473753684" }
  - { label: Claude on Google Play, url: "https://play.google.com/store/apps/details?id=com.anthropic.claude" }
  - { label: Claude Code license, url: "https://github.com/anthropics/claude-code/blob/main/LICENSE.md" }
related: [happy, termius, blink-shell]
solutions: [run-claude-code-from-iphone, check-ai-agent-remotely]
---

## What Remote Control is

Remote Control is a feature of Claude Code, made by Anthropic. It connects the Claude app for iPhone, iPad and Android, or claude.ai/code in a browser, to a Claude Code session that runs on your own machine. The session keeps your local files, tools and settings.

It needs a paid claude.ai plan: Pro, Max, Team or Enterprise. It has no separate charge. It works with Claude Code only.

## How it connects

Your Claude Code session makes outbound HTTPS requests to Anthropic and opens no inbound ports on your machine. The phone talks to the same service. Anthropic's docs say all traffic goes through the Anthropic API over TLS. They also say the session transcript, including your messages, Claude's replies and tool activity, is stored on Anthropic's servers.

Waycar works the other way. Your phone connects straight to your machine over mosh or SSH, and there is no Waycar server in that path. Waycar has an optional push relay. Your machine encrypts each notification first, so the relay cannot read what it says. For Live Activities it does see how many agents are in each status.

## What Waycar adds to Remote Control

- **More than Claude Code.** The Console lists agents from all your machines, sorted by who needs you. That includes Codex, omp, pi and opencode in herdr or tmux, and any other agent herdr knows.
- **The real terminal.** Remote Control is a chat window into the session. Anthropic's docs say commands such as `/plugin` and `/resume` work only in the local terminal. Waycar opens the agent's own terminal, and Chat Mode gives you a chat view for 14 agents.
- **Any way of signing in.** Remote Control needs a claude.ai login. Waycar attaches to the terminal, so how the agent signs in is up to the agent.
- **Closed Sessions.** An agent you quit by mistake comes back from the Console for 30 days.

## Where Remote Control is better

- **Little to set up.** It is built into Claude Code. You sign in to claude.ai, run `/remote-control` and scan a code with the Claude app. No SSH, no UDP, no install on the machine beyond Claude Code.
- **No extra price.** It comes with the paid Claude plan you already use for Claude Code.
- **Reach without SSH.** Because it uses outbound HTTPS only, it can reach a machine that you cannot reach over SSH.
- **Android and the web.** The Claude app runs on Android, and claude.ai/code works in any browser. Waycar is an iPhone and iPad app with no native desktop or web client, and an Android app is coming soon.
- **Push and approvals.** You can turn on push in `/config`. Claude can push when it finishes or needs a decision, and a second setting pushes for permission prompts and questions. You answer prompts in the app.
- **Photos and files.** You can attach a photo or file from the phone, with or without a caption.
- **Session controls.** From the phone you can switch model, effort and permission mode, read a diff of your changes, and run commands such as `/compact` and `/context`.
- **Many sessions.** Its server mode runs several sessions from one process, 32 by default. With `--spawn worktree`, each new session gets its own git worktree.

## What each costs

Remote Control costs nothing on its own. Claude Code is included in paid plans, not in the Free plan. Anthropic lists Pro at $20 a month billed monthly, or $17 a month billed yearly ($200 up front). Max starts at $100 a month.

Waycar is free. You still pay for the agent itself, such as your Claude plan.

## Can you use both?

Yes. Anthropic's docs suggest starting Claude Code inside tmux or screen to keep it running after you disconnect from SSH. That is the same place Waycar attaches. Use Remote Control when you only need Claude Code and no setup. Add Waycar when you also run other agents or want the real terminal.
