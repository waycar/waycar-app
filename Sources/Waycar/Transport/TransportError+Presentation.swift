/// What one `TransportError` is allowed to say: a Summary, an optional Detail
/// carrying the error's own words, and an optional Recovery Suggestion.
/// See Transport Error Presentation in `CONTEXT.md`.
struct TransportErrorPresentation: Equatable, Sendable {
    /// Short, stable, standalone. No trailing period. Safe on an ambient
    /// surface while automatic recovery is running.
    let summary: String
    /// The error's own interpolated text — a transport detail string, or
    /// herdr's code and message. Never authored instruction.
    let detail: String?
    /// Present only when the error itself supports a safe next step.
    let recoverySuggestion: String?

    /// `summary` [+ ": " + `detail`] + "." — what happened, no instruction.
    /// A detail that already ends a sentence gets no second period.
    var explanation: String {
        guard let detail else { return "\(summary)." }
        let endsSentence = detail.last.map { ".!?".contains($0) } ?? false
        return endsSentence ? "\(summary): \(detail)" : "\(summary): \(detail)."
    }

    /// `explanation` [+ " " + `recoverySuggestion`] — the whole presentation.
    var message: String {
        if let recoverySuggestion {
            return "\(explanation) \(recoverySuggestion)"
        }
        return explanation
    }
}

extension TransportError {
    var presentation: TransportErrorPresentation {
        switch self {
        case .sshUnreachable(let detail):
            TransportErrorPresentation(
                summary: "SSH unavailable",
                detail: detail,
                recoverySuggestion:
                    "Check that the Host is awake and reachable, then verify its address and port.")
        case .jumpHostFailed(let underlying):
            Self.jumpHostPresentation(underlying)
        case .tcpForwardingUnavailable:
            TransportErrorPresentation(
                summary: "SSH TCP forwarding is disabled",
                detail: nil,
                recoverySuggestion: "Enable it on the Jump Host.")
        case .authenticationFailed:
            TransportErrorPresentation(
                summary: "Authentication failed",
                detail: nil,
                recoverySuggestion: "Update this Host's credentials or authorized key.")
        case .passwordLoginUnavailable:
            TransportErrorPresentation(
                summary: "This Host accepts only keys",
                detail: nil,
                recoverySuggestion: nil)
        case .deviceKeyCorrupt:
            TransportErrorPresentation(
                summary: "The Device Key is corrupted",
                detail: nil,
                recoverySuggestion: "Replace it and install the new public key on the Host.")
        case .rsaKeyCorrupt:
            TransportErrorPresentation(
                summary: "The RSA Key is corrupted",
                detail: nil,
                recoverySuggestion:
                    "Replace it and register the new public key on every Host that uses it.")
        case .rsaSignatureUnsupported:
            TransportErrorPresentation(
                summary: "The Host does not accept RSA-SHA2-512",
                detail: nil,
                recoverySuggestion:
                    "Enable rsa-sha2-512 signatures on the Host, or choose another "
                    + "authentication method.")
        case .hostKeyRejected:
            TransportErrorPresentation(
                summary: "The host key is not trusted",
                detail: nil,
                recoverySuggestion: "Verify it before reconnecting.")
        case .hostKeyMismatch:
            TransportErrorPresentation(
                summary: "The host key changed",
                detail: nil,
                recoverySuggestion: "Verify the machine before updating trust.")
        case .socketNotFound(let path):
            TransportErrorPresentation(
                summary: "Herdr TUI was not found",
                detail: path,
                recoverySuggestion: "Install herdr on this Host, or check its session.")
        case .herdrBinaryNotFound:
            TransportErrorPresentation(
                summary: "herdr is not on this Host's SSH PATH",
                detail: nil,
                recoverySuggestion:
                    "Homebrew installs are often at /opt/homebrew/bin or /home/linuxbrew/.linuxbrew/bin — "
                    + "put that directory on the account's non-interactive PATH, "
                    + "or symlink herdr into ~/.local/bin.")
        case .streamLocalOpenFailed:
            TransportErrorPresentation(
                summary: "Herdr TUI is not running on this Host",
                detail: nil,
                recoverySuggestion: "If it is running, check SSH stream-local forwarding.")
        case .herdrNotRunning:
            TransportErrorPresentation(
                summary: "Herdr TUI is not running on this Host",
                detail: nil,
                recoverySuggestion: nil)
        case .herdrSessionNotFound(let path):
            TransportErrorPresentation(
                summary: "This herdr session doesn't exist on the Host",
                detail: path,
                recoverySuggestion:
                    "Start it on the Host, or pick another session on the Host page.")
        case .protocolVersionMismatch(let server, let supported):
            TransportErrorPresentation(
                summary: "Incompatible Herdr TUI protocol",
                detail: "Herdr TUI speaks protocol \(server); this app needs at least \(supported)",
                recoverySuggestion: "Update herdr on the Host.")
        case .zellijNotInstalled:
            TransportErrorPresentation(
                summary: "Zellij is not installed on this Host", detail: nil,
                recoverySuggestion: "Install Zellij 0.46 or later on the Host.")
        case .zellijTooOld(let found):
            TransportErrorPresentation(
                summary: "Zellij on this Host is too old",
                detail: "Zellij \(found) is too old. Waycar needs 0.46 or later.",
                recoverySuggestion: "Update Zellij on the Host.")
        case .tmuxNotInstalled:
            TransportErrorPresentation(
                summary: "tmux is not installed on this Host",
                detail: nil,
                recoverySuggestion: "Install tmux 3.2 or later, or herdr.")
        case .tmuxTooOld(let found):
            TransportErrorPresentation(
                summary: "tmux is too old",
                detail: "This Host has tmux \(found); Waycar needs 3.2 or later",
                recoverySuggestion: "Update tmux on the Host.")
        case .coreNotInstalled:
            TransportErrorPresentation(
                summary: "Herdr Core is not installed on this Host",
                detail: nil,
                recoverySuggestion: "Install herdr-core on the Host, or use Herdr TUI or tmux.")
        case .coreNotRunning:
            TransportErrorPresentation(
                summary: "Herdr Core is not running on this Host",
                detail: nil,
                recoverySuggestion: nil)
        case .coreNeedsUpdate(let detail):
            TransportErrorPresentation(
                summary: "Herdr Core on this Host is too old",
                detail: detail,
                recoverySuggestion: "Update herdr-core on the Host with `herdr-core update`.")
        case .coreNeedsWaycarUpdate:
            TransportErrorPresentation(
                summary: "This version of Waycar is too old for Herdr Core on this Host",
                detail: nil,
                recoverySuggestion: "Update Waycar.")
        case .coreRefused(let message, let hint):
            TransportErrorPresentation(
                summary: "Herdr Core refused the connection",
                detail: hint.isEmpty ? message : "\(message) \(hint)",
                recoverySuggestion: nil)
        case .homeDirectoryUnresolvable(let detail):
            TransportErrorPresentation(
                summary: "The remote home directory could not be resolved",
                detail: detail,
                recoverySuggestion: nil)
        case .invalidDirectoryPath(let path):
            TransportErrorPresentation(
                summary: "That folder path cannot be opened",
                detail: path,
                recoverySuggestion: "Pick a folder from the list instead of typing a path.")
        case .eventsChannelAlreadyOpen, .terminalChannelAlreadyOpen:
            TransportErrorPresentation(
                summary: "The connection is busy",
                detail: nil,
                recoverySuggestion: "Close the other terminal before reconnecting.")
        case .timedOut:
            TransportErrorPresentation(
                summary: "Connection timed out",
                detail: nil,
                recoverySuggestion: nil)
        case .cancelled:
            TransportErrorPresentation(
                summary: "Connection cancelled",
                detail: nil,
                recoverySuggestion: nil)
        case .malformedResponse(let payload):
            TransportErrorPresentation(
                summary: "herdr returned an invalid response",
                detail: payload,
                recoverySuggestion: "Check its version.")
        case .apiRejected(let code, let message):
            TransportErrorPresentation(
                summary: "herdr rejected the request",
                detail: "\(message) (\(code))",
                recoverySuggestion: nil)
        case .moshSessionFailed(let detail):
            TransportErrorPresentation(
                summary: "The mosh session failed",
                detail: detail,
                recoverySuggestion: "Sessions will use SSH instead.")
        case .channelFailed(let detail):
            TransportErrorPresentation(
                summary: "Connection dropped",
                detail: detail,
                recoverySuggestion: nil)
        }
    }

    /// A changed host key is a security refusal, not an ordinary outage.
    /// Nested first-hop failures keep that classification: a Jump Host key
    /// change is still a host-key refusal.
    var isHostKeySecurityFailure: Bool {
        switch self {
        case .hostKeyMismatch: true
        case .jumpHostFailed(let underlying): underlying.isHostKeySecurityFailure
        default: false
        }
    }

    /// The runtime this failure says is installed but stopped, which the
    /// user can start with one tap (#389): Herdr TUI for a missing server
    /// (`.herdrNotRunning`) or a stale socket (`.streamLocalOpenFailed`),
    /// Herdr Core for `.coreNotRunning`. A stopped runtime is a normal state
    /// (a Host restart stops it), so its rows read calm. nil for everything
    /// else, `.herdrSessionNotFound` included: starting would create that
    /// session.
    var startableRuntime: HostBackend? {
        switch self {
        case .herdrNotRunning, .streamLocalOpenFailed: .herdr
        case .coreNotRunning: .core
        default: nil
        }
    }

    /// The connection stopped on a host key the user has to decide about:
    /// never trusted, or changed — on the Host or on its Jump Host. The
    /// Console never prompts, so only the Host page's preflight can ask.
    var needsHostKeyDecision: Bool {
        switch self {
        case .hostKeyRejected, .hostKeyMismatch: true
        case .jumpHostFailed(let underlying): underlying.needsHostKeyDecision
        default: false
        }
    }

    private static func jumpHostPresentation(
        _ underlying: TransportError
    ) -> TransportErrorPresentation {
        switch underlying {
        case .jumpHostFailed:
            underlying.presentation
        case .sshUnreachable(let detail):
            TransportErrorPresentation(
                summary: "Jump Host unavailable",
                detail: detail,
                recoverySuggestion:
                    "Check that the Jump Host is awake and reachable, then verify its address and port.")
        case .authenticationFailed:
            TransportErrorPresentation(
                summary: "The Jump Host rejected authentication",
                detail: nil,
                recoverySuggestion: "Update the Jump Host's credentials or authorized key.")
        case .passwordLoginUnavailable:
            TransportErrorPresentation(
                summary: "The Jump Host accepts only keys",
                detail: nil,
                recoverySuggestion: "Authorize a key on both machines, then choose Device Key in Edit Host.")
        case .hostKeyRejected:
            TransportErrorPresentation(
                summary: "The Jump Host's key is not trusted",
                detail: nil,
                recoverySuggestion: "Verify it before reconnecting.")
        case .hostKeyMismatch:
            TransportErrorPresentation(
                summary: "The Jump Host's key changed",
                detail: nil,
                recoverySuggestion: "Verify the machine before updating trust.")
        case .tcpForwardingUnavailable:
            TransportErrorPresentation(
                summary: "SSH TCP forwarding is disabled on the Jump Host",
                detail: nil,
                recoverySuggestion: "Enable it on the Jump Host.")
        case .timedOut:
            TransportErrorPresentation(
                summary: "The Jump Host did not answer in time",
                detail: nil,
                recoverySuggestion: nil)
        case .cancelled:
            TransportErrorPresentation(
                summary: "Jump Host connection cancelled",
                detail: nil,
                recoverySuggestion: nil)
        case .channelFailed(let detail):
            TransportErrorPresentation(
                summary: "The Jump Host connection dropped",
                detail: detail,
                recoverySuggestion: nil)
        case .deviceKeyCorrupt, .rsaKeyCorrupt:
            underlying.presentation
        case .rsaSignatureUnsupported:
            TransportErrorPresentation(
                summary: "The Jump Host does not accept RSA-SHA2-512",
                detail: nil,
                recoverySuggestion:
                    "Enable rsa-sha2-512 signatures on the Jump Host, or choose another "
                    + "authentication method.")
        default:
            TransportErrorPresentation(
                summary: "Jump Host: \(underlying.presentation.summary)",
                detail: underlying.presentation.detail,
                recoverySuggestion: nil)
        }
    }
}
