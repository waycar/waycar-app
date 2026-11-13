import Foundation

/// The Agent Notification trust story (ADR 0008, #76) as plain strings, shared
/// by the pre-permission explainer and the persistent settings privacy section
/// so both surfaces tell exactly the same story. Kept as data — not buried in a
/// View — so a test can pin the load-bearing claims: it is a *push relay*
/// (never a "server"), it sees the device token, ciphertext, source IP, and
/// request timing, and the Live Activity fields APNs needs in cleartext. It
/// cannot see the encrypted notification content (project, task, Agent Summary,
/// a Chat Mode Agent's final reply, Agent type, Host, or pane id); a custom
/// relay only helps a self-built app. All copy is
/// English by project convention.
enum NotificationPrivacyCopy {
    /// The explainer's lead line before the iOS permission prompt.
    static let explainerTitle = "Before you turn on notifications"

    /// The pipeline in one sentence, for the top of both surfaces.
    static let summary =
        "Agent Notifications travel through a push relay: your Host encrypts each "
        + "notification and the relay forwards it to Apple without ever holding the key "
        + "to read it."

    /// What the relay can see — the fields that cross it in the clear.
    static let relaySeesTitle = "What the push relay sees"
    static let relaySees: [String] = [
        "Your device's Apple push token, so Apple knows which device to notify.",
        "The encrypted notification (ciphertext), which it forwards without decrypting.",
        "Your Host's source IP address, as with any network request.",
        "When and how often your Host sends notification requests.",
        "For Live Activities: aggregate status counts, the start, update, or end event, "
            + "priority, and event timing required by Apple. Starting an activity while Waycar "
            + "is closed also sends a random Host identifier and a generic alert.",
    ]

    /// What the relay cannot see — the encrypted content it never holds a key
    /// for. Names the exact encrypted fields so the claim is concrete.
    static let relayCannotSeeTitle = "What it cannot see"
    static let relayCannotSee: [String] = [
        "The notification details: project name, task title, Agent Summary, a Chat Mode "
            + "Agent's final reply, Agent type and name, Host name, pane ID, and per-Agent "
            + "details.",
        "The relay cannot decrypt this content because it never receives your Notification Key.",
    ]

    /// The self-built-app caveat for the custom relay setting.
    static let customRelayCaveat =
        "A custom relay only works with an app you build and sign yourself. It must use APNs "
        + "credentials authorized for that app's bundle ID. Only the developer-hosted relay "
        + "is configured to deliver notifications to Waycar from the App Store."

    /// The one action of every screen shown right before the iOS permission
    /// prompt (the explainer and the Notification Ask): it always goes on to
    /// that prompt (App Review guideline 5.1.1(iv)), so the screen offers no
    /// other way out.
    static let continueToPrompt = "Continue"

    /// The privacy policy on waycar.dev (the site renders the repo-root
    /// `PRIVACY.md`) the settings section links to. Optional, like every
    /// `URL(string:)` in the app (no force unwraps); a link that depends on it
    /// simply hides if the constant ever fails to parse.
    static let privacyPolicyURL = URL(string: "https://waycar.dev/privacy")
    /// The link to it under a disclosure shown before the iOS prompt.
    static let privacyDetailsLink = "Read the privacy details"

    /// Per-Host Live Activity toggle footer: counts are what the Lock Screen
    /// renders in the clear; names and titles stay inside the envelope.
    static let liveActivityFooter =
        "The Lock Screen shows aggregate status counts and update timing. Agent, Host, and task "
        + "details stay encrypted."

    /// Shown under the Live Activity toggle when the system-wide permission
    /// is off. Mirrors the Agent Notifications denied-state wording.
    static let liveActivityDisabledHint =
        "Live Activities are turned off for Waycar. Enable them in Settings to show this Host on the Lock Screen."

    /// The AI summaries toggle label in root Settings.
    static let agentSummariesToggle = "AI Summaries"

    /// The footer under the toggle: off until the user opts in, when it runs,
    /// and which providers it can reach. The request leaves from the Host,
    /// never from this device or the push relay.
    static let agentSummariesFooter =
        "Off unless you turn it on. A one-line summary on each Agent card and notification. "
        + "Runs when an Agent turns Blocked or Done, and while Waycar is open, about once a "
        + "minute and when an Agent changes status, only for Agents whose screen changed. "
        + "Each Host sends the screen to Anthropic, OpenAI, or OpenRouter (which passes it to "
        + "Google or OpenAI models) using its own AI accounts."

    /// The opt-in confirmation shown before AI Summaries turns on. Every
    /// provider named here matches `plugin/src/agent-summary.js`.
    static let agentSummariesConfirmTitle = "Turn on AI Summaries?"
    static let agentSummariesConfirmMessage =
        "Each of your Hosts sends up to the last 60 lines of an Agent's screen to Anthropic, "
        + "OpenAI or OpenRouter (which passes it to Google or OpenAI models), using the AI "
        + "accounts set up on that Host, to write a one-line summary. This runs when an Agent "
        + "turns Blocked or Done, and while Waycar is open, about once a minute and when an "
        + "Agent changes status, only for Agents whose screen changed. The screen can include "
        + "secrets."
    static let agentSummariesConfirm = "Turn On"
    static let agentSummariesCancel = "Not Now"
}

/// The one-time Notification Ask (#71). Its privacy section is
/// `NotificationPrivacyCopy`, through `NotificationDisclosureContent`.
enum NotificationAskCopy {
    static let title = "Know when your Agents need you"
    static let notificationsBenefit = "Get a notification when an Agent is blocked or finishes."
    static let liveActivitiesBenefit = "Follow your Agents live on the Lock Screen."
    static let privacyTitle = "How it stays private"
    /// Under the sheet's story when Turn On and Not Now are its answers:
    /// iOS already allows notifications.
    static let settingsHint =
        "Turn On covers every Host, including ones you add later. You can change this for each "
        + "Host in Settings."
    /// Under the sheet's story when Continue leads to the iOS prompt.
    static let promptHint =
        "Next, iOS asks if Waycar may send notifications. If you allow them, Waycar turns on "
        + "notifications and Live Activities for every Host, including ones you add later. You "
        + "can change this for each Host in Settings."
    static let turnOn = "Turn On"
    static let notNow = "Not Now"

    /// The hint for the sheet's buttons.
    static func hint(for actions: [NotificationAsk.Action]) -> String {
        actions.contains(.continue) ? promptHint : settingsHint
    }
}
