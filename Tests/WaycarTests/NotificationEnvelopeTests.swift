import Foundation
import Testing

@testable import Waycar

/// Decrypt-direction tests for the notification envelope v1 (#69), driven by
/// the shared vectors in `plugin/test-vectors/notification-payload-v1.json` —
/// the same file the Node plugin tests consume for the encrypt direction, so
/// the two implementations cannot drift.
@Suite("Notification envelope")
struct NotificationEnvelopeTests {
    private static let vectors = NotificationVectorFile.shared

    /// Guards against silently loading an empty or truncated vector file;
    /// mirrors the same assertion in the Node suite.
    @Test func sharedVectorFileHasCases() {
        #expect(Self.vectors.valid.count >= 3)
        #expect(Self.vectors.invalid.count >= 10)
        #expect(Self.vectors.invalid.contains { $0.error == "decrypt_failed" })
    }

    @Test(arguments: vectors.valid)
    func decryptsValidVector(vector: NotificationVectorFile.Valid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))

        let payload = try NotificationEnvelope.decrypt(
            Data(vector.envelope.utf8), using: key)

        #expect(payload.paneID == vector.payload.paneId)
        #expect(payload.agentKind == vector.payload.agentKind)
        #expect(payload.status.rawValue == vector.payload.status)
        #expect(
            payload.timestamp
                == Date(timeIntervalSince1970: TimeInterval(vector.payload.timestamp)))
        #expect(payload.project == vector.payload.project)
        #expect(payload.title == vector.payload.title)
        #expect(payload.summary == vector.payload.summary)
        #expect(payload.attention == vector.payload.attention)
        #expect(payload.reply == vector.expectedReply)
        if let expectedBody = vector.expectedBody {
            #expect(AgentNotificationRenderer.alert(for: payload).body == expectedBody)
        }
    }

    /// The key id is derived, never stored: both ends must agree on the
    /// derivation or the extension cannot select the right Notification Key.
    @Test(arguments: vectors.valid)
    func derivesKeyID(vector: NotificationVectorFile.Valid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))
        #expect(NotificationEnvelope.keyID(for: key) == vector.keyId)
    }

    /// Undecryptable input of any shape must surface as a typed
    /// `NotificationEnvelopeError` (driving the generic-banner fallback),
    /// never as a crash or an untyped error.
    @Test(arguments: vectors.invalid)
    func rejectsInvalidVector(vector: NotificationVectorFile.Invalid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))
        do {
            _ = try NotificationEnvelope.decrypt(Data(vector.envelope.utf8), using: key)
            Issue.record("unexpectedly decrypted \(vector.name)")
        } catch {
            #expect(error.wireCode == vector.error, "\(vector.name)")
        }
    }

    /// Any non-negative integer is a valid count on the wire, but no Host
    /// can add more than the cap to the badge: the summed badge must never
    /// overflow however large the counts two Hosts send.
    @Test(arguments: [1_000.0, 9_223_372_036_854_774_784.0, 1e300])
    func clampsAnOversizedAttentionCount(attention: Double) throws {
        let key = Data(0..<32)
        let plaintext =
            #"{"pane":"w1:p1","kind":"claude","status":"blocked","ts":1753305600,"attention":"#
            + "\(attention)}"
        let envelope = try SealedEnvelopeCodec.seal(
            Data(plaintext.utf8), using: key, authenticating: Data("HERDR-NOTIFY:1".utf8))

        let payload = try NotificationEnvelope.decrypt(envelope, using: key)

        #expect(payload.attention == NotificationPayload.maximumAttention)
    }
}
