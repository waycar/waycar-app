import Foundation

/// Native chats over loopback HTTP, carried by the Host's shared SSH link.
/// No shell, PTY, Host Tools or model credentials are involved.
actor UltimateTransport: Transport {
    let session: any HostSSHServices
    let instances: [UltimateInstance]
    private var conversations: [String: [UltimateConversationSummary]] = [:]
    private var concluded: [String: Set<Int>] = [:]
    private var openQuestions: [String: Int] = [:]
    private var questionsByConversation: [String: [Int: Int]] = [:]
    /// Lifetime, stream epoch and which projects are online (CORE-10).
    private var machine = UltimateTransportMachine()
    private var continuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
    private var pumps: [Task<Void, Never>] = []
    private let retryDelays: [Duration]

    private var online: Set<String> { machine.state.online }

    init(
        session: any HostSSHServices, instances: [UltimateInstance],
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]
    ) {
        self.session = session
        self.instances = instances
        self.retryDelays = retryDelays.isEmpty ? [.seconds(30)] : retryDelays
    }

    deinit {
        for pump in pumps { pump.cancel() }
        continuation?.finish()
        if !machine.isClosed {
            let session = session
            Task { await session.release() }
        }
    }

    /// Stale lock files are not running instances. Prove candidates before
    /// publishing them; never let a dead project's old port hide live chats.
    static func open(
        session: any HostSSHServices, instances: [UltimateInstance]
    ) async throws -> UltimateTransport {
        let transport = UltimateTransport(session: session, instances: instances)
        do {
            _ = try await transport.sessionSnapshot()
            return transport
        } catch {
            // A failed open leaves the connection hold with the caller.
            await transport.abandon()
            throw error
        }
    }

    private static func client(
        for instance: UltimateInstance, session: any HostSSHServices
    ) -> UltimateHTTPClient {
        UltimateHTTPClient(port: instance.port) {
            try await session.openUltimateChannel(port: instance.port)
        }
    }

    /// The API has no GET conversations endpoint. Every event stream starts
    /// with the complete summary list; ending this one-shot consumer closes
    /// only its forwarding channel.
    private static func summaries(
        from client: UltimateHTTPClient, instance: UltimateInstance
    ) async throws -> (conversations: [UltimateConversationSummary], concluded: Set<Int>) {
        var identified = false
        var summaries: [UltimateConversationSummary]?
        var ui = UltimateUIState()
        var receivedUI = false
        for try await event in client.events(timeout: .seconds(10)) {
            if event.name == "system" {
                try JSONDecoder().decode(UltimateIdentity.self, from: Data(event.data.utf8)).validate(instance)
                identified = true
            } else if event.name == "conversations" {
                guard identified else { throw UltimateIdentityError.missingSystem }
                summaries = try UltimateConversationSummary.decodeList(Data(event.data.utf8))
            } else if event.name == "ui" || event.name == "uiOps" {
                guard identified else { throw UltimateIdentityError.missingSystem }
                try ui.receive(event)
                if event.name == "ui" { receivedUI = true }
            }
            if let summaries, receivedUI { return (summaries, Set(ui.concluded)) }
        }
        throw TransportError.channelFailed(detail: "Ultimate ended before listing conversations and shared UI.")
    }

    private func abandon() { apply(machine.handle(.abandon)) }

    private func ensureOpen() throws {
        if let refusal = machine.refusal { throw refusal }
    }

    /// Performs what the transport machine asks for. `superseded`,
    /// `keepListing`, `keepPublished`, `keepQuestions`, `startPumps` and
    /// `retry` need the caller's own values and are performed where they are
    /// asked for.
    private func apply(_ effects: [UltimateTransportMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .dropListing(let instance):
                conversations.removeValue(forKey: instance)
                concluded.removeValue(forKey: instance)
            case .forgetConversations:
                conversations.removeAll()
            case .forgetProject(let instance):
                concluded.removeValue(forKey: instance)
                openQuestions.removeValue(forKey: instance)
                questionsByConversation.removeValue(forKey: instance)
                if conversations.removeValue(forKey: instance) != nil { publishInventoryChange() }
            case .failStream(let failure):
                continuation?.finish(throwing: failure)
            case .endStream:
                for pump in pumps { pump.cancel() }
                pumps.removeAll()
                let output = continuation
                continuation = nil
                output?.finish()
            case .release:
                // `close()` awaits it.
                break
            case .superseded, .keepListing, .keepPublished, .keepQuestions, .startPumps, .retry:
                break
            }
        }
    }

    private func request(
        _ instance: UltimateInstance, method: String = "GET", path: String, body: Data? = nil
    ) async throws -> Data {
        try ensureOpen()
        guard online.contains(instance.id) else {
            throw TransportError.channelFailed(detail: "This Ultimate project is offline.")
        }
        do {
            let response = try await Self.client(for: instance, session: session).request(
                method: method, path: path, body: body, timeout: session.requestTimeout)
            guard (200..<300).contains(response.head.status) else {
                throw TransportError.apiRejected(
                    code: "ultimate_http_\(response.head.status)",
                    message: "Ultimate refused the request (HTTP \(response.head.status)).")
            }
            return response.body
        } catch let error as TransportError { throw error }
        catch is CancellationError { throw TransportError.cancelled }
        catch { throw TransportError.channelFailed(detail: "Ultimate: \(error)") }
    }

    func ping() async throws -> ServerInfo {
        try ensureOpen()
        for instance in instances {
            try Task.checkCancellation()
            do {
                _ = try await Self.summaries(
                    from: Self.client(for: instance, session: session), instance: instance)
                return ServerInfo(version: "Ultimate", protocolVersion: 0, backend: .ultimate)
            } catch {
                if Task.isCancelled { throw TransportError.cancelled }
            }
        }
        apply(machine.handle(.pingFailed))
        throw TransportError.channelFailed(detail: "No Ultimate project answered its identity check.")
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        try ensureOpen()
        // Once subscribed, the initial SSE summary and its replacements are
        // the inventory. A concurrent GET must not overwrite newer pushes.
        if !machine.state.streaming {
            // Subscribe and teardown both advance the epoch: even a stream
            // that ended while the read waited supersedes its result.
            let epoch = machine.state.epoch
            for instance in instances {
                try Task.checkCancellation()
                do {
                    let inventory = try await Self.summaries(
                        from: Self.client(for: instance, session: session), instance: instance)
                    let effects = machine.handle(
                        .snapshotRead(epoch: epoch, instance: instance.id, listed: true))
                    guard !effects.contains(.superseded) else { return currentSnapshot() }
                    conversations[instance.id] = inventory.conversations
                    concluded[instance.id] = inventory.concluded
                } catch {
                    if Task.isCancelled { throw TransportError.cancelled }
                    let effects = machine.handle(
                        .snapshotRead(epoch: epoch, instance: instance.id, listed: false))
                    guard !effects.contains(.superseded) else { return currentSnapshot() }
                    apply(effects)
                }
            }
            guard !online.isEmpty else {
                throw TransportError.channelFailed(detail: "No Ultimate project answered its identity check.")
            }
        }
        return currentSnapshot()
    }

    private func currentSnapshot() -> SessionSnapshot {
        UltimateSnapshotBuilder.snapshot(
            instances: instances.filter { online.contains($0.id) }, conversations: conversations)
    }

    func ultimateOpenQuestions() async -> [String: Int] {
        var counts: [String: Int] = [:]
        for instance in instances where online.contains(instance.id) {
            guard let leader = UltimateSnapshotBuilder.leader(in: instance, conversations: conversations[instance.id] ?? []) else { continue }
            counts[UltimateSnapshotBuilder.paneID(leader.id, in: instance)] = openQuestions[instance.id] ?? 0
        }
        return counts
    }

    func ultimateConversationChildren() async -> [String: [UltimateChildInfo]] {
        var children = UltimateSnapshotBuilder.children(
            instances: instances.filter { online.contains($0.id) },
            conversations: conversations, concluded: concluded)
        for instance in instances {
            guard let lead = UltimateSnapshotBuilder.leader(in: instance, conversations: conversations[instance.id] ?? []) else { continue }
            let paneID = UltimateSnapshotBuilder.paneID(lead.id, in: instance)
            children[paneID] = children[paneID]?.map { child in
                var child = child
                child.openQuestions = questionsByConversation[instance.id]?[child.conversationId] ?? 0
                return child
            }
        }
        return children
    }

    func listAgents() async throws -> [Agent] {
        try await sessionSnapshot().agents.map(Agent.init)
    }

    private func target(_ id: String) throws -> (UltimateInstance, Int) {
        for instance in instances {
            let prefix = UltimateSnapshotBuilder.workspaceID(instance) + ":"
            guard id.hasPrefix(prefix), let conversation = Int(id.dropFirst(prefix.count)),
                conversation > 0 else { continue }
            return (instance, conversation)
        }
        throw TransportError.apiRejected(code: "agent_not_found", message: "Unknown Ultimate conversation.")
    }

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        let (instance, conversation) = try target(params.target)
        // Resolve before sending: never fail a delivered prompt because a
        // concurrent SSE update removed its row after the acknowledgement.
        let children = await ultimateConversationChildren()
        guard let summary = conversations[instance.id]?.first(where: { $0.id == conversation }),
              currentSnapshot().agents.contains(where: { $0.paneID == params.target })
                || children.values.contains(where: { $0.contains(where: { $0.paneID == params.target }) })
        else { throw TransportError.apiRejected(code: "agent_not_found", message: "Conversation is no longer listed.") }
        let info = AgentInfo(
            agentStatus: summary.busy ? .working : .idle, focused: false, paneID: params.target,
            revision: 0, tabID: params.target, terminalID: params.target,
            workspaceID: UltimateSnapshotBuilder.workspaceID(instance), agent: "ultimate",
            cwd: summary.cwd ?? instance.project, interactiveReady: true,
            launchPending: false, name: summary.displayName, terminalTitle: summary.title)
        let body = try JSONEncoder().encode(UltimateSubmitRequest(text: params.text))
        let response = try await request(
            instance, method: "POST", path: "/api/conversations/\(conversation)/submit", body: body)
        _ = try JSONDecoder().decode(UltimateSubmitResponse.self, from: response)
        return Agent(info)
    }

    /// Stops this conversation's run without withdrawing queued follow-ups.
    func abortAgentRun(target: String) async throws {
        try await abortConversation(target)
    }

    func abortConversation(_ target: String) async throws {
        let (instance, conversation) = try self.target(target)
        guard conversations[instance.id]?.contains(where: { $0.id == conversation }) == true else {
            throw TransportError.apiRejected(code: "agent_not_found", message: "Conversation is no longer listed.")
        }
        _ = try await request(instance, method: "POST", path: "/api/conversations/\(conversation)/abort")
    }

    func readChatTranscript(_ request: ChatTranscriptRequest) async throws -> ChatTranscriptSnapshot {
        let (instance, conversation) = try target(request.paneID)
        var before = 9_007_199_254_740_991 // Largest exact JavaScript integer.
        var entries: [UltimateEntry] = []
        var next: Int?
        // Bound one read to 512 stored records, including tools and thinking.
        for _ in 0..<8 {
            let data = try await self.request(
                instance, path: "/api/conversations/\(conversation)/history?before=\(before)")
            let page = try JSONDecoder().decode(UltimateHistoryResponse.self, from: data)
            entries.append(contentsOf: page.entries)
            next = page.before
            if let after = request.after?.split(separator: ":").first,
               entries.contains(where: { String($0.id) == String(after) }) { break }
            guard let cursor = next, cursor < before else { break }
            before = cursor
        }
        let busy = conversations[instance.id]?.first { $0.id == conversation }?.busy
            ?? (request.status == .working)
        return UltimateSnapshotBuilder.transcript(
            UltimateHistoryResponse(entries: entries, before: next), busy: busy, after: request.after)
    }

    // MARK: SSE inventory

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        try ensureOpen()
        guard !machine.state.streaming else { throw TransportError.eventsChannelAlreadyOpen }
        guard !instances.isEmpty else { throw TransportError.channelFailed(detail: "No Ultimate projects were discovered.") }
        guard case .startPumps(let id)? = machine.handle(.subscribe).first else {
            throw TransportError.cancelled
        }
        let (events, output) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(HerdrEventStream.bufferLimit))
        continuation = output
        let (ready, readiness) = AsyncThrowingStream<Void, any Error>.makeStream()
        let retryDelays = retryDelays
        let requestTimeout = session.requestTimeout
        for instance in instances {
            let client = Self.client(for: instance, session: session)
            pumps.append(Task { [weak self] in
                var stream = UltimateInstanceStreamMachine(retryDelays: retryDelays)
                func signal(_ effects: [UltimateInstanceStreamMachine.Effect]) {
                    if effects.contains(.signalReady) { readiness.yield(()) }
                }
                defer { signal(stream.handle(.stop)) }
                while !Task.isCancelled {
                    do {
                        _ = stream.handle(.streamOpened)
                        var ui = UltimateUIState()
                        var board = UltimateBoardState()
                        for try await event in client.events() {
                            if event.name == "stream" {
                                let data = try JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8))
                                _ = stream.handle(.streamAnnounced(id: data["id"]?.stringValue))
                            }
                            if stream.isIdentified, try board.receive(event) {
                                await self?.receiveQuestions(board.openQuestions, byConversation: board.openQuestionsByConversation,
                                                            instance: instance, stream: id)
                            }
                            if event.name == "system" {
                                try JSONDecoder().decode(UltimateIdentity.self, from: Data(event.data.utf8)).validate(instance)
                                _ = stream.handle(.identified)
                            } else if event.name == "conversations" {
                                if stream.handle(.listArrived).contains(.refuseMissingIdentity) {
                                    throw UltimateIdentityError.missingSystem
                                }
                                _ = stream.handle(.listed(try UltimateConversationSummary.decodeList(Data(event.data.utf8))))
                            } else if event.name == "ui" || event.name == "uiOps" {
                                if stream.handle(.sharedUIArrived).contains(.refuseMissingIdentity) {
                                    throw UltimateIdentityError.missingSystem
                                }
                                try ui.receive(event)
                                _ = stream.handle(.sharedUIApplied(snapshot: event.name == "ui"))
                            }
                            for effect in stream.handle(.eventDone) {
                                switch effect {
                                case .subscribeBoard(let streamID):
                                    // `board` is instance-global on ROOT_CONVERSATION_ID,
                                    // independently of the project lead's conversation id.
                                    let body = try JSONEncoder().encode(UltimateBoardSubscription(conversation: 1))
                                    let response = try await client.request(
                                        method: "POST", path: "/api/events/\(streamID)/0", body: body, timeout: requestTimeout)
                                    guard (200..<300).contains(response.head.status) else {
                                        throw TransportError.channelFailed(detail: "Ultimate refused its board subscription.")
                                    }
                                    _ = stream.handle(.boardSubscribed)
                                case .publish(let summaries):
                                    await self?.receive(summaries, concluded: Set(ui.concluded), instance: instance, stream: id)
                                    signal(stream.handle(.published))
                                case .refuseMissingIdentity, .signalReady, .report, .backOff:
                                    break
                                }
                            }
                        }
                        throw TransportError.channelFailed(detail: "Ultimate ended its event stream.")
                    } catch {
                        guard !Task.isCancelled else { return }
                        guard case .report(let afterRetry)? = stream.handle(.streamFailed).first else { return }
                        let retry = await self?.instanceFailed(instance, afterRetry: afterRetry, stream: id)
                        let decided = stream.handle(.retryDecided(retry == true))
                        signal(decided)
                        guard let delay = decided.compactMap({ effect -> Duration? in
                            if case .backOff(let delay) = effect { return delay }
                            return nil
                        }).first else { return }
                        do { try await Task.sleep(for: delay) }
                        catch { return }
                        _ = stream.handle(.backoffElapsed)
                    }
                }
            })
        }
        do {
            var count = 0
            for try await _ in ready {
                count += 1
                if count == instances.count { break }
            }
            try Task.checkCancellation()
            try ensureOpen()
            guard machine.isCurrent(stream: id) else { throw TransportError.cancelled }
        } catch {
            endEvents(id: id)
            throw error
        }
        output.onTermination = { [weak self] _ in
            Task { await self?.endEvents(id: id) }
        }
        return HerdrEventStream(events: events) { [weak self] in
            await self?.endEvents(id: id)
        }
    }

    private func receive(
        _ summaries: [UltimateConversationSummary], concluded ids: Set<Int>, instance: UltimateInstance, stream: UInt64
    ) {
        guard machine.handle(.published(stream: stream, instance: instance.id))
            == [.keepPublished(instance: instance.id)]
        else { return }
        guard conversations[instance.id] != summaries || concluded[instance.id] != ids else { return }
        conversations[instance.id] = summaries
        concluded[instance.id] = ids
        publishInventoryChange()
    }

    private func receiveQuestions(_ count: Int, byConversation: [Int: Int], instance: UltimateInstance, stream: UInt64) {
        guard machine.handle(.questionsCounted(stream: stream, instance: instance.id))
            == [.keepQuestions(instance: instance.id)],
              openQuestions[instance.id] != count || questionsByConversation[instance.id] != byConversation else { return }
        openQuestions[instance.id] = count
        questionsByConversation[instance.id] = byConversation
        publishInventoryChange()
    }

    /// A project's outage never takes another project's conversations down.
    /// Once every project has failed its first retry, fail the transport so
    /// EventsSession replaces it; the connector re-discovers current locks.
    private func instanceFailed(_ instance: UltimateInstance, afterRetry: Bool, stream: UInt64) -> Bool {
        let effects = machine.handle(
            .instanceFailed(
                stream: stream, instance: instance.id, afterRetry: afterRetry,
                projects: instances.count))
        apply(effects)
        return effects.contains(.retry)
    }

    private func publishInventoryChange() {
        let event = HerdrEvent(kind: GlobalEventKind.workspaceMetadataUpdated.kind, data: .object([:]))
        if case .dropped = continuation?.yield(event) { _ = continuation?.yield(.eventsDropped) }
    }

    private func endEvents(id: UInt64) {
        apply(machine.handle(.endStream(stream: id)))
    }

    var isConnected: Bool {
        get async {
            guard machine.refusal == nil, !online.isEmpty else { return false }
            return await session.isConnected
        }
    }

    func close() async throws {
        let effects = machine.handle(.close)
        apply(effects)
        if effects.contains(.release) { await session.release() }
    }

    func transportDistrusted() async {
        apply(machine.handle(.distrust))
    }

    // MARK: No terminal or destructive conversation management

    private var unsupported: TransportError {
        .apiRejected(code: "unsupported", message: "Ultimate conversations support messages and Chat Mode only.")
    }
    func focusAgent(_ target: AgentTarget) async throws { try ensureOpen() }
    func checkAgentInputScreen(target: String) async throws { try ensureOpen() }
    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult { throw unsupported }
    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult { throw unsupported }
    func sendAgentKeys(_ params: AgentSendKeysParams) async throws { throw unsupported }
    func sendPaneInput(_ params: PaneSendInputParams) async throws { throw unsupported }
    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent { throw unsupported }
    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec, attempt: WorktreeLaunchAttempt
    ) async throws -> Agent { throw unsupported }
    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
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
