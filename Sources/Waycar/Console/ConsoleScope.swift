import Foundation

/// One Console projection's identity: a Host and one of its backends
/// (ADR 0026). A herdr-only Host has the single scope `(host, .herdr)`.
struct ConsoleScope: Hashable, Sendable {
    let hostID: Host.ID
    let backend: HostBackend
}
