# Waycar

> Waycar is a native iPhone and iPad app for checking on your coding agents in herdr or tmux. Agent terminals run over mosh, so they survive network changes, re-attach on their own after the phone sleeps, and fall back to SSH when mosh can't connect. No account required.

Native for iPhone & iPad · works with herdr and tmux.

**Your agents stay attached. Over mosh, and SSH.**

- Survives network changes
- Catches up after dead zones
- Falls back to SSH on its own
- No account
- Android: coming soon

Watches claude, codex, omp, gemini, opencode, pi and more.

Install on your Mac or Linux box:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

It finds herdr or tmux, sets up Waycar, and offers to show a QR code to pair.

## mosh + SSH: change networks, the session is still there

Plain SSH drops the moment your network changes. Waycar runs your agent terminals over **mosh** instead, so they stay attached when you switch networks. Leave the app or lock your phone and Waycar keeps running for about 20 seconds; after that the session ends and the terminal re-attaches on its own when you come back. SSH stays ready in case mosh can't get through.

**Why mosh beats SSH.** SSH is one TCP connection tied to your phone's network address, so moving from Wi-Fi to cellular breaks it; Waycar then reconnects and re-attaches the terminal on its own. mosh runs over UDP and roams: the session carries on across the network change. `mosh-server` runs on your Host and holds the session there, and your phone gets mosh's redraw of the current screen, so after a dead zone you jump straight to the live screen instead of a replay of every byte. While the app is open, mosh rides out network gaps of up to about a minute. Once the app is suspended (about 20 seconds after you leave it), the session ends over mosh and SSH alike, and the terminal re-attaches on its own when you return. There is no local echo prediction, so typing right into the terminal over mosh echoes at your machine's pace. No UDP or no `mosh-server`? Waycar falls back to SSH on its own, and the MOSH or SSH badge on each Host shows which one you're on. Tap Test Mosh on the Host's page to check.

| Situation | Plain SSH | Waycar over mosh |
| --- | --- | --- |
| You switch networks | The connection drops. Waycar reconnects and brings the terminal back. | Nothing drops. Walk from Wi-Fi to cellular and your agent stays attached. |
| Your phone sleeps | About 20 seconds after you leave the app, the session ends. Waycar re-attaches the terminal on its own when you come back. | The same as SSH: the session ends after about 20 seconds, and the terminal re-attaches on its own when you come back. |
| Mosh can't connect | No change. SSH is always there underneath. | Waycar notices mosh isn't getting through and uses SSH instead. |

- **See which one you're on.** A MOSH or SSH badge next to each Host tells you how you're connected.
- **Back in a moment.** Come back to the app within about 70 seconds of leaving and the terminal re-attaches fast. Its last screen stays up while it reconnects.
- **Queued messages.** A message sent while the Host is offline waits on your phone, files included, and goes out when the Host is back. Cancel or edit it while it waits.
- **Draft at full speed.** You write prompts in the Composer, right on your phone, so a weak signal won't slow your typing. The whole message goes out when you hit Send. When you type right into the terminal, letters show up once your machine sends them back.
- **What your machine needs.** Install `mosh-server` and let UDP traffic reach it. Missing either one? Waycar just stays on SSH.

## Chat Mode: skip the terminal, just talk to your agent

Turn on Chat Mode when you start Claude Code, Codex, omp, pi, opencode, GitHub Copilot CLI, Qwen Code, Gemini CLI, Grok Build, Antigravity, Hermes Agent, Kilo Code, Cline or Muse. The agent opens as a simple chat, with your messages, its replies, and a line that says what it's doing. (Antigravity needs one more step on herdr; see the FAQ.)

- **Replies in your notifications.** When the agent finishes, its reply shows up right in the notification. Read it without opening the app. For now this works with herdr, not tmux.
- **Allow or Cancel, right there.** When the agent asks for permission, tap Allow or Cancel in the chat. Need more? Show Terminal is one tap away. On tmux, Allow and Cancel need Waycar hooks.
- **See what it sees.** Images and videos the agent shows you appear above its reply. Tap one to see it full screen.
- **New Chat from the Home Screen.** Touch and hold the Waycar icon, then tap New Chat. A fresh chat starts right away, where your last chat was. Or pick a Host and agent for it in Settings.

## CarPlay: talk to your agents from the car

Waycar works with CarPlay on iPhone, with iOS 26.4 or later. It is a voice-based conversational app: you hear your agents and answer them out loud. The car's screen lists your agents under a "Talk to Waycar" row: first the ones that need you (Blocked, then Done), then Working and Idle. Each row shows the agent's status and how long ago it changed, with a progress ring when Agent Progress has an estimate. Shells aren't listed, and a long list is cut to fit. Nothing an agent writes is shown on the car's screen: you hear it instead. More: https://waycar.dev/carplay

- **Hear what needs you.** Tap Talk to Waycar for a spoken briefing, such as "One Agent needs you." or "Nothing needs you."
- **Ask out loud.** Tap an agent and ask it anything. Waycar sends your question when you pause and speaks the agent's answer in a sentence or two, then listens for your next question. It stops when you go back on the car's screen, say "stop" or "that's all", or say nothing for two minutes.
- **Yes or no, by voice.** For Claude Code and Codex, Waycar reads a plain yes or no command approval out loud and you say "allow" or "deny". Say what to do instead and Waycar reads it back ("Tell *agent*: … Send?"), then denies the command and sends your words.
- **Held until you're stopped.** Waycar won't allow risky commands, or ones too long to read out, from the car. It won't answer folder-trust or multiple-choice questions, or prompts from other agents, from the car either. Shell symbols are spoken as words, such as "pipe", so you hear exactly what would run.
- **Choose the voice.** Settings › CarPlay Voice picks an installed voice and a speaking speed from 0.75× to 1.5×. Natural Voice (Beta) runs a neural voice model on your iPhone: Kokoro, Pocket TTS or Paradee Lite.
- **Speech stays on your iPhone.** Your speech is transcribed on the iPhone, and CarPlay works with the iPhone locked. The Live Activity also shows on the CarPlay Dashboard. iPad never connects to CarPlay.

Help: https://waycar.dev/help/carplay, voice approvals: https://waycar.dev/help/carplay-voice, voice not working: https://waycar.dev/help/carplay-voice-not-working

## AI Usage (via CodexBar): know which account runs dry, before your agent does

If a Host has [CodexBar](https://github.com/steipete/CodexBar) installed, Waycar shows an AI Usage row at the top of the Console's Agent list, with the provider closest to its limit.

1. Glance: whichever provider is running lowest, shown as the percent left this session and this week.
2. Tap the row for bars, then All details.

- **Every provider, lowest first.** Gauges for each provider's session and weekly limits, plus when each one resets. A pace line under each gauge says how much you have in reserve, or when it runs out. Pull down to refresh.
- **Runs on your Host.** Waycar runs CodexBar on your machine over SSH and checks again every few minutes while the app is open.
- **Entirely optional.** The Hosts list marks the Hosts AI Usage reads from. You can turn AI Usage on or off for any Host, or point Waycar at CodexBar if it didn't find it.

## Closed Sessions: quit by accident? Pick up where you left off

When an agent exits or its tab closes, Waycar keeps it for 30 days. Two taps to pick it back up.

1. **Filter Closed.** Tap Closed in the Console. Every agent that ended shows up, newest first. Search finds them too.
2. **Tap one.** Waycar opens it again in a new tab, in the same folder it ran in.
3. **You're back.** You land in the terminal. Claude Code, Codex, omp, pi, opencode and most other agents pick up the same chat. If an agent didn't save its place, you get its latest session, its resume list or a fresh start.

- **Opened the wrong one?** Just leave it. If you back out without typing while it's idle, it closes again and goes back on the list.
- **On iPhone and iPad.** With iCloud Sync on, an agent that ends on your Mac shows up as closed on both.
- **Out of your way.** Closed agents stay off your main list and clear out after 30 days. Swipe to forget one sooner.

## tmux: already on tmux? Keep it

Waycar works with tmux 3.2 or later too. Same app, same install command. Run both herdr and tmux? Their agents show up together. herdr still gives you the most, so here's the honest list.

| Feature | herdr | tmux |
| --- | --- | --- |
| Agent list | Workspaces, tabs and panes | Sessions, windows and panes |
| Live terminal | Yes | Yes. Your desk and phone can both watch the same window. It fits whichever one opened it or typed in it last. |
| Agent status | Yes, for every agent herdr knows. omp needs herdr's omp integration. GitHub Copilot CLI reads Idle until the model starts to answer. | Claude Code, Codex, omp, pi, opencode, GitHub Copilot CLI, Qwen Code, Gemini CLI, Grok Build, Antigravity, Hermes Agent, Kilo Code, Cline, Cursor Agent, Devin CLI, Kiro CLI and Muse, through Waycar hooks. Others show Unknown. |
| Blocked and Done alerts | Yes | Yes, through Waycar hooks |
| Chat Mode (chat view, New Chat) | Yes. Antigravity chats need herdr's Antigravity integration. | Yes. Allow and Cancel, and Antigravity chats, need Waycar hooks. |
| Chat Mode replies in alerts | Yes | Not yet |
| Live Activities | Yes | Yes, through Waycar hooks |
| New agent on a worktree | Yes | Yes. It opens as a new tmux session. Needs git on your Host. |
| Closed Sessions | Yes. Resume picks up the exact session when herdr's integration for the agent reports its session, or, for Claude Code, pi, GitHub Copilot CLI, Qwen Code and Grok Build, when Waycar started the agent. | Yes. Resume picks up the exact session when Waycar hooks are on. |
| Scrolling an agent's history | Yes, every agent (herdr 0.9.3 or later) | Yes, except Codex. Inline agents and shells scroll through tmux's copy mode, which desk windows on that pane see too. |
| mosh, AI Usage, dictation | Yes | Yes |

## How it works: phone to machine, nothing in between

Waycar talks to herdr or tmux over a plain SSH connection to your computer. There's no account to make and no extra port to open. If you can SSH in and herdr is running, or you have tmux 3.2 or later, you're set. On tmux, run the install command for live status and alerts.

The diagram:

- Your device (Waycar): SSH key made on device; never leaves the Keychain; iPhone · iPad · iOS 18+.
- The link: ssh, straight to your machine; mosh, for live terminals. No cloud, no account.
- Your machine (SSH + herdr or tmux): OpenSSH (stock config); herdr ≥ 0.7.5 or tmux ≥ 3.2; mosh-server, for mosh. Runs claude, codex, omp, gemini, opencode, pi.

What that means for you:

- **The same screen you'd see at your desk.** Waycar shows the agent's real terminal, not a copy. You see exactly what the agent draws.
- **Survives the subway.** Agent terminals run over mosh, so switching networks won't knock them off, and after the phone sleeps they re-attach on their own. If mosh fails, Waycar drops back to SSH. A Jump Host gets you to machines that aren't on the open internet.

## Features: built for the moment an agent needs you

Check in from the couch or unblock an agent on the train, then pick up the whole session on iPad. Every screen is native SwiftUI.

iPhone screens: Console (sorted by status), Attach (live terminal), New Agent (fresh worktree), Hosts (every machine).

### Agent console: every machine, sorted by who needs you first

The Console lists agents from all your Hosts by status, so a blocked one is always on top. Filter by Host, search by folder or title, or long-press to pin an agent. Sort order: Blocked → Done → Working → Idle.

### Terminal: a real, native terminal

Built on Ghostty's terminal engine. Full-screen terminal apps look the way they should, scrolling has momentum, and a long-press selects text. Keep scrolling and a button takes you the rest of the way: to the start, or back to live output.

### Prompting: draft it first, send once

The Composer is a local draft, so you can fix it up before sending, and other-language keyboards still work. Dictation (iOS 26) runs on your device. Snippets and agent Skills drop in without sending anything.

### Workspaces: start an agent on a clean worktree

Turn on New Worktree and your agent gets a fresh git checkout, on its own branch. Or start a Workspace in any folder on the Host.

### Connect: pair a machine with one QR

Your keys are made on the device. The Pairing Code already knows the machine's host key, which means no blind "trust this host?" prompt. Keys are ed25519, made on-device, with the host key pinned. The Hosts sheet shows live CPU, memory and swap gauges for each connected Host.

### iPad: a first-class iPad app, keyboard and all

The Console moves to a sidebar next to the live terminal. Put two Hosts side by side in Stage Manager, drag text and images into the Composer, and keep your hands on the keys with shortcuts. See the iPad gallery: https://waycar.dev/ipad

Keyboard shortcuts:

- ⌘1–9: agents
- ⌘[ ⌘]: switch
- ⌘F: search
- ⌘N: new agent
- ⌘E: input mode
- ⌘↩: send

### Notifications: know the moment an agent blocks

Get a push when an agent is Blocked or Done. It's encrypted on your machine first, so our relay can't read it. Live Activities keep each Host on your Lock Screen and in the Dynamic Island.

### Preview bar: everything it prints, one tap away

Images, PDFs, Markdown files and links the agent prints collect in one preview bar under the terminal. Tap it for the full list: Markdown opens rendered, images and PDFs full screen, links in the browser. Going the other way, send a photo or file to the Host (up to 64 MB) and its path lands in your draft.

### Controls: every key an agent can ask for

The Toolbar under every agent sends Esc, Tab, arrows, Ctrl, F-keys and more straight to it. Pick its keys in Settings, make your own, or tap the keyboard button to type right into the terminal. Keys include esc, tab, ⇧tab, ↑, ↓, ctrl, alt and F-keys.

### Appearance: 30 terminal themes, one for light mode, one for dark

JetBrains Mono and IBM Plex Mono come built in, and you can pinch to zoom the text. Your settings sync to your other devices through end-to-end encrypted iCloud Keychain.

### Agents: bring the agents you already run

Waycar finds the agent tools on each Host and starts them from the New Agent sheet. Plain shells show up in the Console too.

Supported agents (23): claude, codex, omp, gemini, opencode, pi, Amp, Antigravity, Cline, Cursor Agent, Devin CLI, Droid, GitHub Copilot CLI, Grok Build, Hermes Agent, Kilo Code, Kimi CLI, Kiro CLI, Maki, Mastra Code, Muse, Qoder CLI, Qwen Code. Per-agent support on herdr and tmux: https://waycar.dev/help/supported-agents

## Security & privacy: your keys, your machines, nobody else's servers

The app has no accounts, ads, or cross-app tracking. The waycar.dev website runs Reddit and X ad-conversion pixels only where the law allows: after Allow in the EU, EEA, UK and Switzerland, never under Global Privacy Control, and not after Decline. Usage analytics are optional, pseudonymous, and never include your hosts, commands, prompts, or terminal content. Your SSH credentials and terminal data never touch our servers. Notifications are encrypted on your Host before they leave it. Our push relay sees delivery details and, for Live Activities, how many agents are in each status, but never what a notification says. Privacy policy: https://waycar.dev/privacy

- **On-device keys.** Your SSH key is made on your iPhone or iPad. The private half never leaves the Keychain.
- **Pinned fingerprints.** The Pairing Code includes the host key fingerprint, so your first connection is already verified.
- **Checked at both hops.** Waycar verifies the Jump Host and the machine behind it separately.
- **Post-quantum ready.** Uses post-quantum key exchange when your server supports it.
- **On-device dictation.** Speech turns into text on your phone. Nothing is sent, not even to your Host, until you send it.
- **Encrypted sync.** Hosts and keys sync through end-to-end encrypted iCloud Keychain. You can turn that off on any device.

## Setup: one command on the Host, one scan on the phone

1. **Install Waycar on the Host.** Do this once on each machine. The same command works for herdr, tmux, or both.
2. **Show a Pairing Code.** When it's done, the command offers to draw a QR code right in your terminal (herdr and tmux Hosts alike). Run it again anytime to pair another device. Press `c` to copy the code (on Linux it shows the code so you can select it).
3. **Scan it in Waycar.** Waycar makes your keys, pins the machine's host key, and your agents appear. For mosh, also install `mosh-server` on the Host.

Requirements:

- iOS / iPadOS 18+
- Android: coming soon
- herdr ≥ 0.7.5
- or tmux ≥ 3.2
- No Node needed on the Host
- OpenSSH · streamlocal on, for herdr
- macOS: Remote Login on
- mosh-server + UDP, for mosh

```sh
# prerequisites: herdr ≥ 0.7.5 or tmux ≥ 3.2, OpenSSH running, curl and tar (no Node)
curl -fsSL https://waycar.dev/install.sh | sh
# answer Y to show a pairing QR
# scan it in Waycar, or press c to copy (Mac) or show (Linux) the code
# run it again anytime to pair another device
# or to update Waycar, e.g. for Chat Mode
```

## FAQ

### How do I get Waycar?

{{app_store}}, then run the install command on each machine that runs herdr or tmux 3.2 or later, or add the machine by hand in the app. An Android app is coming next.

### Which agents work in Chat Mode?

Claude Code, Codex, omp, pi, opencode, GitHub Copilot CLI, Qwen Code, Gemini CLI, Grok Build, Antigravity, Hermes Agent, Kilo Code, Cline and Muse. Turn on Chat Mode when you start one of them. Other agents open in the terminal like always. Chat Mode needs the latest Waycar plugin on your Host, so run the install command again first. Cline chats get no Chat Prompt, because Cline can only replace its own. On herdr, Antigravity chats need herdr's Antigravity integration: herdr integration install antigravity-cli. Install opencode or Kilo Code before you run the install command, so it adds their Chat Prompt extension.

### Do I need herdr?

No. Waycar also works with tmux 3.2 or later, and the same install command sets it up. herdr still gets you the most: it knows the status of more agents, and for now only herdr puts Chat Mode replies in your notifications.

### How does Waycar know a tmux agent is blocked?

The install command adds small Waycar hooks to Claude Code, Codex, omp, pi, opencode, GitHub Copilot CLI, Qwen Code, Gemini CLI, Grok Build, Antigravity, Hermes Agent, Kilo Code, Cline, Cursor Agent, Devin CLI, Kiro CLI and Muse, as long as they're installed first. When an agent stops to ask you something or finishes, its hook tells tmux, and Waycar reads it. Other agents show Unknown for now. Codex asks you to review new hooks once, on its /hooks screen, before they turn on. Installed an agent later? Run the install command again.

### What does Waycar cost?

Waycar is free. You pay for your own machines and any AI providers you use. The app has no ads, and usage analytics are opt-in. Privacy: https://waycar.dev/privacy

### Does anything go through the cloud?

Not your sessions. Commands, status updates, and live terminals go over SSH straight to your machine. The exceptions are optional push notifications and optional usage analytics, which are pseudonymous and never include your hosts, commands, prompts, or terminal content. If you turn on AI Summaries, your Host also sends recent screen text to its AI provider. There are no accounts.

### What do I need for mosh?

Install mosh-server on the Host and make sure UDP traffic can reach it. Waycar starts mosh for you over SSH, so there's nothing else to set up. Tap Test Mosh on the Host's page to check it. If mosh doesn't work, agents connect over SSH instead.

### What if I don't have CodexBar?

Then nothing changes. You won't see the AI Usage row, and the Host's page says CodexBar not found. Install CodexBar on the Host and tap Check Again.

### My machine isn't reachable from the internet. Can I still use it?

Yes. Put an SSH Jump Host in front of it, like a small server that can reach your machine. Waycar checks host keys at both hops.

### What happens to the terminal I already have open at my desk?

On herdr, opening an agent in Waycar takes over its terminal, and the other client gets disconnected. On iPad, two windows on the same Host can pass it back and forth with Take Over Here. On tmux, nothing is taken over. Your desk and phone can both watch the same window. It fits whichever one opened it or typed in it last.

### What if I quit an agent by mistake?

Waycar keeps it. Tap Closed in the Console, then tap the agent. It opens in a new tab, back in the same chat for Claude Code, Codex, omp, pi, opencode and most others. If an agent didn't save its place, you get its latest session, its own resume list or a fresh start. Closed agents stay for 30 days.

### Will a herdr update break it?

It shouldn't. Waycar needs herdr 0.7.5 or later. Newer releases keep working because it only checks for a minimum version.

### Do my Hosts follow me to my iPad?

Yes, through end-to-end encrypted iCloud Keychain. Both devices need the same Apple Account, two-factor authentication, and iCloud Keychain turned on. Sync can take a minute. Notification settings, Live Activity choices, and terminal zoom stay on each device.

### Where does my voice go when I dictate?

Nowhere. Dictation (iOS 26 or later) uses Apple's on-device speech model. Your audio is never recorded or sent. Only the text goes to your Host, and only when you send it.

### How do notifications reach my phone?

Your Host encrypts each notification and sends it through Waycar's push relay to Apple. The relay can't read what it says. It does see delivery details, plus how many agents are in each status for Live Activities. Everything else in Waycar talks to your Host directly over SSH.

### Is Waycar affiliated with herdr or the AI companies?

No. Waycar is an independent app from OTREVA, LLC. It is not affiliated with or endorsed by herdr, CodexBar, Anthropic, OpenAI, or Google. It works with the tools you already run on your own machine.

### Is there an Android app?

Not yet: Android is coming next. Waycar is on iPhone and iPad today.

## Ride at the back. See the whole train.

A waycar is the caboose, the last car on the train, keeping watch over everything ahead. Waycar is for iPhone and iPad. What's herdr? https://herdr.dev
