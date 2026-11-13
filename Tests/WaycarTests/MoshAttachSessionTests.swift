import Foundation
import Testing

@testable import Waycar

@Suite("Mosh attach session")
struct MoshAttachSessionTests {
    /// Nothing listens on the discard port, so the server stays silent the
    /// way a firewalled mosh UDP port does.
    private static let silentBootstrap = MoshBootstrap(
        host: "127.0.0.1", udpPort: "9", key: "MDEyMzQ1Njc4OWFiY2RlZg")

    private enum OutputOutcome: Sendable {
        case finished
        case failed(any Error)
        case stillWaiting
    }

    @Test func aSilentServerFailsTheOutputAfterTheFirstContactTimeout() async {
        let session = MoshAttachSession.make(
            bootstrap: Self.silentBootstrap, cols: 80, rows: 24,
            firstContactTimeout: .milliseconds(300))

        let outcome = await withTaskGroup(of: OutputOutcome.self) { group in
            group.addTask {
                do {
                    for try await _ in session.output {}
                    return .finished
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return .stillWaiting
            }
            let first = await group.next() ?? .stillWaiting
            group.cancelAll()
            return first
        }

        guard
            case .failed(let error) = outcome,
            case .moshSessionFailed(let detail) = error as? TransportError
        else {
            Issue.record("Expected a thrown moshSessionFailed, got \(outcome)")
            await session.end()
            return
        }
        #expect(detail.contains("did not answer over UDP"))
        #expect(await session.link?.firstContact() == .timedOut)

        let elapsed = await ContinuousClock().measure {
            await session.end()
        }
        #expect(elapsed < .seconds(2))
    }

    // MARK: Lifecycle (MOSH-01)

    /// Reads `session`'s output to its end, within the wait ceiling.
    private func outcome(of session: TerminalAttachSession) async -> OutputOutcome {
        await withTaskGroup(of: OutputOutcome.self) { group in
            group.addTask {
                do {
                    for try await _ in session.output {}
                    return .finished
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .waitCeiling)
                return .stillWaiting
            }
            let first = await group.next() ?? .stillWaiting
            group.cancelAll()
            return first
        }
    }

    /// Abandoning before any server state ends the output cleanly, with no
    /// first contact and no wait for a shutdown acknowledgement; the
    /// first-contact watchdog never fires afterwards.
    @Test func abandoningBeforeFirstContactEndsCleanlyAtOnce() async throws {
        let registry = MoshSessionRegistry()
        let session = MoshAttachSession.make(
            bootstrap: Self.silentBootstrap, cols: 80, rows: 24,
            firstContactTimeout: .milliseconds(400), registry: registry)
        try await waitUntil("the started client should join the registry") { registry.count == 1 }
        let connectivity = try #require(session.link?.connectivity())

        let elapsed = await ContinuousClock().measure {
            await session.abandon()
        }
        #expect(elapsed < .seconds(1), "abandon skips the shutdown handshake")
        guard case .finished = await outcome(of: session) else {
            Issue.record("an abandoned session's output must finish cleanly")
            return
        }
        #expect(await session.link?.firstContact() == .ended)
        #expect(registry.count == 0)
        var updates: [TerminalLinkConnectivity] = []
        for await update in connectivity { updates.append(update) }
        #expect(!updates.contains(.stalled), "no stall was ever published: \(updates)")
        // Past the first-contact timeout: nothing settles twice.
        try await Task.sleep(for: .milliseconds(600))
        #expect(await session.link?.firstContact() == .ended)
    }

    /// Ending a started session before any server state quits with the
    /// handshake, which a silent server never acknowledges: the end is
    /// bounded by the handshake's deadline, and the output finishes cleanly.
    @Test func endingBeforeFirstContactFinishesCleanly() async throws {
        let registry = MoshSessionRegistry()
        let session = MoshAttachSession.make(
            bootstrap: Self.silentBootstrap, cols: 80, rows: 24,
            firstContactTimeout: .seconds(20), registry: registry)
        try await waitUntil("the started client should join the registry") { registry.count == 1 }
        let elapsed = await ContinuousClock().measure {
            await session.end()
        }
        #expect(elapsed < .seconds(5))
        #expect(registry.count == 0)
        guard case .finished = await outcome(of: session) else {
            Issue.record("an ended session's output must finish cleanly")
            return
        }
        #expect(await session.link?.firstContact() == .ended)
    }

    /// A port mosh-server could not have announced fails the output at once
    /// and never joins the registry.
    @Test func anUnusablePortFailsTheOutputAtOnce() async throws {
        let registry = MoshSessionRegistry()
        let session = MoshAttachSession.make(
            bootstrap: MoshBootstrap(host: "127.0.0.1", udpPort: "0", key: "MDEyMzQ1Njc4OWFiY2RlZg"),
            cols: 80, rows: 24, firstContactTimeout: .seconds(20), registry: registry)
        guard
            case .failed(let error) = await outcome(of: session),
            case .moshSessionFailed(let detail) = error as? TransportError
        else {
            Issue.record("an unusable port must fail the output")
            await session.end()
            return
        }
        #expect(detail.contains("unusable UDP port"))
        #expect(await session.link?.firstContact() == .ended)
        #expect(registry.count == 0)
        await session.end()
    }

    /// A first-contact timeout settles first contact once, as timed out,
    /// whatever ends the session afterwards; the timed-out session leaves
    /// the registry and its contact check reads silence.
    @Test func aFirstContactTimeoutSettlesOnceAndLeavesTheRegistry() async throws {
        let registry = MoshSessionRegistry()
        let session = MoshAttachSession.make(
            bootstrap: Self.silentBootstrap, cols: 80, rows: 24,
            firstContactTimeout: .milliseconds(300), registry: registry)
        guard case .failed = await outcome(of: session) else {
            Issue.record("a silent server must fail the output")
            await session.end()
            return
        }
        #expect(await session.link?.firstContact() == .timedOut)
        try await waitUntil("the timed-out session should leave the registry") { registry.count == 0 }
        #expect(await session.link?.awaitServerContact(within: .milliseconds(300)) == false)
        await session.abandon()
        #expect(await session.link?.firstContact() == .timedOut)
    }
}
