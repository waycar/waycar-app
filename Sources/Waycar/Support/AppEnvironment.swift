import Observation
import StoreKit

/// Where this build runs, for the one decision that depends on it: whether
/// the admin tools apply (Settings › Admin and the internal-only analytics
/// events; ADR 0032).
///
/// Two checks, both required. First the binary: the admin panel exists only
/// in Debug builds and in interim TestFlight archives built with the
/// `WAYCAR_ADMIN` compilation condition (`make testflight`, the CI TestFlight
/// workflow). A release archive (`make publish`), which is the build App
/// Review and the App Store get, compiles without it and never allows admin.
/// Second, for a release admin build, the receipt: its verified
/// `AppTransaction` must not be from the production App Store, so an admin
/// archive that ever reached the App Store still would not allow it.
enum AppEnvironment {
    /// False in a release build until `resolve()` proves otherwise. Observable:
    /// a view that reads it (Settings › Admin) redraws when the receipt
    /// resolves after it first rendered.
    @MainActor static var allowsAdmin: Bool { state.allowsAdmin }

    // fileprivate, not private: the macro's conformance extension sits at
    // file scope and must see the type.
    @MainActor @Observable fileprivate final class State {
        var allowsAdmin = AppEnvironment.isDebugBuild
        /// Whether `resolve()` has read a verified `AppTransaction` (of either
        /// environment), which settles `allowsAdmin` for the process.
        var isResolved = false
    }

    @MainActor private static let state = State()

    static let isDebugBuild: Bool = {
        #if DEBUG
            true
        #else
            false
        #endif
    }()

    /// Whether this binary was compiled with the admin panel.
    static let isAdminBuild: Bool = {
        #if DEBUG || WAYCAR_ADMIN
            true
        #else
            false
        #endif
    }()

    /// Reads the App Store receipt until a verified one answers. An
    /// unverifiable or unavailable one (offline with nothing cached, no
    /// Apple Account) leaves admin off, and the next call reads it again;
    /// once a verified one answered, calls do nothing. The app model calls
    /// it at launch and on every return to the foreground.
    @MainActor static func resolve() async {
        guard !isDebugBuild, isAdminBuild, !state.isResolved else { return }
        guard case .verified(let transaction) = try? await AppTransaction.shared else { return }
        state.allowsAdmin = transaction.environment != .production
        state.isResolved = true
    }
}
