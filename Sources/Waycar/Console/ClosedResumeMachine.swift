/// The Closed Session resumes this device started, one per resumed Agent row
/// (CONTEXT.md **Closed Session**), from the resume until its Agent closes,
/// is used, or is found gone.
///
/// - Pending: live, not used from this app yet; its record is unlisted.
///   Only pending resumes reach the file (`ClosedSessionsStore`), as their
///   record and start.
/// - Backing out: the user left it unused. Its row is unlisted and its
///   record listed again at once, while the back-out verifies the row and
///   closes its Pane; a Forget meanwhile marks it forgotten, so its closure
///   records nothing.
/// - Used: the resume of a record with a session was used. The record stays
///   unlisted while the row is listed.
///
/// Every resume carries the terminal it runs (herdr reuses pane ids) and a
/// token minted when it began: a back-out's verification and close answer
/// only while their resume is still the row's and still backing out (B-22),
/// whatever record or terminal a replacement shares.
///
/// A use resolves by what the owner reports of the record: gone, the resume
/// just ends; with a session, it is used; without one, it ends and the
/// record is forgotten everywhere.
struct ClosedResumeMachine: StateMachine {
    /// The resume's record as the owner's records hold it now.
    enum Record: Equatable, Sendable {
        case gone
        case sessionless
        case withSession
    }

    struct Terminal: Equatable, Sendable {
        let id: String
        /// Only this backend's verified snapshots say anything about its pane.
        let backend: HostBackend
        /// Whether a verified snapshot listed it yet: until then its pane
        /// missing means only the resync has not landed.
        var seen = false
    }

    enum Phase: Equatable, Sendable {
        /// `beganAt` in milliseconds.
        case pending(beganAt: Int64)
        /// Keeps `beganAt`: a row not verified yet goes back to pending.
        case backingOut(beganAt: Int64, forgotten: Bool)
        case used
    }

    struct Resume: Equatable, Sendable {
        let token: UInt64
        let record: ClosedSession.ID
        var phase: Phase
        var terminal: Terminal

        var listing: Listing {
            switch phase {
            case .pending(let beganAt): .pending(record, beganAt: beganAt)
            case .backingOut: .backedOut(record)
            case .used: .used(record)
            }
        }
    }

    /// What a row shows in the owner's published dictionaries: one of its
    /// pending, backed-out and used resumes, or none.
    enum Listing: Equatable, Sendable {
        case pending(ClosedSession.ID, beganAt: Int64)
        case backedOut(ClosedSession.ID)
        case used(ClosedSession.ID)
    }

    struct State: Equatable, Sendable {
        var resumes: [ConsoleAgent.ID: Resume] = [:]
    }

    /// What a verified row says about the Agent at the resumed pane.
    enum Verified: Equatable, Sendable {
        /// Idle, done or unknown: nobody is using it.
        case unused
        /// Working or blocked: in use from another client.
        case busy(Record)
    }

    enum BackOutFailure: Equatable, Sendable {
        /// The Console's own `agent_not_found`: not in verified inventory yet.
        case notVerified(Record)
        /// Any other failure but `pane_not_found` (which changes nothing).
        case other(Record)
    }

    enum Event: Sendable {
        case began(
            ConsoleAgent.ID, record: ClosedSession.ID, beganAt: Int64, terminal: String,
            backend: HostBackend)
        /// The user sent input to the row from this app.
        case inputSent(ConsoleAgent.ID, Record)
        /// Resolve one pending resume of `record` as used: the Resume opened
        /// elsewhere. Named once for every resume pending at the start.
        case usedElsewhere(ConsoleAgent.ID, record: ClosedSession.ID, Record)
        case backOutRequested(ConsoleAgent.ID)
        case verified(
            ConsoleAgent.ID, token: UInt64, terminalID: String, isShell: Bool, Verified)
        case backOutFailed(ConsoleAgent.ID, token: UInt64, BackOutFailure)
        /// A snapshot no longer runs the row: its closure is being recorded.
        case captured(ConsoleAgent.ID)
        /// One backend's verified snapshot of a Host, rows by pane id.
        case verifiedSnapshot(Host.ID, HostBackend, rows: [String: ConsoleAgent])
        /// The rows every Host lists now; used resumes of the others end.
        case listed(Set<ConsoleAgent.ID>)
        /// Records forgotten, stamps by id.
        case forgotten([ClosedSession.ID: Int64])
    }

    enum Effect: Equatable, Sendable {
        /// The row's listing changed (nil: it has none now). Emitted only on
        /// a change, before every other effect of the same event, so the
        /// owner updates that row's entries and nothing else.
        case project(ConsoleAgent.ID, Listing?)
        /// Write the file: the pending resumes changed.
        case persist
        case verify(UInt64)
        case close(UInt64)
        /// Forget the record everywhere (a used resume without a session).
        case forget(ClosedSession.ID)
        /// The closure is the resumed record's: it is listed again as it
        /// was, seen running until now. `wasPending` changes the file.
        case captureIsResume(ClosedSession.ID, wasPending: Bool)
        /// The closure of a back-out whose record was forgotten meanwhile:
        /// it records nothing.
        case dropCapture
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .began(let agentID, let record, let beganAt, let terminal, let backend):
            lastToken += 1
            return put(agentID, Resume(
                token: lastToken, record: record, phase: .pending(beganAt: beganAt),
                terminal: Terminal(id: terminal, backend: backend))) + [.persist]
        case .inputSent(let agentID, let record):
            guard let resume = state.resumes[agentID], case .pending = resume.phase else { return [] }
            return resolveAsUsed(agentID, resume.record, record)
        case .usedElsewhere(let agentID, let id, let record):
            if case .pending? = state.resumes[agentID]?.phase {
                return resolveAsUsed(agentID, id, record)
            }
            // Ended earlier in the same pass: a record without a session is
            // forgotten with its first resume. The file is written once more.
            return record == .gone ? [.persist] : []
        case .backOutRequested(let agentID):
            guard let resume = state.resumes[agentID],
                case .pending(let beganAt) = resume.phase
            else { return [] }
            return setPhase(agentID, .backingOut(beganAt: beganAt, forgotten: false))
                + [.persist, .verify(resume.token)]
        case .verified(let agentID, let token, let terminalID, let isShell, let verified):
            guard let resume = backingOut(agentID, token) else { return [] }
            guard terminalID == resume.terminal.id, !isShell else {
                // Another terminal at the pane, or a Shell: the resumed Agent
                // is gone and its closure will never be captured.
                return put(agentID, nil) + [.persist]
            }
            guard case .busy(let record) = verified else { return [.close(token)] }
            return resolveAsUsed(agentID, resume.record, record)
        case .backOutFailed(let agentID, let token, .notVerified(let record)):
            guard let resume = backingOut(agentID, token),
                case .backingOut(let beganAt, let forgotten) = resume.phase
            else { return [] }
            let projected = !forgotten && record != .gone
                ? setPhase(agentID, .pending(beganAt: beganAt))
                : put(agentID, nil)
            return projected + [.persist]
        case .backOutFailed(let agentID, let token, .other(let record)):
            guard let resume = backingOut(agentID, token) else { return [] }
            return resolveAsUsed(agentID, resume.record, record)
        case .captured(let agentID):
            guard let resume = state.resumes[agentID] else { return [] }
            let projected = put(agentID, nil)
            switch resume.phase {
            case .pending:
                return projected + [.captureIsResume(resume.record, wasPending: true)]
            case .backingOut(beganAt: _, forgotten: true):
                return projected + [.dropCapture]
            case .backingOut(beganAt: _, forgotten: false):
                return projected + [.captureIsResume(resume.record, wasPending: false)]
            case .used:
                return projected
            }
        case .verifiedSnapshot(let hostID, let backend, let rows):
            var seen: [ConsoleAgent.ID] = []
            var stale: [ConsoleAgent.ID] = []
            for (agentID, resume) in state.resumes
            where agentID.hostID == hostID && resume.terminal.backend == backend {
                switch rows[agentID.paneID]?.agent.terminalID {
                case resume.terminal.id?:
                    if !resume.terminal.seen { seen.append(agentID) }
                case nil where !resume.terminal.seen:
                    break
                default:
                    stale.append(agentID)
                }
            }
            for agentID in seen { state.resumes[agentID]?.terminal.seen = true }
            var effects: [Effect] = []
            var hadPending = false
            for agentID in stale {
                if case .pending? = state.resumes[agentID]?.phase { hadPending = true }
                effects += put(agentID, nil)
            }
            return hadPending ? effects + [.persist] : effects
        case .listed(let listed):
            let ended: [ConsoleAgent.ID] = state.resumes.compactMap { agentID, resume in
                resume.phase == .used && !listed.contains(agentID) ? agentID : nil
            }
            var effects: [Effect] = []
            for agentID in ended { effects += put(agentID, nil) }
            return effects
        case .forgotten(let stamps):
            let matching: [(ConsoleAgent.ID, Phase)] = state.resumes.compactMap { agentID, resume in
                stamps[resume.record] != nil ? (agentID, resume.phase) : nil
            }
            var effects: [Effect] = []
            for (agentID, phase) in matching {
                switch phase {
                case .pending, .used:
                    effects += put(agentID, nil)
                case .backingOut(let beganAt, _):
                    effects += setPhase(agentID, .backingOut(beganAt: beganAt, forgotten: true))
                }
            }
            return effects
        }
    }

    /// Sets the row's resume; its listing's change, if any.
    private mutating func put(_ agentID: ConsoleAgent.ID, _ resume: Resume?) -> [Effect] {
        let before = state.resumes[agentID]?.listing
        state.resumes[agentID] = resume
        let after = resume?.listing
        return before == after ? [] : [.project(agentID, after)]
    }

    private mutating func setPhase(_ agentID: ConsoleAgent.ID, _ phase: Phase) -> [Effect] {
        guard var resume = state.resumes[agentID] else { return [] }
        resume.phase = phase
        return put(agentID, resume)
    }

    /// The resume at `agentID` while it is still the one `token` names and
    /// still backing out: a capture, a verified snapshot or a new resume
    /// meanwhile ended it.
    private func backingOut(_ agentID: ConsoleAgent.ID, _ token: UInt64) -> Resume? {
        guard let resume = state.resumes[agentID], resume.token == token,
            case .backingOut = resume.phase
        else { return nil }
        return resume
    }

    private mutating func resolveAsUsed(
        _ agentID: ConsoleAgent.ID, _ id: ClosedSession.ID, _ record: Record
    ) -> [Effect] {
        switch record {
        case .gone:
            return put(agentID, nil) + [.persist]
        case .withSession:
            return setPhase(agentID, .used) + [.persist]
        case .sessionless:
            return put(agentID, nil) + [.forget(id)]
        }
    }
}
