import Foundation
import Testing

@testable import Waycar

@Suite("herdr-core error mapping", .timeLimit(.minutes(1)))
struct CoreErrorsTests {
    private func error(_ kind: String, message: String = "core says", hint: String = "") -> CoreRPCError {
        CoreRPCError(code: -32000, kind: kind, message: message, hint: hint)
    }

    static let rows: [(String, CoreErrors.Subject, String)] = [
        ("not_found", .agent, "agent_not_found"),
        ("not_found", .pane, "pane_not_found"),
        ("finished", .agent, "agent_not_found"),
        ("finished", .pane, "pane_not_found"),
        ("blocked", .agent, "agent_blocked"),
        ("blocked", .pane, "agent_blocked"),
        ("unavailable", .agent, "agent_not_ready"),
        ("spawn_failed", .agent, "agent_start_failed"),
        ("name_taken", .agent, "invalid_argument"),
        ("invalid_params", .pane, "invalid_argument"),
        ("status_mismatch", .agent, "core_error"),
        ("machine_unknown", .agent, "core_error"),
        ("a_kind_from_a_newer_core", .agent, "core_error"),
        ("unsupported_generation", .agent, "core_error"),
    ]

    @Test(arguments: CoreErrorsTests.rows)
    func everyKindMapsToItsCode(kind: String, subject: CoreErrors.Subject, code: String) {
        let mapped = CoreErrors.apiError(error(kind), subject: subject)
        #expect(mapped.code == code)
    }

    @Test func mappedKindsKeepCoresMessage() {
        let blocked = error(
            "blocked", message: "t2 is blocked (permission)",
            hint: "typing would answer its dialog; read its screen first")
        #expect(
            CoreErrors.apiError(blocked)
                == HerdrAPIError(code: "agent_blocked", message: "t2 is blocked (permission)"))
        #expect(
            CoreErrors.apiError(error("invalid_params", message: "unknown key \"nope\""))
                == HerdrAPIError(code: "invalid_argument", message: "unknown key \"nope\""))
    }

    @Test func otherKindsAppendTheHintWhenThereIsOne() {
        #expect(
            CoreErrors.apiError(error("conflict", message: "document is at version 1", hint: "read doc.get"))
                == HerdrAPIError(code: "core_error", message: "document is at version 1 read doc.get"))
        #expect(
            CoreErrors.apiError(error("io", message: "disk full", hint: ""))
                == HerdrAPIError(code: "core_error", message: "disk full"))
    }

    @Test func mapConvertsCoreErrorsOnly() {
        #expect(
            CoreErrors.map(error("not_found", message: "no terminal \"t9\""), subject: .pane)
                as? HerdrAPIError == HerdrAPIError(code: "pane_not_found", message: "no terminal \"t9\""))
        #expect(
            CoreErrors.map(error("unsupported_generation", message: "generation 2"))
                as? TransportError == .coreNeedsWaycarUpdate)
        #expect(CoreErrors.map(TransportError.timedOut) as? TransportError == .timedOut)
        let api = HerdrAPIError(code: "invalid_key", message: "x")
        #expect(CoreErrors.map(api) as? HerdrAPIError == api)
        #expect(CoreErrors.map(CancellationError()) is CancellationError)
    }
}
