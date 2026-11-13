import Foundation

@testable import Waycar

/// A scripted `SharedConnection` (#105): each connect hands out the next
/// scripted answer, a Transport and the pooled connection it rides, and
/// every call is recorded in order, so a test can see which connection a
/// session kept, reused, replaced, released or retired.
actor ScriptedSharedConnection {
    enum Call: Equatable, Sendable {
        case connect(replacing: PooledConnectionID?)
        case keep(PooledConnectionID)
        case release(PooledConnectionID)
        case retire(PooledConnectionID)
        case abandonDial
    }

    enum Answer: Sendable {
        case transport(ScriptedTransport, on: PooledConnectionID?)
        /// A connect whose setup (tmux's detection and control-mode open)
        /// takes until `gate` opens; cancellation does not cut it short.
        case gated(ScriptedTransport, on: PooledConnectionID?, ScriptedTransportCallGate)
        case failure(TransportError)
        /// A dial that never finishes on its own (a SYN retried on a path
        /// that went away); only cancellation ends it.
        case hang
    }

    private(set) var calls: [Call] = []
    private var answers: [Answer] = []

    nonisolated var connection: SharedConnection {
        SharedConnection(
            connect: { try await self.connect(replacing: $0) },
            keep: { await self.keep($0) },
            release: { await self.record(.release($0)) },
            retire: { await self.record(.retire($0)) },
            abandonDial: { await self.record(.abandonDial) })
    }

    func answer(_ answer: Answer) {
        answers.append(answer)
    }

    var connectCalls: [Call] {
        calls.filter { if case .connect = $0 { true } else { false } }
    }

    private func connect(replacing: PooledConnectionID?) async throws -> SharedTransport {
        calls.append(.connect(replacing: replacing))
        guard !answers.isEmpty else {
            throw TransportError.sshUnreachable(detail: "no scripted connection left")
        }
        switch answers.removeFirst() {
        case .transport(let transport, let connection):
            return SharedTransport(transport: transport, connection: connection)
        case .gated(let transport, let connection, let gate):
            await gate.waitUntilOpen()
            return SharedTransport(transport: transport, connection: connection)
        case .failure(let failure):
            throw failure
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw TransportError.cancelled
        }
    }

    private func keep(_ connection: PooledConnectionID) -> Bool {
        calls.append(.keep(connection))
        return true
    }

    private func record(_ call: Call) {
        calls.append(call)
    }
}
