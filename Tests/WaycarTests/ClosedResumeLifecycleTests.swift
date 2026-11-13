import Foundation
import Observation
import Testing

@testable import Waycar

/// Pins the resume lifecycle of `ClosedSessionsStore` (CONSOLE-14) through
/// its own API: what reaches the file, and how a back-out's awaits meet a
/// capture, a verified snapshot, a Forget and a use elsewhere.
@MainActor
@Suite("Closed resume lifecycle", .timeLimit(.minutes(1)))
struct ClosedResumeLifecycleTests {
    private func row(
        host: UUID, pane: String = "p1", terminal: String, session: String? = "s1",
        status: AgentStatus = .idle
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host, hostName: "Host",
            agent: Agent(
                terminalID: terminal, kind: "claude", title: "Task", status: status,
                workspaceID: "w1", tabID: "t1", paneID: pane, cwd: "/repo", revision: 1,
                agentSession: session.map {
                    AgentSessionInfo(agent: "claude", kind: .id, source: "herdr:claude", value: $0)
                }),
            workspaceLabel: "repo", repositoryCheckout: nil)
    }

    private func file(_ directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appending(path: "closed-sessions.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Round trip of the on-disk shape: version 1, the records, the
    /// tombstones and, only while one is pending, each pending record with
    /// its earliest resume's start in milliseconds.
    @Test func theFileKeepsPendingResumesAsRecordAndEarliestStart() async throws {
        let (directory, cleanup) = makeClosedSessionsDirectory()
        defer { cleanup() }
        let clock = ManualClock()
        let store = ClosedSessionsStore(directory: directory, now: { clock.now })
        let host = UUID()
        store.record([.init(
            row: row(host: host, terminal: "original"), session: nil,
            lastSeenRunningAt: clock.now)])
        let record = try #require(store.sessions.first)
        #expect(Set(try file(directory).keys) == ["version", "sessions", "tombstones"])
        #expect(try file(directory)["version"] as? Int == 1)

        let first = row(host: host, pane: "pa", terminal: "ta")
        let second = row(host: host, pane: "pb", terminal: "tb")
        clock.advance(by: 10)
        let firstStart = ClosedSession.milliseconds(clock.now)
        store.beginPendingResume(record.id, agent: first.id, terminal: "ta")
        clock.advance(by: 10)
        store.beginPendingResume(record.id, agent: second.id, terminal: "tb")
        #expect(try file(directory)["pendingResumes"] as? [String: Int64] == [record.id: firstStart])

        // Backing out of the first leaves only the second pending on disk.
        await store.backedOut(of: first.id, verifiedRow: { _ in first }, closePane: { _ in })
        let secondStart = firstStart + 10_000
        #expect(try file(directory)["pendingResumes"] as? [String: Int64] == [record.id: secondStart])

        // Capturing the second's closure resolves it: nothing pending.
        store.record([.init(row: second, session: nil, lastSeenRunningAt: clock.now)])
        #expect(try file(directory)["pendingResumes"] == nil)

        let relaunched = ClosedSessionsStore(directory: directory, now: { clock.now })
        #expect(relaunched.sessions.map(\.id) == [record.id])
        #expect(relaunched.pendingResumes.isEmpty)
        #expect(relaunched.backedOutResumes.isEmpty)
    }

    /// A pending resume of a record with a session survives a relaunch only
    /// as the record: the relaunch rewrites the file without it.
    @Test func aRelaunchRewritesThePendingResumeAway() throws {
        let (directory, cleanup) = makeClosedSessionsDirectory()
        defer { cleanup() }
        let store = ClosedSessionsStore(directory: directory)
        let host = UUID()
        store.record([.init(row: row(host: host, terminal: "o"), session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        store.beginPendingResume(record.id, agent: row(host: host, pane: "p2", terminal: "r").id, terminal: "r")
        #expect(try file(directory)["pendingResumes"] != nil)

        let relaunched = ClosedSessionsStore(directory: directory)
        #expect(try file(directory)["pendingResumes"] == nil)
        #expect(relaunched.sessions.map(\.id) == [record.id])
        #expect(try file(directory)["tombstones"] as? [String: Int64] == [:])
    }

    @Test func aCaptureDuringVerificationEndsTheBackOutWithoutAClose() async throws {
        let store = ClosedSessionsStore()
        let host = UUID()
        let start = Date()
        store.record([.init(row: row(host: host, terminal: "o"), session: nil, lastSeenRunningAt: start)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: host, pane: "p2", terminal: "r")
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "r")
        var closes = 0
        let later = start.addingTimeInterval(60)
        await store.backedOut(of: resumed.id, verifiedRow: { _ in
            store.record([.init(row: resumed, session: nil, lastSeenRunningAt: later)])
            return resumed
        }, closePane: { _ in closes += 1 })
        #expect(closes == 0)
        #expect(store.backedOutResumes.isEmpty)
        #expect(store.pendingResumes.isEmpty)
        #expect(store.listedSessions.map(\.id) == [record.id])
        #expect(store.sessions.first?.lastSeenRunningAtMilliseconds == ClosedSession.milliseconds(later))
        #expect(store.sessions.first?.closedAt == record.closedAt)
    }

    @Test func aVerifiedSnapshotEndingTheResumeDuringVerificationClosesNothing() async throws {
        let clock = ManualClock()
        let store = ClosedSessionsStore(now: { clock.now })
        let host = UUID()
        store.record([.init(row: row(host: host, terminal: "o"), session: nil, lastSeenRunningAt: clock.now)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: host, pane: "p2", terminal: "r")
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "r")
        var closes = 0
        await store.backedOut(of: resumed.id, verifiedRow: { _ in
            store.noteVerifiedAgents(on: host, rows: ["p2": self.row(host: host, pane: "p2", terminal: "x")])
            return resumed
        }, closePane: { _ in closes += 1 })
        #expect(closes == 0)
        #expect(store.backedOutResumes.isEmpty)
        #expect(store.listedSessions.map(\.id) == [record.id])
        // Nothing of the resume is left: a capture of the pane is an
        // ordinary closure, not the record's.
        clock.advance(by: 60)
        store.record([.init(row: resumed, session: nil, lastSeenRunningAt: clock.now)])
        #expect(store.sessions.first?.closedAt != record.closedAt)
    }

    @Test func notVerifiedAfterAForgetReleasesTheResume() async throws {
        let store = ClosedSessionsStore()
        let host = UUID()
        store.record([.init(row: row(host: host, terminal: "o"), session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: host, pane: "p2", terminal: "r")
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "r")
        await store.backedOut(of: resumed.id, verifiedRow: { _ in
            store.forget(record.id)
            return resumed
        }, closePane: { _ in
            throw TransportError.apiRejected(code: "agent_not_found", message: "not verified")
        })
        #expect(store.pendingResumes.isEmpty)
        #expect(store.backedOutResumes.isEmpty)
        #expect(store.sessions.isEmpty)
        // A later back-out finds nothing to close.
        var verified = 0
        await store.backedOut(of: resumed.id, verifiedRow: { _ in
            verified += 1
            return resumed
        }, closePane: { _ in })
        #expect(verified == 0)
    }

    @Test func aFailedCloseAfterAForgetReleasesTheResume() async throws {
        let store = ClosedSessionsStore()
        let host = UUID()
        store.record([.init(row: row(host: host, terminal: "o"), session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: host, pane: "p2", terminal: "r")
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "r")
        await store.backedOut(of: resumed.id, verifiedRow: { _ in resumed }, closePane: { _ in
            store.forget(record.id)
            throw TransportError.timedOut
        })
        #expect(store.pendingResumes.isEmpty)
        #expect(store.backedOutResumes.isEmpty)
        #expect(store.sessions.isEmpty)
        #expect(store.listedSessions.isEmpty)
    }

    @Test func aPaneGoneDuringTheBackOutKeepsItBackingOutUntilTheCapture() async throws {
        let store = ClosedSessionsStore()
        let host = UUID()
        store.record([.init(row: row(host: host, terminal: "o"), session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: host, pane: "p2", terminal: "r")
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "r")
        await store.backedOut(of: resumed.id, verifiedRow: { _ in
            throw TransportError.apiRejected(code: "pane_not_found", message: "gone")
        }, closePane: { _ in })
        #expect(store.backedOutResumes[resumed.id] == record.id)
        #expect(store.listedSessions.map(\.id) == [record.id])
        store.noteVerifiedAgents(on: host, rows: [:])
        #expect(store.backedOutResumes[resumed.id] == record.id)
        store.noteVerifiedAgents(on: host, rows: ["p2": row(host: host, pane: "p2", terminal: "x")])
        #expect(store.backedOutResumes.isEmpty)
    }

    @Test(arguments: [true, false])
    func useElsewhereResolvesEveryPendingResumeOfTheRecord(withSession: Bool) async throws {
        let store = ClosedSessionsStore()
        let host = UUID()
        let session: String? = withSession ? "s1" : nil
        store.record([.init(
            row: row(host: host, terminal: "o", session: session), session: nil,
            lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let first = row(host: host, pane: "pa", terminal: "ta", session: session)
        let second = row(host: host, pane: "pb", terminal: "tb", session: session)
        store.beginPendingResume(record.id, agent: first.id, terminal: "ta")
        store.beginPendingResume(record.id, agent: second.id, terminal: "tb")

        store.resolvePendingResumeAsUsed(record.id)

        #expect(store.pendingResumes.isEmpty)
        #expect(store.listedSessions.isEmpty)
        if withSession {
            #expect(store.sessions.map(\.id) == [record.id])
            // Hidden while either used row is listed.
            store.noteLiveAgents([first])
            #expect(store.listedSessions.isEmpty)
            store.noteLiveAgents([])
            #expect(store.listedSessions.map(\.id) == [record.id])
        } else {
            #expect(store.sessions.isEmpty)
        }
    }

    @Test func onlyTheResumesOwnBackendsSnapshotsEndIt() throws {
        let store = ClosedSessionsStore()
        let host = UUID()
        store.record([.init(row: row(host: host, terminal: "o"), session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: host, pane: "p2", terminal: "r")
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "r")
        store.noteVerifiedAgents(on: host, rows: ["p2": resumed])
        store.noteVerifiedAgents(on: host, backend: .tmux, rows: [:])
        #expect(store.pendingResumes[resumed.id]?.record == record.id)
        store.noteVerifiedAgents(on: host, rows: [:])
        #expect(store.pendingResumes.isEmpty)
        #expect(store.listedSessions.map(\.id) == [record.id])
    }

    @Test func aUsedResumeEndsWithItsTerminalOrItsRow() throws {
        let store = ClosedSessionsStore()
        let host = UUID()
        store.record([.init(row: row(host: host, terminal: "o"), session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: host, pane: "p2", terminal: "r", session: "s2")
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "r")
        store.noteUserInput(to: resumed.id)
        #expect(store.pendingResumes.isEmpty)
        store.noteLiveAgents([resumed])
        #expect(store.listedSessions.isEmpty)
        // herdr reused the pane for another terminal: the used resume is over.
        store.noteVerifiedAgents(on: host, rows: ["p2": row(host: host, pane: "p2", terminal: "x", session: "s2")])
        store.noteLiveAgents([resumed])
        #expect(store.listedSessions.map(\.id) == [record.id])
        // Input after that resumes nothing.
        store.noteUserInput(to: resumed.id)
        #expect(store.sessions.map(\.id) == [record.id])
    }

    @Test func aBackOutOfARowWithNoPendingResumeAsksNothing() async throws {
        let store = ClosedSessionsStore()
        let host = UUID()
        store.record([.init(row: row(host: host, terminal: "o"), session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: host, pane: "p2", terminal: "r")
        var asked = 0
        await store.backedOut(of: resumed.id, verifiedRow: { _ in
            asked += 1
            return resumed
        }, closePane: { _ in })
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "r")
        store.noteUserInput(to: resumed.id)
        await store.backedOut(of: resumed.id, verifiedRow: { _ in
            asked += 1
            return resumed
        }, closePane: { _ in })
        #expect(asked == 0)
        // A record that is gone starts no resume at all.
        store.beginPendingResume("missing", agent: resumed.id, terminal: "r")
        #expect(store.pendingResumes.isEmpty)
    }

    /// A verified snapshot that only marks the resumed terminal seen leaves
    /// every published dictionary alone.
    @Test func aTerminalSeenChangePublishesNothing() throws {
        final class Flag: @unchecked Sendable { var fired = false }
        let store = ClosedSessionsStore()
        let host = UUID()
        store.record([.init(row: row(host: host, terminal: "o"), session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: host, pane: "p2", terminal: "r")
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "r")
        let flag = Flag()
        withObservationTracking {
            _ = store.pendingResumes
            _ = store.backedOutResumes
            _ = store.listedSessions
        } onChange: {
            flag.fired = true
        }
        store.noteVerifiedAgents(on: host, rows: ["p2": resumed])
        #expect(!flag.fired)
        #expect(store.pendingResumes[resumed.id]?.record == record.id)
    }
}
