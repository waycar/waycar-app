import Foundation
import Testing

@testable import Waycar

/// Resuming a Closed Session against a scripted launch: where it lands, what
/// it runs, and what becomes of the record.
@MainActor
@Suite("Closed session resumer")
struct ClosedSessionResumerTests {
    @MainActor
    private final class Launches {
        var requests: [AgentLaunchRequest] = []
        var destinations: [StartAgentStore.LaunchDestination] = []
        var hostIDs: [Host.ID] = []
        var backends: [HostBackend?] = []
        var awaited: [ConsoleAgent.ID] = []
        var pending: [ClosedSession.ID] = []
        var recordedLaunches = 0
        var error: (any Error)?
        var agent = Agent(.fixture(paneID: "w1:p-resumed", status: .working))
    }

    private func resumer(
        _ launches: Launches,
        workspaces: [ConsoleWorkspace] = [],
        taken: Set<String> = [],
        beginPendingResume: ((ClosedSession.ID, ConsoleAgent.ID, String) -> Void)? = nil
    ) -> ClosedSessionResumer {
        ClosedSessionResumer(
            workspaces: { _ in workspaces },
            existingAgentNames: { _ in taken },
            start: { request, destination, hostID, backend in
                launches.backends.append(backend)
                launches.requests.append(request)
                launches.destinations.append(destination)
                launches.hostIDs.append(hostID)
                if let error = launches.error { throw error }
                return launches.agent
            },
            awaitAgentVisible: { launches.awaited.append($0) },
            beginPendingResume: beginPendingResume ?? { id, _, _ in launches.pending.append(id) },
            recordLaunch: { launches.recordedLaunches += 1 })
    }

    private let session = ClosedSession.fixture(
        kind: .claude, agentName: "reviewer", cwd: "/work/app", workspaceID: "w1",
        workspaceLabel: "App", session: .init(kind: .id, value: "s-1"))

    @Test func aSessionWhoseWorkspaceRemainsResumesInANewTabThere() async throws {
        let launches = Launches()

        let outcome = await resumer(
            launches, workspaces: [ConsoleWorkspace(id: "w1", label: "App")]
        ).resume(session)

        #expect(
            outcome == .started(ConsoleAgent.ID(hostID: session.hostID, paneID: "w1:p-resumed")))
        #expect(launches.destinations == [.existingWorkspace])
        #expect(launches.hostIDs == [session.hostID])
        let request = try #require(launches.requests.first)
        #expect(request.kind == "claude")
        #expect(request.arguments == ["--resume", "s-1"])
        #expect(request.workspaceID == "w1")
        #expect(request.cwd == "/work/app")
    }

    /// Its Workspace — a removed worktree's, say — is gone: a new Workspace
    /// opens at the directory, and herdr says so if that is gone too.
    @Test func aSessionWhoseWorkspaceIsGoneResumesInANewWorkspaceAtItsDirectory() async throws {
        let launches = Launches()

        _ = await resumer(
            launches, workspaces: [ConsoleWorkspace(id: "w2", label: "Other")]
        ).resume(session)

        #expect(
            launches.destinations
                == [.newWorkspace(NewWorkspaceSpec(directory: "/work/app", label: "App"))])
        let request = try #require(launches.requests.first)
        #expect(request.workspaceID == nil)
        #expect(request.arguments == ["--resume", "s-1"])
    }

    @Test func withNeitherItsWorkspaceNorADirectoryThereIsNothingToLaunch() async {
        let launches = Launches()
        let lost = ClosedSession.fixture(cwd: "", workspaceID: "w-gone")

        let outcome = await resumer(launches).resume(lost)

        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(launches.requests.isEmpty)
        #expect(launches.pending.isEmpty)
    }

    /// herdr-core reports no session id, so a core session resumes with the
    /// agent's own pick (no id) as a new terminal of the same kind in the
    /// same folder, started on core.
    @Test(arguments: [true, false])
    func aCoreSessionResumesAsANewTerminalInItsFolder(workspaceRemains: Bool) async throws {
        let launches = Launches()
        let core = ClosedSession(
            id: "core-1", hostID: UUID(), hostName: "alpha", kind: .claude, agentName: nil,
            title: nil, cwd: "/srv/app", workspaceID: CoreID.workspace(key: "/srv/app"),
            workspaceLabel: "app", tabLabel: nil, session: nil,
            lastSeenRunningAt: Date(timeIntervalSince1970: 1_800_000_000),
            closedAt: Date(timeIntervalSince1970: 1_800_000_000), backend: .core)
        let workspaces =
            workspaceRemains
            ? [ConsoleWorkspace(id: CoreID.workspace(key: "/srv/app"), label: "app", backend: .core)]
            : []

        let outcome = await resumer(launches, workspaces: workspaces).resume(core)

        guard case .started = outcome else {
            Issue.record("expected a start, got \(outcome)")
            return
        }
        let request = try #require(launches.requests.first)
        #expect(request.kind == "claude")
        #expect(request.arguments == ClosedSession.resumeArguments(kind: .claude, session: nil))
        #expect(request.cwd == (workspaceRemains ? "/srv/app" : nil))
        #expect(
            launches.destinations
                == [
                    workspaceRemains
                        ? .existingWorkspace
                        : .newWorkspace(NewWorkspaceSpec(directory: "/srv/app", label: "app"))
                ])
        #expect(launches.backends == [.core])
    }

    /// A resume is counted (for the Review Prompt) once when it starts,
    /// never when herdr refuses it or there is nowhere to start it.
    @Test func onlyAStartedResumeCountsAsALaunch() async {
        let launches = Launches()
        let resume = resumer(launches, workspaces: [ConsoleWorkspace(id: "w1", label: "App")])

        _ = await resume.resume(session)
        #expect(launches.recordedLaunches == 1)

        launches.error = CancellationError()
        _ = await resume.resume(session)
        _ = await resumer(launches).resume(ClosedSession.fixture(cwd: "", workspaceID: "w-gone"))
        #expect(launches.recordedLaunches == 1)
    }

    private func recordedStore() throws -> (ClosedSessionsStore, ClosedSession, ConsoleAgent) {
        let store = ClosedSessionsStore()
        let row = ConsoleAgent(
            hostID: UUID(), hostName: "alpha",
            agent: Agent(
                terminalID: "t1", kind: "claude", title: "Task", status: .idle,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/work/app",
                revision: 1,
                agentSession: AgentSessionInfo(
                    agent: "claude", kind: .id, source: "herdr:claude", value: "s-1")),
            workspaceLabel: "App", repositoryCheckout: nil)
        store.record([ClosedAgentCapture(row: row, session: nil, lastSeenRunningAt: Date())])
        return (store, try #require(store.sessions.first), row)
    }

    /// Resumes the store's record the way the Console does.
    private func resumeRecord(
        _ store: ClosedSessionsStore, _ recorded: ClosedSession, _ launches: Launches
    ) async -> ClosedSessionResumer.Outcome {
        await resumer(
            launches, workspaces: [ConsoleWorkspace(id: "w1", label: "App")],
            beginPendingResume: { store.beginPendingResume($0, agent: $1, terminal: $2) }
        ).resume(recorded)
    }

    /// The resumed Agent's live row: the same session, on the new Pane, in
    /// the terminal the scripted launch starts.
    private func resumedRow(
        _ row: ConsoleAgent, terminalID: String = "term_w1:p-resumed",
        kind: String = "claude", status: AgentStatus = .idle
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: row.hostID, hostName: "alpha",
            agent: Agent(
                terminalID: terminalID, kind: kind, title: "Task", status: status,
                workspaceID: "w1", tabID: "w1:t2", paneID: "w1:p-resumed", cwd: "/work/app",
                revision: 1,
                agentSession: AgentSessionInfo(
                    agent: "claude", kind: .id, source: "herdr:claude", value: "s-1")),
            workspaceLabel: "App", repositoryCheckout: nil)
    }

    /// Backs out of `started` the way the Console does, its Host's verified
    /// snapshot holding `row` at that pane.
    private func backOut(
        _ store: ClosedSessionsStore, _ started: ConsoleAgent.ID, row: ConsoleAgent,
        closePane: (ConsoleAgent) async throws -> Void
    ) async {
        await store.backedOut(of: started, verifiedRow: { _ in row }, closePane: closePane)
    }

    @Test func aStartedResumeHidesTheRecordWhileItsAgentIsLive() async throws {
        let (store, recorded, row) = try recordedStore()
        let launches = Launches()

        let outcome = await resumeRecord(store, recorded, launches)

        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        #expect(outcome == .started(started))
        #expect(launches.awaited == [started])
        #expect(store.listedSessions.isEmpty)
        store.noteLiveAgents([resumedRow(row)])
        #expect(store.listedSessions.isEmpty)
        #expect(store.sessions == [recorded])
    }

    @Test func backingOutUnusedClosesThePaneAndListsTheOriginalRecordAgain() async throws {
        let (store, recorded, row) = try recordedStore()
        let launches = Launches()
        _ = await resumeRecord(store, recorded, launches)
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        // Scrolling never reaches the input signal, so the Agent is unused.
        var closed: [ConsoleAgent.ID] = []

        await backOut(store, started, row: resumedRow(row)) { closed.append($0.id) }
        // The closed Pane is captured again later: the record keeps its time.
        store.record([
            ClosedAgentCapture(
                row: resumedRow(row), session: nil,
                lastSeenRunningAt: Date().addingTimeInterval(60))
        ])

        #expect(closed == [started])
        #expect(store.listedSessions.map(\.id) == [recorded.id])
        #expect(store.listedSessions.first?.closedAt == recorded.closedAt)
    }

    /// The record is back in the Closed list, and the Agent is no longer
    /// listed, the moment the user backs out — not once the close lands.
    @Test func backingOutListsTheRecordAgainWhileThePaneStillCloses() async throws {
        let (store, recorded, row) = try recordedStore()
        let launches = Launches()
        _ = await resumeRecord(store, recorded, launches)
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        store.noteLiveAgents([resumedRow(row)])
        var duringClose: (listed: [ClosedSession.ID], backedOut: Set<ConsoleAgent.ID>)?

        await backOut(store, started, row: resumedRow(row)) { _ in
            duringClose = (store.listedSessions.map(\.id), Set(store.backedOutResumes.keys))
        }

        #expect(duringClose?.listed == [recorded.id])
        #expect(duringClose?.backedOut == [started])
        // Still unlisted until the closure is captured.
        #expect(store.backedOutResumes[started] == recorded.id)
        store.record([
            ClosedAgentCapture(
                row: resumedRow(row), session: nil,
                lastSeenRunningAt: Date().addingTimeInterval(60))
        ])
        store.noteLiveAgents([])
        #expect(store.backedOutResumes.isEmpty)
        #expect(store.listedSessions.map(\.id) == [recorded.id])
    }

    /// A used resume keeps a record with a session: it is not listed while
    /// the Agent runs, and comes back as the session's later closure.
    @Test func inputUsesTheResumeSoBackingOutKeepsTheAgent() async throws {
        let (store, recorded, row) = try recordedStore()
        let launches = Launches()
        _ = await resumeRecord(store, recorded, launches)
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        var closed: [ConsoleAgent.ID] = []

        store.noteUserInput(to: started)
        await backOut(store, started, row: resumedRow(row)) { closed.append($0.id) }

        #expect(closed.isEmpty)
        #expect(store.sessions == [recorded])
        #expect(store.listedSessions.isEmpty)
        store.record([
            ClosedAgentCapture(
                row: resumedRow(row), session: nil,
                lastSeenRunningAt: Date().addingTimeInterval(60))
        ])
        let relisted = try #require(store.listedSessions.first)
        #expect(store.listedSessions.map(\.id) == [recorded.id])
        #expect(relisted.lastSeenRunningAt > recorded.lastSeenRunningAt)
    }

    /// Without a session nothing could match the resumed Agent to its
    /// record again, so using it forgets the record everywhere.
    @Test func inputUsesASessionlessResumeAndForgetsItsRecord() async throws {
        let store = ClosedSessionsStore()
        let hostID = UUID()
        let original = noSessionRow(terminalID: "t1", paneID: "w1:p1", hostID: hostID)
        store.record([ClosedAgentCapture(row: original, session: nil, lastSeenRunningAt: Date())])
        let recorded = try #require(store.sessions.first)
        let started = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p-resumed")
        store.beginPendingResume(recorded.id, agent: started, terminal: "t2")

        store.noteUserInput(to: started)

        #expect(store.sessions.isEmpty)
        // Forgotten: a later capture of the same closure stays gone.
        store.record([
            ClosedAgentCapture(
                row: original, session: nil, lastSeenRunningAt: recorded.lastSeenRunningAt)
        ])
        #expect(store.sessions.isEmpty)
    }

    @Test func aFailedCloseBringsTheAgentBackAndUsesTheResume() async throws {
        let (store, recorded, row) = try recordedStore()
        let launches = Launches()
        _ = await resumeRecord(store, recorded, launches)
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        var attempts = 0

        await backOut(store, started, row: resumedRow(row)) { _ in
            attempts += 1
            throw TransportError.sshUnreachable(detail: "down")
        }
        await backOut(store, started, row: resumedRow(row)) { _ in attempts += 1 }

        #expect(attempts == 1)
        #expect(store.backedOutResumes.isEmpty)
        #expect(store.pendingResumes.isEmpty)
        #expect(store.sessions == [recorded])
        #expect(store.listedSessions.isEmpty)
    }

    @Test func aRelaunchKeepsAPendingResumesRecordUnlistedWhileItsSessionRuns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClosedSessionsStore(directory: directory)
        let (_, recorded, row) = try recordedStore()
        store.record([
            ClosedAgentCapture(
                row: row, session: nil, lastSeenRunningAt: recorded.lastSeenRunningAt)
        ])
        let persisted = try #require(store.sessions.first)
        store.beginPendingResume(
            persisted.id, agent: ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed"),
            terminal: resumedRow(row).agent.terminalID)

        let relaunched = ClosedSessionsStore(directory: directory)
        relaunched.noteLiveAgents([resumedRow(row)])

        #expect(relaunched.pendingResumes.isEmpty)
        #expect(relaunched.sessions.map(\.id) == [persisted.id])
        #expect(relaunched.listedSessions.isEmpty)
        relaunched.noteLiveAgents([])
        #expect(relaunched.listedSessions.map(\.id) == [persisted.id])
    }

    /// A row with no reported session, like gemini's, whose resume lands in
    /// a new terminal: its closure would get a record id of its own.
    private func noSessionRow(terminalID: String, paneID: String, hostID: Host.ID) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: "alpha",
            agent: Agent(
                terminalID: terminalID, kind: "gemini", title: "Task", status: .idle,
                workspaceID: "w1", tabID: "w1:t-\(terminalID)", paneID: paneID, cwd: "/work/app",
                revision: 1),
            workspaceLabel: "App", repositoryCheckout: nil)
    }

    @Test func backingOutOfASessionlessResumeListsTheOriginalOnlyOnce() async throws {
        let store = ClosedSessionsStore()
        let hostID = UUID()
        store.record([
            ClosedAgentCapture(
                row: noSessionRow(terminalID: "t1", paneID: "w1:p1", hostID: hostID),
                session: nil, lastSeenRunningAt: Date())
        ])
        let recorded = try #require(store.sessions.first)
        let started = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p-resumed")
        let resumed = noSessionRow(terminalID: "t2", paneID: "w1:p-resumed", hostID: hostID)
        store.beginPendingResume(recorded.id, agent: started, terminal: "t2")

        await backOut(store, started, row: resumed) { _ in }
        store.record([
            ClosedAgentCapture(
                row: noSessionRow(terminalID: "t2", paneID: "w1:p-resumed", hostID: hostID),
                session: nil, lastSeenRunningAt: Date().addingTimeInterval(60))
        ])

        #expect(store.listedSessions.map(\.id) == [recorded.id])
        #expect(store.listedSessions.first?.closedAt == recorded.closedAt)
    }

    /// The detail's Close shut the resumed Pane before the back-out: its
    /// closure lists the record again, and the back-out's close finding the
    /// Pane gone forgets nothing.
    @Test func aResumeClosedFromTheDetailBeforeBackingOutIsListedAgain() async throws {
        let (store, recorded, row) = try recordedStore()
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        store.beginPendingResume(
            recorded.id, agent: started, terminal: resumedRow(row).agent.terminalID)

        store.record([
            ClosedAgentCapture(
                row: resumedRow(row), session: nil,
                lastSeenRunningAt: Date().addingTimeInterval(60))
        ])
        var attempts = 0
        await backOut(store, started, row: resumedRow(row)) { _ in
            attempts += 1
            throw TransportError.apiRejected(code: "agent_not_found", message: "gone")
        }

        #expect(attempts == 0)
        #expect(store.listedSessions.map(\.id) == [recorded.id])
        #expect(store.listedSessions.first?.closedAt == recorded.closedAt)
    }

    @Test func backingOutOfAPaneAlreadyGoneListsTheRecordAgain() async throws {
        let (store, recorded, row) = try recordedStore()
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        store.beginPendingResume(
            recorded.id, agent: started, terminal: resumedRow(row).agent.terminalID)

        await backOut(store, started, row: resumedRow(row)) { _ in
            throw TransportError.apiRejected(code: "pane_not_found", message: "gone")
        }
        store.record([
            ClosedAgentCapture(
                row: resumedRow(row), session: nil,
                lastSeenRunningAt: Date().addingTimeInterval(60))
        ])

        #expect(store.listedSessions.map(\.id) == [recorded.id])
        #expect(store.listedSessions.first?.closedAt == recorded.closedAt)
    }

    /// The Console's own `agent_not_found` means the row is not verified
    /// yet, not that the Pane is gone: the resume stays pending, and a
    /// later back-out still closes it.
    @Test func backingOutOfARowNotVerifiedYetKeepsTheResumePending() async throws {
        let (store, recorded, row) = try recordedStore()
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        store.beginPendingResume(
            recorded.id, agent: started, terminal: resumedRow(row).agent.terminalID)

        await backOut(store, started, row: resumedRow(row)) { _ in
            throw TransportError.apiRejected(code: "agent_not_found", message: "not listed")
        }

        #expect(store.backedOutResumes.isEmpty)
        #expect(store.pendingResumes[started]?.record == recorded.id)
        #expect(store.listedSessions.isEmpty)
        var closed: [ConsoleAgent.ID] = []
        await backOut(store, started, row: resumedRow(row)) { closed.append($0.id) }
        #expect(closed == [started])
        #expect(store.listedSessions.map(\.id) == [recorded.id])
    }

    /// Working or blocked, the resumed Agent is in use from another client:
    /// backing out here leaves it running and counts the resume as used.
    @Test func backingOutOfAnAgentBusyElsewhereKeepsItAndUsesTheResume() async throws {
        for status in [AgentStatus.working, .blocked] {
            let (store, recorded, row) = try recordedStore()
            let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
            store.beginPendingResume(
                recorded.id, agent: started, terminal: resumedRow(row).agent.terminalID)
            var closed: [ConsoleAgent.ID] = []

            await backOut(store, started, row: resumedRow(row, status: status)) {
                closed.append($0.id)
            }

            #expect(closed.isEmpty)
            #expect(store.backedOutResumes.isEmpty)
            #expect(store.pendingResumes.isEmpty)
            #expect(store.sessions == [recorded])
            store.noteLiveAgents([resumedRow(row, status: status)])
            #expect(store.listedSessions.isEmpty)
        }
    }

    /// herdr reused the resumed pane's id for another terminal: that is not
    /// the resumed Agent, so nothing closes, and the resume is over.
    @Test func backingOutOfAPaneIDReusedByAnotherTerminalClosesNothing() async throws {
        let (store, recorded, row) = try recordedStore()
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        store.beginPendingResume(
            recorded.id, agent: started, terminal: resumedRow(row).agent.terminalID)
        var closed: [ConsoleAgent.ID] = []

        await backOut(store, started, row: resumedRow(row, terminalID: "term_other")) {
            closed.append($0.id)
        }

        #expect(closed.isEmpty)
        #expect(store.backedOutResumes.isEmpty)
        #expect(store.pendingResumes.isEmpty)
        #expect(store.listedSessions.map(\.id) == [recorded.id])
    }

    /// A verified snapshot with the resumed pane holding another terminal,
    /// or gone once it was listed, ends the resume: its entry goes and the
    /// record is listed again. Missing before it was ever listed is the
    /// resync still to land.
    @Test func aVerifiedSnapshotWithoutTheResumedTerminalDropsTheResume() async throws {
        let (store, recorded, row) = try recordedStore()
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        let resumed = resumedRow(row)
        store.beginPendingResume(recorded.id, agent: started, terminal: resumed.agent.terminalID)

        store.noteVerifiedAgents(on: row.hostID, rows: [:])
        #expect(store.pendingResumes[started]?.record == recorded.id)
        store.noteVerifiedAgents(on: UUID(), rows: [:])
        store.noteVerifiedAgents(on: row.hostID, rows: [started.paneID: resumed])
        #expect(store.pendingResumes[started]?.record == recorded.id)
        store.noteVerifiedAgents(
            on: row.hostID, rows: [started.paneID: resumedRow(row, terminalID: "term_other")])

        #expect(store.pendingResumes.isEmpty)
        #expect(store.listedSessions.map(\.id) == [recorded.id])

        // Listed once, then gone.
        store.beginPendingResume(recorded.id, agent: started, terminal: resumed.agent.terminalID)
        store.noteVerifiedAgents(on: row.hostID, rows: [started.paneID: resumed])
        store.noteVerifiedAgents(on: row.hostID, rows: [:])
        #expect(store.pendingResumes.isEmpty)
        #expect(store.listedSessions.map(\.id) == [recorded.id])
    }

    /// The resumed Agent exited, leaving its pane a Shell: there is nothing
    /// to close and no Agent closure will ever be captured, so the resume
    /// leaves no entry behind and the record is listed again.
    @Test func backingOutOfAPaneNowAShellLeavesNoEntry() async throws {
        let (store, recorded, row) = try recordedStore()
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        store.beginPendingResume(
            recorded.id, agent: started, terminal: resumedRow(row).agent.terminalID)
        var closed: [ConsoleAgent.ID] = []

        await backOut(
            store, started,
            row: resumedRow(row, kind: Agent.shellKind, status: .shellTerminal)
        ) { closed.append($0.id) }

        #expect(closed.isEmpty)
        #expect(store.backedOutResumes.isEmpty)
        #expect(store.pendingResumes.isEmpty)
        #expect(store.listedSessions.map(\.id) == [recorded.id])
    }

    /// Forgetting the record while its back-out closes the Pane sticks:
    /// the closure records nothing new.
    @Test func forgettingDuringABackOutKeepsTheRecordForgotten() async throws {
        let (store, recorded, row) = try recordedStore()
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        store.beginPendingResume(
            recorded.id, agent: started, terminal: resumedRow(row).agent.terminalID)

        await backOut(store, started, row: resumedRow(row)) { _ in store.forget(recorded.id) }
        #expect(store.backedOutResumes[started] == recorded.id)
        store.record([
            ClosedAgentCapture(
                row: resumedRow(row), session: nil,
                lastSeenRunningAt: Date().addingTimeInterval(60))
        ])

        #expect(store.sessions.isEmpty)
        #expect(store.backedOutResumes.isEmpty)
    }

    /// Input that lands while the back-out closes the Pane goes with it.
    @Test func inputWhileTheBackOutClosesThePaneIsIgnored() async throws {
        let (store, recorded, row) = try recordedStore()
        let started = ConsoleAgent.ID(hostID: row.hostID, paneID: "w1:p-resumed")
        store.beginPendingResume(
            recorded.id, agent: started, terminal: resumedRow(row).agent.terminalID)

        await backOut(store, started, row: resumedRow(row)) { store.noteUserInput(to: $0.id) }

        #expect(store.listedSessions.map(\.id) == [recorded.id])
        #expect(store.pendingResumes.isEmpty)
    }

    @MainActor
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// A sessionless record's pending resume left by a relaunch is used, so
    /// it is forgotten — as of when the resume began: a later closure of the
    /// same Agent, captured from a snapshot cached before the relaunch, is
    /// still recorded.
    @Test func aRelaunchForgetsASessionlessPendingResumeAsOfWhenItBegan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let store = ClosedSessionsStore(directory: directory, now: { clock.date })
        let hostID = UUID()
        let original = noSessionRow(terminalID: "t1", paneID: "w1:p1", hostID: hostID)
        store.record([
            ClosedAgentCapture(
                row: original, session: nil, lastSeenRunningAt: clock.date.addingTimeInterval(-60))
        ])
        let recorded = try #require(store.sessions.first)
        clock.date = clock.date.addingTimeInterval(60)
        store.beginPendingResume(
            recorded.id, agent: ConsoleAgent.ID(hostID: hostID, paneID: "w1:p-resumed"),
            terminal: "t2")
        let cachedSnapshot = clock.date.addingTimeInterval(30)

        clock.date = clock.date.addingTimeInterval(3600)
        let relaunched = ClosedSessionsStore(directory: directory, now: { clock.date })
        #expect(relaunched.sessions.isEmpty)
        relaunched.record([
            ClosedAgentCapture(row: original, session: nil, lastSeenRunningAt: cachedSnapshot)
        ])

        #expect(relaunched.sessions.map(\.id) == [recorded.id])
        #expect(relaunched.pendingResumes.isEmpty)
    }

    @Test func aFailedResumeKeepsTheRecord() async {
        let launches = Launches()
        launches.error = TransportError.sshUnreachable(detail: "down")

        let outcome = await resumer(
            launches, workspaces: [ConsoleWorkspace(id: "w1", label: "App")]
        ).resume(session)

        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(launches.pending.isEmpty)
        #expect(launches.awaited.isEmpty)
    }

    @Test func theRecordedNameReturnsOnlyWhileNoLiveAgentHasIt() {
        #expect(ClosedSessionResumer.agentName(for: session, taken: []) == "reviewer")
        let taken: Set<String> = ["reviewer", "claude"]
        #expect(
            ClosedSessionResumer.agentName(for: session, taken: taken)
                == StartAgentStore.defaultAgentName(for: .claude, taken: taken))
        // A display name herdr would refuse as an agent name.
        let displayName = ClosedSession.fixture(kind: .omp, agentName: "Oh My Pi")
        #expect(ClosedSessionResumer.agentName(for: displayName, taken: []) == "omp")
    }
}
