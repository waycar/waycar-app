/// One inventory-verification continuation. The owner retains the projection,
/// continuation and timer; this value owns patience, timeout admission and the
/// single settlement claim. Row/terminal identity is still checked after waiting.
struct InventoryVerificationMachine: StateMachine {
    enum Patience: Equatable, Sendable {
        /// User RPCs report a stopped, paused, recovering or unsnapshottable Host.
        case failsFast
        /// Committed swiped Closes wait through reconnect/snapshot recovery,
        /// but not a stopped or paused Host.
        case ridesOutRecovery
        /// Attach waits even through failure, without a timeout.
        case waitsOutFailure
        /// Composer queues at once when the device has no usable path.
        case failsFastOffline
    }

    enum State: Equatable, Sendable {
        case idle
        case waiting(token: UInt64, patience: Patience)
        case finished
    }

    enum Event: Equatable, Sendable {
        case begin(Patience)
        case resolved(UInt64)
        case timedOut(UInt64)
        case cancel
    }

    enum Effect: Equatable, Sendable {
        case armTimeout(UInt64)
        case settle
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    var patience: Patience? {
        guard case .waiting(_, let patience) = state else { return nil }
        return patience
    }

    var token: UInt64? {
        guard case .waiting(let token, _) = state else { return nil }
        return token
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .begin(let patience)):
            lastToken += 1
            state = .waiting(token: lastToken, patience: patience)
            return patience == .waitsOutFailure ? [] : [.armTimeout(lastToken)]
        case (.waiting(let token, _), .resolved(let returned)) where token == returned:
            state = .finished
            return [.settle]
        case (.waiting(let token, let patience), .timedOut(let returned))
            where token == returned && patience != .waitsOutFailure:
            state = .finished
            return [.settle]
        case (.waiting, .cancel):
            state = .finished
            return [.settle]
        case (.idle, _), (.waiting, _), (.finished, _):
            return []
        }
    }
}
