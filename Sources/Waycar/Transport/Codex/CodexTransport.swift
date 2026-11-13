import Foundation

/// Loaded chats on the Host's shared daemon. One RPC reader owns inventory,
/// status and approvals; losing it hands recovery to the connector, never a
/// second connection hidden inside this transport.
actor CodexTransport: Transport {
    let session: any HostSSHServices
    let presence: CodexPresence
    private let rpc: CodexRPCClient
    private var threads: [String: CodexThread] = [:]
    private var subscriptions = CodexSubscriptionMachine()
    /// The `thread/resume` in flight per thread, by `subscriptions`' token.
    private var resumes: [String: Resume] = [:]
    private var turns = CodexActiveTurnMachine()
    private var approvals = CodexApprovalMachine()
    private var home: String?
    private var connection = CodexConnectionMachine()
    private var pump: Task<Void, Never>?
    private var eventID: UInt64 = 0
    private var continuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?

    private struct Resume {
        let token: UInt64
        let task: Task<JSONValue, any Error>
    }

    private init(session: any HostSSHServices, presence: CodexPresence, rpc: CodexRPCClient) {
        self.session = session
        self.presence = presence
        self.rpc = rpc
    }

    deinit {
        pump?.cancel()
        for resume in resumes.values { resume.task.cancel() }
        continuation?.finish()
        let rpc = rpc
        let session = session
        let release = connection.releasesOnDeinit
        Task {
            await rpc.close()
            if release { await session.release() }
        }
    }

    static func open(session: any HostSSHServices, presence: CodexPresence) async throws -> CodexTransport {
        guard let path = presence.socketPath else {
            throw TransportError.channelFailed(detail: "Codex has no running app-server socket.")
        }
        return try await open(session: session, presence: presence,
                              channel: session.openCodexChannel(socketPath: path))
    }

    /// The channel overload also exercises production admission with a duplex
    /// test server. Failed admission closes only what it opened: the caller
    /// still owns the shared SSH hold (as with UltimateTransport.open).
    static func open(
        session: any HostSSHServices, presence: CodexPresence, channel: any UltimateByteChannel
    ) async throws -> CodexTransport {
        let socket = try await CodexWebSocket.connect(channel: channel)
        let rpc = await CodexRPCClient.connect(webSocket: socket, requestTimeout: session.requestTimeout)
        let transport = CodexTransport(session: session, presence: presence, rpc: rpc)
        do {
            _ = try await rpc.initialize(clientName: "waycar",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
            try await transport.loadInventory()
            try Task.checkCancellation()
            await transport.startReader()
            return transport
        } catch {
            await transport.abandon()
            throw Self.transportError(error)
        }
    }

    private func abandon() async {
        await perform(connection.handle(.abandon))
    }

    private func perform(_ effects: [CodexConnectionMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .failEvents:
                continuation?.finish(throwing: CodexConnectionMachine.ended)
                continuation = nil
            case .stopReader: pump?.cancel()
            case .cancelResumes: for resume in resumes.values { resume.task.cancel() }
            case .endEvents: endEvents(id: eventID)
            case .closeRPC: await rpc.close()
            case .release: await session.release()
            }
        }
    }

    private static func transportError(_ error: any Error) -> TransportError {
        if let error = error as? TransportError { return error }
        if let error = error as? CodexRPCError {
            return .apiRejected(code: String(error.code), message: error.message)
        }
        if error is CancellationError { return .cancelled }
        return .channelFailed(detail: "Codex: \(error)")
    }

    private func ensureOpen() throws {
        if let refusal = connection.refusal { throw refusal }
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try ensureOpen()
        do { return try await rpc.request(method: method, params: .object(params)) }
        catch { throw Self.transportError(error) }
    }

    private func loadedThreads() async throws -> [CodexThread] {
        var result: [CodexThread] = []
        var cursor: String?
        var cursors: Set<String> = []
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await request("thread/loaded/list", params)
            guard let ids = page["data"]?.codexArray else {
                throw TransportError.channelFailed(detail: "Codex returned no loaded thread list.")
            }
            for value in ids {
                guard let id = value.stringValue else { continue }
                do {
                    let read = try await request("thread/read", ["threadId": .string(id)])
                    if let value = read["thread"], let thread = CodexThread(value) { result.append(thread) }
                } catch let error as TransportError {
                    // A single thread may have unloaded between list and read.
                    if case .apiRejected = error { continue }
                    throw error
                }
            }
            cursor = page["nextCursor"]?.stringValue
            if let cursor, !cursors.insert(cursor).inserted { break }
        } while cursor != nil
        return result
    }

    private func loadInventory() async throws {
        for thread in try await loadedThreads() { threads[thread.id] = thread }
        home = try? await session.remoteHomeDirectory()
    }

    func ping() async throws -> ServerInfo {
        _ = try await request("thread/loaded/list", ["limit": .number(1)])
        return ServerInfo(version: presence.appServerVersion ?? presence.version, protocolVersion: 0, backend: .codex)
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        try ensureOpen()
        return CodexSnapshotBuilder.snapshot(threads: Array(threads.values), home: home,
                                            version: presence.appServerVersion ?? presence.version)
    }

    func serverSessionLinkFacts() async -> ServerSessionLinkFacts {
        ServerSessionLinkFacts(sessionOrigins: threads.compactMapValues(\.threadSource))
    }

    func listAgents() async throws -> [Agent] { try await sessionSnapshot().agents.map(Agent.init) }

    private func threadID(_ target: String) throws -> String {
        try ensureOpen()
        guard target.hasPrefix("codex:"), target.count > 6 else {
            throw TransportError.apiRejected(code: "agent_not_found", message: "Unknown Codex thread.")
        }
        return String(target.dropFirst(6))
    }

    /// Kept until connection close. Listing alone never resumes a thread.
    private func ensureSubscribed(_ id: String) async throws {
        guard let resume = subscribe(.needed(id)) else { return }
        do {
            let response = try await resume.task.value
            try ensureOpen()
            _ = subscribe(.resumed(id, token: resume.token))
            // A resume response must not overwrite newer broadcast status.
            if threads[id] == nil, let value = response["thread"], let thread = CodexThread(value) {
                threads[id] = thread
                publishInventoryChange()
            }
        } catch {
            _ = subscribe(.resumeFailed(id, token: resume.token))
            throw Self.transportError(error)
        }
    }

    /// Feeds `subscriptions` and performs its effects; returns the resume
    /// to wait for, if it asked for one.
    private func subscribe(_ event: CodexSubscriptionMachine.Event) -> Resume? {
        var waiting: Resume?
        for effect in subscriptions.handle(event) {
            switch effect {
            case .resume(let thread, let token):
                let rpc = rpc
                let task = Task {
                    try await rpc.request(method: "thread/resume", params: .object([
                        "threadId": .string(thread), "excludeTurns": .bool(true)]))
                }
                resumes[thread] = Resume(token: token, task: task)
            case .wait(let thread, let token):
                if let resume = resumes[thread], resume.token == token { waiting = resume }
            case .forget(let thread):
                resumes[thread] = nil
            }
        }
        return waiting
    }

    private func newestTurn(_ id: String) async throws -> JSONValue? {
        let page = try await request("thread/turns/list", ["threadId": .string(id), "limit": .number(1)])
        guard let turns = page["data"]?.codexArray else {
            throw TransportError.channelFailed(detail: "Codex returned no turn list.")
        }
        return turns.first
    }

    private func activeTurn(_ id: String) async throws -> String? {
        switch turns.handle(.needed(id, active: threads[id]?.active == true)).first {
        case .use(let turn)?:
            return turn
        case .lookUp(let token)?:
            let turn: JSONValue?
            do { turn = try await newestTurn(id) } catch {
                // Every throwing exit releases the read (review 177084).
                _ = turns.handle(.lookupFailed(id, token: token))
                throw error
            }
            let running = turn?["status"]?.stringValue == "inProgress" ? turn?["id"]?.stringValue : nil
            guard case .use(let turnID)? = turns.handle(.lookedUp(id, token: token, running: running)).first
            else { return nil }
            return turnID
        case nil:
            return nil
        }
    }

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        let id = try threadID(params.target)
        try await ensureSubscribed(id)
        guard let info = threads[id]?.info else { throw unsupported }
        let input: JSONValue = .array([.object(["type": .string("text"), "text": .string(params.text)])])
        if let turnID = try await activeTurn(id) {
            do {
                _ = try await request("turn/steer", ["threadId": .string(id), "expectedTurnId": .string(turnID), "input": input])
                return Agent(info)
            } catch let error as TransportError {
                guard case .apiRejected = error else { throw error }
                // Every server error uses -32600. Prove the turn ended rather
                // than retrying a policy/validation refusal as a new prompt.
                let newest = try await newestTurn(id)
                guard newest?["status"]?.stringValue != "inProgress" else { throw error }
                _ = turns.handle(.ended(id))
            }
        }
        _ = try await request("turn/start", ["threadId": .string(id), "input": input])
        // The subscriber's turn events own the known turn. A start response can
        // already be stale when a very short turn completes before we resume.
        return Agent(info)
    }

    func abortAgentRun(target: String) async throws {
        let id = try threadID(target)
        guard let turn = try await activeTurn(id) else { return }
        _ = try await request("turn/interrupt", ["threadId": .string(id), "turnId": .string(turn)])
    }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        try ensureOpen()
        guard request.kind == "codex" else { throw unsupported }
        if let id = request.codex?.resumeThreadID {
            try await ensureSubscribed(id)
            guard let thread = threads[id] else { throw unsupported }
            return Agent(thread.info)
        }
        let cwd: String
        if let requested = request.cwd { cwd = requested }
        else { cwd = try await session.remoteHomeDirectory() }
        // The name is the Launch Tag. Codex canonicalizes cwd (X22), so a
        // symlinked folder must not turn a lost answer into a second launch.
        if request.mayHaveStarted {
            let loaded = try await loadedThreads()
            let folder = CodexThread.normalizedCwd(cwd)
            let named = loaded.filter {
                $0.threadSource == "waycar" && $0.name == request.name
            }.max { first, second in
                let firstMatches = CodexThread.normalizedCwd(first.cwd) == folder
                let secondMatches = CodexThread.normalizedCwd(second.cwd) == folder
                return firstMatches == secondMatches ? first.createdAt < second.createdAt : !firstMatches
            }
            // A lost link may have committed thread/start but not name/set.
            // Never adopt a desk TUI or a thread that already has a conversation.
            let unnamed = loaded.filter {
                $0.isEmpty && $0.threadSource == "waycar" && CodexThread.normalizedCwd($0.cwd) == folder
            }.max { $0.createdAt < $1.createdAt }
            if let existing = named ?? unnamed {
                if threads[existing.id] == nil { threads[existing.id] = existing }
                try await ensureSubscribed(existing.id)
                if named == nil {
                    _ = try await self.request("thread/name/set", [
                        "threadId": .string(existing.id), "name": .string(request.name)])
                    threads[existing.id]?.name = request.name
                }
                publishInventoryChange()
                return Agent(threads[existing.id]?.info ?? existing.info)
            }
        }
        var params: [String: JSONValue] = ["cwd": .string(cwd), "threadSource": .string("waycar")]
        if let instructions = request.codex?.developerInstructions { params["developerInstructions"] = .string(instructions) }
        if let model = request.codex?.model { params["model"] = .string(model) }
        if let effort = request.codex?.reasoningEffort {
            params["config"] = .object(["model_reasoning_effort": .string(effort)])
        }
        let response = try await self.request("thread/start", params)
        guard let value = response["thread"], let thread = CodexThread(value) else {
            throw TransportError.channelFailed(detail: "Codex returned no new thread.")
        }
        _ = subscribe(.started(thread.id))
        if threads[thread.id] == nil {
            threads[thread.id] = thread
            publishInventoryChange()
        }
        _ = try await self.request("thread/name/set", ["threadId": .string(thread.id), "name": .string(request.name)])
        // Preserve broadcast status, and do not publish a second change if
        // thread/name/updated already delivered this exact name.
        if threads[thread.id] != nil, threads[thread.id]?.name != request.name {
            threads[thread.id]?.name = request.name
            publishInventoryChange()
        }
        return Agent(threads[thread.id]?.info ?? thread.info)
    }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        try await startAgent(AgentLaunchRequest(
            kind: request.kind, name: request.name, cwd: workspace.directory,
            launchID: request.launchID, mayHaveStarted: request.mayHaveStarted, codex: request.codex))
    }

    func readChatTranscript(_ request: ChatTranscriptRequest) async throws -> ChatTranscriptSnapshot {
        let id = try threadID(request.paneID)
        var turns: [JSONValue] = []
        var cursor: String?
        var cursors: Set<String> = []
        var pages = 0
        repeat {
            var params: [String: JSONValue] = ["threadId": .string(id), "limit": .number(Double(min(50, 200 - turns.count)))]
            if let cursor { params["cursor"] = .string(cursor) }
            let page: JSONValue
            do {
                page = try await self.request("thread/turns/list", params)
            } catch TransportError.apiRejected(_, _) {
                let response = try await self.request("thread/read", [
                    "threadId": .string(id), "includeTurns": .bool(true)])
                guard let values = response["thread"]?["turns"]?.codexArray else {
                    throw TransportError.channelFailed(detail: "Codex returned no thread history.")
                }
                // thread/read is oldest-first; the shared builder takes newest-first.
                // Replace any partial pages, and retain only the newest 200 turns.
                return CodexSnapshotBuilder.transcript(turns: Array(values.suffix(200).reversed()),
                    truncated: values.count > 200, after: request.after)
            }
            pages += 1
            guard let values = page["data"]?.codexArray else {
                throw TransportError.channelFailed(detail: "Codex returned no turn list.")
            }
            turns.append(contentsOf: values.prefix(200 - turns.count))
            cursor = page["nextCursor"]?.stringValue
            if let after = request.after,
               CodexSnapshotBuilder.transcript(turns: turns, truncated: cursor != nil, after: after).header.afterFound { break }
            if let cursor, !cursors.insert(cursor).inserted { break }
        } while cursor != nil && turns.count < 200 && pages < 4
        return CodexSnapshotBuilder.transcript(turns: turns, truncated: cursor != nil, after: request.after)
    }

    func pendingAgentRequests(target: String) async throws -> [AgentPendingRequest] {
        let id = try threadID(target)
        return approvals.requests(id)
    }

    func answerAgentRequest(target: String, requestID: String, answer: AgentRequestAnswer) async throws {
        let id = try threadID(target)
        guard let entry = approvals.request(id, shownAs: requestID) else {
            throw TransportError.apiRejected(code: "agent_request_resolved", message: "This request was already resolved.")
        }
        let result: JSONValue
        switch (entry.request.kind, answer) {
        case (.command, .allow): result = .object(["decision": .string("accept")])
        case (.fileChange(_, let paths), .allow) where !paths.isEmpty:
            result = .object(["decision": .string("accept")])
        case (.command, .cancel), (.fileChange, .cancel): result = .object(["decision": .string("cancel")])
        case (.questions, .answers(let answers)):
            result = .object(["answers": .object(answers.mapValues { .object(["answers": .array($0.map(JSONValue.string))]) })])
        default: throw unsupported
        }
        do { try await rpc.respond(to: entry.id, result: result) }
        catch { throw Self.transportError(error) }
        perform(approvals.handle(.answered(id, entry.id)))
    }

    private func perform(_ effects: [CodexApprovalMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .publish: publishInventoryChange()
            }
        }
    }

    // MARK: One lifetime reader

    private func startReader() {
        let events = rpc.events
        pump = Task { [weak self] in
            do {
                for try await event in events { await self?.receive(event) }
                await self?.connectionEnded()
            } catch { await self?.connectionEnded() }
        }
        for thread in threads.values where thread.agentStatus == .blocked { resumeBlocked(thread.id) }
    }

    private func resumeBlocked(_ id: String) {
        guard !subscriptions.isTracked(id) else { return }
        Task { [weak self] in
            do { try await self?.ensureSubscribed(id) }
            catch { await self?.connectionEnded() }
        }
    }

    private func receive(_ event: CodexRPCEvent) async {
        guard connection.isLive else { return }
        switch event {
        case .serverRequest(let id, let method, let params):
            guard let thread = params?["threadId"]?.stringValue, threads[thread] != nil else { return }
            var kind = Self.requestKind(method, params)
            if method == "item/fileChange/requestApproval",
               let turnID = params?["turnId"]?.stringValue, let itemID = params?["itemId"]?.stringValue {
                // Approval payloads omit changes. Full history includes the pending
                // fileChange item; summary history deliberately does not.
                let page = try? await request("thread/turns/list", [
                    "threadId": .string(thread), "limit": .number(1), "itemsView": .string("full")])
                let turn = page?["data"]?.codexArray?.first { $0["id"]?.stringValue == turnID }
                let item = turn?["items"]?.codexArray?.first {
                    $0["id"]?.stringValue == itemID && $0["type"]?.stringValue == "fileChange"
                }
                let changes = item?["changes"]?.codexArray ?? []
                let paths = changes.compactMap { $0["path"]?.stringValue }.filter { !$0.isEmpty }
                kind = .fileChange(reason: params?["reason"]?.stringValue,
                                   paths: paths.count == changes.count ? paths : [])
                guard connection.isLive, threads[thread] != nil else { return }
            }
            let request = AgentPendingRequest(id: id.displayString, kind: kind)
            perform(approvals.handle(.asked(thread, .init(id: id, request: request))))
        case .notification(let method, let params):
            if method == "thread/started", let value = params?["thread"], let thread = CodexThread(value) {
                if threads[thread.id] == nil {
                    threads[thread.id] = thread
                    publishInventoryChange()
                    if thread.agentStatus == .blocked { resumeBlocked(thread.id) }
                }
                return
            }
            guard let id = params?["threadId"]?.stringValue else { return }
            switch method {
            case "thread/closed":
                guard threads.removeValue(forKey: id) != nil else { return }
                perform(approvals.handle(.dropped(id)))
                _ = turns.handle(.ended(id))
                _ = subscribe(.closed(id))
                publishInventoryChange()
            case "thread/status/changed":
                guard let status = params?["status"] else { return }
                // 0.167.1's TUI resume broadcasts status, not thread/started.
                // Discover that thread once without subscribing just to list it.
                if threads[id] == nil, status["type"]?.stringValue != "notLoaded" {
                    do {
                        let read = try await request("thread/read", ["threadId": .string(id)])
                        guard connection.isLive else { return }
                        if let value = read["thread"], let thread = CodexThread(value) {
                            threads[id] = thread
                            publishInventoryChange()
                            if thread.agentStatus == .blocked { resumeBlocked(id) }
                        }
                    } catch let error as TransportError {
                        // It may have unloaded between the status and the read.
                        if case .apiRejected = error { return }
                        await connectionEnded()
                    } catch { await connectionEnded() }
                }
                guard var thread = threads[id] else { return }
                let effects = thread.activity.handle(.statusChanged(status))
                threads[id] = thread
                perform(effects, thread: id)
            case "thread/name/updated":
                guard threads[id] != nil else { return }
                let name = params?["threadName"]?.stringValue
                guard threads[id]?.name != name else { return }
                threads[id]?.name = name
                publishInventoryChange()
            case "turn/started":
                if let effects = threads[id]?.activity.handle(.turnStarted) { perform(effects, thread: id) }
                _ = turns.handle(.started(id, turn: params?["turn"]?["id"]?.stringValue,
                                          tracked: subscriptions.isTracked(id)))
            case "turn/completed":
                _ = turns.handle(.completed(id, turn: params?["turn"]?["id"]?.stringValue))
            case "serverRequest/resolved":
                guard let requestID = params?["requestId"] else { return }
                perform(approvals.handle(.resolvedElsewhere(id, requestID)))
            default: break
            }
        }
    }

    private static func requestKind(_ method: String, _ params: JSONValue?) -> AgentPendingRequest.Kind {
        switch method {
        case "item/commandExecution/requestApproval":
            return .command(command: params?["command"]?.stringValue ?? "", cwd: params?["cwd"]?.stringValue,
                            reason: params?["reason"]?.stringValue)
        case "item/fileChange/requestApproval":
            return .fileChange(reason: params?["reason"]?.stringValue, paths: [])
        case "item/tool/requestUserInput":
            let questions = (params?["questions"]?.codexArray ?? []).compactMap { value -> ChatQuestion? in
                guard let id = value["id"]?.stringValue, let text = value["question"]?.stringValue else { return nil }
                let options = (value["options"]?.codexArray ?? []).enumerated().compactMap { offset, option -> ChatQuestionOption? in
                    guard let label = option["label"]?.stringValue else { return nil }
                    return ChatQuestionOption(key: String(UnicodeScalar(97 + offset) ?? "a"), label: label,
                                              detail: option["description"]?.stringValue, recommended: false)
                }
                return ChatQuestion(ref: id, text: text, kind: "choice", options: options)
            }
            return .questions(ChatQuestionCard(body: "", questions: questions))
        default: return .unsupported(method: method)
        }
    }

    private func connectionEnded() async {
        await perform(connection.handle(.connectionEnded))
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

    func focusAgent(_ target: AgentTarget) async throws {
        let id = try threadID(target.target)
        if let effects = threads[id]?.activity.handle(.acknowledged) { perform(effects, thread: id) }
    }

    private func perform(_ effects: [CodexThreadActivityMachine.Effect], thread id: String) {
        for effect in effects {
            switch effect {
            case .forgetTurn: _ = turns.handle(.ended(id))
            case .dropRequests: perform(approvals.handle(.dropped(id)))
            case .publish: publishInventoryChange()
            case .resumeBlocked: resumeBlocked(id)
            }
        }
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

    func remoteHomeDirectory() async throws -> String { try await session.remoteHomeDirectory() }
    func listDirectories(at path: String) async throws -> RemoteDirectoryListing { try await session.listDirectories(at: path) }
    func availableAgentKinds() async throws -> [SupportedAgentKind] { [.codex] }

    // MARK: No terminal or destructive thread management

    private var unsupported: TransportError {
        .apiRejected(code: "unsupported", message: "Codex threads support messages and Chat Mode only.")
    }
    func checkAgentInputScreen(target: String) async throws { try ensureOpen() }
    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult { throw unsupported }
    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult { throw unsupported }
    func sendAgentKeys(_ params: AgentSendKeysParams) async throws { throw unsupported }
    func sendPaneInput(_ params: PaneSendInputParams) async throws { throw unsupported }
    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec, attempt: WorktreeLaunchAttempt
    ) async throws -> Agent { throw unsupported }
    func closePane(_ params: PaneTarget, closesWorktreeGroup: Bool) async throws { throw unsupported }
    func closeTab(_ params: TabTarget) async throws { throw unsupported }
    func movePane(_ params: PaneMoveParams) async throws -> PaneMoveResponse { throw unsupported }
    func renameAgent(_ params: AgentRenameParams) async throws { throw unsupported }
    func renameWorkspace(_ params: WorkspaceRenameParams) async throws { throw unsupported }
    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession { throw unsupported }
    func probeMoshServer() async throws -> Bool { false }
    func runMoshBootstrap(_ request: TerminalAttachRequest) async throws -> MoshBootstrap { throw unsupported }
}

extension JSONValue {
    var codexArray: [JSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }
    var codexNumber: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }
}
