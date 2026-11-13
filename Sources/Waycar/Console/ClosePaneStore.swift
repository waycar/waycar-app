import Foundation
import Observation

/// The Agent detail screen's close-pane action (#13, User Story 9). The
/// screen confirms first only when Closed Sessions could not bring the
/// conversation back (`ClosedSession.resumesConversation(of:)`, #185);
/// otherwise Close Agent calls `closePane()` at once. The closed pane
/// disappears from the Console through its normal snapshot/delta machinery,
/// so this store only fires the RPC and reports its outcome; the screen
/// dismisses itself on `.closed`.
///
/// Kept off the SSH types (standing repo rule): it talks to an injected
/// closure over the `ConsoleStore`, so it is testable against a scripted
/// transport.
@MainActor
@Observable
final class ClosePaneStore {
    enum State: Equatable {
        /// No close in flight; the pane is untouched.
        case idle
        /// A `pane.close` RPC is in flight.
        case closing
        /// The last close failed; the message is user-facing and the pane is
        /// left untouched.
        case failed(String)
        /// The close succeeded; the screen dismisses.
        case closed
    }

    private(set) var state: State = .idle

    private let close: () async throws -> Void
    /// In-flight guard flipped synchronously before the first await, so a
    /// repeated Close Agent cannot fire `pane.close` twice (mirrors #10/#12).
    private var isClosing = false

    init(close: @escaping () async throws -> Void) {
        self.close = close
    }

    /// Fires `pane.close`. On success the state flips to `.closed` for the
    /// screen to dismiss; on failure the pane is left untouched and the error
    /// surfaces.
    func closePane() async {
        guard !isClosing else { return }
        isClosing = true
        state = .closing
        defer { isClosing = false }
        do {
            try await close()
            state = .closed
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case let apiError as HerdrAPIError:
            "herdr rejected the close: \(apiError.message)"
        default:
            "Closing the pane failed: \(error)"
        }
    }
}
