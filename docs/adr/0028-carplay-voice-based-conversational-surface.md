---
status: accepted
---

# Waycar in CarPlay as a voice-based conversational app

_2026-10-08, accepted: `com.apple.developer.carplay-voice-based-conversation`; design in `docs/design/carplay.md`, branch `Apple-Carplay`._

Mike's story is "while driving, see my latest Agents and what each is doing, and dictate to an Agent to unblock it". Waycar is a voice-based conversational CarPlay app (CPG p.7): the Agents are the conversational partner, Waycar adds no LLM of its own. It is not a communication, driving-task or audio app.

Decisions:

- **Voice-only output.** The car screen shows Agent identity, status word and age only. Summaries, Chat Mode replies, dictated transcripts, readbacks and Blocked commands are spoken, never shown (CPG p.4 #6, p.7 #3). Voice-state titles stay generic ("Listening", "Send?").
- **One Console.** The CarPlay scene runs on the app's one `ConsoleStore`, reached through `AppModelRegistry`; a CarPlay-only launch starts the app (`WaycarAppModel.start()`), and connecting scenes of either role dial once the Keychain is readable (`KeychainReadability`), not only while protected data is available: the secrets are `AfterFirstUnlock`, and the primary function must work with the phone locked (CPG p.29).
- **Multi-source activity.** `AppActivityCoordinator` counts foreground sources (`.phone`, `.carPlay`); the grace period and its background assertion start only once every source has left. Without this the phone window's `.background` tore the Host connections down 20 s into every drive.
- **Locked-phone caches.** Connection memory and Backend presence move to `.completeUntilFirstUserAuthentication` (existing files migrated on launch); inventory, chat transcripts and last frames stay `.complete`. An unreadable file is never cached as empty nor written over.
- **Notifications while only the car is active** present on the Lock Screen and Watch instead of being silenced (ADR 0008 amendment).
- **Blocked prompts by voice.** Allow only for claude/codex permission prompts classified from the screen with the cursor on option 1 labelled exactly "Yes" / "Yes, proceed", the command read out losslessly and matching no risk pattern; risky or unreadable commands are held (Deny or Hold); trust dialogs, questions, `[y/n]` and every other kind are read-only. Answers go through Chat Mode's re-read guard (`BlockedPromptAnswerer`): the screen read before the keys must equal the one read aloud, and keys are never retried. Deny with a correction is Esc, then at most 8 s for a non-Blocked status, then one `agent.prompt`; on timeout the text becomes the Composer draft. No ADR 0009/0024 amendment: Waycar never types into a Blocked prompt.
- **Free text** is read back and sent only on an explicit Send; each car prompt carries a spoken-reply suffix asking for two short sentences, and the reply is spoken capped at two sentences.
- **Audio citizenship.** One `.playAndRecord`/`.default` session, activated only for a turn the driver started and released with `.notifyOthersOnDeactivation`; speech stays on device (ADR 0003).
- **Free.** CarPlay answers existing Agents and is never Pro-metered (ADR 0023).
- **Locked-phone write authority.** While CarPlay is connected, Allow, Deny and Send work with the phone locked, with no in-app opt-in: the only consent is iOS's per-car "Allow CarPlay While Locked", and the Blocked rules above bound what can be sent (design Q8). Leaving the car's screen ends the voice turn at once.
- **iOS floor.** Below iOS 26.4 the CarPlay scene shows one static screen stating the requirement, and neither starts the Console nor dials.
- **Locked caches.** Stores still `.complete` (Last Frames, Mosh availability) treat a file that exists but cannot be read as not loaded yet: nothing is swept or written over until it reads.

## Consequences

- Every user sees the CarPlay icon once shipped (CPG p.12); the quality bar is everyone, not Mike.
- Device builds need a provisioning profile with the CarPlay capability; a profile without it fails to sign.
- The CarPlay scene needs iOS 26.4 for the category and iOS 26 for SpeechAnalyzer; the app itself stays iOS 18+.
