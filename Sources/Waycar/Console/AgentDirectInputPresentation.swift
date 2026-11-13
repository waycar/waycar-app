import CoreGraphics
import Foundation
import Observation

/// Focused Direct Input chrome policy: software-keyboard coverage, keyboard
/// layout, and the Hide/Show accessibility copy the switcher control speaks.
/// Separates Ghostty first-responder intent from the software keyboard
/// footprint so a hardware keyboard cannot leave a stale gap.
///
/// ``layout`` is the single production seam for the Agent detail bottom inset
/// and tools dock height — `AgentTerminalView` consumes it directly.
struct AgentDirectInputPresentation: Equatable, Sendable {
    var keyboardPresentation: AgentComposerKeyboardPresentation
    /// Production bottom inset / tools height. Do not rebuild this beside the view.
    var layout: AgentComposerKeyboardLayout

    /// Software keyboard coverage, with an explicit Tools→iOS pre-show hold so
    /// the 60 ms inset coalesce cannot drop the terminal through `.hidden`.
    /// `expectsSystemKeyboard` is only valid until measured height becomes
    /// positive; after that, height alone drives `.system`. First responder
    /// alone never counts — that is hardware-keyboard territory.
    static func keyboardPresentation(
        usesToolsKeyboard: Bool,
        softwareKeyboardHeight: CGFloat,
        expectsSystemKeyboard: Bool
    ) -> AgentComposerKeyboardPresentation {
        if usesToolsKeyboard { return .tools }
        if softwareKeyboardHeight > 0 || expectsSystemKeyboard { return .system }
        return .hidden
    }

    static func resolve(
        usesToolsKeyboard: Bool,
        expectsSystemKeyboard: Bool,
        currentHeight: CGFloat,
        lastPresentedHeight: CGFloat
    ) -> AgentDirectInputPresentation {
        let presentation = keyboardPresentation(
            usesToolsKeyboard: usesToolsKeyboard,
            softwareKeyboardHeight: currentHeight,
            expectsSystemKeyboard: expectsSystemKeyboard)
        let layout = AgentComposerKeyboardLayout(
            currentHeight: currentHeight,
            lastPresentedHeight: lastPresentedHeight,
            presentation: presentation)
        return AgentDirectInputPresentation(
            keyboardPresentation: presentation,
            layout: layout)
    }

    /// VoiceOver copy for the Toolbar's fixed controls. Titles and symbols
    /// are `ToolbarFixedControl`'s, shared with Settings → Toolbar.
    static let openMessageAgentAccessibilityHint =
        "Opens the Composer. The keyboard stays down until you tap the text field."
    static let closeMessageAgentAccessibilityHint =
        "Closes the Composer. The draft is unchanged."
    static let showTerminalKeyboardAccessibilityHint =
        "Types straight into the Agent's terminal."
    static let dismissTerminalKeyboardAccessibilityHint = "Dismisses the keyboard."

    /// ⌨'s hint: closing Message Agent is only announced when it is open.
    static func terminalKeyboardAccessibilityHint(
        isKeyboardUp: Bool, isMessageAgentOpen: Bool
    ) -> String {
        if isKeyboardUp { return dismissTerminalKeyboardAccessibilityHint }
        return isMessageAgentOpen
            ? showTerminalKeyboardAccessibilityHint + " Closes Message Agent."
            : showTerminalKeyboardAccessibilityHint
    }
    static let dictateToAgentAccessibilityHint =
        "Speak a message; tap stop to send it to the Agent. Speech is transcribed on this device."

    /// The Toolbar's 🎤 (Dictate to Agent) shows only where speech can be
    /// transcribed and the Composer delivers to an Agent: a Shell never gets
    /// one, since its stop would run the speech as a command.
    @MainActor
    static func showsDictateToAgent(
        dictation: DictationStore, composer: AgentComposerStore
    ) -> Bool {
        dictation.isAvailable && composer.deliversToAgent
    }

    /// Single production predicate for arming Direct Input keyboard handoff
    /// across terminal replacement/reactivation and Agent-switch paths. Intent,
    /// Ghostty first responder, tools keyboard, or measured software height.
    static func shouldClaimKeyboard(
        wantsKeyboard: Bool,
        isKeyboardUp: Bool,
        usesToolsKeyboard: Bool,
        softwareKeyboardHeight: CGFloat
    ) -> Bool {
        wantsKeyboard || isKeyboardUp || usesToolsKeyboard || softwareKeyboardHeight > 0
    }
}

/// 💬's count of the Composer Tray's items while Message Agent is closed, so
/// uploads in progress and failures stay visible without the card's chips.
struct MessageAgentTrayBadge: Equatable, Sendable {
    let count: Int
    let failedCount: Int
    let uploadingCount: Int
    let waitingCount: Int

    /// Nil while Message Agent is open (its chips show every item) or the
    /// tray is empty.
    init?(items: [ComposerTray.Item], isMessageAgentOpen: Bool) {
        guard !isMessageAgentOpen, !items.isEmpty else { return nil }
        count = items.count
        failedCount = items.filter(\.status.isFailed).count
        uploadingCount = items.filter { if case .staging = $0.status { true } else { false } }.count
        waitingCount = items.filter { if case .queued = $0.status { true } else { false } }.count
    }

    /// Tints the badge red instead of the accent.
    var hasFailure: Bool { failedCount > 0 }

    /// 💬's VoiceOver value, e.g. "3 images or files, 1 failed, 1 uploading,
    /// 1 waiting".
    var accessibilityValue: String {
        var parts = [count == 1 ? "1 image or file" : "\(count) images or files"]
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if uploadingCount > 0 { parts.append("\(uploadingCount) uploading") }
        if waitingCount > 0 { parts.append("\(waitingCount) waiting") }
        return parts.joined(separator: ", ")
    }
}

/// Survives same-screen terminal pipeline replacement so Direct Input can
/// reclaim a keyboard that was up without raising one that was down. Distinct
/// from ``TerminalKeyboardHandoff``, which carries intent across Agent switches
/// that tear the whole view down.
@MainActor
@Observable
final class DirectInputKeyboardIntent {
    private(set) var wantsKeyboard = false

    func setWantsKeyboard(_ wantsKeyboard: Bool) {
        self.wantsKeyboard = wantsKeyboard
    }
}
