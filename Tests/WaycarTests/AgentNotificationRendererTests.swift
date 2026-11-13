import Foundation
import Testing

@testable import Waycar

/// The service extension's whole job as a pure function: pick the right
/// Notification Key by the envelope's kid, decrypt, and rewrite the alert to
/// workspace, Agent kind, and status — or degrade to the generic fallback banner
/// on any undecryptable push (#71). Envelopes come from the shared vectors,
/// so this stays in lockstep with the plugin's encrypt direction.
@Suite("Agent notification renderer")
struct AgentNotificationRendererTests {
    private static let vectors = NotificationVectorFile.shared

    private static func record(
        forVector vector: NotificationVectorFile.Valid, named hostName: String
    ) throws -> NotificationKeyRecord {
        let key = try #require(Data(base64URLEncoded: vector.key))
        return NotificationKeyRecord(hostID: UUID(), hostName: hostName, key: key)
    }

    private static func vector(named name: String) throws -> NotificationVectorFile.Valid {
        try #require(vectors.valid.first { $0.name == name })
    }

    /// A payload from a plugin that predates the display fields: the copy
    /// degrades to the friendly Agent kind and status rather than falling
    /// back to the generic banner.
    @Test func rewritesABlockedPushWithoutDisplayFields() throws {
        let vector = try Self.vector(named: "blocked claude agent")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.title == "Claude")
        #expect(alert.body == "Blocked — waiting for input")
    }

    /// The shape the current plugin sends: the workspace leads, the friendly
    /// Agent kind trails it, and the body carries status only.
    @Test func leadsWithTheWorkspaceAndFriendlyAgentKind() throws {
        let vector = try Self.vector(named: "blocked agent with a project and a task title")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.title == "Caterm · Claude")
        #expect(alert.body == "Blocked — waiting for input")
    }

    /// The Host is the same machine on every notification and would spend the
    /// whole title on an address; it must never reach the alert.
    @Test func neverNamesTheHost() throws {
        let vector = try Self.vector(named: "blocked agent with a project and a task title")
        let record = try Self.record(forVector: vector, named: "zingerbee@192.168.31.64")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(!alert.title.contains("zingerbee"))
        #expect(!alert.body.contains("zingerbee"))
    }

    @Test func doesNotRenderTheTerminalTask() {
        let alert = AgentNotificationRenderer.alert(
            workspace: "Waycar", agentKind: "codex", status: .done)

        #expect(alert == AgentNotificationAlert(title: "Waycar · Codex", body: "Done"))
    }

    @Test func namesMuseFriendly() {
        let alert = AgentNotificationRenderer.alert(
            workspace: "Waycar", agentKind: "muse", status: .done)

        #expect(alert.title == "Waycar · Muse")
    }

    /// Every kind New Agent can launch gets an explicit label; the raw
    /// protocol id is only the fallback for kinds Waycar does not know.
    @Test(arguments: SupportedAgentKind.allCases)
    func labelsEverySupportedKind(kind: SupportedAgentKind) {
        #expect(AgentNotificationIdentity.kindLabel(kind.rawValue) != kind.rawValue)
    }

    /// Best-effort fields: whitespace-only is the same as absent, so a Host
    /// that resolved a blank never renders a dangling separator.
    @Test func treatsBlankDisplayFieldsAsAbsent() {
        let alert = AgentNotificationRenderer.alert(
            workspace: "  ", agentKind: "claude", status: .blocked)

        #expect(alert.title == "Claude")
        #expect(alert.body == "Blocked — waiting for input")
    }

    /// An unrecognized status still names itself factually.
    @Test func rendersAnUnrecognizedStatusFactually() {
        let alert = AgentNotificationRenderer.alert(
            workspace: "waycar", agentKind: "claude", status: AgentStatus(rawValue: "exited"))

        #expect(alert.body == "Status: exited")
    }

    @Test func rewritesADonePush() throws {
        let vector = try Self.vector(named: "done codex agent under a second key")
        let record = try Self.record(forVector: vector, named: "vps-1")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.title == "Codex")
        #expect(alert.body == "Done")
    }

    /// The status set is open on the wire; an unrecognized value must still
    /// render factually rather than fall back or crash.
    @Test func passesAnUnrecognizedStatusThrough() throws {
        let vector = try Self.vector(named: "unrecognized status string passes through leniently")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.body == "Status: exited")
    }

    /// An Agent Summary says what the Blocked Agent wants, after the status
    /// word, and the display fields still lead the title.
    @Test func rendersABlockedPushWithItsAgentSummary() throws {
        let vector = try Self.vector(
            named: "blocked agent with an Agent Summary, between the title and the attention count")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.title == "Caterm · Claude")
        #expect(alert.body == "Blocked: approve merge of PR #512")
    }

    @Test func rendersADonePushWithItsAgentSummary() throws {
        let vector = try Self.vector(named: "done agent carrying only an Agent Summary")
        let record = try Self.record(forVector: vector, named: "vps-1")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert.body == "Done: added upload retries, tests pass")
    }

    /// The one-sentence summary runs up to 100 characters and reaches the
    /// alert whole; the app never re-trims it to the old few-word shape.
    @Test func keepsAFullLengthAgentSummaryIntact() {
        let sentence =
            "Finished the VoiceOver audit: fixed 14 missing labels across Settings and the composer"
        #expect(
            AgentNotificationRenderer.alert(
                workspace: "Waycar", agentKind: "gemini", status: .done, summary: sentence
            ).body == "Done: \(sentence)")
    }

    /// A blank summary is no summary; a status the renderer does not know
    /// stays factual rather than borrowing the summary's claim.
    @Test func ignoresABlankSummaryAndOneOnAnUnrecognizedStatus() {
        #expect(
            AgentNotificationRenderer.alert(
                workspace: "Waycar", agentKind: "claude", status: .blocked, summary: " \n")
                == AgentNotificationRenderer.alert(
                    workspace: "Waycar", agentKind: "claude", status: .blocked))
        #expect(
            AgentNotificationRenderer.alert(
                workspace: "Waycar", agentKind: "claude",
                status: AgentStatus(rawValue: "exited"), summary: "shipped it"
            ).body == "Status: exited")
    }

    /// Several registered Hosts means several Notification Keys; the kid in
    /// the cleartext header must select the right one without trial
    /// decryption. Picking the wrong key yields the generic fallback, so
    /// each envelope rendering its own payload is the proof.
    @Test func selectsTheRightKeyAmongSeveralHostsByKid() throws {
        let blocked = try Self.vector(named: "blocked claude agent")
        let done = try Self.vector(named: "done codex agent under a second key")
        let records = [
            try Self.record(forVector: blocked, named: "mac-studio"),
            try Self.record(forVector: done, named: "vps-1"),
        ]

        let blockedAlert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": blocked.envelope], keys: records)
        let doneAlert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": done.envelope], keys: records)

        #expect(blockedAlert.title == "Claude")
        #expect(blockedAlert.body == "Blocked — waiting for input")
        #expect(doneAlert.title == "Codex")
        #expect(doneAlert.body == "Done")
    }

    @Test func unknownKidFallsBackToTheGenericBanner() throws {
        let blocked = try Self.vector(named: "blocked claude agent")
        let done = try Self.vector(named: "done codex agent under a second key")
        // Only the *other* Host's key is registered, so the kid matches nothing.
        let records = [try Self.record(forVector: done, named: "vps-1")]

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": blocked.envelope], keys: records)

        #expect(alert == AgentNotificationRenderer.fallback)
    }

    @Test func noRegisteredKeysFallsBack() throws {
        let vector = try Self.vector(named: "blocked claude agent")

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [])

        #expect(alert == AgentNotificationRenderer.fallback)
    }

    /// Every invalid vector — broken framing, future version, tampered
    /// material, wrong key, garbage plaintext — must degrade to the generic
    /// fallback banner even when a plausible key is registered.
    @Test(arguments: vectors.invalid)
    func undecryptableVectorFallsBack(vector: NotificationVectorFile.Invalid) throws {
        let key = try #require(Data(base64URLEncoded: vector.key))
        let record = NotificationKeyRecord(hostID: UUID(), hostName: "mac-studio", key: key)

        let alert = AgentNotificationRenderer.alert(
            userInfo: ["envelope": vector.envelope], keys: [record])

        #expect(alert == AgentNotificationRenderer.fallback, "\(vector.name)")
    }

    @Test func pushWithoutAnEnvelopeFallsBack() throws {
        let vector = try Self.vector(named: "blocked claude agent")
        let record = try Self.record(forVector: vector, named: "mac-studio")

        #expect(
            AgentNotificationRenderer.alert(userInfo: [:], keys: [record])
                == AgentNotificationRenderer.fallback)
        #expect(
            AgentNotificationRenderer.alert(userInfo: ["envelope": 42], keys: [record])
                == AgentNotificationRenderer.fallback)
    }

    /// The fallback copy is generic, so an intercepted
    /// or forged push never renders attacker-chosen text.
    @Test func fallbackCopyIsGeneric() {
        #expect(AgentNotificationRenderer.fallback.title == "Waycar")
        #expect(AgentNotificationRenderer.fallback.body == "Agent update")
    }
}
