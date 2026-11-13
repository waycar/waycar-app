import Foundation
import Synchronization

@testable import Waycar

/// A scripted herdr-core on the other end of a `HostControlChannel`: the
/// connect line's marker (after optional login noise), `hello`'s plain
/// answer, and from there JSON-RPC over frames.
///
/// Channel 0 carries one request per DATA frame (the client ends its
/// requests with a newline; core's replies carry none), and `responder`
/// answers each one with a channel-0 DATA frame. `pushEvent`, `pushHeartbeat`
/// and `end` play core's side of the events channel `events.subscribe`
/// names (channel 1, ``eventsChannel``): notification lines in DATA frames,
/// which the client acknowledges with CREDIT frames (``credits``). Reads
/// park until output is queued; `close()` fails a parked read and every later
/// read or write, as a closed SSH channel does.
final class FakeCoreChannel: HostControlChannel {
    /// What core answers one request with.
    enum Reply: Sendable {
        /// The raw JSON of the reply's `result`.
        case result(String)
        case error(kind: String, message: String, hint: String)
        /// Never answers.
        case none
    }

    typealias Responder = @Sendable (_ method: String, _ params: JSONValue) -> Reply

    private enum WaiterKind {
        case requests
        case credits
        case closed
    }

    private struct Waiter {
        let kind: WaiterKind
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private enum ReadResult: Sendable {
        case data(Data)
        case eof
        case closed
    }

    private struct Request: Sendable {
        let id: Int
        let method: String
        let params: JSONValue
    }

    private struct Outcome: Sendable {
        var helloAnswered = false
        var requests: [Request] = []
        var ready: [CheckedContinuation<Void, Never>] = []
    }

    private struct State {
        var reads: [ReadResult] = []
        var reader: CheckedContinuation<ReadResult, Never>?
        var helloBuffer = Data()
        var helloLine: String?
        var decoder = CoreFrameDecoder()
        var requests: [(method: String, params: JSONValue)] = []
        var requestIDs: [String: Int] = [:]
        var credits: [(channel: UInt32, bytes: Int)] = []
        var waiters: [Waiter] = []
        var closeCount = 0
        var exitStatus: Int32?
        var standardError = ""
    }

    static let closedError = TransportError.channelFailed(detail: "fake core channel closed")

    /// The channel `events.subscribe` results name.
    static let eventsChannel: UInt32 = 1

    /// Every method `CoreTransport` needs, and `hello`.
    static let defaultMethods = ["hello"] + CoreTransport.requiredMethods

    /// `hello`'s plain answer line (without its newline): a core of
    /// `version` offering `methods`.
    static func helloReply(
        version: String = "0.1.14", coreID: String = "b16ea0348871a1e21dd8773e29771545",
        methods: [String] = FakeCoreChannel.defaultMethods
    ) -> String {
        let names = methods.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"id":0,"jsonrpc":"2.0","result":{"core":{"id":"\#(coreID)","name":"fakebox"},"features":["framed","attach","events","status","shell"],"framed":true,"generation":1,"methods":[\#(names)],"version":"\#(version)"}}"#
    }

    /// An `events.subscribe` result: the events channel, `seq` and the given
    /// terminal records (raw JSON).
    static func subscribeResult(seq: Int, terminals: [String]) -> String {
        #"{"channel":\#(eventsChannel),"seq":\#(seq),"terminals":[\#(terminals.joined(separator: ","))]}"#
    }

    /// The command line the session was asked to run, for the test's own
    /// bookkeeping.
    let command: String
    private let helloText: String
    private let responder: Responder
    private let state = Mutex(State())

    /// - Parameters:
    ///   - noise: login output printed before the marker; whole lines.
    ///   - emitsMarker: false for a command that fails before it prints the
    ///     marker (core not installed, refused); script that with
    ///     `finishCommand`.
    ///   - hello: the plain line (no newline) answering the client's `hello`.
    init(
        command: String = "", noise: String = "", emitsMarker: Bool = true,
        hello: String = FakeCoreChannel.helloReply(), responder: @escaping Responder
    ) {
        self.command = command
        helloText = hello
        self.responder = responder
        if emitsMarker {
            enqueue(.data(Data((noise + CoreConnectCommand.connectMarker + "\n").utf8)))
        } else if !noise.isEmpty {
            enqueue(.data(Data(noise.utf8)))
        }
    }

    // MARK: Scripting

    /// One notification line, as core pushes it on the events channel.
    func pushEvent(seq: Int, type: String, terminal: String?, data: String) {
        let terminalField = terminal.map { #""terminal":"\#($0)","# } ?? ""
        push(
            line: #"{"jsonrpc":"2.0","method":"event","params":{"data":\#(data),\#(terminalField)"seq":\#(seq),"type":"\#(type)"}}"#
        )
    }

    /// Releases a request whose responder returned `.none`.
    func answer(_ method: String, result: String) {
        guard let id = state.withLock({ $0.requestIDs[method] }) else { return }
        let payload = Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8)
        enqueue(.data(CoreFrameCodec.data(channel: 0, payload)))
    }

    /// A `missed` notification: a fresh snapshot of `terminals` (raw JSON
    /// records, comma-joined) at `seq`.
    func pushMissed(seq: Int, terminals: String) {
        push(line: #"{"jsonrpc":"2.0","method":"missed","params":{"seq":\#(seq),"terminals":[\#(terminals)]}}"#)
    }

    func pushHeartbeat(seq: Int) {
        push(line: #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":\#(seq)}}"#)
    }

    /// EOF with no CLOSE frame, as a core restart ends every connection.
    func end() {
        enqueue(.eof)
    }

    /// The command ending the way `hc connect` does when it fails: stdout
    /// closes, the exit status and the stderr text become readable.
    func finishCommand(exitStatus: Int32, standardError: String = "") {
        state.withLock { state in
            state.exitStatus = exitStatus
            state.standardError = standardError
        }
        enqueue(.eof)
    }

    private func push(line: String) {
        enqueue(.data(CoreFrameCodec.data(channel: Self.eventsChannel, Data((line + "\n").utf8))))
    }

    private func enqueue(_ result: ReadResult) {
        let reader: CheckedContinuation<ReadResult, Never>? = state.withLock { state in
            guard state.closeCount == 0 else { return nil }
            if let reader = state.reader {
                state.reader = nil
                return reader
            }
            state.reads.append(result)
            return nil
        }
        reader?.resume(returning: result)
    }

    // MARK: Observation

    /// The plain `hello` line the client wrote, without its newline; nil
    /// until it did.
    var helloLine: String? {
        state.withLock { $0.helloLine }
    }

    /// Every request the client sent on channel 0, in order.
    var requests: [(method: String, params: JSONValue)] {
        state.withLock { $0.requests }
    }

    /// The `params` of each request for `method`, in order.
    func params(of method: String) -> [JSONValue] {
        requests.filter { $0.method == method }.map { $0.params }
    }

    /// Every CREDIT frame the client sent: the channel and the bytes
    /// acknowledged.
    var credits: [(channel: UInt32, bytes: Int)] {
        state.withLock { $0.credits }
    }

    var closeCount: Int {
        state.withLock { $0.closeCount }
    }

    var isClosed: Bool {
        closeCount > 0
    }

    func waitForRequests(_ count: Int) async {
        await wait(.requests, count: count)
    }

    func waitForCredits(_ count: Int) async {
        await wait(.credits, count: count)
    }

    func waitUntilClosed() async {
        await wait(.closed, count: 0)
    }

    private func wait(_ kind: WaiterKind, count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let satisfied: Bool = state.withLock { state in
                switch kind {
                case .requests where state.requests.count >= count: return true
                case .credits where state.credits.count >= count: return true
                case .closed where state.closeCount > 0: return true
                default: break
                }
                state.waiters.append(
                    Waiter(kind: kind, count: count, continuation: continuation))
                return false
            }
            if satisfied { continuation.resume() }
        }
    }

    // MARK: HostControlChannel

    func write(_ data: Data, timeout: Duration) async throws {
        let outcome: Outcome = try state.withLock { state -> Outcome in
            guard state.closeCount == 0 else { throw Self.closedError }
            var outcome = Outcome()
            var framed = data
            if state.helloLine == nil {
                state.helloBuffer.append(data)
                guard let newline = state.helloBuffer.firstIndex(of: 0x0A) else { return outcome }
                state.helloLine = String(
                    decoding: state.helloBuffer[state.helloBuffer.startIndex..<newline],
                    as: UTF8.self)
                framed = Data(state.helloBuffer[(newline + 1)...])
                state.helloBuffer = Data()
                outcome.helloAnswered = true
            }
            let frames = (try? state.decoder.feed(framed)) ?? []
            for frame in frames {
                if frame.kind == .credit {
                    if let bytes = CoreFrameCodec.creditBytes(of: frame) {
                        state.credits.append((channel: frame.channel, bytes: bytes))
                    }
                    continue
                }
                guard frame.channel == 0, frame.kind == .data,
                    let message = try? JSONDecoder().decode(JSONValue.self, from: frame.payload),
                    case .number(let id)? = message["id"],
                    let method = message["method"]?.stringValue
                else { continue }
                let params = message["params"] ?? .null
                state.requests.append((method: method, params: params))
                state.requestIDs[method] = Int(id)
                outcome.requests.append(Request(id: Int(id), method: method, params: params))
            }
            let requestCount = state.requests.count
            let creditCount = state.credits.count
            state.waiters.removeAll { waiter in
                let satisfied: Bool
                switch waiter.kind {
                case .requests: satisfied = requestCount >= waiter.count
                case .credits: satisfied = creditCount >= waiter.count
                case .closed: satisfied = false
                }
                if satisfied { outcome.ready.append(waiter.continuation) }
                return satisfied
            }
            return outcome
        }
        if outcome.helloAnswered {
            enqueue(.data(Data((helloText + "\n").utf8)))
        }
        for request in outcome.requests {
            if let payload = reply(to: request) {
                enqueue(.data(CoreFrameCodec.data(channel: 0, payload)))
            }
        }
        for continuation in outcome.ready { continuation.resume() }
    }

    private func reply(to request: Request) -> Data? {
        switch responder(request.method, request.params) {
        case .none:
            return nil
        case .result(let raw):
            return Data(#"{"jsonrpc":"2.0","id":\#(request.id),"result":\#(raw)}"#.utf8)
        case .error(let kind, let message, let hint):
            let object: [String: Any] = [
                "jsonrpc": "2.0", "id": request.id,
                "error": [
                    "code": -32000, "message": message,
                    "data": ["kind": kind, "hint": hint],
                ] as [String: Any],
            ]
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ReadResult, Never>) in
            let ready: ReadResult? = state.withLock { state in
                if state.closeCount > 0 { return .closed }
                if !state.reads.isEmpty { return state.reads.removeFirst() }
                state.reader = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        switch result {
        case .data(let data): return data
        case .eof: return nil
        case .closed: throw Self.closedError
        }
    }

    func exitStatus(timeout: Duration) async throws -> Int32 {
        guard let status = state.withLock({ $0.exitStatus }) else { throw TransportError.timedOut }
        return status
    }

    func standardErrorTail() async -> String {
        state.withLock { $0.standardError }
    }

    func close() async {
        let parked: (reader: CheckedContinuation<ReadResult, Never>?, waiters: [Waiter]) =
            state.withLock { state in
                state.closeCount += 1
                let reader = state.reader
                state.reader = nil
                let closed = state.waiters.filter { $0.kind == .closed }
                state.waiters.removeAll { $0.kind == .closed }
                return (reader, closed)
            }
        parked.reader?.resume(returning: .closed)
        for waiter in parked.waiters { waiter.continuation.resume() }
    }
}
