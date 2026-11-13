import Foundation

/// Carries the user's "I am still typing" intent across the Agent surface
/// teardown a switch forces (the sidebar, ⌘[ / ⌘], the new-agent sheet, a
/// shell row opened from here). Deliberately not observable: arming it must
/// not invalidate the SwiftUI view that is about to be replaced anyway, and
/// the new surface has to read the intent before its first layout.
@MainActor
final class TerminalKeyboardHandoff {
    private var armedID: ConsoleAgent.ID?
    private var armedMode: TerminalKeyboardMode = .text

    func arm(for id: ConsoleAgent.ID, mode: TerminalKeyboardMode = .text) {
        armedID = id
        armedMode = mode
    }

    /// Read before the destination builds its input view. Consuming focus
    /// later must not briefly present the Apple keyboard for a tools handoff.
    func mode(for id: ConsoleAgent.ID) -> TerminalKeyboardMode? {
        armedID == id ? armedMode : nil
    }

    func cancel(for id: ConsoleAgent.ID) {
        guard armedID == id else { return }
        armedID = nil
    }

    /// Reads and clears the intent — a handoff is good for exactly one screen,
    /// so a later push from the Agent list starts with the keyboard down.
    func consume(_ id: ConsoleAgent.ID) -> Bool {
        guard armedID == id else { return false }
        armedID = nil
        return true
    }

    /// A late terminal creation cannot cancel or consume a newer opening.
    private var shellTerminal: (token: UUID, mode: TerminalKeyboardMode)?

    var shellTerminalToken: UUID? { shellTerminal?.token }

    /// Whether a screen is about to take the keyboard over. The screen being
    /// left must then keep first responder until that screen claims it,
    /// instead of dismissing on its way out: a dismissal starts UIKit's hide
    /// animation, and the next claim can only re-present the keyboard after
    /// it has fully dropped.
    var isArmed: Bool { armedID != nil || shellTerminal != nil }

    /// The keyboard is up and a shell row is about to be opened. Not keyed
    /// by identity: the destination is often unknown when the intent is
    /// captured (New Terminal creates it first; Open Terminal may ask which
    /// one), so Agent detail re-arms it for the row once the row is resolved,
    /// in the same mode — a tools dock stays a tools dock.
    @discardableResult
    func armShellTerminal(mode: TerminalKeyboardMode = .text) -> UUID {
        let token = UUID()
        shellTerminal = (token, mode)
        return token
    }

    /// No shell row came up (creation failed or was cancelled), so the
    /// intent must not raise the keyboard on an unrelated later open.
    func cancelShellTerminal(ifOwnedBy token: UUID?) {
        guard shellTerminal?.token == token else { return }
        shellTerminal = nil
    }

    /// The mode the shell handoff was armed in, or nil when none was armed.
    func consumeShellTerminal(ifOwnedBy token: UUID?) -> TerminalKeyboardMode? {
        guard shellTerminal?.token == token else { return nil }
        defer { shellTerminal = nil }
        return shellTerminal?.mode
    }
}
