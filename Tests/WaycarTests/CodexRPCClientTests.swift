import Foundation
import Testing

@testable import Waycar

@Suite("Codex bidirectional RPC", .timeLimit(.minutes(1)))
struct CodexRPCClientTests {
    private func fixture(timeout: Duration = .seconds(5)) async throws -> (CodexMemoryChannel, CodexRPCClient) {
        let channel = CodexMemoryChannel()
        let socket = try await CodexWebSocket.connect(channel: channel)
        return (channel, await CodexRPCClient.connect(webSocket: socket, requestTimeout: timeout))
    }

    private func messages(_ channel: CodexMemoryChannel, count: Int) async throws -> [JSONValue] {
        try await channel.waitForFrames(count).map {
            try JSONDecoder().decode(JSONValue.self, from: $0.payload)
        }
    }

    private func feed(_ value: JSONValue, to channel: CodexMemoryChannel) async throws {
        let data = try JSONEncoder().encode(value)
        await channel.feed(CodexMemoryChannel.serverFrame(opcode: 1, payload: data))
    }

    @Test func matchesOutOfOrderAndNullResults() async throws {
        let (channel, client) = try await fixture()
        let first = Task { try await client.request(method: "first", params: .object(["x": .number(1)])) }
        let second = Task { try await client.request(method: "second") }
        let sent = try await messages(channel, count: 2)
        for message in sent.reversed() {
            #expect(message["jsonrpc"] == nil)
            let method = try #require(message["method"]?.stringValue)
            if method == "second" { #expect(message["params"] == nil) }
            try await feed(.object([
                "id": try #require(message["id"]),
                "result": method == "first" ? .string("first result") : .null,
                "unknown": .bool(true)
            ]), to: channel)
        }
        #expect(try await first.value == .string("first result"))
        #expect(try await second.value == .null)
        await client.close()
    }

    @Test func typedRemoteError() async throws {
        let (channel, client) = try await fixture()
        let request = Task { try await client.request(method: "fail") }
        let sent = try #require(try await messages(channel, count: 1).first)
        try await feed(.object([
            "id": try #require(sent["id"]),
            "error": .object(["code": .number(-32001), "message": .string("denied"), "data": .object(["why": .string("policy")])])
        ]), to: channel)
        await #expect(throws: CodexRPCError(code: -32001, message: "denied", data: .object(["why": .string("policy")]))) {
            _ = try await request.value
        }
        await client.close()
    }

    @Test func notificationsServerRequestsAndResponses() async throws {
        let (channel, client) = try await fixture()
        var events = client.events.makeAsyncIterator()
        await channel.feed(CodexMemoryChannel.serverFrame(text: #"{"method":"thread/started","params":{"id":"thread"},"future":true}"#))
        #expect(try await events.next() == .notification(method: "thread/started", params: .object(["id": .string("thread")])))
        // i64 max must round-trip exactly rather than through Double.
        await channel.feed(CodexMemoryChannel.serverFrame(text: #"{"id":9223372036854775807,"method":"item/commandExecution/requestApproval","params":{"command":"ls"}}"#))
        #expect(try await events.next() == .serverRequest(
            id: .integer(Int64.max), method: "item/commandExecution/requestApproval",
            params: .object(["command": .string("ls")])))
        try await client.respond(to: .integer(Int64.max), result: .object(["decision": .string("accept")]))
        await channel.feed(CodexMemoryChannel.serverFrame(text: #"{"id":"approval-2","method":"approval"}"#))
        #expect(try await events.next() == .serverRequest(id: .string("approval-2"), method: "approval", params: nil))
        try await client.respondError(to: .string("approval-2"), code: -32601, message: "unsupported")
        let frames = try await channel.waitForFrames(2)
        struct Response: Decodable { let id: CodexRPCID; let result: JSONValue?; let error: CodexRPCError? }
        let accepted = try JSONDecoder().decode(Response.self, from: frames[0].payload)
        #expect(accepted.id == .integer(Int64.max))
        #expect(accepted.result == .object(["decision": .string("accept")]))
        let rejected = try JSONDecoder().decode(Response.self, from: frames[1].payload)
        #expect(rejected.id == .string("approval-2"))
        #expect(rejected.error == CodexRPCError(code: -32601, message: "unsupported", data: nil))
        await client.close()
    }

    @Test func timeoutAndCancellationDoNotConsumeOtherReplies() async throws {
        let (channel, client) = try await fixture()
        let expired = Task { try await client.request(method: "timeout", timeout: .milliseconds(20)) }
        _ = try await messages(channel, count: 1)
        await #expect(throws: CodexRPCClientError.timedOut) { _ = try await expired.value }
        let cancelled = Task { try await client.request(method: "cancel") }
        _ = try await messages(channel, count: 2)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        let surviving = Task { try await client.request(method: "survive") }
        let sent = try await messages(channel, count: 3)
        // Late replies to cancelled or expired calls have no continuation left.
        for message in sent {
            try await feed(.object(["id": try #require(message["id"]), "result": .bool(true)]), to: channel)
        }
        #expect(try await surviving.value == .bool(true))
        await client.close()
    }

    @Test func cancelledAndExpiredQueuedFramesNeverReachTheChannel() async throws {
        let (channel, client) = try await fixture()
        await channel.blockNextWrite()
        let blocker = Task { try await client.respond(to: .string("blocker"), result: .null) }
        _ = try await messages(channel, count: 1)
        let cancelled = Task { try await client.request(method: "turn/start") }
        let expired = Task { try await client.request(method: "expired", timeout: .milliseconds(40)) }
        await #expect(throws: CodexRPCClientError.timedOut) { _ = try await expired.value }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        await channel.releaseWrite()
        try await blocker.value
        // This final write proves the queue drained, including skipped frames.
        try await client.respond(to: .string("after"), result: .null)
        let all = try await messages(channel, count: 2)
        #expect(all.count == 2)
        let methods = all.compactMap { $0["method"]?.stringValue }
        #expect(methods.isEmpty)
        #expect(all.compactMap { $0["id"]?.stringValue } == ["blocker", "after"])
        await client.close()
    }

    // MARK: Pins: call commitment (CODEX-07)

    @Test func aCommittedCallThatTimesOutStaysSentAndIgnoresItsLateReply() async throws {
        let (channel, client) = try await fixture()
        await channel.blockNextWrite()
        let expired = Task { try await client.request(method: "turn/start", timeout: .milliseconds(40)) }
        // The frame is at the head of the write queue: committed, mid-write.
        let sent = try #require(try await messages(channel, count: 1).first)
        await #expect(throws: CodexRPCClientError.timedOut) { _ = try await expired.value }
        await channel.releaseWrite()
        try await feed(.object(["id": try #require(sent["id"]), "result": .bool(true)]), to: channel)
        let surviving = Task { try await client.request(method: "survive") }
        let all = try await messages(channel, count: 2)
        #expect(all.map { $0["method"]?.stringValue } == ["turn/start", "survive"])
        try await feed(.object(["id": try #require(all[1]["id"]), "result": .string("ok")]), to: channel)
        #expect(try await surviving.value == .string("ok"))
        await client.close()
    }

    @Test func aCommittedCallThatIsCancelledStillFinishesItsWrite() async throws {
        let (channel, client) = try await fixture()
        await channel.blockNextWrite()
        let cancelled = Task { try await client.request(method: "turn/start") }
        _ = try await messages(channel, count: 1)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        await channel.releaseWrite()
        // The queue continues after the committed frame.
        try await client.respond(to: .string("after"), result: .null)
        let all = try await messages(channel, count: 2)
        #expect(all[0]["method"] == .string("turn/start") && all[1]["id"] == .string("after"))
        await client.close()
    }

    @Test func closeFailsEveryCallOnceAndRefusesLaterOnes() async throws {
        let (channel, client) = try await fixture()
        let pending = Task { try await client.request(method: "one") }
        let sent = try #require(try await messages(channel, count: 1).first)
        await client.close()
        await #expect(throws: CodexRPCClientError.closed) { _ = try await pending.value }
        // A reply that arrives after close resumes nothing.
        try await feed(.object(["id": try #require(sent["id"]), "result": .bool(true)]), to: channel)
        await #expect(throws: CodexRPCClientError.closed) { _ = try await client.request(method: "late") }
        await #expect(throws: CodexRPCClientError.closed) { try await client.respond(to: .integer(1), result: .null) }
        #expect(await channel.closed)
    }

    @Test func transportEndFailsAllPendingAndFinishesEvents() async throws {
        let (channel, client) = try await fixture()
        let first = Task { try await client.request(method: "one") }
        let second = Task { try await client.request(method: "two") }
        _ = try await messages(channel, count: 2)
        await channel.feed(CodexMemoryChannel.serverFrame(opcode: 8, payload: Data()))
        await #expect(throws: CodexRPCClientError.closed) { _ = try await first.value }
        await #expect(throws: CodexRPCClientError.closed) { _ = try await second.value }
        var events = client.events.makeAsyncIterator()
        await #expect(throws: CodexRPCClientError.closed) { _ = try await events.next() }
        await #expect(throws: CodexRPCClientError.closed) { _ = try await client.request(method: "late") }
        #expect(await channel.closed)
        await client.close()
    }

    @Test func malformedAndNonObjectLinesAreIgnored() async throws {
        let (channel, client) = try await fixture()
        var events = client.events.makeAsyncIterator()
        for text in ["not json", "[]", "42", "{bad}"] {
            await channel.feed(CodexMemoryChannel.serverFrame(text: text))
        }
        await channel.feed(CodexMemoryChannel.serverFrame(text: #"{"method":"good","params":{},"future":"ignored"}"#))
        #expect(try await events.next() == .notification(method: "good", params: .object([:])))
        let request = Task { try await client.request(method: "still alive") }
        let sent = try #require(try await messages(channel, count: 1).first)
        try await feed(.object(["id": try #require(sent["id"]), "result": .bool(true)]), to: channel)
        #expect(try await request.value == .bool(true))
        await client.close()
    }

    @Test func initializeThenInitialized() async throws {
        let (channel, client) = try await fixture()
        let initialization = Task { try await client.initialize(clientName: "waycar", version: "1.0") }
        let sent = try #require(try await messages(channel, count: 1).first)
        #expect(sent["method"] == .string("initialize"))
        #expect(sent["params"] == .object([
            "clientInfo": .object(["name": .string("waycar"), "version": .string("1.0")]),
            "capabilities": .object(["experimentalApi": .bool(false)])
        ]))
        let result: JSONValue = .object([
            "userAgent": .string("codex/1"), "codexHome": .string("/home/user/.codex"),
            "platformFamily": .string("unix"), "platformOs": .string("linux"), "future": .bool(true)
        ])
        try await feed(.object(["id": try #require(sent["id"]), "result": result]), to: channel)
        #expect(try await initialization.value == result)
        let all = try await messages(channel, count: 2)
        #expect(all[1] == .object(["method": .string("initialized")]))
        await client.close()
    }
}
