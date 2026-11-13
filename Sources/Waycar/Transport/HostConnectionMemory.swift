import Foundation

/// What a Host's earlier connections proved, kept across launches so the
/// next connection can skip asking again (#105, C-CACHE): the remote
/// `$HOME` the herdr socket path is resolved against, the herdr protocol
/// version the last `ping` reported, and the login PATH herdr-core's lines
/// export (`CoreLoginPath`).
///
/// Every value is a hint, never an authority. The connection still proves
/// what it relies on and corrects the memory: a socket that is not where a
/// remembered `$HOME` puts it re-resolves `$HOME` once and retries
/// (`HostSSHSession.refreshHomeDirectory(afterFailureAt:location:)`), and a
/// `ping` that fails the protocol floor still fails the connection. A nil
/// value forgets what was kept.
///
/// Production is `ConsoleInventoryCache.ConnectionMemory`, bound to one
/// Host's connection target, so editing where the Host points discards it.
protocol HostConnectionMemory: Sendable {
    var homeDirectory: String? { get }
    func rememberHomeDirectory(_ home: String?)
    var protocolVersion: Int? { get }
    func rememberProtocolVersion(_ version: Int?)
    /// The Host's login PATH, which a core this device starts gets
    /// (`CoreLoginPath`); forgotten after a Backend Install, since a directory
    /// that did not exist when it was resolved (`~/.local/bin`) is on a
    /// later one.
    var loginPATH: String? { get }
    func rememberLoginPATH(_ path: String?)
    /// The existing backend-presence record, not a second cached copy.
    /// Replacement sessions can use it when fresh detection was skipped.
    var codexPresence: CodexPresence? { get }
    /// The same record's OpenCode 2 presence, which holds no password.
    var opencodePresence: OpenCodePresence? { get }
}

extension HostConnectionMemory {
    /// Memories that predate the login PATH keep nothing.
    var loginPATH: String? { nil }
    func rememberLoginPATH(_ path: String?) {}
    var codexPresence: CodexPresence? { nil }
    var opencodePresence: OpenCodePresence? { nil }
}
