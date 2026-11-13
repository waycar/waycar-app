import Foundation

/// One connection's remote `$HOME`, which home-relative herdr socket paths
/// are resolved against (`HerdrSocketLocation.path(homeDirectory:)`).
///
/// A `$HOME` an earlier connection proved (`HostConnectionMemory`) is used
/// at once, so a connection that has one runs no home exec at all — not even
/// the dial-time prewarm (#105, C-CACHE). Without one, the exec runs once,
/// single-flight, and its answer is remembered for the next connection.
///
/// A remembered `$HOME` is not proven. A socket that is not where it puts
/// the path (`socketNotFound`, `streamLocalOpenFailed`, `herdrNotRunning`,
/// `herdrSessionNotFound`) calls
/// `refresh(afterFailureAt:location:resolvingWith:)`: the remembered value
/// is dropped, the exec resolves the real one, and the caller retries once
/// when that moves the socket path.
actor HomeDirectoryResolver {
    private let memory: (any HostConnectionMemory)?
    private let resolved = SharedAsyncOperation<String>(cachesSuccess: true)
    /// The remembered `$HOME` this connection uses until a socket failure
    /// says otherwise; nil once resolved over exec instead.
    private var remembered: String?

    init(memory: (any HostConnectionMemory)?) {
        self.memory = memory
        remembered = memory?.homeDirectory
    }

    /// Whether a remembered `$HOME` answers without an exec.
    var hasRememberedValue: Bool { remembered != nil }

    /// The remembered `$HOME`, else the exec's answer (`resolve`, run once
    /// per connection and joined by concurrent callers). Failures are not
    /// cached: the next demand runs the exec again.
    func value(
        resolvingWith resolve: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        if let remembered { return remembered }
        let memory = memory
        return try await resolved.value {
            let home = try await resolve()
            memory?.rememberHomeDirectory(home)
            return home
        }
    }

    /// A request found no herdr socket at `failedPath`. Drops the remembered
    /// `$HOME` that produced it and resolves `$HOME` over exec; returns
    /// whether the socket path moved, i.e. whether one retry can succeed. A
    /// `$HOME` this connection already resolved over exec is not asked again,
    /// and a failed exec forgets the remembered value for the next
    /// connection too.
    func refresh(
        afterFailureAt failedPath: String,
        location: HerdrSocketLocation,
        resolvingWith resolve: @escaping @Sendable () async throws -> String
    ) async -> Bool {
        if case .absolutePath = location { return false }
        if let remembered, location.path(homeDirectory: remembered) == failedPath {
            self.remembered = nil
        }
        do {
            let fresh = try await value(resolvingWith: resolve)
            return location.path(homeDirectory: fresh) != failedPath
        } catch {
            memory?.rememberHomeDirectory(nil)
            return false
        }
    }
}
