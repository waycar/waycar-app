import Foundation
import WaycarSSH

/// What a New Agent › OpenCode launch creates (`startSession`). The caller
/// mints `sessionID` once (`OpenCodeSessionID.mint()`) and keeps it with its
/// launch: a retry after a lost answer sends the same id, and OpenCode answers
/// with the session it already made (O11).
struct OpenCodeSessionLaunch: Sendable, Equatable {
    struct Model: Sendable, Equatable {
        let id: String
        let providerID: String
    }

    let sessionID: String
    let title: String
    let directory: String
    var model: Model? = nil
    /// The Chat Prompt, kept as the session's instruction entry
    /// `chatPromptEntryKey`, which OpenCode adds to the system prompt.
    var instructions: String? = nil
    /// Sent as the first prompt; a retry skips it once the session has history.
    var firstMessage: String? = nil
    /// An earlier try may have reached the Host.
    var mayHaveStarted = false
}

extension OpenCodeSessionLaunch.Model {
    /// Settings › Chat Mode's `provider/model`; nil without both halves.
    init?(selector: String) {
        guard let slash = selector.firstIndex(of: "/") else { return nil }
        let provider = String(selector[..<slash])
        let model = String(selector[selector.index(after: slash)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        self.init(id: model, providerID: provider)
    }
}

/// One image the Composer attaches to a prompt (`POST /prompt` `files`).
struct OpenCodePromptFile: Sendable, Equatable {
    let mime: String
    let data: Data
    let name: String?
}

/// The sessions of one Host's shared OpenCode 2 server
/// (`docs/design/opencode-backend.md`): loopback HTTP over direct-tcpip, one
/// channel per request, plus one `GET /api/event` stream. The stream replays
/// nothing (O14), so every `server.connected`, the first and each one after a
/// reconnect or a server restart, re-lists the sessions and re-reads what runs
/// and what waits. The server password lives only in this actor's memory.
///
/// Requests a subagent's child session raises (any descendant of a listed
/// top-level session, by its `parentID` chain) show on that top-level
/// session's card and make it Blocked; answering there answers the child.
actor OpenCodeTransport: Transport {
    let session: any HostSSHServices
    let presence: OpenCodePresence
    private let client: UltimateHTTPClient
    private var password: String?
    private var sessions: [String: OpenCodeSession] = [:]
    /// Archived top-level sessions, newest first by `archivedCap`: Closed
    /// Sessions (card 1530 1a).
    private var archived: [String: ArchivedServerSession] = [:]
    /// Each listed session's turn, last result and when it was seen.
    private var activity = OpenCodeActivityMachine()
    /// Pending requests by the listed top-level session whose card shows
    /// them; each names the session that raised it.
    private var requests: [String: [OpenCodeRequest]] = [:]
    /// A child session's parent, as reads and `session.created` told.
    private var parents: [String: String] = [:]
    /// Descendant sessions with a turn running, to their top-level session.
    private var runningDescendants: [String: String] = [:]
    private var home: String?
    private var connection: OpenCodeConnectionMachine
    private var pump: Task<Void, Never>?
    private var eventID: UInt64 = 0
    private var continuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?

    static let pageSize = 100
    static let inventoryCap = 500
    /// Closed Sessions lists the newest archived sessions, one page.
    static let archivedCap = 100
    /// The instruction entry carrying a Chat Mode session's Chat Prompt. It
    /// reaches the model as `<context key="waycar-chat-prompt">` in the
    /// system prompt (live, OpenCode 2.2.7, 2026-11-11).
    static let chatPromptEntryKey = "waycar-chat-prompt"
    static let eventTypes = [
        "session.created", "session.renamed", "session.metadata.updated", "session.viewed",
        "session.archived", "session.unarchived", "session.deleted",
        "session.execution.started", "session.execution.succeeded", "session.execution.failed",
        "session.execution.interrupted", "permission.asked", "permission.replied",
        "form.created", "form.replied", "form.cancelled"
    ]
    private static let resolvedTags: Set<String> = [
        "PermissionNotFoundError", "FormNotFoundError", "FormAlreadySettledError"
    ]

    /// How far a `parentID` chain is followed to its top-level session.
    static let maximumDepth = 8

    private init(
        session: any HostSSHServices, presence: OpenCodePresence, endpoint: OpenCodeEndpoint,
        retryDelays: [Duration]
    ) {
        self.session = session
        self.presence = presence
        connection = OpenCodeConnectionMachine(retryDelays: retryDelays)
        client = UltimateHTTPClient(port: endpoint.port) {
            try await session.openOpenCodeChannel(host: endpoint.host, port: endpoint.port)
        }
    }

    deinit {
        pump?.cancel()
        continuation?.finish()
        if connection.releasesOnDeinit {
            let session = session
            Task { await session.release() }
        }
    }

    /// Reads the password, opens the event stream and returns after its
    /// first inventory. A failed open leaves the SSH hold with the caller.
    static func open(
        session: any HostSSHServices, presence: OpenCodePresence,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]
    ) async throws -> OpenCodeTransport {
        guard presence.isRunning, let endpoint = presence.endpoint else {
            throw TransportError.channelFailed(detail: "OpenCode's server is not running.")
        }
        let transport = OpenCodeTransport(
            session: session, presence: presence, endpoint: endpoint, retryDelays: retryDelays)
        do {
            try await transport.start()
            return transport
        } catch {
            await transport.abandon()
            throw transportError(error)
        }
    }

    private func start() async throws {
        try await readPassword()
        home = try? await session.remoteHomeDirectory()
        let (ready, readiness) = AsyncStream<Result<Void, any Error>>.makeStream()
        startReader(readiness: readiness)
        for await result in ready {
            try result.get()
            return
        }
        throw TransportError.cancelled
    }

    private func abandon() async {
        await perform(connection.handle(.abandon))
    }

    private func perform(_ effects: [OpenCodeConnectionMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .stopPump: pump?.cancel()
            case .endEvents: endEvents(id: eventID)
            case .forgetPassword: password = nil
            case .release: await session.release()
            case .lose(let failure):
                continuation?.finish(throwing: failure)
                continuation = nil
            case .opened, .reconnect, .rereadPassword, .wait, .failOpen:
                break // The pump's own steps (`receive`, `streamFailed`).
            }
        }
    }

    private static func transportError(_ error: any Error) -> TransportError {
        if let error = error as? TransportError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? UltimateHTTPError, error == .timedOut { return .timedOut }
        return .channelFailed(detail: "OpenCode: \(error)")
    }

    private func ensureOpen() throws {
        if let refusal = connection.refusal { throw refusal }
    }

    // MARK: Password and HTTP

    /// `cat` of the registration file (O6). Neither its output nor the
    /// password reaches an error, a log or anything persisted.
    private func readPassword() async throws {
        let path = presence.registrationPath
        let quoted = path.hasPrefix("~/") ? "\"$HOME\"/" + ShellWord.quoted(String(path.dropFirst(2)))
            : ShellWord.quoted(path)
        let result: SSHExecResult
        do { result = try await session.runExec("cat -- \(quoted)", input: Data(), timeout: nil) }
        catch let error as TransportError { throw error }
        catch is CancellationError { throw TransportError.cancelled }
        catch { throw TransportError.channelFailed(detail: "OpenCode: the server registration could not be read.") }
        // Close or distrust may have forgotten the password during the read.
        guard connection.keepsPassword else { throw TransportError.cancelled }
        guard result.exitStatus == 0,
              let value = try? JSONDecoder().decode(JSONValue.self, from: result.stdout),
              let password = value["password"]?.stringValue, !password.isEmpty
        else {
            throw TransportError.apiRejected(code: "opencode_password_unavailable",
                message: "Waycar could not read the OpenCode server's password on this Host.")
        }
        self.password = password
    }

    /// Whether the server password is in memory (tests: B-41).
    var holdsServerPassword: Bool { password != nil }

    private func authHeaders() -> [(String, String)] {
        [("Authorization", "Basic " + Data("opencode:\(password ?? "")".utf8).base64EncodedString())]
    }

    /// One request; a 401 re-reads the password once, a second is an auth
    /// failure. Non-2xx answers become `apiRejected` with OpenCode's `_tag`.
    @discardableResult
    private func send(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue? {
        try ensureOpen()
        let data = try body.map { try JSONEncoder().encode($0) }
        var response = try await perform(method, path, data)
        if response.head.status == 401 {
            try await readPassword()
            response = try await perform(method, path, data)
            if response.head.status == 401 { throw OpenCodeConnectionMachine.unauthorized }
        }
        let value = response.body.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: response.body)
        guard (200..<300).contains(response.head.status) else {
            let status = response.head.status
            throw TransportError.apiRejected(code: value?["_tag"]?.stringValue ?? "opencode_http_\(status)",
                message: value?["message"]?.stringValue ?? "OpenCode refused the request (HTTP \(status)).")
        }
        if !response.body.isEmpty, value == nil {
            throw TransportError.malformedResponse("OpenCode answered \(method) with a body that is not JSON.")
        }
        return value
    }

    private func perform(_ method: String, _ path: String, _ body: Data?) async throws -> UltimateHTTPResponse {
        do {
            return try await client.request(method: method, path: path, body: body, headers: authHeaders(),
                                            timeout: session.requestTimeout)
        } catch { throw Self.transportError(error) }
    }

    private static func segment(_ id: String) throws -> String {
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        }) else { throw TransportError.apiRejected(code: "agent_not_found", message: "Unknown OpenCode session.") }
        return id
    }

    private static func query(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func sessionID(_ target: String) throws -> String {
        try ensureOpen()
        guard target.hasPrefix("opencode:") else {
            throw TransportError.apiRejected(code: "agent_not_found", message: "Unknown OpenCode session.")
        }
        return try Self.segment(String(target.dropFirst("opencode:".count)))
    }

    // MARK: Inventory

    /// Top-level unarchived sessions, newest first, at most 500 (pick 1b).
    private func listSessions() async throws -> [OpenCodeSession] {
        var result: [OpenCodeSession] = []
        var seen: Set<String> = []
        var cursor: String?
        var cursors: Set<String> = []
        while true {
            var query = "parentID=null&archived=false&limit=\(Self.pageSize)"
            query += cursor.map { "&cursor=\(Self.query($0))" } ?? "&order=desc"
            let response = try await send("GET", "/api/session?\(query)")
            guard let page = response?["data"]?.codexArray else {
                throw TransportError.malformedResponse("OpenCode returned no session list.")
            }
            for value in page {
                if let entry = OpenCodeSession(value), seen.insert(entry.id).inserted { result.append(entry) }
            }
            // The list ends where `cursor.next` is null; a short page need
            // not be the last. An empty page or a repeated cursor ends it too.
            guard !page.isEmpty, result.count < Self.inventoryCap,
                  let next = response?["cursor"]?["next"]?.stringValue, cursors.insert(next).inserted else { break }
            cursor = next
        }
        return Array(result.prefix(Self.inventoryCap))
    }

    /// The newest archived top-level sessions (`archived=true` lists only
    /// those, contract check), for Closed Sessions. A server refusing the
    /// filter lists none rather than failing the connection.
    private func listArchived() async throws -> [String: ArchivedServerSession] {
        let response: JSONValue?
        do {
            response = try await send(
                "GET", "/api/session?parentID=null&archived=true&limit=\(Self.archivedCap)&order=desc")
        } catch TransportError.apiRejected { return [:] }
        let entries = (response?["data"]?.codexArray ?? []).compactMap(ArchivedServerSession.init(opencode:))
        return Dictionary(entries.map { ($0.sessionID, $0) }) { first, _ in first }
    }

    func archivedServerSessions() async -> [ArchivedServerSession] {
        archived.values.sorted { ($0.archivedAt, $0.sessionID) > ($1.archivedAt, $1.sessionID) }
    }

    /// Where each session came from: a Waycar launch leaves
    /// `metadata.waycar`, a desk session has no `metadata` (O9, O11). Only
    /// `user` sessions join the folder link (`ServerSessionLinks`).
    func serverSessionLinkFacts() async -> ServerSessionLinkFacts {
        ServerSessionLinkFacts(sessionOrigins: sessions.mapValues { session in
            switch session.metadata?["waycar"] {
            case nil, .null?: "user"
            default: "waycar"
            }
        })
    }

    /// Keeps `entry` among the archived sessions, at most `archivedCap`.
    private func noteArchived(_ entry: ArchivedServerSession) {
        archived[entry.sessionID] = entry
        guard archived.count > Self.archivedCap else { return }
        let kept = archived.values.sorted { $0.archivedAt > $1.archivedAt }.prefix(Self.archivedCap)
        archived = Dictionary(kept.map { ($0.sessionID, $0) }) { first, _ in first }
    }

    private func activeSessions() async throws -> Set<String> {
        guard case .object(let map)? = try await send("GET", "/api/session/active")?["data"] else {
            throw TransportError.malformedResponse("OpenCode returned no active sessions.")
        }
        return Set(map.compactMap { id, value in value["type"]?.stringValue == "running" ? id : nil })
    }

    private func fetchRequests(_ id: String, cwd: String?) async throws -> [OpenCodeRequest] {
        let segment = try Self.segment(id)
        let permissions = try await send("GET", "/api/session/\(segment)/permission")?["data"]?.codexArray ?? []
        let forms = try await send("GET", "/api/session/\(segment)/form")?["data"]?.codexArray ?? []
        return permissions.compactMap { OpenCodeRequest(permission: $0, cwd: cwd) }
            + forms.compactMap { OpenCodeRequest(form: $0) }
    }

    private func fetchSession(_ id: String) async throws -> OpenCodeSession? {
        do {
            guard let value = try await send("GET", "/api/session/\(Self.segment(id))") else { return nil }
            return OpenCodeSession(value["data"] ?? value)
        } catch TransportError.apiRejected(let code, _) where code == "SessionNotFoundError" { return nil }
    }

    /// The whole picture after a (re)connect: nothing is replayed. A running
    /// session that is not listed is a descendant when its `parentID` chain
    /// leads to a listed one: its requests go to that card.
    private func sync() async throws {
        let listed = try await listSessions()
        let archivedNow = try await listArchived()
        let active = try await activeSessions()
        var pending: [String: [OpenCodeRequest]] = [:]
        let byID = Dictionary(listed.map { ($0.id, $0) }) { first, _ in first }
        for entry in listed where active.contains(entry.id) {
            do { pending[entry.id] = try await fetchRequests(entry.id, cwd: entry.directory) }
            catch TransportError.apiRejected(let code, _) where code == "SessionNotFoundError" { continue }
        }
        var descendants: [String: String] = [:]
        for id in active.subtracting(byID.keys).sorted() {
            guard let root = await rootSession(of: id, roots: Set(byID.keys)) else { continue }
            descendants[id] = root
            do { pending[root, default: []] += try await fetchRequests(id, cwd: byID[root]?.directory) }
            catch TransportError.apiRejected(let code, _) where code == "SessionNotFoundError" { continue }
        }
        try ensureOpen()
        sessions = byID
        archived = archivedNow
        perform(activity.handle(.relisted(byID.mapValues(\.times), running: active)))
        runningDescendants = descendants
        requests = pending.filter { !$0.value.isEmpty }
        publishInventoryChange()
    }

    /// The listed top-level session `id` belongs to: itself, or the first
    /// listed one up its `parentID` chain, read from the server where the
    /// chain is not known yet. Nil for a chain that leads to no listed
    /// session (archived, past the cap) or that cannot be read.
    private func rootSession(of id: String, roots: Set<String>? = nil) async -> String? {
        var current = id
        for _ in 0..<Self.maximumDepth {
            if roots?.contains(current) ?? (sessions[current] != nil) { return current }
            if let parent = parents[current] {
                current = parent
                continue
            }
            guard let segment = try? Self.segment(current),
                  let value = try? await send("GET", "/api/session/\(segment)"),
                  let parent = (value["data"] ?? value)["parentID"]?.stringValue, !parent.isEmpty
            else { return nil }
            parents[current] = parent
            current = parent
        }
        return nil
    }

    /// `rootSession(of:)` from what is already known, with no read.
    private func knownRoot(of id: String) -> String? {
        var current = id
        for _ in 0..<Self.maximumDepth {
            if sessions[current] != nil { return current }
            if let root = runningDescendants[current] { return root }
            guard let parent = parents[current] else { return nil }
            current = parent
        }
        return nil
    }

    private var statuses: [String: AgentStatus] {
        sessions.mapValues { activity.status($0.id, blocked: !(requests[$0.id] ?? []).isEmpty) ?? .idle }
    }

    private func info(_ id: String) -> AgentInfo? {
        guard let entry = sessions[id] else { return nil }
        return entry.info(status: statuses[id] ?? .idle)
    }

    func ping() async throws -> ServerInfo {
        let info = try await send("GET", "/api/info")
        return ServerInfo(
            version: info?["version"]?.stringValue ?? presence.version, protocolVersion: 0, backend: .opencode)
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        try ensureOpen()
        return OpenCodeSnapshotBuilder.snapshot(sessions: Array(sessions.values), statuses: statuses,
                                               home: home, version: presence.version)
    }

    func listAgents() async throws -> [Agent] { try await sessionSnapshot().agents.map(Agent.init) }

    /// Marks the session's latest result seen, as OpenCode's own clients do
    /// when they show it (`POST /view`, which emits `session.viewed`). The
    /// Console decides when a read counts as a view.
    func markViewed(target: String) async throws {
        let id = try sessionID(target)
        for case .postView(let idle) in activity.handle(.viewRequested(id)) {
            try await send("POST", "/api/session/\(id)/view", body: .object(["idle": .number(idle)]))
            perform(activity.handle(.viewPosted(id, idle: idle)))
        }
    }

    /// What `activity` asks of the inventory; `.postView` is `markViewed`'s.
    private func perform(_ effects: [OpenCodeActivityMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .publish: publishInventoryChange()
            case .postView: break
            }
        }
    }

    // MARK: Chat

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        try await prompt(target: params.target, text: params.text, files: [])
    }

    /// A running session takes the prompt too: OpenCode steers it in (O13).
    func prompt(target: String, text: String, files: [OpenCodePromptFile]) async throws -> Agent {
        let id = try sessionID(target)
        guard let info = info(id) else {
            throw TransportError.apiRejected(code: "agent_not_found", message: "This OpenCode session is no longer listed.")
        }
        var body: [String: JSONValue] = ["text": .string(text)]
        if !files.isEmpty {
            body["files"] = .array(files.map { file in
                var entry: [String: JSONValue] = [
                    "uri": .string("data:\(file.mime);base64,\(file.data.base64EncodedString())")]
                if let name = file.name { entry["name"] = .string(name) }
                return .object(entry)
            })
        }
        try await send("POST", "/api/session/\(id)/prompt", body: .object(body))
        return Agent(info)
    }

    /// A prompt queued before Stop stays queued on the Host (O16).
    func abortAgentRun(target: String) async throws {
        let id = try sessionID(target)
        try await send("POST", "/api/session/\(id)/interrupt")
    }

    /// Newest first, at most four pages of 100 history items (O15).
    func readChatTranscript(_ request: ChatTranscriptRequest) async throws -> ChatTranscriptSnapshot {
        let id = try sessionID(request.paneID)
        var items: [JSONValue] = []
        var cursor: String?
        var cursors: Set<String> = []
        var more = false
        for _ in 0..<4 {
            let query = cursor.map { "cursor=\(Self.query($0))" } ?? "order=desc"
            let page = try await send("GET", "/api/session/\(id)/message?limit=\(Self.pageSize)&\(query)")
            guard let values = page?["data"]?.codexArray else {
                throw TransportError.malformedResponse("OpenCode returned no message list.")
            }
            items.append(contentsOf: values)
            // History ends where `cursor.next` is null (or on an empty page).
            let next = page?["cursor"]?["next"]?.stringValue
            more = !values.isEmpty && next != nil
            guard more, let next, cursors.insert(next).inserted else { more = false; break }
            cursor = next
            if let after = request.after, OpenCodeSnapshotBuilder.transcript(
                sessionID: id, items: items, truncated: true, running: false, after: after).header.afterFound { break }
        }
        return OpenCodeSnapshotBuilder.transcript(sessionID: id, items: items, truncated: more,
                                                  running: activity.isRunning(id), after: request.after)
    }

    /// A user prompt's image (`/<messageID>/files/<n>/data`, from the
    /// transcript), fetched from that one message.
    func readChatMedia(_ request: ChatMediaRequest) async throws -> Data {
        guard case .sessionInline(let session, _, let pointer, _, let maxBytes) = request else {
            throw ChatMediaError.unsupported
        }
        let parts = pointer.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[2] == "files", parts[4] == "data",
              let index = Int(parts[3]), index >= 0 else { throw ChatMediaError.unsupported }
        try ensureOpen()
        let value = try await send("GET", "/api/session/\(Self.segment(session))/message/\(Self.segment(String(parts[1])))")
        let files = (value?["data"] ?? value)?["files"]?.codexArray ?? []
        guard index < files.count, let base64 = files[index]["data"]?.stringValue else {
            throw ChatMediaError.unavailable
        }
        guard base64.utf8.count / 4 * 3 <= maxBytes + 2 else { throw ChatMediaError.tooLarge }
        guard let data = Data(base64Encoded: base64), data.count <= maxBytes else {
            throw ChatMediaError.unavailable
        }
        return data
    }

    // MARK: Requests

    /// The session's own requests and those of its running descendants.
    func pendingAgentRequests(target: String) async throws -> [AgentPendingRequest] {
        let id = try sessionID(target)
        let cwd = sessions[id]?.directory
        var fetched = try await fetchRequests(id, cwd: cwd)
        let children = Set(runningDescendants.filter { $0.value == id }.keys)
            .union((requests[id] ?? []).map(\.sessionID).filter { $0 != id })
        for child in children.sorted() {
            do { fetched += try await fetchRequests(child, cwd: cwd) }
            catch TransportError.apiRejected(let code, _) where code == "SessionNotFoundError" {
                runningDescendants[child] = nil
            }
        }
        if fetched != requests[id] ?? [] {
            requests[id] = fetched.isEmpty ? nil : fetched
            publishInventoryChange()
        }
        return fetched.map(\.pending)
    }

    func answerAgentRequest(target: String, requestID: String, answer: AgentRequestAnswer) async throws {
        let id = try sessionID(target)
        var entry = requests[id]?.first { $0.id == requestID }
        if entry == nil {
            _ = try await pendingAgentRequests(target: target)
            entry = requests[id]?.first { $0.id == requestID }
        }
        guard let entry else { throw Self.resolved }
        let request = try Self.segment(entry.id)
        // A descendant's request is answered in the session that raised it.
        let raisedBy = try Self.segment(entry.sessionID)
        let path: String
        let body: JSONValue
        switch (entry.source, entry.kind, answer) {
        case (.permission, .command, .allow), (.permission, .fileChange, .allow):
            path = "permission/\(request)/reply"
            body = .object(["decision": .string("once")])
        case (.permission, .command, .cancel), (.permission, .fileChange, .cancel):
            path = "permission/\(request)/reply"
            body = .object(["decision": .string("reject")])
        case (.form, .questions, .answers(let answers)):
            path = "form/\(request)/reply"
            body = .object(["answer": entry.formAnswer(answers)])
        default: throw unsupported
        }
        do { try await send("POST", "/api/session/\(raisedBy)/\(path)", body: body) }
        catch TransportError.apiRejected(let code, _) where Self.resolvedTags.contains(code) {
            removeRequest(entry.id, session: id)
            throw Self.resolved
        }
        removeRequest(entry.id, session: id)
    }

    private static let resolved = TransportError.apiRejected(
        code: "agent_request_resolved", message: "This request was already resolved.")

    private func removeRequest(_ requestID: String, session id: String) {
        guard let before = requests[id] else { return }
        let after = before.filter { $0.id != requestID }
        guard after.count != before.count else { return }
        requests[id] = after.isEmpty ? nil : after
        publishInventoryChange()
    }

    // MARK: Start, archive, unarchive

    /// Creates (or, for an id it already has, returns) the session, then
    /// sends the first message. The id is the Launch Tag (O11).
    func startSession(_ launch: OpenCodeSessionLaunch) async throws -> Agent {
        try ensureOpen()
        guard launch.sessionID.hasPrefix("ses_") else {
            throw TransportError.apiRejected(code: "invalid_session_id", message: "Not an OpenCode session id.")
        }
        let id = try Self.segment(launch.sessionID)
        var body: [String: JSONValue] = [
            "id": .string(id), "title": .string(launch.title),
            "metadata": .object(["waycar": .object(["launch": .string(id), "origin": .string("waycar")])]),
            "location": .object(["directory": .string(launch.directory)])
        ]
        if let model = launch.model {
            body["model"] = .object(["id": .string(model.id), "providerID": .string(model.providerID)])
        }
        let created = try await send("POST", "/api/session", body: .object(body))
        guard let value = created?["data"] ?? created, let entry = OpenCodeSession(value), entry.id == id else {
            throw TransportError.malformedResponse("OpenCode returned no new session.")
        }
        if sessions[id] == nil {
            sessions[id] = entry
            perform(activity.handle(.listed(id, entry.times)))
            publishInventoryChange()
        }
        // Putting the entry replaces it, so a retry repeats it harmlessly.
        if let instructions = launch.instructions, !instructions.isEmpty {
            try await send("PUT", "/api/experimental/session/\(id)/instructions/entries/\(Self.chatPromptEntryKey)",
                           body: .object(["value": .string(instructions)]))
        }
        if let message = launch.firstMessage, !message.isEmpty {
            var started = false
            if launch.mayHaveStarted {
                let history = try await send("GET", "/api/session/\(id)/message?limit=1&order=desc")
                started = !(history?["data"]?.codexArray ?? []).isEmpty
            }
            if !started { try await send("POST", "/api/session/\(id)/prompt", body: .object(["text": .string(message)])) }
        }
        return Agent(info(id) ?? entry.info(status: .idle))
    }

    /// New Agent's create, with the id its launch minted once
    /// (`OpenCodeLaunchOptions.sessionID`): a retry creates the same session.
    /// A request without one may not retry. A Closed Session's Resume
    /// (`OpenCodeLaunchOptions.resumeSessionID`) unarchives that session
    /// instead, which is safe to repeat.
    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        try ensureOpen()
        guard request.kind == SupportedAgentKind.opencode.rawValue else { throw unsupported }
        if let resumed = request.opencode?.resumeSessionID {
            let id = try Self.segment(resumed)
            try await setArchived(sessionID: id, false)
            guard let info = info(id) else {
                throw TransportError.apiRejected(
                    code: "agent_not_found", message: "This OpenCode session is no longer on the Host.")
            }
            return Agent(info)
        }
        let options = request.opencode
        guard let sessionID = options?.sessionID ?? (request.mayHaveStarted ? nil : OpenCodeSessionID.mint())
        else { throw unsupported }
        let directory: String
        if let cwd = request.cwd { directory = cwd } else { directory = try await session.remoteHomeDirectory() }
        return try await startSession(OpenCodeSessionLaunch(
            sessionID: sessionID, title: request.name, directory: directory,
            model: options?.model.flatMap(OpenCodeSessionLaunch.Model.init(selector:)),
            instructions: options?.instructions, mayHaveStarted: request.mayHaveStarted))
    }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        try await startAgent(AgentLaunchRequest(
            kind: request.kind, name: request.name, cwd: workspace.directory,
            launchID: request.launchID, mayHaveStarted: request.mayHaveStarted, opencode: request.opencode))
    }

    /// Archive (the Agent's Archive action, card 1530 1a) or unarchive (a
    /// Closed Session's Resume): `PATCH /api/session/{id} {archived}`.
    func setArchived(sessionID: String, _ archived: Bool) async throws {
        try ensureOpen()
        let id = try Self.segment(sessionID)
        try await send("PATCH", "/api/session/\(id)", body: .object(["archived": .bool(archived)]))
        if archived {
            guard let entry = sessions.removeValue(forKey: id) else { return }
            noteArchived(entry.archived(at: Date()))
            forget(id)
            publishInventoryChange()
        } else {
            let wasArchived = self.archived.removeValue(forKey: id) != nil
            if sessions[id] == nil, let entry = try await fetchSession(id), sessions[id] == nil {
                sessions[id] = entry
                perform(activity.handle(.listed(id, entry.times)))
            } else if !wasArchived { return }
            publishInventoryChange()
        }
    }

    /// An OpenCode session never closes; closing its card archives it.
    func closePane(_ params: PaneTarget, closesWorktreeGroup: Bool) async throws {
        try await setArchived(sessionID: sessionID(params.paneID), true)
    }

    /// The Console row's swipe (**Archive**): a session is its own tab.
    func closeTab(_ params: TabTarget) async throws {
        try await setArchived(sessionID: sessionID(params.tabID), true)
    }

    // MARK: Events

    private static var eventPath: String {
        "/api/event?" + eventTypes.map { "types=\($0)" }.joined(separator: "&")
    }

    /// One stream for the transport's life, driven by `connection`: a
    /// dropped stream reconnects after `retryDelays`; when they run out the
    /// transport is lost and the connector replaces it.
    private func startReader(readiness: AsyncStream<Result<Void, any Error>>.Continuation) {
        let client = client
        pump = Task { [weak self] in
            defer { readiness.finish() }
            while !Task.isCancelled {
                do {
                    guard let headers = await self?.streamHeaders() else { return }
                    for try await event in client.events(path: Self.eventPath, headers: headers) {
                        guard let self else { return }
                        if try await self.receive(event) { readiness.yield(.success(())) }
                    }
                    throw TransportError.channelFailed(detail: "OpenCode ended its event stream.")
                } catch {
                    if Task.isCancelled { return }
                    switch await self?.streamFailed(error) {
                    case .reconnect?: continue
                    case .wait(let delay)?:
                        do { try await Task.sleep(for: delay) } catch { return }
                    case .failOpen(let failure)?:
                        readiness.yield(.failure(failure))
                        return
                    case .stop?, nil: return
                    }
                }
            }
        }
    }

    /// What the pump does after a failed stream.
    private enum StreamStep: Sendable {
        case reconnect
        case wait(Duration)
        case failOpen(TransportError)
        case stop
    }

    /// The headers for the next stream request, which ends any backoff.
    private func streamHeaders() -> [(String, String)] {
        _ = connection.handle(.connecting)
        return authHeaders()
    }

    /// Feeds a stream failure to `connection`, re-reads the password when it
    /// asks, and says what the pump does next.
    private func streamFailed(_ error: any Error) async -> StreamStep {
        let unauthorized = (error as? UltimateHTTPError) == UltimateHTTPError.status(401)
        var effects = connection.handle(.streamFailed(Self.transportError(error), unauthorized: unauthorized))
        var step = StreamStep.stop
        while !effects.isEmpty {
            let effect = effects.removeFirst()
            switch effect {
            case .rereadPassword:
                do {
                    try await readPassword()
                    effects += connection.handle(.passwordRead(nil))
                } catch {
                    effects += connection.handle(.passwordRead(Self.transportError(error)))
                }
            case .reconnect: step = .reconnect
            case .wait(let delay): step = .wait(delay)
            case .failOpen(let failure): step = .failOpen(failure)
            case .opened, .lose, .stopPump, .endEvents, .forgetPassword, .release:
                await perform([effect])
            }
        }
        return step
    }

    /// Applies one event; true once the first `server.connected` has been
    /// followed by a complete re-read.
    private func receive(_ event: UltimateServerEvent) async throws -> Bool {
        guard connection.isLive,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8)),
              let type = value["type"]?.stringValue
        else { return false }
        if type == "server.connected" {
            try await sync()
            return connection.handle(.relisted).contains(.opened)
        }
        let data = value["data"]
        guard let id = data?["sessionID"]?.stringValue ?? data?["form"]?["sessionID"]?.stringValue else { return false }
        if sessions[id] == nil, archived[id] == nil, await receiveDescendant(type, id: id, data: data) { return false }
        var changed = false
        switch type {
        case "session.created", "session.unarchived":
            if type == "session.unarchived", archived.removeValue(forKey: id) != nil { changed = true }
            guard sessions[id] == nil, data?["parentID"] == nil || data?["parentID"] == .null,
                  let entry = try await fetchSession(id), sessions[id] == nil else { break }
            sessions[id] = entry
            perform(activity.handle(.listed(id, entry.times)))
            changed = true
        case "session.renamed":
            guard sessions[id] != nil, let title = data?["title"]?.stringValue, sessions[id]?.title != title else { break }
            sessions[id]?.title = title
            changed = true
        case "session.metadata.updated":
            let metadata = data?["metadata"] == .null ? nil : data?["metadata"]
            guard sessions[id] != nil, sessions[id]?.metadata != metadata else { break }
            sessions[id]?.metadata = metadata
            changed = true
        case "session.viewed":
            guard sessions[id] != nil, let idle = data?["idle"]?.codexNumber else { break }
            changed = activity.handle(.viewed(id, idle: idle)).contains(.publish)
        case "session.archived":
            let archivedAt = value["created"]?.codexNumber.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            if let entry = sessions.removeValue(forKey: id) {
                noteArchived(entry.archived(at: archivedAt))
                changed = true
            } else if archived[id] == nil, let segment = try? Self.segment(id),
                      let read = try? await send("GET", "/api/session/\(segment)"),
                      let entry = ArchivedServerSession(opencode: read["data"] ?? read) {
                // Archived beyond the listed cap, or listed by no read yet.
                noteArchived(entry)
                changed = true
            }
            forget(id)
        case "session.deleted":
            changed = sessions.removeValue(forKey: id) != nil
            if archived.removeValue(forKey: id) != nil { changed = true }
            forget(id)
        case "session.execution.started":
            changed = sessions[id] != nil && activity.handle(.started(id)).contains(.publish)
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            guard sessions[id] != nil else { break }
            _ = activity.handle(.ended(id, at: value["created"]?.codexNumber ?? Date().timeIntervalSince1970 * 1000,
                                       reason: data?["reason"]?.stringValue))
            // Only this session's own requests end with its turn: a
            // subagent's child can outlive it (2.2.7), so its tracking and
            // requests stay until the child ends or its request resolves.
            let descendants = (requests[id] ?? []).filter { $0.sessionID != id }
            requests[id] = descendants.isEmpty ? nil : descendants
            sessions[id]?.outcome = String(type.dropFirst("session.execution.".count))
            changed = true
        case "permission.asked":
            guard sessions[id] != nil, let request = OpenCodeRequest(permission: data ?? .null, cwd: sessions[id]?.directory)
            else { break }
            requests[id, default: []].removeAll { $0.id == request.id }
            requests[id, default: []].append(request)
            changed = true
        case "form.created":
            guard sessions[id] != nil, let request = OpenCodeRequest(form: data?["form"] ?? .null) else { break }
            requests[id, default: []].removeAll { $0.id == request.id }
            requests[id, default: []].append(request)
            changed = true
        case "permission.replied":
            if let request = data?["requestID"]?.stringValue { removeRequest(request, session: id) }
        case "form.replied", "form.cancelled":
            if let request = data?["id"]?.stringValue { removeRequest(request, session: id) }
        default: break
        }
        if changed { publishInventoryChange() }
        return false
    }

    /// Drops what a session that left the list (archived, deleted) kept.
    private func forget(_ id: String) {
        _ = activity.handle(.unlisted(id))
        requests.removeValue(forKey: id)
        runningDescendants = runningDescendants.filter { $0.value != id }
    }

    /// One event about a session that is not listed: true when it was a
    /// descendant's (or a child's creation), which this handled. A request
    /// a descendant raises goes onto its top-level session's card; its turn
    /// ending drops what it still asked. Nothing here changes the top-level
    /// session's own turn or Done.
    private func receiveDescendant(_ type: String, id: String, data: JSONValue?) async -> Bool {
        switch type {
        case "session.created":
            guard let parent = data?["parentID"]?.stringValue, !parent.isEmpty else { return false }
            parents[id] = parent
            return true
        case "session.execution.started":
            guard let root = await rootSession(of: id) else { return true }
            runningDescendants[id] = root
            return true
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            guard let root = runningDescendants.removeValue(forKey: id) ?? knownRoot(of: id),
                  let before = requests[root] else { return true }
            let after = before.filter { $0.sessionID != id }
            if after.count != before.count {
                requests[root] = after.isEmpty ? nil : after
                publishInventoryChange()
            }
            return true
        case "permission.asked", "form.created":
            guard let root = await rootSession(of: id), sessions[root] != nil else { return true }
            let cwd = sessions[root]?.directory
            let request = type == "form.created"
                ? OpenCodeRequest(form: data?["form"] ?? .null)
                : OpenCodeRequest(permission: data ?? .null, cwd: cwd)
            guard let request else { return true }
            runningDescendants[id] = root
            requests[root, default: []].removeAll { $0.id == request.id }
            requests[root, default: []].append(request)
            publishInventoryChange()
            return true
        case "permission.replied":
            if let root = knownRoot(of: id), let request = data?["requestID"]?.stringValue {
                removeRequest(request, session: root)
            }
            return true
        case "form.replied", "form.cancelled":
            if let root = knownRoot(of: id), let request = data?["id"]?.stringValue {
                removeRequest(request, session: root)
            }
            return true
        default:
            return false
        }
    }

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        try ensureOpen()
        guard continuation == nil else { throw TransportError.eventsChannelAlreadyOpen }
        eventID &+= 1
        let id = eventID
        let (events, output) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(HerdrEventStream.bufferLimit))
        continuation = output
        output.onTermination = { [weak self] _ in Task { await self?.endEvents(id: id) } }
        return HerdrEventStream(events: events) { [weak self] in await self?.endEvents(id: id) }
    }

    private func publishInventoryChange() {
        let event = HerdrEvent(kind: GlobalEventKind.workspaceMetadataUpdated.kind, data: .object([:]))
        if case .dropped = continuation?.yield(event) { _ = continuation?.yield(.eventsDropped) }
    }

    private func endEvents(id: UInt64) {
        guard id == eventID else { return }
        let output = continuation
        continuation = nil
        output?.finish()
    }

    var isConnected: Bool {
        get async {
            guard connection.isLive else { return false }
            return await session.isConnected
        }
    }

    func close() async throws {
        await perform(connection.handle(.close))
    }

    func transportDistrusted() async {
        await perform(connection.handle(.distrust))
    }

    /// Opening an OpenCode Agent marks its result seen, as OpenCode's own
    /// clients do (`markViewed`).
    func focusAgent(_ target: AgentTarget) async throws { try await markViewed(target: target.target) }
    func remoteHomeDirectory() async throws -> String { try await session.remoteHomeDirectory() }
    func listDirectories(at path: String) async throws -> RemoteDirectoryListing { try await session.listDirectories(at: path) }
    func availableAgentKinds() async throws -> [SupportedAgentKind] { [.opencode] }

    // MARK: No terminal of its own

    private var unsupported: TransportError {
        .apiRejected(code: "unsupported", message: "OpenCode sessions support messages and Chat Mode only.")
    }
    func checkAgentInputScreen(target: String) async throws { try ensureOpen() }
    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult { throw unsupported }
    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult { throw unsupported }
    func sendAgentKeys(_ params: AgentSendKeysParams) async throws { throw unsupported }
    func sendPaneInput(_ params: PaneSendInputParams) async throws { throw unsupported }
    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec, attempt: WorktreeLaunchAttempt
    ) async throws -> Agent { throw unsupported }
    func movePane(_ params: PaneMoveParams) async throws -> PaneMoveResponse { throw unsupported }
    func renameAgent(_ params: AgentRenameParams) async throws { throw unsupported }
    func renameWorkspace(_ params: WorkspaceRenameParams) async throws { throw unsupported }
    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession { throw unsupported }
    func probeMoshServer() async throws -> Bool { false }
    func runMoshBootstrap(_ request: TerminalAttachRequest) async throws -> MoshBootstrap { throw unsupported }
}
