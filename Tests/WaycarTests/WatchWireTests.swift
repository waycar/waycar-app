import Foundation
import Testing

@testable import Waycar

/// The iPhone ↔ watch wire: every value round-trips through the versioned
/// envelope, other versions and unknown discriminators fail loudly, and the
/// state's derived counts and host naming follow the design.
@Suite("Watch wire")
struct WatchWireTests {
    // MARK: Fixtures

    /// A whole-second date, so ISO 8601 round-trips it exactly.
    private static let date = Date(timeIntervalSince1970: 1_791_800_000)
    /// An Agent id.
    private static let agent = WatchAgentID(
        hostID: UUID(uuidString: "6F1C2B0E-3D4A-4B5C-8D9E-0F1A2B3C4D5E") ?? UUID(), paneID: "w1:p2")
    /// A message or prompt id.
    private static let messageID = UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()

    /// A row with the given status.
    private static func row(_ status: String, pane: String = "p") -> WatchAgentRow {
        WatchAgentRow(
            id: WatchAgentID(hostID: agent.hostID, paneID: pane), title: "site · codex",
            status: status, statusSince: date, hostName: "studio", isChatMode: false)
    }

    /// A Host with the given name.
    private static func host(_ name: String) -> WatchHost {
        WatchHost(id: UUID(), name: name, condition: .confirmed)
    }

    /// A populated state.
    private static let state = WatchState(
        generatedAt: date,
        hosts: [WatchHost(id: agent.hostID, name: "studio", condition: .connecting)],
        rows: [
            row("blocked"),
            WatchAgentRow(
                id: agent, title: "site · claude", status: "working", statusSince: nil,
                hostName: "studio", isChatMode: true),
        ],
        voiceTranscription: true)

    /// Encodes then decodes through the codec.
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try WatchWireCodec.decode(T.self, from: WatchWireCodec.encode(value))
    }

    /// The JSON object the codec wrote.
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Round trips

    @Test(arguments: [
        WatchRequest.refresh,
        .latest(agent),
        .blockedPrompt(agent),
        .answer(agent, promptID: messageID, .allow),
        .answer(agent, promptID: messageID, .deny),
        .send(messageID: messageID, agent, text: "ship it"),
        .voice(messageID: messageID, agent),
    ])
    func requestRoundTrips(_ request: WatchRequest) throws {
        #expect(try roundTrip(request) == request)
    }

    @Test(arguments: [
        WatchReply.received,
        .state(state),
        .state(.empty),
        .latest(nil),
        .latest(WatchLatest(source: .summary, text: "Fixed the build", lastReply: nil, isStale: false)),
        .latest(
            WatchLatest(
                source: .summary, text: "Running the tests.",
                lastReply: "Done. Tests pass.\n\nDeployed to staging.", isStale: false)),
        .latest(WatchLatest(source: .reply, text: "Done. Tests pass.", lastReply: nil, isStale: true)),
        .blockedPrompt(nil),
        .blockedPrompt(
            WatchBlockedPrompt(
                promptID: messageID, approval: .allow, command: "npm test", holdReason: nil)),
        .blockedPrompt(
            WatchBlockedPrompt(
                promptID: messageID, approval: .hold, command: "rm -rf build", holdReason: "Risky")),
        .blockedPrompt(
            WatchBlockedPrompt(promptID: messageID, approval: .readOnly, command: nil, holdReason: nil)),
        .answerResult(.sent),
        .answerResult(.promptChanged),
        .answerResult(.refused),
        .answerResult(.failed),
        .failure("Can't reach studio"),
    ])
    func replyRoundTrips(_ reply: WatchReply) throws {
        #expect(try roundTrip(reply) == reply)
    }

    @Test(arguments: [
        WatchDelivery.sent(text: "ship it"),
        .notSent(reason: "iPhone didn't answer"),
        .unknown,
        .keptAsDraft(reason: .blocked),
        .keptAsDraft(reason: .signInRequired),
        .keptAsDraft(reason: .folderTrustRequired),
        .noWords,
    ])
    func deliveryAndEventRoundTrip(_ delivery: WatchDelivery) throws {
        #expect(try roundTrip(delivery) == delivery)
        let event = WatchEvent.delivery(messageID: Self.messageID, Self.agent, delivery)
        #expect(try roundTrip(event) == event)
    }

    @Test func hostConditionsAndVoiceFileRoundTrip() throws {
        for condition in [WatchHostCondition.confirmed, .connecting, .unreachable] {
            let host = WatchHost(id: Self.agent.hostID, name: "studio", condition: condition)
            #expect(try roundTrip(host) == host)
        }
        let file = WatchVoiceFile(messageID: Self.messageID, agentID: Self.agent, duration: 4.25)
        #expect(try roundTrip(file) == file)
    }

    // MARK: Envelope shape

    @Test func wrapsBodyInVersionedEnvelopeWithISO8601Dates() throws {
        let object = try json(WatchWireCodec.encode(Self.state))
        #expect(object["v"] as? Int == 1)
        let body = try #require(object["body"] as? [String: Any])
        #expect(body["generatedAt"] as? String == "2026-10-12T10:13:20Z")
    }

    @Test func associatedValueEnumsUseTypeDiscriminator() throws {
        let request = WatchRequest.send(messageID: Self.messageID, Self.agent, text: "hi")
        let body = try #require(try json(WatchWireCodec.encode(request))["body"] as? [String: Any])
        #expect(body["type"] as? String == "send")
        #expect(body["text"] as? String == "hi")
        #expect(body["messageID"] as? String == Self.messageID.uuidString)
    }

    // MARK: Rejections

    @Test func rejectsOtherVersions() {
        #expect(throws: WatchWireError.versionMismatch(2)) {
            try WatchWireCodec.decode(WatchRequest.self, from: Data(#"{"v":2,"body":{"type":"refresh"}}"#.utf8))
        }
        #expect(throws: WatchWireError.versionMismatch(0)) {
            try WatchWireCodec.decode(WatchRequest.self, from: Data(#"{"v":0,"body":"anything"}"#.utf8))
        }
    }

    @Test(arguments: [
        #"{"v":1,"body":{"type":"teleport"}}"#,
        #"{"v":1,"body":{"type":"sent","text":"x"}}"#,
        #"{"v":1,"body":{}}"#,
    ])
    func rejectsUnknownRequestDiscriminator(_ json: String) {
        #expect(throws: WatchWireError.malformed) {
            try WatchWireCodec.decode(WatchRequest.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsUnknownDiscriminatorsOnEveryEnum() {
        let body = Data(#"{"v":1,"body":{"type":"future"}}"#.utf8)
        #expect(throws: WatchWireError.malformed) { try WatchWireCodec.decode(WatchReply.self, from: body) }
        #expect(throws: WatchWireError.malformed) { try WatchWireCodec.decode(WatchDelivery.self, from: body) }
        #expect(throws: WatchWireError.malformed) { try WatchWireCodec.decode(WatchEvent.self, from: body) }
    }

    @Test(arguments: [
        "not json",
        "",
        #"{"body":{"type":"refresh"}}"#,
        #"{"v":"1","body":{"type":"refresh"}}"#,
        #"{"v":1}"#,
        #"[1]"#,
    ])
    func rejectsJunk(_ text: String) {
        #expect(throws: WatchWireError.malformed) {
            try WatchWireCodec.decode(WatchRequest.self, from: Data(text.utf8))
        }
    }

    @Test func rejectsMissingPayloadAndWrongType() throws {
        #expect(throws: WatchWireError.malformed) {
            try WatchWireCodec.decode(WatchRequest.self, from: Data(#"{"v":1,"body":{"type":"latest"}}"#.utf8))
        }
        let request = try WatchWireCodec.encode(WatchRequest.refresh)
        #expect(throws: WatchWireError.malformed) { try WatchWireCodec.decode(WatchState.self, from: request) }
        let host = Data(
            #"{"v":1,"body":{"id":"\#(Self.agent.hostID.uuidString)","name":"x","condition":"asleep"}}"#.utf8)
        #expect(throws: WatchWireError.malformed) { try WatchWireCodec.decode(WatchHost.self, from: host) }
    }

    // MARK: Derived state

    @Test func countsBucketStatusesAndUnknownCountsAsIdle() {
        let statuses = ["blocked", "done", "done", "working", "working", "working", "idle", "unknown", "", "Blocked"]
        let state = WatchState(
            generatedAt: Self.date, hosts: [],
            rows: statuses.enumerated().map { Self.row($1, pane: "p\($0)") }, voiceTranscription: false)
        #expect(state.counts == WatchCounts(blocked: 1, done: 2, working: 3, idle: 4))
        #expect(WatchState.empty.counts == WatchCounts())
    }

    @Test func showsHostNamesOnlyForMoreThanOneHost() {
        func state(_ hosts: [WatchHost]) -> WatchState {
            WatchState(generatedAt: Self.date, hosts: hosts, rows: [], voiceTranscription: false)
        }
        #expect(!state([]).showsHostNames)
        #expect(!state([Self.host("studio")]).showsHostNames)
        #expect(state([Self.host("studio"), Self.host("lab")]).showsHostNames)
    }

    /// The watch keeps its rows for a Host the incoming state does not
    /// confirm and lists nothing for (a phone relaunched cold), so a Blocked
    /// row keeps its status and never buzzes again; a confirmed Host's
    /// empty list and a listing Host's rows are taken as sent.
    @Test func keepsShownRowsOnlyForUnconfirmedHostsListingNothing() {
        let shown = Self.state
        func incoming(_ condition: WatchHostCondition, rows: [WatchAgentRow] = []) -> WatchState {
            WatchState(
                generatedAt: Self.date.addingTimeInterval(60),
                hosts: [WatchHost(id: Self.agent.hostID, name: "studio", condition: condition)],
                rows: rows, voiceTranscription: true)
        }

        let connecting = incoming(.connecting).keepingRows(from: shown)
        #expect(connecting.rows == shown.rows)
        #expect(connecting.generatedAt == Self.date.addingTimeInterval(60))
        #expect(incoming(.unreachable).keepingRows(from: shown).rows == shown.rows)
        #expect(incoming(.confirmed).keepingRows(from: shown).rows.isEmpty)
        let listed = incoming(.connecting, rows: [Self.row("done", pane: "other")])
        #expect(listed.keepingRows(from: shown) == listed)
        #expect(incoming(.connecting).keepingRows(from: nil).rows.isEmpty)
    }

    // MARK: Progress

    @Test(arguments: [
        WatchProgress(done: 3, total: 7, phase: nil, staleAfter: date),
        WatchProgress(done: nil, total: nil, phase: "verifying", staleAfter: date),
        WatchProgress(done: nil, total: nil, phase: nil, staleAfter: nil),
    ])
    func progressRoundTrips(_ progress: WatchProgress) throws {
        #expect(try roundTrip(progress) == progress)
        let row = WatchAgentRow(
            id: Self.agent, title: "site · claude", status: "working", statusSince: nil,
            hostName: "studio", isChatMode: false, progress: progress)
        #expect(try roundTrip(row) == row)
    }

    @Test func rowWithoutProgressKeyDecodesAsNoBar() throws {
        let data = Data(
            #"{"v":1,"body":{"id":{"hostID":"\#(Self.agent.hostID.uuidString)","paneID":"p"},"title":"t","status":"working","hostName":"studio","isChatMode":false}}"#
                .utf8)
        let row = try WatchWireCodec.decode(WatchAgentRow.self, from: data)
        #expect(row.progress == nil)
        #expect(row.status == "working")
    }

    @Test func progressPendingFollowsAgentProgressRules() {
        #expect(WatchProgress(done: nil, total: nil, phase: nil, staleAfter: nil).isPending)
        #expect(!WatchProgress(done: 3, total: 7, phase: nil, staleAfter: nil).isPending)
        #expect(!WatchProgress(done: nil, total: nil, phase: "wrapping_up", staleAfter: nil).isPending)
        #expect(WatchProgress(done: nil, total: nil, phase: "dreaming", staleAfter: nil).isPending)
        #expect(WatchProgress(done: 8, total: 7, phase: nil, staleAfter: nil).isPending)
        #expect(WatchProgress(done: 0, total: 0, phase: nil, staleAfter: nil).isPending)
        #expect(WatchProgress(done: 3, total: nil, phase: nil, staleAfter: nil).isPending)
        #expect(!WatchProgress(done: 8, total: 7, phase: "exploring", staleAfter: nil).isPending)
    }

    @Test func progressIsStaleFromStaleAfter() {
        let progress = WatchProgress(done: 1, total: 2, phase: nil, staleAfter: Self.date)
        #expect(!progress.isStale(at: Self.date.addingTimeInterval(-1)))
        #expect(progress.isStale(at: Self.date))
        #expect(progress.isStale(at: Self.date.addingTimeInterval(60)))
        let pending = WatchProgress(done: nil, total: nil, phase: nil, staleAfter: nil)
        #expect(!pending.isStale(at: Self.date))
    }

    /// Latest text splits on blank lines, and a long paragraph between its
    /// lines, so the watch never lays out one huge `Text`.
    @Test func latestTextSplitsIntoBoundedParagraphs() {
        #expect(WatchLatest.paragraphs("One.\n\n\n\nTwo\nlines.") == ["One.", "Two\nlines."])
        let line = String(repeating: "a", count: 100)
        let long = Array(repeating: line, count: 60).joined(separator: "\n")
        let parts = WatchLatest.paragraphs(long)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.utf8.count <= WatchLatest.paragraphByteLimit })
        #expect(parts.joined(separator: "\n") == long)
    }
}
