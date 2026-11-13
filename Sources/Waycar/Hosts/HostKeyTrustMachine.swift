/// The Host page's host-key decisions (TOFU with fingerprint confirmation):
/// a probe's first-connect question, and a changed key offered for explicit
/// replacement. A changed key is never accepted silently: only the user's
/// confirmation writes the presented key, and only while checks are not
/// running on an enabled Host.
///
/// The two decisions are independent and may be up at once (a mosh test can
/// ask about its Jump Host while Trust New Key writes the Host's pin). The
/// pin write is not a checks epoch: checks may run, clear the offer and see
/// the mismatch again while it awaits; once it lands, the offer clears and
/// checks rerun on the new pin. One question at a time: a second probe's
/// question is declined at once rather than replacing the first.
struct HostKeyTrustMachine: StateMachine {
    enum Question: Equatable, Sendable {
        case none
        /// A probe's connect waits on the user's verdict, however long they
        /// take; the owner holds its continuation under `token`.
        case asking(token: UInt64, HostKeyCandidate)
    }

    enum Replacement: Equatable, Sendable {
        case none
        /// Checks met a changed key; the old pin stays authoritative.
        case offered(HostKeyReplacement)
    }

    struct State: Equatable, Sendable {
        var question: Question = .none
        var replacement: Replacement = .none
        /// Confirmed replacement pins still being written.
        var writes: Set<UInt64> = []
    }

    enum Event: Equatable, Sendable {
        /// A probe's connect presents a key with no pin.
        case asked(HostKeyCandidate, hostEnabled: Bool)
        /// The user's verdict, or a decline on their behalf: the run was
        /// cancelled, the page went away, or the Host turned off.
        case answered(trusted: Bool)
        case checksStarted
        case mismatched(HostKeyReplacement)
        /// Trust New Key, confirmed in the dialog.
        case replacementConfirmed(hostEnabled: Bool, checksRunning: Bool)
        case pinWritten(UInt64)
    }

    enum Effect: Equatable, Sendable {
        /// Hold the probe's continuation under the token.
        case wait(UInt64)
        /// Answer the probe false at once; nothing is held.
        case decline
        case resolve(UInt64, trusted: Bool)
        case writePin(UInt64, HostKeyFingerprint)
        case runChecks
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var pendingCandidate: HostKeyCandidate? {
        if case .asking(_, let candidate) = state.question { return candidate }
        return nil
    }

    var offeredReplacement: HostKeyReplacement? {
        if case .offered(let replacement) = state.replacement { return replacement }
        return nil
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state.question, event) {
        case (.none, .asked(let candidate, hostEnabled: true)):
            let token = nextToken()
            state.question = .asking(token: token, candidate)
            return [.wait(token)]
        case (.none, .asked(_, hostEnabled: false)), (.asking, .asked):
            return [.decline]
        case (.asking(let token, _), .answered(let trusted)):
            state.question = .none
            return [.resolve(token, trusted: trusted)]
        case (.none, .answered):
            return []
        case (_, .checksStarted):
            state.replacement = .none
            return []
        case (_, .mismatched(let replacement)):
            state.replacement = .offered(replacement)
            return []
        case (_, .replacementConfirmed(let enabled, let running)):
            guard enabled, !running, case .offered(let replacement) = state.replacement
            else { return [] }
            let token = nextToken()
            state.writes.insert(token)
            return [.writePin(token, replacement.presented)]
        case (_, .pinWritten(let token)):
            guard state.writes.remove(token) != nil else { return [] }
            state.replacement = .none
            return [.runChecks]
        }
    }

    private mutating func nextToken() -> UInt64 {
        lastToken += 1
        return lastToken
    }
}
