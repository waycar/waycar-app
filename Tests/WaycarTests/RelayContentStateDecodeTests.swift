import Foundation
import Testing

@testable import Waycar

/// Decodes relay-assembled `content-state` bytes with the exact decoder
/// ActivityKit uses (default `JSONDecoder`), proving a pushed update cannot
/// be silently dropped by an OS-side decode mismatch.
@Suite("Relay content-state decode")
struct RelayContentStateDecodeTests {
    /// The `content-state` value, byte for byte, from the APNs body that
    /// `relay/src/worker.js` (`buildLiveActivityApnsBody`) splices for a
    /// `liveactivity` update push carrying counts 9/1/0 and the first valid
    /// envelope of `plugin/test-vectors/live-activity-content-v1.json`. The
    /// relay embeds the envelope string unparsed, so these are not bytes any
    /// Swift or Node encoder would produce. Captured by driving the relay's
    /// fetch handler with APNs stubbed; `relay/test/worker.test.js` pins the
    /// splice layout.
    private static let relayContentState = #"""
        {"counts":{"working":9,"blocked":1,"done":0},"envelope":{"v":1,"kid":"Yw3NKWbEM2Y","n":"AAECAwQFBgcICQoL","ct":"PCC3fKCLtmive8zwk4IRA-f0vRaTFz4JXALHqT8ZYdxkMpTe2Jco6EWGU8_780lMmypCt3ihzKhU_kR-Os_XmplIqh_x6wSEsspN4F9mmmndO0aE7t20zEfd_6sdns2tLk_8AhndL5Ao-r4zalkDCNUVCdiTpEb_b8V1muOfDW_JcH2bmPWjPHuVapsfty6yFNjBQxcrojc8fcU5e-Kl_ybmXUBWC9nG"}}
        """#

    @Test func decodesRelayAssembledContentState() throws {
        let state = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self,
            from: Data(Self.relayContentState.utf8))

        #expect(state.counts == .init(working: 9, blocked: 1, done: 0, idle: 0))
        let sealed = LiveActivityVectorFile.shared.valid[0].envelope
        let expected = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.Envelope.self, from: Data(sealed.utf8))
        #expect(state.envelope == expected)
    }
}
