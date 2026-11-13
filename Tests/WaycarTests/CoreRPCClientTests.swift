import Foundation
import Testing

@testable import Waycar

@Suite("herdr-core RPC client", .timeLimit(.minutes(1)))
struct CoreRPCClientTests {
    // MARK: Helpers

    static let marker = "WAYCAR-CORE-7f3a9c"

    struct Params: Encodable, Sendable {
        var tag: Int
    }

    struct Echo: Decodable, Sendable, Equatable {
        var tag: Int
    }

    struct NoParams: Encodable, Sendable {}

    struct Rig: Sendable {
        let fake: FakeHostControlChannel
        let client: CoreRPCClient
    }

    private static let helloLine =
        #"{"jsonrpc":"2.0","id":0,"method":"hello","params":{"framed":true,"generation":1}}"# + "\n"

    private static func bytes(_ text: String) -> Data { Data(text.utf8) }

    /// One DATA frame carrying `text`.
    private static func frame(_ channel: UInt32, _ text: String) -> Data {
        CoreFrameCodec.data(channel: channel, bytes(text))
    }

    private static func reply(_ id: Int, _ result: String) -> Data {
        // Core ends no channel-0 message with a newline: a frame is one message.
        frame(0, #"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
    }

    private static func errorReply(_ id: Int, kind: String, message: String, hint: String) -> Data {
        frame(
            0,
            #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"data":{"hint":"\#(hint)","kind":"\#(kind)"},"message":"\#(message)"}}"#
        )
    }

    private static func subscribeResult(channel: UInt32, seq: Int) -> String {
        #"{"channel":\#(channel),"seq":\#(seq),"terminals":[{"address":"t1","state":"live"}]}"#
    }

    /// A marker line and `hello`'s answer, as one read.
    private static var loginAndHello: Data {
        bytes(marker + "\n" + CoreTranscripts.helloReply + "\n")
    }

    private static func connected(
        configuration: CoreRPCClient.Configuration = CoreRPCClient.Configuration(),
        after extra: Data = Data()
    ) async throws -> Rig {
        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake, configuration: configuration)
        fake.feed(loginAndHello + extra)
        _ = try await client.open(marker: marker)
        return Rig(fake: fake, client: client)
    }

    /// The error `operation` throws, as a `TransportError`; nil if it
    /// returned or threw something else.
    private static func transportError<T>(
        _ operation: () async throws -> T
    ) async -> TransportError? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error as? TransportError
        }
    }

    /// The `CoreRPCError` `operation` throws; nil if it returned or threw
    /// something else.
    private static func coreError<T>(
        _ operation: () async throws -> T
    ) async -> CoreRPCError? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error as? CoreRPCError
        }
    }

    private struct Request {
        var id: Int
        var method: String
        var params: JSONValue?
        var tag: Int? {
            guard case .number(let value)? = params?["tag"] else { return nil }
            return Int(exactly: value)
        }
    }

    /// The requests written after `hello`, each of which must be exactly one
    /// DATA frame on channel 0 holding one LF-terminated line: writes never
    /// interleave or split a frame.
    private static func requests(_ fake: FakeHostControlChannel) throws -> [Request] {
        try fake.writtenData.dropFirst().compactMap { write -> Request? in
            var decoder = CoreFrameDecoder()
            let frames = try decoder.feed(write)
            #expect(frames.count == 1, "one frame per write")
            #expect(decoder.bufferedByteCount == 0)
            guard let frame = frames.first, frame.channel == 0, frame.kind == .data,
                frame.payload.last == 0x0A,
                let line = try? JSONDecoder().decode(JSONValue.self, from: frame.payload),
                case .number(let id)? = line["id"], let method = line["method"]?.stringValue
            else { return nil }
            return Request(id: Int(id), method: method, params: line["params"])
        }
    }

    // MARK: open

    @Test func openSendsHelloAndReturnsCoresAnswer() async throws {
        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake)
        fake.feed(Self.loginAndHello)
        let hello = try await client.open(marker: Self.marker)
        #expect(fake.writtenLines == [Self.helloLine])
        #expect(hello.coreID == "b16ea0348871a1e21dd8773e29771545")
        #expect(hello.version == "0.1.14")
        #expect(hello.framed)
        #expect(hello.methods.contains("terminal.keys"))
        #expect(await client.isOpen)
    }

    @Test func loginNoiseBeforeTheMarkerIsDiscarded() async throws {
        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake)
        // A `.bashrc` echo, a line that merely contains the marker, then the
        // marker split across two reads with CRLF, then hello in pieces.
        fake.feed("Welcome to the box\r\nrun: echo \(Self.marker) done\r\nlast login: ye")
        fake.feed("sterday\r\n\(Self.marker.prefix(6))")
        fake.feed("\(Self.marker.dropFirst(6))\r\n")
        fake.feed(Self.bytes(CoreTranscripts.helloReply + "\n"), chunkSize: 7)
        let hello = try await client.open(marker: Self.marker)
        #expect(hello.version == "0.1.14")
    }

    @Test func extraTextAfterTheMarkerLineEndsIsKeptForTheFrameDecoder() async throws {
        // The hello answer is followed, in the same read, by the first four
        // bytes of the next frame; the rest arrives later.
        let reply = Self.reply(1, #"{"tag":42}"#)
        let rig = try await Self.connected(after: reply.prefix(4))
        async let echo = rig.client.call("terminal.get", params: Params(tag: 1), as: Echo.self)
        _ = await rig.fake.waitForWrites(2)
        rig.fake.feed(reply.dropFirst(4))
        #expect(try await echo == Echo(tag: 42))
    }

    @Test func aMissingMarkerFailsOnTheByteLimit() async {
        let fake = FakeHostControlChannel()
        var configuration = CoreRPCClient.Configuration()
        configuration.markerByteLimit = 100
        let client = CoreRPCClient(channel: fake, configuration: configuration)
        fake.feed(String(repeating: "noise noise\n", count: 12))
        let error = await Self.transportError { try await client.open(marker: Self.marker) }
        guard case .channelFailed(let detail)? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(detail.hasPrefix("extra text on login"))
        await fake.waitUntilClosed()
        #expect(await client.isOpen == false)
    }

    @Test func aMissingMarkerFailsOnTheHandshakeTimeout() async {
        let fake = FakeHostControlChannel()
        var configuration = CoreRPCClient.Configuration()
        configuration.handshakeTimeout = .milliseconds(150)
        let client = CoreRPCClient(channel: fake, configuration: configuration)
        fake.feed("a prompt that never ends")
        let error = await Self.transportError { try await client.open(marker: Self.marker) }
        guard case .channelFailed(let detail)? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(detail.hasPrefix("extra text on login"))
        await fake.waitUntilClosed()
    }

    @Test func aSilentCoreAfterTheMarkerTimesOut() async {
        let fake = FakeHostControlChannel()
        var configuration = CoreRPCClient.Configuration()
        configuration.handshakeTimeout = .milliseconds(150)
        let client = CoreRPCClient(channel: fake, configuration: configuration)
        fake.feed(Self.marker + "\n")
        let error = await Self.transportError { try await client.open(marker: Self.marker) }
        #expect(error == .timedOut)
    }

    @Test func textWhereTheAnswerShouldBeIsMalformed() async {
        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake)
        fake.feed(Self.marker + "\nSegmentation fault\n")
        let error = await Self.transportError { try await client.open(marker: Self.marker) }
        guard case .malformedResponse(let message)? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func aHelloThatIsNotFramedIsMalformed() async {
        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake)
        let plain = CoreTranscripts.helloReply.replacingOccurrences(
            of: #""framed":true"#, with: #""framed":false"#)
        fake.feed(Self.marker + "\n" + plain + "\n")
        let error = await Self.transportError { try await client.open(marker: Self.marker) }
        guard case .malformedResponse? = error else {
            Issue.record("got \(String(describing: error))")
            return
        }
    }

    @Test func aRefusedGenerationNeedsAWaycarUpdate() async {
        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake)
        fake.feed(
            Self.marker
                + #"\#n{"error":{"code":-32000,"data":{"hint":"this core speaks generation 1","kind":"unsupported_generation"},"message":"generation 2 is not supported"},"id":0,"jsonrpc":"2.0"}"#
                + "\n")
        let error = await Self.transportError { try await client.open(marker: Self.marker) }
        #expect(error == .coreNeedsWaycarUpdate)
    }

    @Test func exit127WithTheNotInstalledLineIsCoreNotInstalled() async {
        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake)
        fake.feed(Self.marker + "\n")
        fake.finishCommand(
            exitStatus: 127, standardError: "sh: herdr-core is not installed here\n")
        let error = await Self.transportError { try await client.open(marker: Self.marker) }
        #expect(error == .coreNotInstalled)
    }

    @Test(arguments: CoreRPCClientTests.refusals)
    func aFailedConnectSaysWhy(status: Int32, standardError: String, expected: TransportError) async {
        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake)
        fake.feed(Self.marker + "\n")
        fake.finishCommand(exitStatus: status, standardError: standardError)
        let error = await Self.transportError { try await client.open(marker: Self.marker) }
        #expect(error == expected)
        #expect(await client.isOpen == false)
    }

    static let refusals: [(Int32, String, TransportError)] = [
        // `hc connect`'s own one-line error (observed: a session name that is a path).
        (
            2,
            #"{"error":{"hint":"use letters, digits, - _ .","kind":"usage","message":"HC_SESSION \"a/b\" can't be a folder name"}}"# + "\n",
            .coreRefused(
                message: #"HC_SESSION "a/b" can't be a folder name"#, hint: "use letters, digits, - _ .")
        ),
        // stderr noise before it: the last line that parses wins.
        (
            5,
            "hc: no systemd user manager here\n"
                + #"{"error":{"hint":"","kind":"unavailable","message":"core did not start within 5 s"}}"#
                + "\n",
            .coreRefused(message: "core did not start within 5 s", hint: "")
        ),
        (1, "something broke\nbadly\n", .coreRefused(message: "something broke\nbadly", hint: "")),
        (3, "", .coreRefused(message: "herdr-core exited with status 3", hint: "")),
        // 127 is not-installed even when stderr arrives late or says something else.
        (127, "bash: hc: command not found\n", .coreNotInstalled),
        (127, "", .coreNotInstalled),
        (CoreConnectCommand.notRunningStatus, CoreConnectCommand.notRunningText, .coreNotRunning),
        (CoreConnectCommand.notRunningStatus, "", .coreNotRunning),
        (0, "hc: turned on linger for me\n", .channelFailed(detail: "the herdr-core connection closed")),
    ]

    @Test func aReadFailureBeforeTheAnswerIsThatFailure() async {
        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake)
        fake.feed(Self.marker + "\n")
        fake.failRead(.sshUnreachable(detail: "reset"))
        let error = await Self.transportError { try await client.open(marker: Self.marker) }
        #expect(error == .sshUnreachable(detail: "reset"))
    }

    // MARK: calls

    @Test func concurrentCallsResolveOutOfOrder() async throws {
        let rig = try await Self.connected()
        async let first = rig.client.call("terminal.get", params: Params(tag: 1), as: Echo.self)
        async let second = rig.client.call("terminal.list", params: Params(tag: 2), as: Echo.self)
        async let third = rig.client.call("terminal.read", params: Params(tag: 3), as: Echo.self)
        _ = await rig.fake.waitForWrites(4)
        let requests = try Self.requests(rig.fake)
        #expect(Set(requests.map(\.id)) == [1, 2, 3])
        #expect(Set(requests.compactMap(\.tag)) == [1, 2, 3])
        // Answer in the reverse of arrival, each with the tag of its own request.
        for request in requests.reversed() {
            rig.fake.feed(Self.reply(request.id, #"{"tag":\#(request.tag ?? -1)}"#))
        }
        #expect(try await first == Echo(tag: 1))
        #expect(try await second == Echo(tag: 2))
        #expect(try await third == Echo(tag: 3))
        let methods = Dictionary(uniqueKeysWithValues: requests.compactMap { r in r.tag.map { ($0, r.method) } })
        #expect(methods == [1: "terminal.get", 2: "terminal.list", 3: "terminal.read"])
    }

    @Test func manyCallsWriteWholeFramesAndEachGetsItsOwnAnswer() async throws {
        let rig = try await Self.connected()
        let count = 25
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for tag in 0..<count {
                group.addTask {
                    try await rig.client.call("terminal.get", params: Params(tag: tag), as: Echo.self).tag
                }
            }
            _ = await rig.fake.waitForWrites(count + 1)
            for request in try Self.requests(rig.fake).reversed() {
                rig.fake.feed(Self.reply(request.id, #"{"tag":\#(request.tag ?? -1)}"#))
            }
            var tags: [Int] = []
            for try await tag in group { tags.append(tag) }
            return tags
        }
        #expect(results.sorted() == Array(0..<count))
    }

    @Test func aReplySplitAcrossReadsAndALargeOneStillResolve() async throws {
        let rig = try await Self.connected()
        async let first = rig.client.call("terminal.get", params: Params(tag: 1), as: Echo.self)
        _ = await rig.fake.waitForWrites(2)
        // Three bytes per read.
        rig.fake.feed(Self.reply(1, #"{"tag":7}"#), chunkSize: 3)
        #expect(try await first == Echo(tag: 7))
        // A reply far larger than one read, as terminal.list of a busy Host is.
        struct Big: Decodable, Sendable { let text: String }
        async let second = rig.client.call("terminal.list", params: Params(tag: 2), as: Big.self)
        _ = await rig.fake.waitForWrites(3)
        let text = String(repeating: "x", count: 200_000)
        rig.fake.feed(Self.reply(2, #"{"text":"\#(text)"}"#), chunkSize: 4_096)
        #expect(try await second.text.count == 200_000)
    }

    @Test func anErrorReplyThrowsACoreRPCError() async throws {
        let rig = try await Self.connected()
        let call = Task {
            await Self.coreError { try await rig.client.call("terminal.send", params: Params(tag: 1)) }
        }
        _ = await rig.fake.waitForWrites(2)
        rig.fake.feed(
            Self.errorReply(1, kind: "blocked", message: "t2 is blocked (permission)", hint: "read first"))
        #expect(
            await call.value
                == CoreRPCError(
                    code: -32000, kind: "blocked", message: "t2 is blocked (permission)",
                    hint: "read first"))
        #expect(await rig.client.isOpen, "an error reply does not end the connection")
    }

    @Test func anErrorWithoutDataDefaultsToInternalAndAnEmptyHint() async throws {
        let rig = try await Self.connected()
        let call = Task { await Self.coreError { try await rig.client.call("x", params: NoParams()) } }
        _ = await rig.fake.waitForWrites(2)
        rig.fake.feed(
            Self.frame(0, #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}"# + "\n"))
        #expect(
            await call.value == CoreRPCError(code: -32603, kind: "internal", message: "boom", hint: ""))
    }

    @Test func aMissingResultFieldIsMalformedAndNullIsAValue() async throws {
        let rig = try await Self.connected()
        async let typed = Self.transportError {
            try await rig.client.call("terminal.get", params: Params(tag: 1), as: Echo.self)
        }
        _ = await rig.fake.waitForWrites(2)
        rig.fake.feed(Self.reply(1, #"{"other":1}"#))
        guard case .malformedResponse? = await typed else {
            Issue.record("a reply without the required key must be malformed")
            return
        }
        async let noResult = Self.transportError { try await rig.client.call("x", params: NoParams()) }
        _ = await rig.fake.waitForWrites(3)
        rig.fake.feed(Self.frame(0, #"{"jsonrpc":"2.0","id":2}"# + "\n"))
        guard case .malformedResponse? = await noResult else {
            Issue.record("a reply with neither result nor error must be malformed")
            return
        }
        async let object: JSONValue = rig.client.call("server.stop", params: NoParams())
        _ = await rig.fake.waitForWrites(4)
        rig.fake.feed(Self.reply(3, #"{"stopped":true}"#))
        #expect(try await object == .object(["stopped": .bool(true)]))
        async let null: JSONValue = rig.client.call("x", params: NoParams())
        _ = await rig.fake.waitForWrites(5)
        rig.fake.feed(Self.reply(4, "null"))
        #expect(try await null == .null)
    }

    @Test func unparseableLinesAndRepliesForNobodyAreIgnored() async throws {
        let rig = try await Self.connected()
        async let call = rig.client.call("terminal.get", params: Params(tag: 1), as: Echo.self)
        _ = await rig.fake.waitForWrites(2)
        rig.fake.feed(Self.frame(0, "this is not json\n"))
        rig.fake.feed(Self.frame(0, #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse"}}"# + "\n"))
        rig.fake.feed(Self.reply(99, #"{"tag":0}"#))
        rig.fake.feed(Self.reply(1, #"{"tag":5}"#))
        #expect(try await call == Echo(tag: 5))
        #expect(await rig.client.isOpen)
    }

    @Test func aCallTimesOutAndALateReplyIsDropped() async throws {
        var configuration = CoreRPCClient.Configuration()
        configuration.callTimeout = .milliseconds(150)
        let rig = try await Self.connected(configuration: configuration)
        let error = await Self.transportError {
            try await rig.client.call("terminal.wait", params: Params(tag: 1), as: Echo.self)
        }
        #expect(error == .timedOut)
        #expect(await rig.client.isOpen, "a timed-out call does not end the connection")
        // The late answer to id 1 changes nothing for the next call.
        rig.fake.feed(Self.reply(1, #"{"tag":111}"#))
        async let next = rig.client.call("terminal.get", params: Params(tag: 2), as: Echo.self)
        _ = await rig.fake.waitForWrites(3)
        rig.fake.feed(Self.reply(2, #"{"tag":222}"#))
        #expect(try await next == Echo(tag: 222))
    }

    @Test func aPerCallTimeoutOverridesTheDefault() async throws {
        let rig = try await Self.connected()
        let error = await Self.transportError {
            try await rig.client.call(
                "terminal.wait", params: Params(tag: 1), timeout: .milliseconds(100))
        }
        #expect(error == .timedOut)
    }

    @Test func eofMidCallFailsEveryPendingCallAndLaterOnes() async throws {
        let rig = try await Self.connected()
        let first = Task {
            await Self.transportError { try await rig.client.call("a", params: Params(tag: 1)) }
        }
        let second = Task {
            await Self.transportError { try await rig.client.call("b", params: Params(tag: 2)) }
        }
        _ = await rig.fake.waitForWrites(3)
        rig.fake.finishOutput()
        let ended = TransportError.channelFailed(detail: "herdr-core ended the connection")
        #expect(await first.value == ended)
        #expect(await second.value == ended)
        #expect(await rig.client.isOpen == false)
        let writes = rig.fake.writtenData.count
        let late = await Self.transportError { try await rig.client.call("c", params: Params(tag: 3)) }
        #expect(late == ended)
        #expect(rig.fake.writtenData.count == writes, "nothing is written after the connection died")
    }

    @Test func aReadErrorFailsCallsWithThatError() async throws {
        let rig = try await Self.connected()
        let call = Task {
            await Self.transportError { try await rig.client.call("a", params: Params(tag: 1)) }
        }
        _ = await rig.fake.waitForWrites(2)
        rig.fake.failRead(.sshUnreachable(detail: "network lost"))
        #expect(await call.value == .sshUnreachable(detail: "network lost"))
        #expect(await rig.client.isOpen == false)
    }

    @Test func closeFailsPendingCallsAndIsIdempotent() async throws {
        let rig = try await Self.connected()
        let call = Task {
            await Self.transportError { try await rig.client.call("a", params: Params(tag: 1)) }
        }
        _ = await rig.fake.waitForWrites(2)
        await rig.client.close()
        #expect(await call.value == .cancelled)
        #expect(await rig.client.isOpen == false)
        #expect(rig.fake.isClosed)
        await rig.client.close()
        #expect(rig.fake.closeCount == 1)
        let after = await Self.transportError { try await rig.client.call("a", params: Params(tag: 2)) }
        #expect(after == .cancelled)
    }

    @Test func aFrameTooLargeEndsTheConnectionAsMalformed() async throws {
        let rig = try await Self.connected()
        let call = Task {
            await Self.transportError { try await rig.client.call("a", params: Params(tag: 1)) }
        }
        _ = await rig.fake.waitForWrites(2)
        let tooLarge = CoreFrameCodec.maximumPayloadBytes + 1
        rig.fake.feed(
            Data([0, 0, 0, 0, 0] + (0..<4).map { UInt8(truncatingIfNeeded: tooLarge >> ($0 * 8)) }))
        guard case .malformedResponse? = await call.value else {
            Issue.record("an impossible frame length must end the connection")
            return
        }
    }

    // MARK: events

    private static func subscribed(
        configuration: CoreRPCClient.Configuration = CoreRPCClient.Configuration(),
        channel: UInt32 = 7, seq: Int = 103, then events: Data = Data()
    ) async throws -> (
        rig: Rig, snapshot: CoreSubscription,
        notifications: AsyncThrowingStream<CoreNotification, any Error>
    ) {
        let rig = try await connected(configuration: configuration)
        let subscribing = Task { try await rig.client.subscribe() }
        _ = await rig.fake.waitForWrites(2)
        rig.fake.feed(reply(1, subscribeResult(channel: channel, seq: seq)) + events)
        let result = try await subscribing.value
        return (rig, result.snapshot, result.notifications)
    }

    @Test func subscribeSendsAnUnfilteredRequestAndReturnsTheSnapshot() async throws {
        let (rig, snapshot, _) = try await Self.subscribed()
        let request = try #require(try Self.requests(rig.fake).first)
        #expect(request.method == "events.subscribe")
        #expect(request.params == .object([:]))
        #expect(snapshot.channel == 7)
        #expect(snapshot.seq == 103)
        #expect(snapshot.terminals.map(\.address) == ["t1"])
    }

    @Test func eventsFollowingTheReplyInTheSameReadAreNotLost() async throws {
        let created = CoreTranscripts.eventFrames[0]
        let (_, _, notifications) = try await Self.subscribed(then: Self.frame(7, created))
        var iterator = notifications.makeAsyncIterator()
        guard case .event(let event)? = try await iterator.next() else {
            Issue.record("expected the created event")
            return
        }
        #expect(event.seq == 104)
        #expect(event.type == "created")
        #expect(event.terminal == "t1d")
        #expect(event.data["address"]?.stringValue == "t1d")
    }

    @Test func eachEventsFrameIsAnsweredWithACreditFrameOfItsLength() async throws {
        let created = CoreTranscripts.eventFrames[0]
        #expect(created.utf8.count == 753, "the captured frame is 753 bytes (0x02F1)")
        let heartbeat = #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":5}}"# + "\n"
        let (rig, _, notifications) = try await Self.subscribed(
            then: Self.frame(7, created) + Self.frame(7, heartbeat))
        var iterator = notifications.makeAsyncIterator()
        _ = try await iterator.next()
        let heartbeatNotification = try await iterator.next()
        #expect(heartbeatNotification == .heartbeat(seq: 5))
        let writes = await rig.fake.waitForWrites(4)
        #expect(writes.count == 4)
        // CREDIT: channel 7 LE, kind 1, length 4, then the payload length u32 LE.
        #expect(rig.fake.writtenData[2] == Data([7, 0, 0, 0, 1, 4, 0, 0, 0, 0xF1, 0x02, 0, 0]))
        #expect(rig.fake.writtenData[3] == Data([7, 0, 0, 0, 1, 4, 0, 0, 0, 58, 0, 0, 0]))
    }

    @Test func aLineSplitAcrossEventsFramesIsOneNotification() async throws {
        let line = try #require(
            CoreTranscripts.eventFrames.first { $0.contains(#""type":"turn""#) })
        let bytes = Array(line.utf8)
        let cut = 37
        let (rig, _, notifications) = try await Self.subscribed(
            then: CoreFrameCodec.data(channel: 7, Data(bytes[..<cut]))
                + CoreFrameCodec.data(channel: 7, Data(bytes[cut...])))
        var iterator = notifications.makeAsyncIterator()
        guard case .event(let event)? = try await iterator.next() else {
            Issue.record("expected the turn event")
            return
        }
        #expect(event.type == "turn")
        #expect(event.seq == 109)
        #expect(event.data["turn"] == .number(1))
        _ = await rig.fake.waitForWrites(4)
        #expect(rig.fake.writtenData[2] == CoreFrameCodec.credit(channel: 7, bytes: cut))
        #expect(rig.fake.writtenData[3] == CoreFrameCodec.credit(channel: 7, bytes: bytes.count - cut))
    }

    @Test func notificationsDecodeAndNoiseIsIgnored() async throws {
        let lines = [
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{"keep":true},"seq":104,"terminal":"t1","type":"keep"}}"#,
            "garbage",
            #"{"jsonrpc":"2.0","method":"future.thing","params":{"seq":105}}"#,
            #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":104}}"#,
            #"{"jsonrpc":"2.0","method":"missed","params":{"seq":80,"terminals":[{"address":"t5","state":"live"}]}}"#,
        ].joined(separator: "\n") + "\n"
        let (rig, _, notifications) = try await Self.subscribed(then: Self.frame(7, lines))
        // Frames the client must skip: another channel, a FACTS frame, an
        // unknown kind, a reply-less DATA on channel 0.
        rig.fake.feed(Self.frame(9, "ignored on another channel\n"))
        rig.fake.feed(CoreFrameCodec.encode(CoreFrame(channel: 7, kind: .facts, payload: Data("{}".utf8))))
        rig.fake.feed(CoreFrameCodec.encode(CoreFrame(channel: 7, kind: .unknown(77), payload: Data([1]))))
        rig.fake.feed(Self.frame(7, #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":106}}"# + "\n"))
        var iterator = notifications.makeAsyncIterator()
        guard case .event(let event)? = try await iterator.next() else {
            Issue.record("expected the keep event")
            return
        }
        #expect(event.type == "keep" && event.terminal == "t1" && event.data["keep"] == .bool(true))
        let heartbeat104 = try await iterator.next()
        #expect(heartbeat104 == .heartbeat(seq: 104))
        guard case .missed(let seq, let terminals)? = try await iterator.next() else {
            Issue.record("expected missed")
            return
        }
        #expect(seq == 80 && terminals.map(\.address) == ["t5"])
        let heartbeat106 = try await iterator.next()
        #expect(heartbeat106 == .heartbeat(seq: 106))
        // Credit went out for the two events-channel DATA frames only (plus
        // the hello and subscribe writes).
        _ = await rig.fake.waitForWrites(4)
        #expect(rig.fake.writtenData.count == 4)
    }

    @Test func aSecondSubscribeIsRefused() async throws {
        let (rig, _, _) = try await Self.subscribed()
        let error = await Self.transportError { try await rig.client.subscribe() }
        #expect(error == .eventsChannelAlreadyOpen)
    }

    @Test func aFailedSubscribeCanBeRetried() async throws {
        let rig = try await Self.connected()
        let first = Task { await Self.transportError { try await rig.client.subscribe() } }
        _ = await rig.fake.waitForWrites(2)
        rig.fake.feed(Self.errorReply(1, kind: "internal", message: "no", hint: ""))
        // The error is a CoreRPCError, not a TransportError.
        #expect(await first.value == nil)
        let second = Task { try await rig.client.subscribe() }
        _ = await rig.fake.waitForWrites(3)
        rig.fake.feed(Self.reply(2, Self.subscribeResult(channel: 3, seq: 1)))
        #expect(try await second.value.snapshot.channel == 3)
    }

    @Test func aCloseFrameOnTheEventsChannelEndsTheStream() async throws {
        let (rig, _, notifications) = try await Self.subscribed()
        rig.fake.feed(CoreFrameCodec.close(channel: 7))
        var iterator = notifications.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("the stream should have failed")
        } catch let error as TransportError {
            #expect(error == .channelFailed(detail: "herdr-core closed the events stream"))
        }
    }

    @Test func eofEndsTheStreamWithTheConnectionsFailure() async throws {
        let (rig, _, notifications) = try await Self.subscribed()
        rig.fake.finishOutput()
        var iterator = notifications.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("the stream should have failed")
        } catch let error as TransportError {
            #expect(error == .channelFailed(detail: "herdr-core ended the connection"))
        }
        #expect(await rig.client.isOpen == false)
    }

    @Test func closeEndsTheStreamAsCancelled() async throws {
        let (rig, _, notifications) = try await Self.subscribed()
        await rig.client.close()
        var iterator = notifications.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("the stream should have failed")
        } catch let error as TransportError {
            #expect(error == .cancelled)
        }
    }

    @Test func silenceWhileSubscribedFailsTheConnectionButFramesKeepItAlive() async throws {
        var configuration = CoreRPCClient.Configuration()
        configuration.eventsSilenceTimeout = .milliseconds(400)
        let (rig, _, notifications) = try await Self.subscribed(configuration: configuration)
        var iterator = notifications.makeAsyncIterator()
        // Six heartbeats 150 ms apart: well past 400 ms in total, never 400 ms quiet.
        for seq in 1...6 {
            try await Task.sleep(for: .milliseconds(150))
            rig.fake.feed(Self.frame(7, #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":\#(seq)}}"# + "\n"))
            let beat = try await iterator.next()
            #expect(beat == .heartbeat(seq: seq))
        }
        #expect(await rig.client.isOpen)
        // Then nothing: the connection fails with a timeout.
        do {
            _ = try await iterator.next()
            Issue.record("silence should have failed the stream")
        } catch let error as TransportError {
            #expect(error == .timedOut)
        }
        #expect(await rig.client.isOpen == false)
        let call = await Self.transportError { try await rig.client.call("a", params: Params(tag: 1)) }
        #expect(call == .timedOut)
    }

    @Test func aConnectionNobodySubscribedToMayStayQuiet() async throws {
        var configuration = CoreRPCClient.Configuration()
        configuration.eventsSilenceTimeout = .milliseconds(100)
        let rig = try await Self.connected(configuration: configuration)
        try await Task.sleep(for: .milliseconds(450))
        #expect(await rig.client.isOpen)
    }

    // MARK: lifecycle (CORE-04)

    @Test func aSecondOpenIsRefusedAndAFailedOpenRethrowsItsFailure() async throws {
        let rig = try await Self.connected()
        let again = await Self.transportError { try await rig.client.open(marker: Self.marker) }
        #expect(again == .channelFailed(detail: "the herdr-core connection was already opened"))
        #expect(await rig.client.isOpen)

        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake)
        fake.failRead(.sshUnreachable(detail: "gone"))
        let first = await Self.transportError { try await client.open(marker: Self.marker) }
        #expect(first == .sshUnreachable(detail: "gone"))
        let second = await Self.transportError { try await client.open(marker: Self.marker) }
        #expect(second == first)
        #expect(await client.isOpen == false)
    }

    @Test func callsBeforeOpenAreRefusedWithoutWriting() async {
        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake)
        let call = await Self.transportError { try await client.call("a", params: Params(tag: 1)) }
        #expect(call == .channelFailed(detail: "the herdr-core connection is not open"))
        let subscribe = await Self.transportError { try await client.subscribe() }
        #expect(subscribe == .channelFailed(detail: "the herdr-core connection is not open"))
        #expect(fake.writtenData.isEmpty)
    }

    @Test func closeWhileOpeningEndsTheOpenAsCancelled() async throws {
        let fake = FakeHostControlChannel()
        let client = CoreRPCClient(channel: fake)
        let opening = Task { await Self.transportError { try await client.open(marker: Self.marker) } }
        // The marker alone: the open sends hello and then waits for its
        // answer, so the close below lands while the open is reading.
        fake.feed(Self.bytes(Self.marker + "\n"))
        _ = await fake.waitForWrites(1)
        await client.close()
        #expect(await opening.value == .cancelled)
        #expect(await client.isOpen == false)
        #expect(fake.closeCount == 1)
    }

    @Test func aSubscribeWhileOneIsPendingIsRefused() async throws {
        let rig = try await Self.connected()
        let first = Task { try await rig.client.subscribe() }
        _ = await rig.fake.waitForWrites(2)
        let second = await Self.transportError { try await rig.client.subscribe() }
        #expect(second == .eventsChannelAlreadyOpen)
        rig.fake.feed(Self.reply(1, Self.subscribeResult(channel: 7, seq: 1)))
        #expect(try await first.value.snapshot.channel == 7)
        #expect(rig.fake.writtenData.count == 2, "the refused subscribe wrote nothing")
    }

    @Test func afterTheEventsChannelClosesSubscribeStaysRefusedCallsWorkAndSilenceIsFine() async throws {
        var configuration = CoreRPCClient.Configuration()
        configuration.eventsSilenceTimeout = .milliseconds(100)
        let (rig, _, notifications) = try await Self.subscribed(configuration: configuration)
        rig.fake.feed(CoreFrameCodec.close(channel: 7))
        var iterator = notifications.makeAsyncIterator()
        _ = try? await iterator.next()
        let again = await Self.transportError { try await rig.client.subscribe() }
        #expect(again == .eventsChannelAlreadyOpen)
        // Liveness stopped with the events channel: silence is not a failure.
        try await Task.sleep(for: .milliseconds(450))
        #expect(await rig.client.isOpen)
        let call = Task { try await rig.client.call("a", params: Params(tag: 4), as: Echo.self) }
        _ = await rig.fake.waitForWrites(3)
        rig.fake.feed(Self.reply(2, #"{"tag":4}"#))
        #expect(try await call.value == Echo(tag: 4))
        // A frame on the closed channel's number is no longer events.
        rig.fake.feed(Self.frame(7, #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":9}}"# + "\n"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.fake.writtenData.count == 3, "no CREDIT for a frame on a closed events channel")
    }

    @Test func aSubscribeReplyWithoutAChannelFailsAndCanBeRetried() async throws {
        var configuration = CoreRPCClient.Configuration()
        configuration.eventsSilenceTimeout = .milliseconds(100)
        let rig = try await Self.connected(configuration: configuration)
        let first = Task { await Self.transportError { try await rig.client.subscribe() } }
        _ = await rig.fake.waitForWrites(2)
        rig.fake.feed(Self.reply(1, #"{"seq":1,"terminals":[]}"#))
        guard case .malformedResponse? = await first.value else {
            Issue.record("a reply naming no events channel must fail the subscribe")
            return
        }
        // No liveness was armed for a subscription that never started.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await rig.client.isOpen)
        let second = Task { try await rig.client.subscribe() }
        _ = await rig.fake.waitForWrites(3)
        rig.fake.feed(Self.reply(2, Self.subscribeResult(channel: 5, seq: 2)))
        #expect(try await second.value.snapshot.channel == 5)
    }

    @Test func theFirstFailureWinsOverALaterOne() async throws {
        let (rig, _, notifications) = try await Self.subscribed()
        rig.fake.failRead(.sshUnreachable(detail: "network lost"))
        var iterator = notifications.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("the stream should have failed")
        } catch let error as TransportError {
            #expect(error == .sshUnreachable(detail: "network lost"))
        }
        await rig.client.close()
        let call = await Self.transportError { try await rig.client.call("a", params: Params(tag: 1)) }
        #expect(call == .sshUnreachable(detail: "network lost"))
        try await waitUntil("the channel closes") { rig.fake.closeCount >= 1 }
        #expect(rig.fake.closeCount == 1)
    }
}
