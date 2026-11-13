---
title: CarPlay voice isn't working
description: Fix CarPlay voice problems in Waycar, from missing microphone access and speech models to iOS versions older than 26.4.
category: troubleshooting
order: 60
keywords: [microphone, speech model, listening, voice input, ios 26.4, car, dictation]
related: [carplay, carplay-voice, dictation]
---

When Waycar can't listen in the car, it says why out loud. Most problems come from microphone access, a missing on-device speech model, dictation already running in Waycar, or an older iOS.

## What Waycar says

| Waycar says | What to do |
| --- | --- |
| "Waycar doesn't have microphone access." | On your iPhone, open iOS Settings, then Waycar, and turn on Microphone. |
| "There's no on-device speech model for your language." | Speech is transcribed on the iPhone, so it needs an on-device speech model for your language. Your language isn't available for on-device speech on this iPhone. |
| "The speech model isn't available right now." | The speech model for your language couldn't be downloaded. Check that your iPhone is online, then tap the agent again. |
| "The microphone is already in use." | Waycar is already dictating in a Composer on your iPhone. Stop that dictation, then tap the agent again. |
| "Voice input isn't ready yet. Try again in a moment." | Waycar is still getting the speech model, or is waiting for you to allow the microphone on your iPhone. Answer any prompt on the iPhone, wait a moment, and tap again. |
| "Listening stopped unexpectedly." | Tap the agent again to start over. |
| "Voice input isn't available on this device." | This iPhone can't take voice input for Waycar. |

## The car screen says Waycar needs iOS 26.4

The car's screen shows "Waycar in CarPlay needs iOS 26.4 or later." on older iOS versions. Update your iPhone in iOS Settings, General, Software Update.

## There's no CarPlay Voice in Settings

CarPlay is iPhone only, so Waycar on iPad has no CarPlay settings. On an iPhone, **Settings › CarPlay Voice** appears on iOS 26.4 and later.

## Waycar stops listening

The conversation ends when you go back on the car's screen, say "stop" or "that's all", or say nothing for two minutes. Tap the agent again to keep talking. See [CarPlay](/help/carplay).

## The voice sounds robotic

Pick a better voice in **Settings › CarPlay Voice**. See [Choose the voice](/help/carplay#choose-the-voice).

## Good to know

- Dictation in the phone's Composer uses the same on-device speech. See [Dictation](/help/dictation) for its own messages.
- For approvals the car holds or won't answer, see [Approve commands by voice](/help/carplay-voice).
