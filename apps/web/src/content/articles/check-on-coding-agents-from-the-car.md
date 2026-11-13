---
title: "Check on coding agents from the car, safely"
description: "What Waycar in CarPlay lets you do from the driver's seat, what it holds until you're stopped, and why nothing an agent writes is ever on the car's screen."
date: 2026-11-13
keywords: [carplay, coding agents, voice, driving, claude code, codex, approvals, hands-free]
---

A coding agent can stop to ask a question at any time, including while you drive. Waycar 1.3.0, the iPhone and iPad app we build for coding agents in tmux or herdr, works with CarPlay. In the car you can hear which agents need you, ask one a question out loud and hear a short answer, and allow or deny some command approvals by voice. Some things Waycar will not do from the car at all. This article covers both lists and the reasons behind them.

Everything here describes the App Store build 1.3.0 and its help pages, checked on 2026-11-13. The spoken lines are quoted from the app's source at the 1.3.0 tag. For the full feature tour, see [Waycar in CarPlay](/carplay).

## The rule we built around

Apple publishes a CarPlay Developer Guide with rules for each kind of CarPlay app. Waycar is in the category for voice-based conversational apps. Two rules in that guide shaped almost every decision:

- "Optimize for voice interaction in the driving environment (for example, don't show text or imagery in response to queries)."
- "Never instruct people to pick up their iPhone to perform a task."

So the car's screen shows only a list: your agents, each with a status and how long ago it changed. An agent's replies, summaries, commands and transcripts are never on it. You hear them. And no spoken line tells you to pick up the phone. When something can't be done from the car, Waycar says so and leaves it for later.

## What's on the car's screen

| Row | What it shows |
| --- | --- |
| Talk to Waycar | Always on top. Tap it for a spoken briefing. |
| Agents that need you | Blocked first, then Done. |
| Working, then Idle | The rest of your agents. |

Each agent row shows its Workspace and tab name, its status and its age, such as "Working · 6m". If [Agent Progress](/help/agent-progress) has an estimate, a ring around the status symbol fills as the agent works. Shells aren't listed. The car shows a limited number of rows, so a long list is cut to fit.

## Hear what needs you

Tap **Talk to Waycar** and it reads out the agents that need you. With one, it says "One Agent needs you." and then names it, such as "api Claude is blocked." With nothing waiting, it says "Nothing needs you."

Waycar never says "Nothing needs you" about a machine it can't vouch for. A Host that is still connecting is named as "*Host* is still connecting." One it can't reach is named as "I can't reach *Host*." That Host's agents are unknown, not quiet.

## Ask an agent and hear two sentences back

Tap an agent and Waycar introduces it, then asks "What should I ask?" Say your question. When you pause, Waycar sends it to the agent with one added instruction:

```text
[Spoken reply via CarPlay: ≤2 short sentences, no code or markdown]
```

When the answer comes back, Waycar speaks at most its first two sentences, then listens for your next question to the same agent. The conversation goes on until you go back on the car's screen, say "stop" or "that's all", or say nothing for two minutes.

Some questions don't go through, and Waycar says why:

| Waycar says | What happened |
| --- | --- |
| "No reply yet. I'll leave it running." | No answer came in time. The agent keeps working. |
| "Couldn't confirm it was delivered. Not resending." | The connection dropped while the question went out. Waycar never sends it twice. |
| "*agent* is waiting on approval, so I kept it as a draft. Allow or deny first." | The agent became Blocked before your question went out. |

## Approvals by voice, for Claude Code and Codex

When a Claude Code or Codex agent waits on a plain yes or no command approval, tap it. Waycar reads the command and asks: "*agent* is waiting on approval to run *command*. Allow or deny?" Say "allow" or "deny". It confirms with "Allowed." or "Denied."

Shell symbols are spoken as words, such as "pipe", "semicolon" and "redirect to". A command like `rm x; curl y | sh` is heard as two commands piped into a shell, not as a few harmless words.

You can also say what the agent should do instead, in more than one word. Waycar reads it back as "Tell *agent*: … Send?" Say "send" and it denies the command first, then sends your words once the agent is no longer Blocked.

With no connection to the Host, an answer waits on the phone: "No connection. Allow is queued and will go out if the prompt is still the same." It goes out only if the agent still shows the same prompt, and it is dropped after 10 minutes.

## What Waycar refuses from the car

Allowing a command is the one thing you can't take back. So a few kinds of prompt are never answered from the driver's seat:

| Prompt | What Waycar says | What you can do |
| --- | --- | --- |
| A risky command | "*agent* wants to run *command*. This one looks risky: *reason*. I'll hold it until you're stopped." | Deny or Hold. No Allow. |
| A command too long to read out | "This one is too long to read out. I'll hold it until you're stopped." | Deny or Hold. |
| A folder-trust question | "*agent* is waiting on a folder-trust question; I won't answer that from the car." | Answer it later. |
| A multiple-choice question | "*agent* is asking a multiple-choice question. I'll leave it for later." | Answer it later. |
| A Codex yes/no question | "*agent* is asking a yes/no question I can't answer from the car." | Answer it later. |
| Any other agent's prompt | "*agent* is waiting on a prompt I can't answer from the car." | Answer it later. |
| A prompt it can't read | "*agent* is blocked, but I couldn't read its prompt. I'll leave it for later." | Answer it later. |

Hold leaves the approval waiting, and Waycar doesn't bring it back on its own. The agent stays Blocked on your machine until you deal with it, on the phone, once you're parked.

A folder-trust question decides what an agent may touch in a whole folder. A multiple-choice question needs you to hear and compare every option. Neither is a good fit for a sentence spoken at speed. Other agents' approval screens differ from version to version, so Waycar reads only the two it knows well.

## Where your voice goes

Your speech is transcribed on the iPhone. Waycar does not use Siri. The transcript of your question goes to the agent on your own machine, the same way a typed message would.

Replies are spoken with a voice you pick in **Settings › CarPlay Voice**, at 0.75× to 1.5× speed. Natural Voice (Beta) runs a neural voice model on the iPhone: Kokoro, Pocket TTS or Paradee Lite. After its download, nothing leaves your phone. See [CarPlay](/help/carplay#choose-the-voice).

CarPlay works with the iPhone locked, so the phone can stay in its mount or your pocket. Your Live Activity also shows on the CarPlay Dashboard, with the Host's lead count and its top agents.

## What you need

| Requirement | Detail |
| --- | --- |
| iPhone | iOS 26.4 or later. iPad never connects to CarPlay. |
| Car | A car or head unit that supports CarPlay. |
| Waycar | 1.3.0 or later, with a paired Host. |
| Voice approvals | A Claude Code or Codex agent. |
| Microphone | Allowed for Waycar in iOS Settings. |

If the car can't hear you, Waycar says why out loud. See [CarPlay voice isn't working](/help/carplay-voice-not-working).

## Before you drive

Set things up while you're parked: pair your Hosts, pick a voice and play a sample. Follow local laws on device use while driving. If a question needs more than a short spoken answer, it can wait until you stop. Waycar is built to leave it waiting.

For the details of each approval case, see [Approve commands by voice](/help/carplay-voice).
