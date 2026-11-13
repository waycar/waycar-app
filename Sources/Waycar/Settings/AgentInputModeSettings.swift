import Foundation
import Observation

/// Which input an Agent view has open above its Toolbar. `.direct` is the
/// Toolbar alone, with the terminal (Direct Input, ADR 0016) taking the
/// keyboard when ⌨ raises it; `.composer` is Message Agent: the Composer card
/// (ADR 0013) is open. The two are mutually exclusive.
enum AgentInputMode: String, CaseIterable, Identifiable, Sendable {
    case composer
    case direct

    var id: Self { self }
}

/// One Agent view's open input. Never persisted or shared: every Agent view
/// opens on the Toolbar alone (`.direct`), and Message Agent stays open only
/// until the person closes it or leaves. A reference type so the terminal's
/// keyboard-claim closures read the live mode, not a stale copy.
@MainActor
@Observable
final class AgentInputModeState {
    /// The value lives outside the macro's tracking so `select` can store it
    /// before it tells observers. The macro's own setter tells them first
    /// (`willSet`), and SwiftUI answers by rendering the view inside that
    /// call while its first updates run (WAY-522): the render then read the
    /// old mode, and the change that had not landed yet was never reported
    /// to the tracking that render had just set up.
    @ObservationIgnored private var storedMode: AgentInputMode = .direct

    var mode: AgentInputMode {
        access(keyPath: \.mode)
        return storedMode
    }

    var isDirect: Bool { mode == .direct }

    func select(_ mode: AgentInputMode) {
        guard mode != storedMode else { return }
        storedMode = mode
        withMutation(keyPath: \.mode) {}
    }
}
