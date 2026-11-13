/// Preflight and Check Again may overlap. Each preflight completion belongs
/// only to its latest read; Check Again remains single-flight through its
/// follow-up preflight. Neither effect can install or start a runtime.
struct BackendInstallProbeMachine: StateMachine {
    enum Preflight: Equatable, Sendable {
        case unread
        case reading(UInt64)
        case ready(HostInstallPreflight)
        case failed(String)
    }

    enum State: Equatable, Sendable {
        case idle(Preflight, note: String?)
        case checking(token: UInt64, preflight: Preflight, note: String?)
        /// Detection answered; the owner is delivering its effects, possibly
        /// waiting for the follow-up preflight, before releasing Check Again.
        case settling(token: UInt64, preflight: Preflight, note: String?)
    }

    enum Event: Sendable {
        case load
        case preflightReady(UInt64, HostInstallPreflight)
        case preflightFailed(UInt64, String)
        case checkAgain
        case detected(UInt64, HostBackendPresence)
        case detectionFailed(UInt64, String)
        case checkEnded(UInt64)
    }

    enum Effect: Equatable, Sendable {
        case read(UInt64)
        case detect(UInt64)
        case found(HostBackendPresence)
        case record(HostBackendPresence)
        case announce(String)
    }

    private(set) var state: State = .idle(.unread, note: nil)
    private var lastToken: UInt64 = 0

    private var preflight: Preflight {
        switch state {
        case .idle(let preflight, _), .checking(_, let preflight, _), .settling(_, let preflight, _): preflight
        }
    }

    var presentation: BackendInstallPanelStore.PreflightState {
        switch preflight {
        case .unread, .reading: .loading
        case .ready(let facts): .ready(facts)
        case .failed(let message): .failed(message)
        }
    }

    var isChecking: Bool {
        switch state {
        case .idle: false
        case .checking, .settling: true
        }
    }

    var checkNote: String? {
        switch state {
        case .idle(_, let note), .checking(_, _, let note), .settling(_, _, let note): note
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .load):
            if case .ready = preflight { return [] }
            return read()
        case (_, .preflightReady(let token, let facts)):
            guard preflight == .reading(token) else { return [] }
            setPreflight(.ready(facts))
            return []
        case (_, .preflightFailed(let token, let message)):
            guard preflight == .reading(token) else { return [] }
            setPreflight(.failed(message))
            return []
        case (.idle(let preflight, _), .checkAgain):
            lastToken += 1
            state = .checking(token: lastToken, preflight: preflight, note: nil)
            return [.detect(lastToken)]
        case (.checking(let current, let preflight, _), .detected(let token, let presence)) where current == token:
            state = .settling(token: token, preflight: preflight, note: nil)
            guard let gap = HostBackendGap(presence: presence) else {
                return [.found(presence)]
            }
            let note = "Checked just now. \(gap.foundLabel)"
            state = .settling(token: token, preflight: preflight, note: note)
            return [.record(presence), .announce(note)] + read()
        case (.checking(let current, let preflight, _), .detectionFailed(let token, let message)) where current == token:
            state = .settling(token: token, preflight: preflight, note: message)
            return [.announce(message)]
        case (.settling(let current, let preflight, let note), .checkEnded(let token)) where current == token:
            state = .idle(preflight, note: note)
            return []
        case (.idle, _), (.checking, _), (.settling, _):
            return []
        }
    }

    private mutating func read() -> [Effect] {
        lastToken += 1
        setPreflight(.reading(lastToken))
        return [.read(lastToken)]
    }

    private mutating func setPreflight(_ preflight: Preflight) {
        switch state {
        case .idle(_, let note): state = .idle(preflight, note: note)
        case .checking(let token, _, let note): state = .checking(token: token, preflight: preflight, note: note)
        case .settling(let token, _, let note): state = .settling(token: token, preflight: preflight, note: note)
        }
    }
}
