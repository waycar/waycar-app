---
title: Waycar vs Happy
metaTitle: "Waycar vs Happy Coder: Claude Code from your iPhone"
description: "Happy is a free MIT app that reaches Claude, Codex and Grok through an encrypted relay. Waycar reaches agents in tmux or herdr over mosh or SSH, with no account."
name: Happy
kind: agent-environment
summary: Happy is a free, MIT licensed app with its own agent runtime and phone, desktop and web apps for Claude, Codex and Grok. Waycar is an iPhone console for coding agents in tmux or herdr.
checked: 2026-10-18
order: 5
keywords: [happy coder alternative, happy vs waycar, happy coder vs waycar, claude code iphone app, claude code remote from phone, codex iphone app, happy engineering]
rows:
  runs-where: { level: info, text: "Your own machine (Happy Agent daemon), or a server you run" }
  account: { level: info, text: "Sources differ: App Store says account, docs say none" }
  path: { level: info, text: "Through Happy's relay, end-to-end encrypted" }
  mosh: { level: no, text: "No. The phone goes through Happy's relay, not mosh" }
  persistent: { level: yes, text: "Yes. The Happy Agent daemon keeps sessions running" }
  host-setup: { level: info, text: "Happy Desktop or npm i -g happy, plus a signed-in agent CLI" }
  agents: { level: info, text: "Claude, Codex, Grok. The original CLI adds more agents" }
  status: { level: partial, text: "Partial: list with working, blocked and unread marks" }
  push: { level: yes, text: "Yes, when an agent needs input or finishes" }
  approve: { level: yes, text: "Yes, approve or deny in the app" }
  chat: { level: yes, text: "Yes, a chat view with tool rows and diffs" }
  terminal: { level: no, text: "No. The phone app is a chat client, not a terminal" }
  live-activity: { level: unknown, text: "Not documented" }
  attach: { level: yes, text: "Yes, a photo or screenshot into the prompt" }
  voice: { level: yes, text: "Yes, with ElevenLabs. 20 free minutes per 30 days" }
  usage: { level: partial, text: "Partial: context and Claude 5h and 7d limits" }
  resume: { level: yes, text: "Yes, resume sessions from the app" }
  ios: { level: yes, text: "Yes, iPhone and iPad, iOS 15.1 or later" }
  android: { level: yes, text: "Yes, on Google Play" }
  desktop: { level: yes, text: "Yes: desktop app for macOS, Windows, Linux, and a web app" }
  source: { level: info, text: "Open source, MIT licensed" }
  price: { level: info, text: "Free. Voice: 20 free min per 30 days, then a subscription" }
  general-ssh: { level: no, text: "No. An app for agents, not an SSH client" }
pickWaycar:
  - You run agents in tmux or herdr on your own Mac or Linux machine and want your phone to reach them directly over mosh or SSH.
  - You want no Waycar account and no Waycar server in the path of your sessions. The optional push relay cannot read your encrypted notifications.
  - You want to pick up agents you already started in tmux or herdr, with one list sorted by who needs you.
  - You want a Live Activity on the Lock Screen and Chat Mode for 14 agents you start in Waycar, with Allow and Cancel for permission requests.
pickThem:
  - You want a free app under the MIT license, with the option to host your own server.
  - You want Android, a web app or a desktop app, not only an iPhone app.
  - You want one app that runs Claude, Codex and Grok itself, with subagents on any of them.
  - You want an agent on a server or a Mac mini that keeps working while your laptop sleeps.
faq:
  - q: Is Happy Coder free?
    a: Yes. Happy says the app is free and MIT licensed, and the models run on your own Claude, Codex and Grok subscriptions. Voice is the only thing it charges for. You get 20 free minutes per 30 days. Waycar is free, with every feature included and unlimited launches.
  - q: Does Happy need an account?
    a: Its sources differ. The App Store listing says to create an account in the app, with no email address or password. One page of its docs says there is no hosted account for the app. We claim neither. Waycar has no account at all.
  - q: Is Happy end-to-end encrypted?
    a: Its docs say content is encrypted on one device and decrypted on another, and the relay only stores and forwards opaque blobs. Voice is the exception. Its privacy policy says voice audio and context sent to the voice agent are not covered by that encryption.
  - q: Does Happy work with tmux sessions I started myself?
    a: We did not find this in its docs. The docs describe starting a session with happy claude or happy codex, or from Happy Desktop. They do not describe attaching to an existing tmux pane. Waycar is built for agents in tmux or herdr on your machine.
  - q: Does Happy support mosh or SSH from the phone?
    a: No. Its docs describe the phone path as Happy's own relay. SSH is used only to install Happy Agent on a server. Waycar runs agent terminals over mosh and falls back to SSH on its own.
sources:
  - { label: Happy docs home (maintenance mode note), url: "https://happy.engineering/docs/" }
  - { label: "Happy: how it works", url: "https://happy.engineering/how-it-works/" }
  - { label: "Happy: welcome and pricing", url: "https://happy.engineering/welcome/" }
  - { label: "Happy: the mobile app and the relay", url: "https://happy.engineering/mobile/" }
  - { label: "Happy: voice", url: "https://happy.engineering/voice/" }
  - { label: "Happy: remote server guide", url: "https://happy.engineering/guides/remote-server/" }
  - { label: "Happy docs: not a general terminal emulator", url: "https://happy.engineering/docs/comparisons/diy-terminal-app/" }
  - { label: Happy on the App Store, url: "https://apps.apple.com/us/app/happy-codex-claude-code-app/id6748571505" }
  - { label: Happy on Google Play, url: "https://play.google.com/store/apps/details?id=com.ex3ndr.happy" }
  - { label: Happy privacy policy, url: "https://raw.githubusercontent.com/slopus/happy/main/PRIVACY.md" }
  - { label: Happy source code on GitHub, url: "https://github.com/slopus/happy" }
  - { label: Happy CLI readme on GitHub, url: "https://github.com/slopus/happy/blob/main/packages/happy-cli/README.md" }
related: [claude-code-remote-control, kittylitter, paseo]
solutions: [run-claude-code-from-iphone, check-ai-agent-remotely]
---

## What Happy is

Happy (also called Happy Coder) is made by Happy Engineering. It is a free app for starting, steering and approving coding agent sessions from a phone. It runs on iPhone, iPad, Android and the web, with a desktop app for macOS, Windows and Linux.

The product has changed. The maker now describes Happy as a desktop "harness", which means an app with its own agent runtime. Happy Desktop and the Happy Agent daemon run Claude, Codex and Grok themselves, and the phone app is one client for them. The original Happy CLI wraps the claude and codex commands in your terminal. Its docs say it is in maintenance mode.

Happy is free and MIT licensed. Voice is the only paid feature.

## Where the agent runs, and how your phone reaches it

The agent runs on your own machine, or on a server where you install Happy Agent. Nothing runs on the phone. You install Happy Desktop on the machine, or run the original CLI with Node 20 or newer.

Your phone does not connect to that machine directly. It goes through Happy's relay. The docs say devices hold the keys, and the relay stores opaque blobs. It sees that sessions exist and when they were active, not what is in them. On accounts its sources differ: the App Store says to create one in the app, and one docs page says there is no hosted account. We claim neither.

Waycar takes the other path. Your phone talks straight to your machine over mosh or SSH, and there is no Waycar account. Waycar has an optional push relay. Your machine encrypts each notification first, so the relay cannot read what it says. The relay does see your Apple push token, your machine's IP address and request timing, and, for Live Activities, how many agents are working, blocked, done or idle.

The machine must be on and awake for Waycar. Agent terminals need herdr 0.7.5 or newer, tmux 3.2 or newer, or herdr-core 0.1.10 or newer. We did not find in Happy's docs whether it can attach to a tmux pane you started yourself.

## What Waycar adds to Happy

In Waycar the agent runs on your machine, in herdr or tmux, not in the app. Waycar starts, shows and steers it.

- **One list, sorted by who needs you.** The Console shows agents from all your machines as Blocked, Done, Working or Idle. Per its source code, Happy's list marks sessions as working, blocked or unread. We did not find sorting in its docs.
- **Agents you started yourself.** Open Waycar and pick up what already runs in herdr or tmux. The agent keeps going when your phone drops off. We did not find in Happy's docs whether it can do this.
- **A Live Activity.** Waycar puts agent status on the Lock Screen. We did not find a Live Activity in Happy's docs. Both apps send a push when an agent needs you.
- **A terminal over mosh.** Waycar opens the agent's terminal over mosh and falls back to SSH on its own. mosh keeps going while the app is open and catches up after dead zones. Happy's phone app is a chat client.

## Where Happy is better

- **Open source.** The app, the CLI, the desktop app and the relay server are MIT licensed. You can read the code and host your own server. Waycar's app is closed source.
- **More platforms.** Happy runs on Android, the web and desktop. Waycar is an iPhone and iPad app with no native desktop or web client. An Android app is coming soon.
- **Its own agent runtime.** Happy Agent runs the agent itself, with subagents on any model, agents that message each other, scheduled messages and persistent bots. In Waycar the agent runs on your machine in herdr or tmux, and Waycar starts, shows and steers it.
- **Sessions that outlive your laptop.** The daemon keeps sessions running when you quit Desktop. On a server, work goes on while your laptop sleeps. A Waycar machine must stay on and awake.

## What each costs

Happy is free. The app, desktop app and original CLI cost $0, and models run on your own subscriptions or API keys. Voice gets 20 free minutes per 30 days. A subscription raises that to 5 hours. Its voice page does not state the price. The App Store lists one in-app purchase, Plus Monthly at $19.99, but its pages do not say that is the voice plan.

Waycar is free, with every feature included and unlimited agent and shell launches. No account or subscription.

## Can you use both?

Yes. They do different jobs. Use Happy for a free, open source app with Android and a desktop app. Use Waycar when your agents already live in herdr or tmux and you want a direct path, with no account.
