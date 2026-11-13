import Foundation
import Synchronization

@testable import Waycar

/// A `MoshSessionFactory` whose sessions the test drives (#105): their
/// output, first contact, connectivity and whether the server is heard
/// from, and which teardown each got — a clean end or an abandon. No UDP.
final class ScriptedMoshSessions: Sendable {
    enum Teardown: Equatable, Sendable {
        case ended
        case abandoned
    }

    final class Session: TerminalSessionLink, Sendable {
        let bootstrap: MoshBootstrap
        let cols: Int
        let rows: Int
        let firstContactTimeout: Duration
        let gate = WaycarSSHAttachOutputGate()
        let input = TerminalAttachInputQueue()

        private struct State {
            var firstContact: TerminalLinkFirstContact?
            var firstContactWaiters: [CheckedContinuation<TerminalLinkFirstContact, Never>] = []
            var connectivity: TerminalLinkConnectivity?
            var subscribers: [UUID: AsyncStream<TerminalLinkConnectivity>.Continuation] = [:]
            var heardOnReturn = true
            var serverContactChecks = 0
            var teardown: Teardown?
            var resizes: [TerminalAttachInput] = []
        }

        private let state = Mutex(State())

        init(bootstrap: MoshBootstrap, cols: Int, rows: Int, firstContactTimeout: Duration) {
            self.bootstrap = bootstrap
            self.cols = cols
            self.rows = rows
            self.firstContactTimeout = firstContactTimeout
            let input = input
            Task { [weak self] in
                while let item = await input.next() {
                    if case .resize = item {
                        self?.state.withLock { $0.resizes.append(item) }
                    }
                }
            }
        }

        var teardown: Teardown? { state.withLock { $0.teardown } }
        var serverContactChecks: Int { state.withLock { $0.serverContactChecks } }
        var resizes: [TerminalAttachInput] { state.withLock { $0.resizes } }

        /// The server's frames.
        func emit(_ text: String) {
            answer()
            gate.yield(Data(text.utf8))
        }

        func answer() {
            settleFirstContact(.answered)
            setConnectivity(.connected)
        }

        /// The first-contact watchdog firing: nothing answered.
        func timeOutFirstContact() {
            settleFirstContact(.timedOut)
            gate.finish(throwing: TransportError.moshSessionFailed(
                detail: MoshAttachSession.firstContactTimeoutDetail(firstContactTimeout)))
        }

        /// The server ending the session (its command exited).
        func finish() {
            gate.finish()
            endLink()
        }

        func fail(_ error: any Error) {
            gate.finish(throwing: error)
            endLink()
        }

        func setConnectivity(_ connectivity: TerminalLinkConnectivity) {
            let subscribers = state.withLock { current in
                current.connectivity = connectivity
                return Array(current.subscribers.values)
            }
            for subscriber in subscribers { subscriber.yield(connectivity) }
        }

        /// What a return's server-contact check hears.
        func setHeardOnReturn(_ heard: Bool) {
            state.withLock { $0.heardOnReturn = heard }
        }

        func makeSession() -> TerminalAttachSession {
            TerminalAttachSession(
                output: gate.makeOutput,
                input: input,
                onEndStarted: gate.beginExplicitEnd,
                link: self,
                abandoner: { [self] in tearDown(.abandoned) }
            ) { [self] in
                tearDown(.ended)
            }
        }

        // MARK: TerminalSessionLink

        func connectivity() -> AsyncStream<TerminalLinkConnectivity> {
            let (stream, continuation) = AsyncStream.makeStream(of: TerminalLinkConnectivity.self)
            let id = UUID()
            state.withLock { current in
                if let connectivity = current.connectivity { continuation.yield(connectivity) }
                if current.teardown != nil {
                    continuation.finish()
                } else {
                    current.subscribers[id] = continuation
                }
            }
            return stream
        }

        func firstContact() async -> TerminalLinkFirstContact {
            await withCheckedContinuation { continuation in
                state.withLock { current in
                    if let settled = current.firstContact {
                        continuation.resume(returning: settled)
                    } else {
                        current.firstContactWaiters.append(continuation)
                    }
                }
            }
        }

        func awaitServerContact(within timeout: Duration) async -> Bool {
            state.withLock { current in
                current.serverContactChecks += 1
                return current.heardOnReturn && current.teardown == nil
            }
        }

        func repaint(cols: Int, rows: Int) async {}

        private func tearDown(_ teardown: Teardown) {
            state.withLock { current in
                if current.teardown == nil { current.teardown = teardown }
            }
            gate.finish()
            endLink()
        }

        private func endLink() {
            settleFirstContact(.ended)
            let subscribers = state.withLock { current in
                defer { current.subscribers.removeAll() }
                return Array(current.subscribers.values)
            }
            for subscriber in subscribers { subscriber.finish() }
        }

        private func settleFirstContact(_ outcome: TerminalLinkFirstContact) {
            let waiters = state.withLock { current -> [CheckedContinuation<TerminalLinkFirstContact, Never>] in
                guard current.firstContact == nil else { return [] }
                current.firstContact = outcome
                defer { current.firstContactWaiters.removeAll() }
                return current.firstContactWaiters
            }
            for waiter in waiters { waiter.resume(returning: outcome) }
        }
    }

    private let made = Mutex<[Session]>([])

    var sessions: [Session] { made.withLock { $0 } }

    var factory: MoshSessionFactory {
        { [self] bootstrap, cols, rows, firstContactTimeout in
            let session = Session(
                bootstrap: bootstrap, cols: cols, rows: rows,
                firstContactTimeout: firstContactTimeout)
            made.withLock { $0.append(session) }
            return session.makeSession()
        }
    }

    static let bootstrap = MoshBootstrap(
        host: "203.0.113.7", udpPort: "60001", key: "MDEyMzQ1Njc4OWFiY2RlZg")
}
