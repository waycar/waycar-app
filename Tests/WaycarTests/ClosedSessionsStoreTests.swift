import Foundation
import Testing

@testable import Waycar

/// Closed Sessions kept on this device: capture, Forget, a live session
/// leaving the list while it runs, Hosts leaving the catalog, and the 30-day
/// expiry.
@MainActor
@Suite("Closed sessions store")
struct ClosedSessionsStoreTests {
    private func row(
        _ hostID: Host.ID, pane: String, kind: String = "claude", terminal: String? = nil,
        session: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: "alpha",
            agent: Agent(
                terminalID: terminal ?? "term-\(pane)", kind: kind, title: "Task",
                status: .idle, workspaceID: "w1", tabID: "w1:t1", paneID: pane,
                cwd: "/work/project", revision: 1,
                agentSession: session.map {
                    AgentSessionInfo(agent: kind, kind: .id, source: "herdr:\(kind)", value: $0)
                }),
            workspaceLabel: "Project", repositoryCheckout: nil)
    }

    /// `row`, last seen running at `seen`.
    private func capture(_ row: ConsoleAgent, seen: Date?) -> ClosedAgentCapture {
        ClosedAgentCapture(row: row, session: row.agent.agentSession, lastSeenRunningAt: seen)
    }

    @Test func capturedSessionsListNewestFirstAndSurviveRelaunch() {
        let (directory, cleanup) = makeClosedSessionsDirectory()
        defer { cleanup() }
        let clock = ManualClock()
        let hostID = UUID()
        let store = ClosedSessionsStore(directory: directory, now: { clock.now })

        store.record([capture(row(hostID, pane: "p1", session: "one"), seen: clock.now)])
        clock.advance(by: 60)
        store.record([capture(row(hostID, pane: "p2", session: "two"), seen: clock.now)])

        #expect(store.sessions.map(\.session?.value) == ["two", "one"])
        let relaunched = ClosedSessionsStore(directory: directory, now: { clock.now })
        #expect(relaunched.sessions == store.sessions)
    }

    @Test func shellsAndUnknownKindsAreNeverRecorded() {
        let clock = ManualClock()
        let store = ClosedSessionsStore(now: { clock.now })
        let hostID = UUID()

        store.record([
            capture(row(hostID, pane: "shell", kind: Agent.shellKind), seen: clock.now),
            capture(row(hostID, pane: "mystery", kind: "unknown"), seen: clock.now),
        ])

        #expect(store.sessions.isEmpty)
    }

    @Test func aRecordLastsThirtyDaysFromItsClosure() {
        let (directory, cleanup) = makeClosedSessionsDirectory()
        defer { cleanup() }
        let clock = ManualClock()
        let store = ClosedSessionsStore(directory: directory, now: { clock.now })
        store.record([capture(row(UUID(), pane: "p1", session: "one"), seen: clock.now)])

        clock.advance(by: ClosedSessionsStore.retention)
        store.pruneExpired()
        #expect(store.sessions.count == 1, "exactly thirty days old is still kept")

        clock.advance(by: 0.001)
        store.pruneExpired()
        #expect(store.sessions.isEmpty)
        #expect(ClosedSessionsStore(directory: directory, now: { clock.now }).sessions.isEmpty)
    }

    @Test func anExpiredRecordIsDroppedOnLaunch() {
        let (directory, cleanup) = makeClosedSessionsDirectory()
        defer { cleanup() }
        let clock = ManualClock()
        ClosedSessionsStore(directory: directory, now: { clock.now })
            .record([capture(row(UUID(), pane: "p1", session: "one"), seen: clock.now)])

        clock.advance(by: ClosedSessionsStore.retention + 1)

        #expect(ClosedSessionsStore(directory: directory, now: { clock.now }).sessions.isEmpty)
    }

    /// A device back after a long absence notices, all at once, Agents that
    /// closed long ago: those it last saw running more than thirty days ago,
    /// or at a time it does not know, are no news.
    @Test func aCaptureLastSeenRunningTooLongAgoIsNotRecorded() {
        let clock = ManualClock()
        let hostID = UUID()
        let store = ClosedSessionsStore(now: { clock.now })

        store.record([
            capture(
                row(hostID, pane: "p1", session: "stale"),
                seen: clock.now.addingTimeInterval(-ClosedSessionsStore.retention - 1)),
            capture(row(hostID, pane: "p2", session: "unknown"), seen: nil),
            capture(
                row(hostID, pane: "p3", session: "recent"),
                seen: clock.now.addingTimeInterval(-ClosedSessionsStore.retention)),
        ])

        #expect(store.sessions.map(\.session?.value) == ["recent"])
    }

    /// Forget covers every copy of the record last seen running no later
    /// than it: a device that noticed the closure only after coming back
    /// cannot return it. The same session seen running after the Forget
    /// (resumed) and closing again is news.
    @Test func forgettingBeatsAStaleCaptureButNotALaterClosure() throws {
        let clock = ManualClock()
        let hostID = UUID()
        let store = ClosedSessionsStore(now: { clock.now })
        let agent = row(hostID, pane: "p1", session: "one")
        let seen = clock.now
        clock.advance(by: 1)
        store.record([capture(agent, seen: seen)])
        let id = try #require(store.sessions.first?.id)

        clock.advance(by: 10)
        store.forget(id)
        #expect(store.sessions.isEmpty)
        // Noticed a minute later by a device that last looked before Forget.
        clock.advance(by: 60)
        store.record([capture(agent, seen: seen)])
        #expect(store.sessions.isEmpty)

        let seenAgain = clock.now
        clock.advance(by: 5)
        store.record([
            capture(row(hostID, pane: "p7", terminal: "term-new", session: "one"), seen: seenAgain)
        ])
        #expect(store.sessions.map(\.id) == [id])
        #expect(store.sessions.first?.lastSeenRunningAt == seenAgain)
    }

    /// Two devices capture the same closure; the one that saw the Agent
    /// running last knows best when it closed.
    @Test func aCaptureSeenRunningEarlierLeavesTheRecordAlone() throws {
        let clock = ManualClock()
        let hostID = UUID()
        let store = ClosedSessionsStore(now: { clock.now })
        let agent = row(hostID, pane: "p1", session: "one")
        let seen = clock.now
        store.record([capture(agent, seen: seen)])
        let recorded = try #require(store.sessions.first)

        clock.advance(by: 600)
        store.record([capture(agent, seen: seen.addingTimeInterval(-300))])

        #expect(store.sessions == [recorded])
    }

    /// Resumed on any device, or restored by herdr: while its session runs
    /// on its Host a record is not listed, and nothing forgets it.
    @Test func aSessionRunningAgainOnItsHostIsUnlistedUntilItClosesAgain() throws {
        let clock = ManualClock()
        let hostID = UUID()
        let store = ClosedSessionsStore(now: { clock.now })
        store.record([
            capture(row(hostID, pane: "p1", session: "resumed"), seen: clock.now),
            capture(row(hostID, pane: "p2", session: "still-closed"), seen: clock.now),
            capture(row(hostID, pane: "p3", kind: "gemini"), seen: clock.now),
        ])
        let recorded = store.sessions

        // Another Host running the same session id says nothing about this one.
        store.noteLiveAgents([row(UUID(), pane: "x", session: "resumed")])
        #expect(store.listedSessions == recorded)
        let resumed = row(hostID, pane: "p9", session: "resumed")
        store.noteLiveAgents([resumed])

        #expect(Set(store.listedSessions.map(\.session?.value)) == ["still-closed", nil])
        #expect(store.sessions == recorded)

        // It closes again: listed again, as the later closure.
        clock.advance(by: 60)
        store.record([capture(resumed, seen: clock.now.addingTimeInterval(-5))])
        store.noteLiveAgents([])
        #expect(store.listedSessions.count == 3)
        let first = try #require(store.listedSessions.first)
        #expect(first.session?.value == "resumed")
        #expect(first.closedAt == clock.now)
    }

    @Test func removedHostsTakeTheirRecordsWithThem() {
        let (directory, cleanup) = makeClosedSessionsDirectory()
        defer { cleanup() }
        let clock = ManualClock()
        let kept = UUID()
        let removed = UUID()
        let store = ClosedSessionsStore(directory: directory, now: { clock.now })
        store.record([
            capture(row(kept, pane: "p1", session: "a"), seen: clock.now),
            capture(row(removed, pane: "p1", session: "b"), seen: clock.now),
        ])

        store.retainHosts([kept])

        #expect(store.sessions.map(\.hostID) == [kept])
        #expect(
            ClosedSessionsStore(directory: directory, now: { clock.now }).sessions.map(\.hostID)
                == [kept])
    }
}
