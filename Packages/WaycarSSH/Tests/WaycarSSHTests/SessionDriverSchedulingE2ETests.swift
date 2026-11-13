import Darwin
import Foundation
import Synchronization
import Testing

@testable import WaycarSSH

/// Channel opens that yield the session (WS3), interactive priority
/// (C-PRIORITY), one-shots that return before their channel closes (C-CLOSE,
/// C-EXECLINE), and the peer address (C-PEER), against the disposable sshd.
/// Members of `SessionDriverE2ETests`, so they share its fixture gate, its
/// serialization and its time limit.
extension SessionDriverE2ETests {
    /// libssh2 keeps a pending open in the session's own state and leaves the
    /// server's answer in the session packet queue for whoever reads it, so
    /// the opener need not hold the session for the round trip. The PTY
    /// ping's reads take the CHANNEL_OPEN_CONFIRMATION off the socket while
    /// the opener is parked; the open must still find it, at once.
    @Test("a ping completes while another channel open waits for its answer")
    func pingCompletesWhileAChannelOpenIsPending() async throws {
        try await exercisePingWhileParked(atStep: "channel open") { connection in
            let result = try await connection.execute("printf opened", timeout: .sshdBudget(10))
            #expect(result.stdout == Data("opened".utf8))
        }
    }

    @Test("a ping completes while a PTY request waits for its answer")
    func pingCompletesWhileAPTYRequestIsPending() async throws {
        try await exercisePingWhileParked(atStep: "PTY request") { connection in
            let opened = try await connection.openPTY(
                command: "cat",
                columns: 80,
                rows: 24,
                timeout: .sshdBudget(10))
            try await opened.write(Data("opened\n".utf8), timeout: .sshdBudget(5))
            try await self.readPTY(
                opened,
                untilContaining: "opened",
                timeout: .sshdBudget(5),
                comment: "the PTY opened while its request yielded is not usable")
            try await opened.close(timeout: .sshdBudget(5))
        }
    }

    @Test("an interactive open overtakes queued normal opens")
    func interactiveOpenOvertakesQueuedNormalOpens() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        // One open in flight at a time, so the later opens queue for the slot.
        await connection.setChannelOpenLimitForTesting(1)
        let order = ChannelOpenOrder()
        let gate = SessionWaitHold()
        await recordChannelOpenClaims(on: connection, into: order)
        await connection.holdNextChannelOpenSlotForTesting {
            await gate.waitUntilReleased()
        }
        let holder = labelledExec(on: connection, "holder", .normal)
        var execs = [holder]
        do {
            try await requireEventually("the first open should hold the slot") {
                await gate.hasEntered
            }
            for (index, label) in ["normal-1", "normal-2"].enumerated() {
                execs.append(labelledExec(on: connection, label, .normal))
                try await requireEventually("\(label) should queue for the slot") {
                    await connection.channelOpenWaiterCountForTesting() == index + 1
                }
            }
            execs.append(labelledExec(on: connection, "interactive", .interactive))
            try await requireEventually("the interactive open should queue last") {
                await connection.channelOpenWaiterCountForTesting() == 3
            }
            await gate.release()
            for exec in execs { _ = try await exec.value }
        } catch {
            await gate.release()
            for exec in execs { exec.cancel() }
            for exec in execs { _ = try? await exec.value }
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
        #expect(order.names == ["holder", "interactive", "normal-1", "normal-2"])
        #expect(await connection.isConnected)
        try await connection.close(timeout: .sshdBudget(2))
    }

    /// The holder parks after its open, still holding the operation mutex,
    /// so all three later execs queue for the mutex itself. The order they
    /// reach the open slot is the order the mutex admitted them.
    @Test("an interactive operation overtakes queued normal operations")
    func interactiveOperationOvertakesQueuedNormalOperations() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let order = ChannelOpenOrder()
        let established = SessionWaitHold()
        await connection.holdNextOneShotEstablishedForTesting {
            await established.waitUntilReleased()
        }
        let holder = labelledExec(on: connection, "holder", .normal)
        var execs = [holder]
        do {
            try await requireEventually("the holder should park holding the session") {
                await established.hasEntered
            }
            await recordChannelOpenClaims(on: connection, into: order)
            for (index, label) in ["normal-1", "normal-2"].enumerated() {
                execs.append(labelledExec(on: connection, label, .normal))
                try await requireEventually("\(label) should queue for the session") {
                    await connection.operationWaiterCountForTesting == index + 1
                }
            }
            execs.append(labelledExec(on: connection, "interactive", .interactive))
            try await requireEventually("the interactive operation should queue last") {
                await connection.operationWaiterCountForTesting == 3
            }
            await established.release()
            for exec in execs { _ = try await exec.value }
        } catch {
            await established.release()
            for exec in execs { exec.cancel() }
            for exec in execs { _ = try? await exec.value }
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
        #expect(order.names == ["interactive", "normal-1", "normal-2"])
        try await connection.close(timeout: .sshdBudget(2))
    }

    @Test("a stream-local RPC returns before its channel closes and is released once")
    func streamLocalRPCReturnsBeforeItsChannelCloses() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let socketPath = try #require(SessionDriverTestEnvironment.streamLocalSocketPath)
        let connection = try await environment.connect()
        let closeGate = SessionWaitHold()
        await connection.holdBackgroundChannelReleasesForTesting {
            await closeGate.waitUntilReleased()
        }
        let releases = ReleaseCounter()

        let response = try await connection.exchangeStreamLocal(
            socketPath: socketPath,
            request: Data(#"{"id":"early","method":"ping"}\#n"#.utf8),
            timeout: .sshdBudget(10),
            onChannelReleased: { await releases.increment() })
        #expect(!response.isEmpty)
        // Returned with the channel still registered and its close not begun.
        #expect(await releases.count == 0)
        #expect(await connection.oneShotRegistryCountForTesting() == 1)
        try await requireEventually("the close should wait in the background") {
            await closeGate.hasEntered
        }
        await connection.holdBackgroundChannelReleasesForTesting(nil)
        await closeGate.release()
        try await requireEventually("the release should follow the real close") {
            await releases.count == 1
        }
        #expect(await connection.oneShotRegistryCountForTesting() == 0)
        #expect(await connection.isConnected)

        // A refused open is released exactly once too, before the call throws.
        await #expect(throws: SSHError.streamLocalOpenFailed) {
            _ = try await connection.exchangeStreamLocal(
                socketPath: "/nonexistent/waycar-\(UUID().uuidString).sock",
                request: Data(#"{"id":"refused","method":"ping"}\#n"#.utf8),
                timeout: .sshdBudget(10),
                onChannelReleased: { await releases.increment() })
        }
        #expect(await releases.count == 2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await releases.count == 2)
        #expect(await connection.isConnected)
        try await connection.close(timeout: .sshdBudget(2))
    }

    /// The budget is the caller's, held from before each RPC until its
    /// `onChannelReleased`, as the app's forwarding admission is. With every
    /// close parked, the first eight RPCs return and the rest must wait: a
    /// release that ran before the real close would let them through and put
    /// more live channels on the session than the budget admits.
    @Test("eight concurrent RPCs never exceed the budget while their closes are pending")
    func concurrentRPCsNeverExceedTheBudgetWhileClosesArePending() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let socketPath = try #require(SessionDriverTestEnvironment.streamLocalSocketPath)
        let connection = try await environment.connect()
        let budget = ChannelBudget(limit: 8)
        let liveChannels = PeakCounter()
        let closeGate = SessionWaitHold()
        await connection.holdBackgroundChannelReleasesForTesting {
            await closeGate.waitUntilReleased()
        }

        let rpcs = (0..<12).map { index in
            Task {
                await budget.acquire()
                let response = try await connection.exchangeStreamLocal(
                    socketPath: socketPath,
                    request: Data(#"{"id":"rpc\#(index)","method":"ping"}\#n"#.utf8),
                    timeout: .sshdBudget(15),
                    onChannelReleased: { await budget.release() })
                await liveChannels.record(await connection.oneShotRegistryCountForTesting())
                return response
            }
        }
        do {
            try await requireEventually("eight RPCs should return and four wait for budget") {
                let returned = await liveChannels.samples
                let waiting = await budget.waiting
                return returned == 8 && waiting == 4
            }
            #expect(await connection.oneShotRegistryCountForTesting() == 8)
            await connection.holdBackgroundChannelReleasesForTesting(nil)
            await closeGate.release()
            for rpc in rpcs { #expect(!(try await rpc.value).isEmpty) }
            try await requireEventually("every channel should close") {
                await connection.oneShotRegistryCountForTesting() == 0
            }
        } catch {
            await connection.holdBackgroundChannelReleasesForTesting(nil)
            await closeGate.release()
            for rpc in rpcs { rpc.cancel() }
            for rpc in rpcs { _ = try? await rpc.value }
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
        #expect(await liveChannels.peak <= 8)
        try await requireEventually("every budget slot should come back") {
            await budget.inUse == 0
        }
        #expect(await connection.isConnected)
        try await connection.close(timeout: .sshdBudget(2))
    }

    @Test("exec-until-line returns on the matching line before EOF")
    func execUntilLineReturnsOnTheMatchingLineBeforeEOF() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let releases = ReleaseCounter()

        let result = try await connection.executeUntilLine(
            "printf 'banner\\nREADY 42\\n'; sleep 3; printf 'late\\n'",
            timeout: .sshdBudget(15),
            onChannelReleased: { await releases.increment() }
        ) { $0.hasPrefix("READY ") }
        #expect(result.matchedLine == "READY 42")
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        #expect(stdout.hasPrefix("banner\nREADY 42\n"))
        #expect(!stdout.contains("late"))
        // The command is still sleeping: its channel drains in the background.
        #expect(await releases.count == 0)
        #expect(await connection.oneShotRegistryCountForTesting() == 1)
        try await requireEventually("the drained channel should close after EOF") {
            await releases.count == 1
        }
        #expect(await connection.oneShotRegistryCountForTesting() == 0)

        let noMatch = try await connection.executeUntilLine(
            "printf 'one\\ntwo'",
            timeout: .sshdBudget(15)
        ) { $0 == "three" }
        #expect(noMatch.matchedLine == nil)
        #expect(noMatch.stdout == Data("one\ntwo".utf8))

        let lastLine = try await connection.executeUntilLine(
            "printf 'one\\ntwo'",
            timeout: .sshdBudget(15)
        ) { $0 == "two" }
        #expect(lastLine.matchedLine == "two")

        await #expect(throws: SSHError.responseTooLarge(limit: 8)) {
            _ = try await connection.executeUntilLine(
                "printf 'a long line with no match'",
                maximumOutputBytes: 8,
                timeout: .sshdBudget(15)
            ) { _ in false }
        }
        try await requireEventually("every exec channel should close") {
            await connection.oneShotRegistryCountForTesting() == 0
        }
        #expect(await connection.isConnected)
        try await connection.close(timeout: .sshdBudget(2))
    }

    @Test("a direct connection reports its numeric peer address and a jumped one none")
    func peerAddressIsNumericDirectAndNilThroughAJumpHost() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let jump = try await environment.connect()
        let peer = try #require(await jump.peerAddress)
        #expect(isNumericIPAddress(peer), "\(peer) is not a numeric address")
        if isNumericIPAddress(environment.endpoint.host) {
            #expect(peer == environment.endpoint.host)
        }

        let target = try await jump.connectThrough(
            to: environment.endpoint,
            timeout: .sshdBudget(10))
        do {
            try await environment.authenticate(target)
            #expect(await target.peerAddress == nil)
            let echo = try await target.execute("printf jumped", timeout: .sshdBudget(5))
            #expect(echo.stdout == Data("jumped".utf8))
        } catch {
            try? await target.close(timeout: .sshdBudget(2))
            throw error
        }
        // Closes the Jump Host connection under it too.
        try await target.close(timeout: .sshdBudget(2))
    }

    /// Parks the operation `open` starts at its first session wait in diagnostic
    /// step `step`, proves a PTY round trip on another channel completes
    /// meanwhile, then lets `open` finish.
    ///
    /// An open waits only if its first read finds no answer yet. The sshd is on
    /// loopback, so on a loaded host its answer can reach the socket before
    /// that read and the open finishes without ever waiting; there is then
    /// nothing to park and nothing to prove (WAY-505: a 15 s "should park on
    /// its answer" failure on `main`). That is a miss in the setup, not a
    /// failure of the driver, so the scenario runs again on a fresh connection.
    /// An open that never waits in any attempt is a failure.
    private func exercisePingWhileParked(
        atStep step: String,
        _ open: @escaping @Sendable (SSHConnection) async throws -> Void
    ) async throws {
        let attempts = 5
        for attempt in 1...attempts {
            if try await pingWhileParked(atStep: step, open) { return }
            SSHDiagnostics.note(
                "\(step) finished before it waited for its answer (attempt \(attempt) of \(attempts))")
        }
        Issue.record(
            "\(step) never waited for its answer in \(attempts) attempts; nothing was parked")
    }

    /// One attempt of `exercisePingWhileParked`. Returns false, with its
    /// connection closed, when the open finished without parking.
    private func pingWhileParked(
        atStep step: String,
        _ open: @escaping @Sendable (SSHConnection) async throws -> Void
    ) async throws -> Bool {
        let environment = try #require(SessionDriverTestEnvironment.current)
        // The hold below finds the step through the diagnostic context, which
        // exists only while a sink is installed; the fixture installs one.
        try #require(SSHDiagnostics.isEnabled)
        let connection = try await environment.connect()
        let pinger = try await connection.openPTY(
            command: "cat",
            columns: 80,
            rows: 24,
            timeout: .sshdBudget(5))
        let parked = SessionWaitHold()
        await holdSessionWait(atStep: step, on: connection, parked)
        let opened = ReleaseCounter()
        let opening = Task {
            do {
                try await open(connection)
            } catch {
                await opened.increment()
                throw error
            }
            await opened.increment()
        }
        let pinged = ReleaseCounter()
        var ping: Task<Void, any Error>?
        do {
            try await requireEventually("\(step) should park on its answer") {
                let hasParked = await parked.hasEntered
                let hasOpened = await opened.count == 1
                return hasParked || hasOpened
            }
            guard await parked.hasEntered else {
                // Finished without waiting: surfaces its error, if it had one.
                try await opening.value
                try await pinger.close(timeout: .sshdBudget(5))
                try await connection.close(timeout: .sshdBudget(2))
                return false
            }
            // The answer reaches the socket while the opener is parked; the
            // ping's reads are what take it off.
            try await Task.sleep(for: .milliseconds(300))
            ping = Task {
                try await pinger.write(Data("ping\n".utf8), timeout: .sshdBudget(5))
                try await self.readPTY(
                    pinger,
                    untilContaining: "ping",
                    timeout: .sshdBudget(5),
                    comment: "the PTY ping")
                await pinged.increment()
            }
            try await requireEventually(
                "the ping should complete while \(step) is pending",
                timeout: .sshdBudget(5)
            ) {
                await pinged.count == 1
            }
            await parked.release()
            let released = ContinuousClock.now
            try await opening.value
            // Its answer was already in the packet queue: no wait for a
            // socket edge that will never come.
            #expect(released.duration(to: .now) < .seconds(2))
            try await ping?.value
        } catch {
            await parked.release()
            opening.cancel()
            ping?.cancel()
            _ = try? await opening.value
            _ = try? await ping?.value
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
        try await pinger.close(timeout: .sshdBudget(5))
        #expect(await connection.isConnected)
        try await connection.close(timeout: .sshdBudget(2))
        return true
    }
}

/// Parks the first session wait whose diagnostic step is `step` on `hold`;
/// any other wait passes and re-arms the hook.
private func holdSessionWait(
    atStep step: String,
    on connection: SSHConnection,
    _ hold: SessionWaitHold
) async {
    await connection.holdNextSessionWaitForTesting {
        if SSHDiagnosticOperation.current?.step == step {
            await hold.waitUntilReleased()
        } else {
            await holdSessionWait(atStep: step, on: connection, hold)
        }
    }
}

/// Which test caller a channel-open claim belongs to. The claim observer runs
/// in the claiming task, so it reads the claimant's own label.
private enum ChannelOpenLabel {
    @TaskLocal static var name: String = ""
}

private final class ChannelOpenOrder: Sendable {
    private let claimed = Mutex<[String]>([])

    var names: [String] { claimed.withLock { $0 } }

    func record(_ name: String) { claimed.withLock { $0.append(name) } }
}

/// Records every later channel-open claim in claim order. The claim observer
/// runs under the operation mutex; a one-shot hold that re-armed itself ran
/// after the mutex was handed on, so under load the next claimant could pass
/// before the re-arm and go unrecorded.
private func recordChannelOpenClaims(
    on connection: SSHConnection,
    into order: ChannelOpenOrder
) async {
    await connection.observeChannelOpenClaimsForTesting {
        order.record(ChannelOpenLabel.name)
    }
}

private func labelledExec(
    on connection: SSHConnection,
    _ label: String,
    _ priority: SSHOperationPriority
) -> Task<SSHExecResult, any Error> {
    Task {
        try await SSHOperationPriority.$current.withValue(priority) {
            try await ChannelOpenLabel.$name.withValue(label) {
                try await connection.execute("printf \(label)", timeout: .sshdBudget(15))
            }
        }
    }
}

private actor ReleaseCounter {
    private(set) var count = 0

    func increment() { count += 1 }
}

private actor PeakCounter {
    private(set) var samples = 0
    private(set) var peak = 0

    func record(_ value: Int) {
        samples += 1
        peak = max(peak, value)
    }
}

/// A caller-side channel budget with the app admission's shape: a slot is
/// taken before a channel opens and handed straight to the next waiter when
/// released.
private actor ChannelBudget {
    private let limit: Int
    private(set) var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    var waiting: Int { waiters.count }

    func acquire() async {
        guard inUse >= limit else {
            inUse += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            inUse -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private func isNumericIPAddress(_ text: String) -> Bool {
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    return inet_pton(AF_INET, text, &ipv4) == 1 || inet_pton(AF_INET6, text, &ipv6) == 1
}
