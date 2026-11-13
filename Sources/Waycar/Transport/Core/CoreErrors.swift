import Foundation

/// herdr-core's error kinds (`error.data.kind`) to the errors the UI already
/// branches on (design §7). The kind set is open: an unknown one becomes
/// `core_error` carrying core's message and hint.
enum CoreErrors {
    /// What the failing call addressed, which names the code a missing or
    /// finished terminal gets: an Agent call (`promptAgent`, `readAgent`) or
    /// a Pane call (`readPane`, `closePane`).
    enum Subject: Sendable {
        case agent
        case pane
    }

    /// The code for a kind core has no UI counterpart for.
    static let genericCode = "core_error"

    static func apiError(_ error: CoreRPCError, subject: Subject = .agent) -> HerdrAPIError {
        switch error.kind {
        case "not_found", "finished":
            let code = subject == .agent ? "agent_not_found" : "pane_not_found"
            return HerdrAPIError(code: code, message: error.message)
        case "blocked":
            return HerdrAPIError(code: "agent_blocked", message: error.message)
        case "unavailable":
            return HerdrAPIError(code: "agent_not_ready", message: error.message)
        case "spawn_failed":
            return HerdrAPIError(code: "agent_start_failed", message: error.message)
        case "name_taken", "invalid_params":
            return HerdrAPIError(code: "invalid_argument", message: error.message)
        default:
            let message =
                error.hint.isEmpty ? error.message : error.message + " " + error.hint
            return HerdrAPIError(code: genericCode, message: message)
        }
    }

    /// `error` as the Transport surfaces it: a `CoreRPCError` becomes the
    /// `HerdrAPIError` for its kind, or `TransportError.coreNeedsWaycarUpdate`
    /// for a refused protocol generation. Every other error (a
    /// `TransportError`, cancellation) passes through unchanged.
    static func map(_ error: any Error, subject: Subject = .agent) -> any Error {
        guard let core = error as? CoreRPCError else { return error }
        if core.kind == "unsupported_generation" { return TransportError.coreNeedsWaycarUpdate }
        return apiError(core, subject: subject)
    }
}
