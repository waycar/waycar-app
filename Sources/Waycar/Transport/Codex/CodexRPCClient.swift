import Foundation
import os

/// Codex ids are signed integers or strings, including for server approvals.
/// Decode integers directly, not through JSONValue's Double (which loses i64 bits).
enum CodexRPCID: Sendable, Hashable, Codable {
    case integer(Int64)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) { self = .integer(number) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

struct CodexRPCError: Error, Sendable, Equatable, Codable {
    let code: Int64
    let message: String
    let data: JSONValue?
}

enum CodexRPCClientError: Error, Equatable {
    case timedOut, closed
}

enum CodexRPCEvent: Sendable, Equatable {
    case notification(method: String, params: JSONValue?)
    case serverRequest(id: CodexRPCID, method: String, params: JSONValue?)
}

/// Bidirectional Codex RPC, intentionally without a `jsonrpc` field. A reader
/// demultiplexes responses independently of server requests awaiting user input.
actor CodexRPCClient {
    nonisolated let events: AsyncThrowingStream<CodexRPCEvent, any Error>
    private let eventContinuation: AsyncThrowingStream<CodexRPCEvent, any Error>.Continuation
    private let webSocket: CodexWebSocket
    private let requestTimeout: Duration
    private var reader: Task<Void, Never>?
    /// Which calls are pending and committed, and whether the client ended.
    private var calls = CodexCallMachine()
    /// What each pending call holds, keyed by its id (`calls`' token).
    private var pending: [CodexRPCID: Pending] = [:]
    private static let logger = Logger(subsystem: "com.otreva.waycar", category: "codex-rpc")

    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let timer: Task<Void, Never>
        let send: Task<Void, Never>
    }

    private struct Outbound: Encodable {
        var id: CodexRPCID?
        var method: String?
        var params: JSONValue?
        var result: JSONValue?
        var error: CodexRPCError?
    }

    private struct Inbound: Decodable {
        let id: CodexRPCID?
        let method: String?
        let params: JSONValue?
        let result: JSONValue?
        let error: CodexRPCError?
        private enum CodingKeys: String, CodingKey { case id, method, params, result, error }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(CodexRPCID.self, forKey: .id)
            method = try container.decodeIfPresent(String.self, forKey: .method)
            params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
            // A null result is still a response, not an absent result.
            result = container.contains(.result) ? try container.decode(JSONValue.self, forKey: .result) : nil
            error = try container.decodeIfPresent(CodexRPCError.self, forKey: .error)
        }
    }

    private init(webSocket: CodexWebSocket, requestTimeout: Duration) {
        self.webSocket = webSocket
        self.requestTimeout = requestTimeout
        (events, eventContinuation) = AsyncThrowingStream.makeStream()
    }

    static func connect(
        webSocket: CodexWebSocket, requestTimeout: Duration = .seconds(30)
    ) async -> CodexRPCClient {
        let client = CodexRPCClient(webSocket: webSocket, requestTimeout: requestTimeout)
        await client.startReader()
        return client
    }

    deinit {
        reader?.cancel()
        eventContinuation.finish()
        for (id, call) in pending {
            call.timer.cancel()
            if calls.phase(of: id) != .committed { call.send.cancel() }
            call.continuation.resume(throwing: CodexRPCClientError.closed)
        }
        let socket = webSocket
        Task { await socket.close() }
    }

    func request(
        method: String, params: JSONValue? = nil, timeout: Duration? = nil
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !calls.isEnded else { throw CodexRPCClientError.closed }
        // String ids avoid integer wraparound and cannot collide with server ids:
        // server requests are routed by method before the pending-call lookup.
        let id = CodexRPCID.string(UUID().uuidString)
        let text = try encode(Outbound(id: id, method: method, params: params))
        let budget = timeout ?? requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: budget) } catch { return }
                    await self?.failCall(id, error: CodexRPCClientError.timedOut)
                }
                let send = Task<Void, Never> { [weak self] in await self?.sendRequest(id: id, text: text) }
                pending[id] = Pending(continuation: continuation, timer: timer, send: send)
                _ = calls.handle(.enqueued(id))
            }
        } onCancel: {
            Task { await self.failCall(id, error: CancellationError()) }
        }
    }

    func respond(to id: CodexRPCID, result: JSONValue) async throws {
        try await send(Outbound(id: id, result: result))
    }

    func respondError(to id: CodexRPCID, code: Int64, message: String) async throws {
        try await send(Outbound(id: id, error: CodexRPCError(code: code, message: message, data: nil)))
    }

    /// Stable v1 initialize: no experimental API, attestation or extensions.
    /// Return the schema-free response (userAgent, codexHome, platformFamily,
    /// platformOs) so callers can use new server fields without a wire bump.
    @discardableResult
    func initialize(clientName: String, version: String) async throws -> JSONValue {
        let result = try await request(method: "initialize", params: .object([
            "clientInfo": .object(["name": .string(clientName), "version": .string(version)]),
            "capabilities": .object(["experimentalApi": .bool(false)])
        ]))
        try await send(Outbound(method: "initialized"))
        return result
    }

    func close() async {
        finish(error: CodexRPCClientError.closed)
        await webSocket.close()
    }

    private func encode(_ message: Outbound) throws -> String {
        String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    }

    private func send(_ message: Outbound) async throws {
        guard !calls.isEnded else { throw CodexRPCClientError.closed }
        let text = try encode(message)
        do { try await webSocket.send(text: text) }
        catch is CancellationError { throw CancellationError() }
        catch { finish(error: error); throw error }
    }

    private func sendRequest(id: CodexRPCID, text: String) async {
        guard calls.phase(of: id) != nil else { return }
        do {
            try await webSocket.send(text: text) { [weak self] in
                await self?.beginWrite(id) ?? false
            }
        } catch is CancellationError {
            failCall(id, error: CancellationError())
        } catch { finish(error: error) }
    }

    /// Called at the head of the socket's write queue, under this client's
    /// isolation. After this commit point a timeout still fails the call, but
    /// the frame may have been sent: it must not be blindly replayed.
    private func beginWrite(_ id: CodexRPCID) -> Bool {
        calls.handle(.writeBegan(id)) == [.write(id)]
    }

    private func failCall(_ id: CodexRPCID, error: any Error) {
        settle(.failed(id), .failure(error))
    }

    /// Feeds `calls` and performs what it asks: every call it settles is
    /// resumed with `outcome`.
    private func settle(_ event: CodexCallMachine.Event, _ outcome: Result<JSONValue, any Error>) {
        for effect in calls.handle(event) {
            switch effect {
            case .write:
                break
            case .settle(let id, let withdraw):
                guard let call = pending.removeValue(forKey: id) else { continue }
                call.timer.cancel()
                if withdraw { call.send.cancel() }
                call.continuation.resume(with: outcome)
            case .stopReader:
                reader?.cancel()
                reader = nil
            case .finishEvents:
                guard case .failure(let error) = outcome else { continue }
                eventContinuation.finish(throwing: error)
            }
        }
    }

    private func startReader() {
        let socket = webSocket
        reader = Task { [weak self] in
            do {
                while let text = try await socket.receive() {
                    guard let self else { return }
                    await self.ingest(text)
                }
                await self?.finish(error: CodexRPCClientError.closed)
            } catch { await self?.finish(error: error) }
        }
    }

    private func ingest(_ text: String) {
        guard !calls.isEnded else { return }
        guard let message = try? JSONDecoder().decode(Inbound.self, from: Data(text.utf8)) else {
            // Do not log a malformed message's potentially sensitive payload.
            Self.logger.notice("Ignoring malformed Codex RPC message")
            return
        }
        route(message)
    }

    private func route(_ message: Inbound) {
        if let method = message.method {
            if let id = message.id {
                eventContinuation.yield(.serverRequest(id: id, method: method, params: message.params))
            } else { eventContinuation.yield(.notification(method: method, params: message.params)) }
        } else if let id = message.id {
            if let error = message.error { settle(.answered(id), .failure(error)) }
            else if let result = message.result { settle(.answered(id), .success(result)) }
        }
    }

    private func finish(error: any Error) {
        settle(.ended, .failure(error))
    }
}
