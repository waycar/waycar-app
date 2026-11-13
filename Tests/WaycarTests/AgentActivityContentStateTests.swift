import Foundation
import Testing

@testable import Waycar

/// ContentState must decode the contract sample with a plain default
/// `JSONDecoder` — ActivityKit uses that decoder on the APNs update, and
/// any type mismatch drops the whole update.
@Suite("Agent activity ContentState")
struct AgentActivityContentStateTests {
    /// Exact sample from docs/agents/live-activity-contract.md.
    private static let contractJSON = """
        {"counts": {"working": 2, "blocked": 1, "done": 0},
         "envelope": {"v": 1, "kid": "Yw3NKWbEM2Y", "n": "AAECAwQFBgcICQoL", "ct": "PCC3fA"}}
        """

    @Test func decodesTheContractSampleWithTheDefaultDecoder() throws {
        let state = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self, from: Data(Self.contractJSON.utf8))

        #expect(state.counts.working == 2)
        #expect(state.counts.blocked == 1)
        #expect(state.counts.done == 0)
        let envelope = try #require(state.envelope)
        #expect(envelope.v == 1)
        #expect(envelope.kid == "Yw3NKWbEM2Y")
        #expect(envelope.n == "AAECAwQFBgcICQoL")
        #expect(envelope.ct == "PCC3fA")
    }

    @Test func roundTripsThroughTheDefaultCoder() throws {
        let original = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self, from: Data(Self.contractJSON.utf8))

        let decoded = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self,
            from: try JSONEncoder().encode(original))

        #expect(decoded == original)
    }

    /// Pushes from a plugin or relay that predates `idle` omit the key;
    /// ActivityKit must still accept them.
    @Test func legacyCountsWithoutIdleDecodeAsZeroIdle() throws {
        let state = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self, from: Data(Self.contractJSON.utf8))

        #expect(state.counts.idle == 0)
    }

    @Test func idleCountDecodesAndRoundTrips() throws {
        let json = #"{"counts":{"working":1,"blocked":0,"done":0,"idle":3}}"#

        let state = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self, from: Data(json.utf8))
        let decoded = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self,
            from: try JSONEncoder().encode(state))

        #expect(state.counts == .init(working: 1, blocked: 0, done: 0, idle: 3))
        #expect(decoded == state)
    }

    @Test func absentEnvelopeDecodesAsNil() throws {
        let json = #"{"counts":{"working":0,"blocked":0,"done":1}}"#

        let state = try JSONDecoder().decode(
            AgentActivityAttributes.ContentState.self, from: Data(json.utf8))

        #expect(state.counts == .init(working: 0, blocked: 0, done: 1))
        #expect(state.envelope == nil)
    }

    /// A push-to-start names this type in `attributes-type` and carries the
    /// `attributes` the plugin builds from the Host registration; ActivityKit
    /// decodes them with its default decoder, so both must match exactly or
    /// the Host's start is silently dropped.
    @Test func pushToStartVectorDecodesAsTheActivityAttributes() throws {
        let vector = LiveActivityVectorFile.shared.pushToStart

        #expect(String(describing: AgentActivityAttributes.self) == vector.attributesType)
        let attributes = try JSONDecoder().decode(
            AgentActivityAttributes.self, from: try JSONEncoder().encode(vector.attributes))
        let hostID = try #require(UUID(uuidString: vector.hostId))
        #expect(attributes == AgentActivityAttributes(hostID: hostID.uuidString))
    }
}
