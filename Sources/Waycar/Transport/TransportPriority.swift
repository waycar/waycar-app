import WaycarSSH

/// How urgently a piece of Transport work runs on its Host's shared
/// connection (#105, C-PRIORITY): `interactive` is work the user is waiting
/// on and goes ahead of queued `normal` work. The Console names it; only
/// Transport/ knows what it maps to on the SSH connection.
enum TransportPriority: Sendable {
    case interactive
    case normal

    var sshPriority: SSHOperationPriority {
        switch self {
        case .interactive: .interactive
        case .normal: .normal
        }
    }
}

extension EventsSession {
    /// `withTransport(_:)` at `priority`: every SSH operation the call
    /// starts, and any work it leaves behind, inherits it.
    func withTransport<Value: Sendable>(
        priority: TransportPriority,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        try await SSHOperationPriority.$current.withValue(priority.sshPriority) {
            try await withTransport(operation)
        }
    }
}
