import Foundation

/// Which kind of binary is running, for what analytics it may send (#105).
/// The network events go out only from internal builds — Debug, and the
/// interim TestFlight archives compiled with `WAYCAR_ADMIN` — so the App
/// Store build (`make publish`) sends exactly what its App Privacy answers
/// declare. The compile-time half of the gate; `GatedAnalytics` adds the
/// runtime receipt check (`AppEnvironment.allowsAdmin`).
enum BuildFlavor: Sendable, Equatable {
    case appStore
    case internalTesting

    static let current: BuildFlavor = AppEnvironment.isAdminBuild ? .internalTesting : .appStore

    func sends(_ event: AnalyticsEvent) -> Bool {
        !event.isInternalOnly || self == .internalTesting
    }
}

/// The network analytics vocabulary (#105). Every property value is a
/// fixed word or a bucket: never a Host, address, username, pane, path,
/// error text, or exact duration.
enum NetworkAnalytics {
    /// Why a connect or attach failed, or a transport was lost: the error's
    /// class, never its detail (which can name the Host or a path).
    enum Failure: String, Sendable, CaseIterable {
        case unreachable
        case jumpHost = "jump_host"
        case auth
        case hostKey = "host_key"
        case herdr
        case timeout
        case mosh
        case channel
        case tmux
        case cancelled

        init(_ error: any Error) {
            switch error {
            case let error as TransportError: self.init(error)
            case is MoshLinkLost: self = .timeout
            case is CancellationError: self = .cancelled
            default: self = .channel
            }
        }

        init(_ error: TransportError) {
            switch error {
            case .sshUnreachable: self = .unreachable
            case .jumpHostFailed, .tcpForwardingUnavailable: self = .jumpHost
            case .authenticationFailed, .passwordLoginUnavailable, .deviceKeyCorrupt, .rsaKeyCorrupt, .rsaSignatureUnsupported:
                self = .auth
            case .hostKeyRejected, .hostKeyMismatch: self = .hostKey
            case .socketNotFound, .herdrBinaryNotFound, .streamLocalOpenFailed, .herdrNotRunning,
                .herdrSessionNotFound, .protocolVersionMismatch, .homeDirectoryUnresolvable,
                .malformedResponse, .apiRejected, .coreNotInstalled, .coreNotRunning,
                .coreNeedsUpdate, .coreNeedsWaycarUpdate, .coreRefused:
                self = .herdr
            case .timedOut: self = .timeout
            case .cancelled: self = .cancelled
            case .moshSessionFailed: self = .mosh
            case .channelFailed, .eventsChannelAlreadyOpen, .terminalChannelAlreadyOpen,
                .invalidDirectoryPath:
                self = .channel
            case .tmuxNotInstalled, .tmuxTooOld, .zellijNotInstalled, .zellijTooOld: self = .tmux
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case success
        case failure(Failure)

        init(_ error: any Error) {
            self = .failure(Failure(error))
        }

        var value: String {
            switch self {
            case .success: "success"
            case .failure(let failure): failure.rawValue
            }
        }
    }

    /// How a Host's connection came up: the one kept across the suspension
    /// proved itself, a hedged fresh dial beat it (or replaced a live one
    /// that stopped answering), or a plain dial.
    enum ConnectPath: String, Sendable, CaseIterable {
        case kept
        case hedge
        case fresh
    }

    /// What set the connect off. `pathChange`: a network path came back
    /// after none; `moshRecovery`: a mosh server answered again after a
    /// stall, a silent outage no path change shows.
    enum ConnectTrigger: String, Sendable, CaseIterable {
        case launch
        case foreground
        case retry
        case pathChange = "path_change"
        case moshRecovery = "mosh_recovery"
    }

    /// Upper bounds of the millisecond buckets: what a user feels as
    /// instant, quick, a wait, and broken.
    static let millisecondBounds = [100, 250, 500, 1000, 2000, 5000, 10_000]
    /// Upper bounds of the background-seconds buckets, on the lifecycle's
    /// own edges: the 20 s Background Grace Period, and a standby's 50 s
    /// usable age after it (70 s).
    static let backgroundSecondBounds = [5, 20, 70, 300, 1800, 3600]

    static func millisecondsBucket(_ duration: Duration) -> String {
        bucket(max(duration.wholeMilliseconds, 0), bounds: millisecondBounds)
    }

    /// nil: not after a return to the foreground.
    static func backgroundBucket(_ absence: Duration?) -> String {
        guard let absence else { return "none" }
        return bucket(max(absence.wholeMilliseconds / 1000, 0), bounds: backgroundSecondBounds)
    }

    /// nil: never recovered.
    static func recoveryBucket(_ recovery: Duration?) -> String {
        recovery.map(millisecondsBucket) ?? "never"
    }

    /// "lower-upper" for the first bound `value` is under, else "last+".
    private static func bucket(_ value: Int, bounds: [Int]) -> String {
        var lower = 0
        for upper in bounds {
            if value < upper { return "\(lower)-\(upper)" }
            lower = upper
        }
        return "\(lower)+"
    }
}

/// One Host connect attempt (`host_connect`).
struct HostConnectReport: Equatable, Sendable {
    let outcome: NetworkAnalytics.Outcome
    let duration: Duration
    let path: NetworkAnalytics.ConnectPath
    let trigger: NetworkAnalytics.ConnectTrigger
}

/// One terminal attach attempt, from its start to live or its end
/// (`terminal_attach`).
struct TerminalAttachReport: Equatable, Sendable {
    /// nil when it ended before a transport was chosen.
    let transport: TerminalSessionFlavor?
    let route: TerminalAttachRoute?
    let outcome: NetworkAnalytics.Outcome
    let duration: Duration
    /// The return to the foreground it belongs to, if any.
    let foregroundReturn: ForegroundReturn?
}

/// A live transport that was lost, and how long it took to come back
/// (`transport_lost`).
struct TransportLossReport: Equatable, Sendable {
    let transport: TerminalSessionFlavor
    let reason: NetworkAnalytics.Failure
    /// nil: it never came back.
    let recovery: Duration?
}
