import Foundation

/// JSON-RPC and the events stream over one framed `herdr-core connect`
/// (design §5; research `rpc-facts.md` §2-3, `attach-facts.md` §1 and §4).
///
/// The connect line prints a marker, then `exec`s the core: `open(marker:)`
/// throws away everything up to the marker (a noisy `~/.bashrc` prints ahead
/// of it, C21), says `hello` with `framed: true` as one plain line, and from
/// the byte after the reply reads frames. One reader task decodes them:
/// channel 0 carries the replies, one JSON message per DATA frame, which
/// resolve concurrent calls by id in any order, and the channel
/// `events.subscribe` returns carries the notification lines (a line can
/// span frames), each frame answered with a CREDIT frame once consumed.
///
/// Every write goes through one writer task fed in order, so frames never
/// interleave. The connection ends once, for one reason: `close()`, EOF (core
/// restarts and `hc update` end every connection that way, with no CLOSE
/// frame), a read or write error, a malformed stream, or silence while
/// subscribed. That reason fails every pending call and the notification
/// stream, and every later call.
///
/// Version and method floor checks are the owner's: they read the returned
/// `CoreHello`.
actor CoreRPCClient {
    struct Configuration: Sendable {
        var callTimeout: Duration = .seconds(30)
        var handshakeTimeout: Duration = .seconds(10)
        var markerByteLimit = 64 * 1024
        /// Core sends a heartbeat every 15 s while subscribed; this much
        /// silence of any kind fails the connection.
        var eventsSilenceTimeout: Duration = .seconds(45)
        var writeTimeout: Duration = .seconds(10)

        init() {}
    }

    private static let readChunkBytes = 64 * 1024
    /// An idle connection may be quiet for minutes; a read timing out is not
    /// an error (liveness is `eventsSilenceTimeout`'s job).
    private static let readTimeout: Duration = .seconds(300)
    private static let maximumHelloLineBytes = 1024 * 1024
    private static let helloLine = Data(
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"hello\",\"params\":{\"framed\":true,\"generation\":1}}\n"
            .utf8)

    private struct PendingCall {
        let continuation: CheckedContinuation<Data, any Error>
        let timer: Task<Void, Never>
        let isSubscribe: Bool
    }

    private let channel: any HostControlChannel
    private let configuration: Configuration
    private var connection = CoreRPCConnectionMachine()
    private var decoder = CoreFrameDecoder()
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var liveness: Task<Void, Never>?
    private var outbox: AsyncStream<Data>.Continuation?
    private var pending: [Int: PendingCall] = [:]
    private var nextID = 1
    private var eventsLines = LineBuffer()
    private var eventsContinuation: AsyncThrowingStream<CoreNotification, any Error>.Continuation?
    private var lastFrameAt = ContinuousClock.now
    private var channelCloseStarted = false

    init(channel: any HostControlChannel, configuration: Configuration = Configuration()) {
        self.channel = channel
        self.configuration = configuration
    }

    deinit {
        reader?.cancel()
        writer?.cancel()
        liveness?.cancel()
        outbox?.finish()
        eventsContinuation?.finish(throwing: TransportError.cancelled)
        if !channelCloseStarted {
            let channel = channel
            Task { await channel.close() }
        }
    }

    var isOpen: Bool { connection.isOpen }

    /// Feeds the connection machine and performs what it asks for; a
    /// refusal comes back as the thrown error.
    private func apply(_ event: CoreRPCConnectionMachine.Event) throws {
        for effect in connection.handle(event) {
            switch effect {
            case .refuse(let error):
                throw error
            case .startIO:
                lastFrameAt = .now
                startWriter()
                startReader()
            case .startLiveness:
                // Set before anything else is read: events can follow the
                // reply in the same read.
                lastFrameAt = .now
                startLiveness()
            case .stopLiveness:
                liveness?.cancel()
            case .forgetEvents:
                eventsContinuation = nil
            case .endEvents(let error):
                eventsContinuation?.finish(throwing: error)
                eventsContinuation = nil
            case .tearDown(let error):
                tearDown(error)
            }
        }
    }

    // MARK: Open

    /// Waits for `marker`, says `hello`, and starts the reader. Returns core's
    /// `hello` result; `framed` is guaranteed true.
    func open(marker: String) async throws -> CoreHello {
        try apply(.openRequested)
        let channel = channel
        let configuration = configuration
        let excess: [UInt8]
        do {
            excess = try await AsyncDeadline.run(for: configuration.handshakeTimeout) {
                try await Self.discardLogin(
                    channel: channel, marker: marker, limit: configuration.markerByteLimit,
                    readTimeout: configuration.handshakeTimeout)
            }
        } catch {
            throw await openFailed(error, markerPhase: true)
        }
        guard connection.isOpening else { throw connection.failure }
        let exchange: HelloExchange
        do {
            exchange = try await AsyncDeadline.run(for: configuration.handshakeTimeout) {
                try await Self.exchangeHello(
                    channel: channel, excess: excess, writeTimeout: configuration.writeTimeout,
                    readTimeout: configuration.handshakeTimeout)
            }
        } catch {
            throw await openFailed(error, markerPhase: false)
        }
        guard connection.isOpening else { throw connection.failure }
        try apply(.handshakeFinished)
        if !exchange.excess.isEmpty {
            do {
                try ingest(exchange.excess)
            } catch {
                let failure = Self.malformedStream(error)
                fail(failure)
                throw failure
            }
        }
        return exchange.hello
    }

    // MARK: Calls

    func call<Value: Decodable & Sendable>(
        _ method: String, params: some Encodable & Sendable, as type: Value.Type,
        timeout: Duration? = nil
    ) async throws -> Value {
        let line = try await requestLine(method, params: params, timeout: timeout)
        return try Self.decodeResult(Value.self, from: line)
    }

    func call(
        _ method: String, params: some Encodable & Sendable, timeout: Duration? = nil
    ) async throws -> JSONValue {
        try await call(method, params: params, as: JSONValue.self, timeout: timeout)
    }

    /// Calls `events.subscribe` with no filter. From the reply on, DATA frames
    /// on the returned channel become `notifications`, the stream's failure
    /// is why the connection ended, and silence of `eventsSilenceTimeout`
    /// fails the connection. One subscription per client.
    func subscribe() async throws -> (
        snapshot: CoreSubscription,
        notifications: AsyncThrowingStream<CoreNotification, any Error>
    ) {
        try apply(.subscribeRequested)
        let (stream, continuation) = AsyncThrowingStream<CoreNotification, any Error>.makeStream()
        eventsContinuation = continuation
        do {
            let line = try await send(
                method: "events.subscribe", params: Data("{}".utf8),
                timeout: configuration.callTimeout, isSubscribe: true)
            let snapshot = try Self.decodeResult(CoreSubscription.self, from: line)
            guard snapshot.channel != nil else {
                throw TransportError.malformedResponse(
                    "herdr-core did not say which channel carries its events.")
            }
            return (snapshot, stream)
        } catch {
            try? apply(.subscribeFailed)
            continuation.finish()
            throw error
        }
    }

    /// Ends the connection: every pending call and the notification stream
    /// fail with `TransportError.cancelled` and the channel is closed.
    /// Idempotent.
    func close() async {
        fail(.cancelled)
        await closeChannel()
    }

    private func requestLine(
        _ method: String, params: some Encodable & Sendable, timeout: Duration?
    ) async throws -> Data {
        let body: Data
        do {
            body = try JSONEncoder().encode(params)
        } catch {
            throw TransportError.malformedResponse("Waycar could not write the \(method) request.")
        }
        return try await send(
            method: method, params: body, timeout: timeout ?? configuration.callTimeout,
            isSubscribe: false)
    }

    private func requireOpen() throws {
        if let refusal = connection.callRefusal { throw refusal }
    }

    private func send(
        method: String, params: Data, timeout: Duration, isSubscribe: Bool
    ) async throws -> Data {
        try requireOpen()
        if Task.isCancelled { throw TransportError.cancelled }
        guard let outbox else {
            throw TransportError.channelFailed(detail: "the herdr-core connection is not open")
        }
        let id = nextID
        nextID += 1
        let frame = CoreFrameCodec.data(
            channel: 0, Self.request(id: id, method: method, params: params))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: TransportError.cancelled)
                    return
                }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.finishCall(id, throwing: TransportError.timedOut)
                }
                pending[id] = PendingCall(
                    continuation: continuation, timer: timer, isSubscribe: isSubscribe)
                outbox.yield(frame)
            }
        } onCancel: {
            Task { await self.finishCall(id, throwing: TransportError.cancelled) }
        }
    }

    /// Fails one call (timeout, cancellation); a later reply for it is dropped.
    private func finishCall(_ id: Int, throwing error: TransportError) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timer.cancel()
        call.continuation.resume(throwing: error)
    }

    private static func request(id: Int, method: String, params: Data) -> Data {
        let methodJSON = (try? JSONEncoder().encode(method)) ?? Data("\"\"".utf8)
        var line = Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"#.utf8)
        line.append(methodJSON)
        line.append(Data(#","params":"#.utf8))
        line.append(params)
        line.append(Data("}\n".utf8))
        return line
    }

    // MARK: Reading

    private func startWriter() {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        outbox = continuation
        let channel = channel
        let timeout = configuration.writeTimeout
        writer = Task { [weak self] in
            for await data in stream {
                do {
                    try await channel.write(data, timeout: timeout)
                } catch {
                    await self?.fail(Self.transport(error))
                    return
                }
            }
        }
    }

    private func startReader() {
        let channel = channel
        reader = Task { [weak self] in
            while !Task.isCancelled {
                let result: Result<Data?, any Error>
                do {
                    result = .success(
                        try await channel.read(
                            maximumBytes: Self.readChunkBytes, timeout: Self.readTimeout))
                } catch {
                    result = .failure(error)
                }
                guard let self else { return }
                guard await self.handleRead(result) else { return }
            }
        }
    }

    /// Whether the reader should keep reading.
    private func handleRead(_ result: Result<Data?, any Error>) -> Bool {
        switch result {
        case .success(let data?):
            do {
                try ingest(data)
            } catch {
                fail(Self.malformedStream(error))
            }
        case .success(nil):
            fail(.channelFailed(detail: "herdr-core ended the connection"))
        case .failure(let error):
            if let transport = error as? TransportError, transport == .timedOut, isOpen {
                return true
            }
            fail(Self.transport(error))
        }
        return isOpen
    }

    private func ingest(_ data: Data) throws {
        let frames = try decoder.feed(data)
        guard !frames.isEmpty else { return }
        lastFrameAt = .now
        for frame in frames { handle(frame) }
    }

    private func handle(_ frame: CoreFrame) {
        guard isOpen else { return }
        if frame.channel == 0 {
            // Channel 0 carries one JSON message per DATA frame, with no
            // trailing newline (captured, `attach-wire-minimal`): a frame is
            // never a fragment of one. Splitting at a newline tolerates a
            // core that does end its messages with one.
            guard frame.kind == .data else { return }
            for message in frame.payload.split(separator: 0x0A, omittingEmptySubsequences: true) {
                handleReply(Data(message))
            }
            return
        }
        guard frame.channel == connection.eventsChannel else { return }
        switch frame.kind {
        case .data:
            for line in eventsLines.append(frame.payload) {
                if let notification = Self.notification(from: line) {
                    eventsContinuation?.yield(notification)
                }
            }
            if !frame.payload.isEmpty {
                outbox?.yield(
                    CoreFrameCodec.credit(channel: frame.channel, bytes: frame.payload.count))
            }
        case .close:
            try? apply(.eventsClosed)
        default:
            break
        }
    }

    private func handleReply(_ line: Data) {
        guard let header = try? JSONDecoder().decode(ReplyHeader.self, from: line),
            let id = header.id, let call = pending.removeValue(forKey: id)
        else { return }
        call.timer.cancel()
        if let error = header.error {
            call.continuation.resume(throwing: error.coreError)
            return
        }
        if call.isSubscribe,
            let subscription = try? JSONDecoder().decode(Reply<CoreSubscription>.self, from: line)
                .result,
            let channel = subscription.channel
        {
            try? apply(.subscribeReplied(channel: channel))
        }
        call.continuation.resume(returning: line)
    }

    // MARK: Liveness

    private func startLiveness() {
        liveness?.cancel()
        liveness = Task { [weak self] in
            while !Task.isCancelled {
                guard let remaining = await self?.silenceRemaining() else { return }
                if remaining <= .zero {
                    await self?.silenceExpired()
                    return
                }
                do { try await Task.sleep(for: remaining) } catch { return }
            }
        }
    }

    private func silenceRemaining() -> Duration? {
        guard isOpen else { return nil }
        return (lastFrameAt + configuration.eventsSilenceTimeout) - ContinuousClock.now
    }

    private func silenceExpired() {
        guard let remaining = silenceRemaining(), remaining <= .zero else { return }
        fail(.timedOut)
    }

    // MARK: Failure

    /// Ends the connection with `error`, once: the first reason stays.
    private func fail(_ error: TransportError) {
        try? apply(.failed(error))
    }

    private func tearDown(_ error: TransportError) {
        reader?.cancel()
        writer?.cancel()
        liveness?.cancel()
        outbox?.finish()
        outbox = nil
        let calls = pending
        pending = [:]
        for call in calls.values {
            call.timer.cancel()
            call.continuation.resume(throwing: error)
        }
        eventsContinuation?.finish(throwing: error)
        eventsContinuation = nil
        if !channelCloseStarted {
            Task { await self.closeChannel() }
        }
    }

    private func closeChannel() async {
        guard !channelCloseStarted else { return }
        channelCloseStarted = true
        await channel.close()
    }

    /// The failure `open` throws, after ending the connection with it.
    private func openFailed(_ error: any Error, markerPhase: Bool) async -> TransportError {
        if case .failed(let failure) = connection.state { return failure }
        let failure: TransportError
        switch error {
        case let handshake as HandshakeFailure:
            switch handshake {
            case .ended:
                failure = await explainEnd(readError: nil)
            case .channel(let underlying):
                failure = await explainEnd(readError: underlying)
            case .timedOut:
                failure = markerPhase ? extraTextOnLogin() : .timedOut
            case .protocolError(let transport):
                failure = transport
            }
        case is AsyncDeadlineError:
            failure = markerPhase ? extraTextOnLogin() : .timedOut
        default:
            failure = Self.transport(error)
        }
        fail(failure)
        return connection.failure
    }

    private func extraTextOnLogin() -> TransportError {
        Self.extraTextOnLogin(limit: configuration.markerByteLimit)
    }

    private static func extraTextOnLogin(limit: Int) -> TransportError {
        .channelFailed(
            detail:
                "extra text on login: the Host printed more than \(limit) bytes, or took too long, before herdr-core answered. Remove the output from the Host's shell startup files, such as ~/.bashrc."
        )
    }

    /// Why the command ended before it answered `hello`: its exit status and
    /// stderr say (`hc connect` prints one JSON error line when it fails).
    private func explainEnd(readError: (any Error)?) async -> TransportError {
        let status = try? await channel.exitStatus(timeout: .seconds(2))
        let tail = await channel.standardErrorTail()
        if let status, status != 0 {
            return Self.refusal(status: status, standardError: tail)
        }
        if let readError { return Self.transport(readError) }
        return .channelFailed(detail: "the herdr-core connection closed")
    }

    /// `.coreRefused` from the last stderr line that is `hc`'s error JSON,
    /// else from the tail's text, else from the exit status.
    static func refusal(status: Int32, standardError: String) -> TransportError {
        // Our wrapper's exits, even when stderr has not arrived yet.
        if status == 127 { return .coreNotInstalled }
        if status == CoreConnectCommand.notRunningStatus { return .coreNotRunning }
        let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in trimmed.split(whereSeparator: \.isNewline).reversed() {
            guard let data = line.data(using: .utf8),
                let parsed = try? JSONDecoder().decode(ConnectError.self, from: data),
                !parsed.message.isEmpty
            else { continue }
            return .coreRefused(message: parsed.message, hint: parsed.hint)
        }
        let message = trimmed.isEmpty ? "herdr-core exited with status \(status)" : trimmed
        return .coreRefused(message: message, hint: "")
    }

    private static func transport(_ error: any Error) -> TransportError {
        if let transport = error as? TransportError { return transport }
        if error is CancellationError { return .cancelled }
        return .channelFailed(detail: error.localizedDescription)
    }

    private static func malformedStream(_ error: any Error) -> TransportError {
        .malformedResponse("herdr-core sent a frame Waycar cannot read.")
    }

    // MARK: Handshake

    private enum HandshakeFailure: Error {
        /// EOF before the answer.
        case ended
        /// A read or write failed before the answer.
        case channel(any Error)
        /// A read's own timeout.
        case timedOut
        case protocolError(TransportError)
    }

    private struct HelloExchange: Sendable {
        let hello: CoreHello
        let excess: Data
    }

    private static func readChunk(
        _ channel: any HostControlChannel, timeout: Duration
    ) async throws -> Data {
        do {
            guard
                let data = try await channel.read(maximumBytes: readChunkBytes, timeout: timeout)
            else { throw HandshakeFailure.ended }
            return data
        } catch let failure as HandshakeFailure {
            throw failure
        } catch let error as TransportError where error == .timedOut {
            throw HandshakeFailure.timedOut
        } catch {
            throw HandshakeFailure.channel(error)
        }
    }

    /// Reads and drops stdout through the line equal to `marker` (CRLF
    /// tolerated); returns the bytes read after it. At most `limit` bytes
    /// may arrive without the marker.
    private static func discardLogin(
        channel: any HostControlChannel, marker: String, limit: Int, readTimeout: Duration
    ) async throws -> [UInt8] {
        let markerBytes = Array(marker.utf8)
        var buffer: [UInt8] = []
        var total = 0
        while true {
            let chunk = try await readChunk(channel, timeout: readTimeout)
            total += chunk.count
            buffer.append(contentsOf: chunk)
            if dropThroughMarker(&buffer, marker: markerBytes) { return buffer }
            if total > limit {
                throw HandshakeFailure.protocolError(extraTextOnLogin(limit: limit))
            }
        }
    }

    /// Drops every complete line of `buffer`, and returns true if one of
    /// them was `marker`, in which case only the bytes after it remain.
    private static func dropThroughMarker(_ buffer: inout [UInt8], marker: [UInt8]) -> Bool {
        var start = 0
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            var line = buffer[start..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            start = newline + 1
            if line.elementsEqual(marker) {
                buffer.removeSubrange(0..<start)
                return true
            }
        }
        buffer.removeSubrange(0..<start)
        return false
    }

    /// Sends `hello` and reads its plain reply line; whatever follows the
    /// line in the same reads is the first frame bytes.
    private static func exchangeHello(
        channel: any HostControlChannel, excess: [UInt8], writeTimeout: Duration,
        readTimeout: Duration
    ) async throws -> HelloExchange {
        do {
            try await channel.write(helloLine, timeout: writeTimeout)
        } catch {
            throw HandshakeFailure.channel(error)
        }
        var buffer = excess
        while true {
            if let first = buffer.first, first != UInt8(ascii: "{") {
                throw HandshakeFailure.protocolError(
                    .malformedResponse("The Host printed text where herdr-core's answer should be."))
            }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                let rest = Data(buffer[(newline + 1)...])
                return HelloExchange(hello: try helloResult(line), excess: rest)
            }
            if buffer.count > maximumHelloLineBytes {
                throw HandshakeFailure.protocolError(
                    .malformedResponse("herdr-core's answer is too long to be a hello."))
            }
            buffer.append(contentsOf: try await readChunk(channel, timeout: readTimeout))
        }
    }

    private static func helloResult(_ line: Data) throws -> CoreHello {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(ReplyHeader.self, from: line) else {
            throw HandshakeFailure.protocolError(
                .malformedResponse("herdr-core's hello answer could not be read."))
        }
        if let error = header.error {
            let core = error.coreError
            if core.kind == "unsupported_generation" {
                throw HandshakeFailure.protocolError(.coreNeedsWaycarUpdate)
            }
            throw HandshakeFailure.protocolError(
                .coreRefused(message: core.message, hint: core.hint))
        }
        let hello: CoreHello
        do {
            hello = try decoder.decode(Reply<CoreHello>.self, from: line).result
        } catch {
            throw HandshakeFailure.protocolError(
                .malformedResponse("herdr-core's hello answer could not be read."))
        }
        guard hello.framed else {
            throw HandshakeFailure.protocolError(
                .malformedResponse("herdr-core did not switch to framed mode."))
        }
        return hello
    }

    // MARK: Decoding

    private static func decodeResult<Value: Decodable>(
        _ type: Value.Type, from line: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(Reply<Value>.self, from: line).result
        } catch {
            throw TransportError.malformedResponse("herdr-core sent a reply Waycar cannot read.")
        }
    }

    private static func notification(from line: Data) -> CoreNotification? {
        guard let parsed = try? JSONDecoder().decode(NotificationLine.self, from: line),
            let params = parsed.params, let seq = params.seq
        else { return nil }
        switch parsed.method {
        case "event":
            guard let type = params.type else { return nil }
            return .event(
                CoreEvent(
                    seq: seq, type: type, terminal: params.terminal, data: params.data ?? .null))
        case "heartbeat":
            return .heartbeat(seq: seq)
        case "missed":
            guard let terminals = params.terminals else { return nil }
            return .missed(seq: seq, terminals: terminals)
        default:
            return nil
        }
    }
}

// MARK: - Wire helpers

/// Splits a byte stream into lines at LF, keeping the incomplete tail.
private struct LineBuffer {
    private var bytes: [UInt8] = []

    /// The complete, non-empty lines `data` finishes, without their LF.
    mutating func append(_ data: Data) -> [Data] {
        bytes.append(contentsOf: data)
        var lines: [Data] = []
        var start = 0
        while let newline = bytes[start...].firstIndex(of: 0x0A) {
            if newline > start { lines.append(Data(bytes[start..<newline])) }
            start = newline + 1
        }
        if start > 0 { bytes.removeSubrange(0..<start) }
        return lines
    }
}

private struct WireError: Decodable {
    var code: Int
    var kind: String
    var message: String
    var hint: String

    private enum CodingKeys: String, CodingKey { case code, message, data }
    private enum DataKeys: String, CodingKey { case kind, hint }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? container.decodeIfPresent(Int.self, forKey: .code)) ?? -32000
        message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? ""
        let data = try? container.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
        kind = (try? data?.decodeIfPresent(String.self, forKey: .kind)) ?? "internal"
        hint = (try? data?.decodeIfPresent(String.self, forKey: .hint)) ?? ""
    }

    var coreError: CoreRPCError {
        CoreRPCError(code: code, kind: kind, message: message, hint: hint)
    }
}

/// The parts of a reply every call reads: its id and its error, if any.
private struct ReplyHeader: Decodable {
    var id: Int?
    var error: WireError?

    private enum CodingKeys: String, CodingKey { case id, error }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(Int.self, forKey: .id)
        error = try? container.decodeIfPresent(WireError.self, forKey: .error)
    }
}

/// A reply's `result`, which must be present (it may be `null`).
private struct Reply<Value: Decodable>: Decodable {
    let result: Value

    private enum CodingKeys: String, CodingKey { case result }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.result) else {
            throw DecodingError.keyNotFound(
                CodingKeys.result,
                DecodingError.Context(
                    codingPath: container.codingPath, debugDescription: "the reply has no result"))
        }
        result = try container.decode(Value.self, forKey: .result)
    }
}

private struct NotificationLine: Decodable {
    struct Params: Decodable {
        var seq: Int?
        var type: String?
        var terminal: String?
        var data: JSONValue?
        var terminals: [CoreTerminal]?

        private enum CodingKeys: String, CodingKey { case seq, type, terminal, data, terminals }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            seq = try? container.decodeIfPresent(Int.self, forKey: .seq)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            terminal = try? container.decodeIfPresent(String.self, forKey: .terminal)
            data = try? container.decodeIfPresent(JSONValue.self, forKey: .data)
            terminals = try? container.decodeIfPresent([CoreTerminal].self, forKey: .terminals)
        }
    }

    var method: String?
    var params: Params?

    private enum CodingKeys: String, CodingKey { case method, params }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try? container.decodeIfPresent(String.self, forKey: .method)
        params = try? container.decodeIfPresent(Params.self, forKey: .params)
    }
}

/// `hc connect`'s stderr line when it fails: `{"error":{"kind","message","hint"}}`.
private struct ConnectError: Decodable {
    var message: String
    var hint: String

    private enum CodingKeys: String, CodingKey { case error }
    private enum BodyKeys: String, CodingKey { case message, hint }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let body = try container.nestedContainer(keyedBy: BodyKeys.self, forKey: .error)
        message = (try? body.decodeIfPresent(String.self, forKey: .message)) ?? ""
        hint = (try? body.decodeIfPresent(String.self, forKey: .hint)) ?? ""
    }
}
