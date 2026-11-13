@testable import MoshTransport

extension StateMachine {
    /// Applies `events` in order and returns all their effects: the setup
    /// step of a transition test (the app's docs/design/state-machines.md).
    mutating func handle(_ events: [Event]) -> [Effect] {
        var effects: [Effect] = []
        for event in events {
            effects += handle(event)
        }
        return effects
    }

    /// A copy that has applied `events`, for a test that starts mid-lifecycle.
    func after(_ events: [Event]) -> Self {
        var machine = self
        _ = machine.handle(events)
        return machine
    }
}
