---
title: CarPlay
description: See your agents on the car's screen and talk to them out loud with CarPlay on iPhone, with spoken answers and nothing agent-written on screen.
category: devices
order: 40
keywords: [car, driving, voice, talk to waycar, hands-free, natural voice, kokoro, voice models, carplay voice]
related: [carplay-voice, carplay-voice-not-working, agent-progress, agent-status]
---

On an iPhone with iOS 26.4 or later, Waycar shows your agents on the car's screen in CarPlay. Tap an agent and ask it anything out loud, hands-free. Waycar sends your question when you pause and speaks the agent's answer.

CarPlay is iPhone only. An iPad never connects to CarPlay, so Waycar on iPad has no CarPlay settings.

## What's on the car's screen

A **Talk to Waycar** row sits on top, then your agents in attention order: Blocked first, then Done, Working and Idle. Each agent reads as it does on your phone, Workspace and tab name, with its status and how long ago it changed. Shells aren't listed.

A Working or Blocked agent with an [Agent Progress](/help/agent-progress) estimate gets a ring around its status symbol: one segment per plan step, or one per phase, filled as it goes. A plan with more than 12 steps draws one continuous ring. The detail text adds the label between the status and the age, such as "Working · 3/7 · 6m" or "Working · verifying · 12m". An out-of-date ring is dimmed.

Nothing an agent writes is shown on the car's screen. You hear it instead.

## Hear what needs you

Tap **Talk to Waycar** for a spoken briefing, such as "One Agent needs you." When nothing is waiting, Waycar says "Nothing needs you." A Host that is still connecting is named as "*Host* is still connecting.", and one Waycar can't reach as "I can't reach *Host*." Tap **Done** to stop.

## Ask an agent something

1. Tap an agent and speak your question.
2. When you pause, Waycar sends it. The screen shows **Sending…**, then **Waiting for reply**. Nothing is read back and there's nothing to tap.
3. Waycar speaks the agent's answer in a sentence or two, then listens for your next question to the same agent.

The conversation goes on until you go back on the car's screen, say "stop" or "that's all", or say nothing for two minutes.

Sometimes the question doesn't go through:

| Waycar says | What happened |
| --- | --- |
| "No reply yet. I'll leave it running." | No answer came in time. The agent keeps working; check it later. |
| "Couldn't confirm it was delivered. Not resending." | The connection dropped while your question was going out. Waycar never sends it twice; check the agent later. |
| "*agent* is waiting on approval, so I kept it as a draft. Allow or deny first." | The agent became Blocked before your question went out. Answer the approval, then ask again. |
| "That Agent isn't in the list anymore." | The agent closed or its Host went away. |

When an agent waits on a command approval, you can answer by voice. See [Approve commands by voice](/help/carplay-voice).

## Choose the voice

Waycar speaks with the best voice installed on your iPhone. To pick another, open **Settings › CarPlay Voice**. The list starts with **Automatic**, shown with the voice it uses now, such as "Automatic (Ava (Premium, en-US))". Automatic follows the best installed voice, including ones you download later. Every other voice shows its quality, **Premium**, **Enhanced** or **Compact**, and its language. The **CarPlay Voice** row in Settings shows the voice in use, or **Default**. The row appears on iPhone, on iOS 26.4 and later, and each iPhone keeps its own choice.

For a more natural voice, download an Enhanced or Premium English voice in iOS Settings, Accessibility, Read & Speak, Voices. Siri voices aren't available to apps.

### Speaking speed

**Settings › CarPlay Voice › Speaking Speed** sets how fast CarPlay speaks: 0.75×, 0.9×, 1.0× (normal), 1.1×, 1.25× or 1.5×. It applies to the Apple voice and the Natural Voice alike. **Play Sample** speaks one sentence with the voice and speed in use now. The **CarPlay Voice** row in Settings shows just the name of the voice in use, such as "Heart" or "Ava".

### Natural Voice (Beta)

**Settings › CarPlay Voice › Natural Voice** speaks with a neural voice model that runs on your iPhone. Pick one:

| Model | Download | Choose it if |
|---|---|---|
| Kokoro | about 230 MB | You want the most natural voice |
| Pocket TTS | about 530 MB | You want speech to start fastest, smooth long replies, and the most speakers (19 English speakers, default Alba) |
| Paradee Lite | about 13 MB (plus Kokoro's text model if not already downloaded) | You want the smallest download and least battery |

Tap **Download** next to a model (once each), then select it and pick a **Speaker**. Selecting another downloaded model switches instantly. **Delete** removes a model to free space; files another downloaded model still uses are kept. After a download, nothing leaves your phone. Whenever the Natural Voice can't speak, Waycar uses the voice chosen above.

## Good to know

- Speech is transcribed on the iPhone.
- CarPlay works with the iPhone locked.
- Agent Notifications still reach the Lock Screen and Apple Watch while Waycar is open only in the car.
- The car shows a limited number of rows, so a long agent list is cut to fit.

Voice or the microphone not working? See [CarPlay voice isn't working](/help/carplay-voice-not-working).
