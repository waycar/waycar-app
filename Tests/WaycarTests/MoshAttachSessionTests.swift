import Foundation
import Testing

@testable import Waycar

@Suite("Mosh attach session")
struct MoshAttachSessionTests {
    /// Nothing listens on the discard port, so the server stays silent the
    /// way a firewalled mosh UDP port does.
    private static let silentBootstrap = MoshBootstrap(
        host: "127.0.0.1", udpPort: "9", key: "MDEyMzQ1Njc4OWFiY2RlZg")

    private enum OutputOutcome: Sendable {
        case finished
        case failed(any Error)
        case stillWaiting
    }

    @Test func aSilentServerFailsTheOutputAfterTheFirstContactTimeout() async {
        let session = MoshAttachSession.make(
            bootstrap: Self.silentBootstrap, cols: 80, rows: 24,
            firstContactTimeout: .milliseconds(300))

        let outcome = await withTaskGroup(of: OutputOutcome.self) { group in
            group.addTask {
                do {
                    for try await _ in session.output {}
                    return .finished
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return .stillWaiting
            }
            let first = await group.next() ?? .stillWaiting
            group.cancelAll()
            return first
        }

        guard
            case .failed(let error) = outcome,
            case .moshSessionFailed(let detail) = error as? TransportError
        else {
            Issue.record("Expected a thrown moshSessionFailed, got \(outcome)")
            await session.end()
            return
        }
        #expect(detail.contains("did not answer over UDP"))
        #expect(await session.link?.firstContact() == .timedOut)

        let elapsed = await ContinuousClock().measure {
            await session.end()
        }
        #expect(elapsed < .seconds(2))
    }
}
