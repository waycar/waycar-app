import Foundation

/// Oversized Normal-mode attach → draw/quiet → Ctrl-g (Locked) → redraw/quiet → checked focus → resize.
struct ZellijAttachMachine: StateMachine {
    /// Attach mode, input and post-claim quiet are one recipe; pass the same recipe to the PTY builder.
    struct Claim: Sendable, Equatable {
        let mode: String
        let bytes: [UInt8]
        let settle: Duration

        static let `default` = Claim(mode: "normal", bytes: [0x07], settle: .milliseconds(200))
    }

    enum Result: Sendable, Equatable { case exactPane, wholeSession }
    struct Desk: Sendable, Equatable {
        let clientID: Int
        let tabID: Int
        let pane: String
    }
    enum State: Sendable, Equatable {
        case idle
        case drawing(timeout: UInt64, quiet: UInt64?)
        case sendingClaim(timeout: UInt64, token: UInt64, outputSeen: Bool)
        case claiming(timeout: UInt64, quiet: UInt64?)
        case navigating(UInt64)
        case restoring(UInt64)
        case resizing(UInt64, Result)
        case finished(Result)
    }
    enum Event: Sendable {
        case ptyOpened
        /// Only bytes after AttachBootstrapHandshake's marker count as drawing.
        case outputSeen
        case quietElapsed(UInt64)
        case attachTimeout(UInt64)
        case claimSent(UInt64, success: Bool)
        case navigationResult(UInt64, before: [ZellijClient], after: [ZellijClient])
        case restoreResult(UInt64)
        case resized(UInt64)
    }
    enum Effect: Sendable, Equatable {
        case armTimeout(UInt64, after: Duration)
        case armQuiet(UInt64, after: Duration)
        /// Default: byte 0x07 enters Locked from Normal without typing into the pane.
        case sendClaim(UInt64, bytes: [UInt8])
        case runNavigation(UInt64)
        case restoreDesk(UInt64, Desk)
        case resizeToPhone(UInt64)
        case finish(Result)
    }

    let targetPane: String
    let claim: Claim
    /// All panes (plugins included) mapped to their stable tab ids at attach start.
    let tabByPane: [String: Int]
    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    init(targetPane: String, tabByPane: [String: Int], claim: Claim = .default) {
        self.targetPane = targetPane
        self.tabByPane = tabByPane
        self.claim = claim
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .ptyOpened):
            let token = token()
            state = .drawing(timeout: token, quiet: nil)
            return [.armTimeout(token, after: .seconds(5))]
        case (.drawing(let timeout, _), .outputSeen):
            let quiet = token()
            state = .drawing(timeout: timeout, quiet: quiet)
            return [.armQuiet(quiet, after: .milliseconds(200))]
        case (.drawing(let timeout, let quiet), .quietElapsed(let token)) where quiet == token:
            let next = self.token()
            state = .sendingClaim(timeout: timeout, token: next, outputSeen: false)
            return [.sendClaim(next, bytes: claim.bytes)]
        case (.sendingClaim(let timeout, let token, _), .outputSeen):
            state = .sendingClaim(timeout: timeout, token: token, outputSeen: true)
            return []
        case (.sendingClaim(let timeout, let pending, let drawn), .claimSent(let token, let success))
        where pending == token:
            guard success else { return resize(.wholeSession) }
            state = .claiming(timeout: timeout, quiet: nil)
            return drawn ? claimOutput(timeout: timeout) : []
        case (.claiming(let timeout, _), .outputSeen):
            return claimOutput(timeout: timeout)
        case (.claiming(_, let quiet), .quietElapsed(let token)) where quiet == token:
            let next = self.token()
            state = .navigating(next)
            return [.runNavigation(next)]
        case (.drawing(let timeout, _), .attachTimeout(let token)),
            (.sendingClaim(let timeout, _, _), .attachTimeout(let token)),
            (.claiming(let timeout, _), .attachTimeout(let token)):
            guard timeout == token else { return [] }
            return resize(.wholeSession)
        case (.navigating(let pending), .navigationResult(let token, let before, let after))
        where pending == token:
            guard let phone = before.max(by: { $0.id < $1.id }),
                after.map(\.id).sorted() == before.map(\.id).sorted(),
                Set(before.map(\.id)).count == before.count
            else { return resize(.wholeSession) }
            let moved = before.filter { client in
                client.id != phone.id && after.first(where: { $0.id == client.id })?.pane != client.pane
            }
            if moved.count == 1, let client = moved.first, let tab = tabByPane[client.pane] {
                let next = self.token()
                state = .restoring(next)
                return [.restoreDesk(next, Desk(clientID: client.id, tabID: tab, pane: client.pane))]
            }
            let exact = moved.isEmpty && after.first(where: { $0.id == phone.id })?.pane == targetPane
            return resize(exact ? .exactPane : .wholeSession)
        case (.restoring(let pending), .restoreResult(let token)) where pending == token:
            return resize(.wholeSession)
        case (.resizing(let pending, let result), .resized(let token)) where pending == token:
            state = .finished(result)
            return [.finish(result)]
        case (.idle, _), (.drawing, _), (.sendingClaim, _), (.claiming, _), (.navigating, _),
            (.restoring, _), (.resizing, _), (.finished, _):
            return []
        }
    }

    private mutating func claimOutput(timeout: UInt64) -> [Effect] {
        let quiet = token()
        state = .claiming(timeout: timeout, quiet: quiet)
        return [.armQuiet(quiet, after: claim.settle)]
    }

    private mutating func token() -> UInt64 {
        lastToken += 1
        return lastToken
    }
    private mutating func resize(_ result: Result) -> [Effect] {
        let token = token()
        state = .resizing(token, result)
        return [.resizeToPhone(token)]
    }
}
