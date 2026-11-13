import Foundation

/// The session metadata the Console needs (`GET /api/session`, O10); unknown
/// fields are ignored. Times are OpenCode's epoch milliseconds.
struct OpenCodeSession: Sendable, Equatable {
    let id: String
    var title: String?
    let directory: String
    let created: Double
    /// Absent and `null` alike: a desk TUI session has none (O9).
    var metadata: JSONValue?
    /// The times as the server listed them; the transport's
    /// `OpenCodeActivityMachine` keeps them current from there.
    let idle: Double?
    let viewed: Double?
    var outcome: String?

    /// A top-level, unarchived session, or nil.
    init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue, id.hasPrefix("ses"),
              let directory = value["location"]?["directory"]?.stringValue, !directory.isEmpty,
              value["parentID"] == nil || value["parentID"] == .null,
              value["time"]?["archived"]?.codexNumber == nil
        else { return nil }
        self.id = id
        self.directory = directory
        title = value["title"]?.stringValue
        created = value["time"]?["created"]?.codexNumber ?? 0
        metadata = value["metadata"] == .null ? nil : value["metadata"]
        idle = value["time"]?["idle"]?.codexNumber
        viewed = value["time"]?["viewed"]?.codexNumber
        outcome = value["outcome"]?.stringValue
    }

    var paneID: String { "opencode:\(id)" }
    var workspaceID: String { "opencode:cwd:\(directory)" }
    /// The Launch Tag a Waycar launch left (`metadata.waycar.launch`).
    var launchTag: String? { metadata?["waycar"]?["launch"]?.stringValue }
    var displayName: String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "OpenCode" : title
    }

    /// This session as Closed Sessions lists it once archived at `date`.
    func archived(at date: Date) -> ArchivedServerSession {
        ArchivedServerSession(sessionID: id, title: title, directory: directory, workspaceID: workspaceID,
                              archivedAt: date)
    }

    var times: OpenCodeActivityMachine.Times { .init(idle: idle, viewed: viewed) }

    func info(status: AgentStatus) -> AgentInfo {
        AgentInfo(agentStatus: status, focused: false, paneID: paneID, revision: 0,
                  tabID: paneID, terminalID: paneID, workspaceID: workspaceID, agent: "opencode",
                  agentSession: AgentSessionInfo(agent: "opencode", kind: .id, source: "opencode", value: id),
                  cwd: directory, interactiveReady: true, launchPending: false, name: displayName)
    }
}

extension ArchivedServerSession {
    /// An archived top-level session from a list or get, or nil.
    init?(opencode value: JSONValue) {
        guard let id = value["id"]?.stringValue, id.hasPrefix("ses"),
              let directory = value["location"]?["directory"]?.stringValue, !directory.isEmpty,
              value["parentID"] == nil || value["parentID"] == .null,
              let archived = value["time"]?["archived"]?.codexNumber
        else { return nil }
        self.init(sessionID: id, title: value["title"]?.stringValue, directory: directory,
                  workspaceID: "opencode:cwd:\(directory)", archivedAt: Date(timeIntervalSince1970: archived / 1000))
    }
}

/// One pending permission request or Form (O17, O18).
struct OpenCodeRequest: Sendable, Equatable {
    enum Source: Sendable, Equatable { case permission, form }
    let id: String
    let sessionID: String
    let source: Source
    let kind: AgentPendingRequest.Kind
    /// Option labels to Form values, per question ref.
    let optionValues: [String: [String: String]]
    /// Multiselect fields take an array of values.
    let multiselect: Set<String>

    init?(permission value: JSONValue, cwd: String?) {
        guard let id = value["id"]?.stringValue, let sessionID = value["sessionID"]?.stringValue else { return nil }
        let resources = (value["resources"]?.codexArray ?? []).compactMap(\.stringValue)
        let reason = value["message"]?.stringValue
        self.id = id
        self.sessionID = sessionID
        source = .permission
        optionValues = [:]
        multiselect = []
        switch value["action"]?.stringValue {
        case "shell": kind = .command(command: resources.joined(separator: "\n"), cwd: cwd, reason: reason)
        case "edit", "write", "patch": kind = .fileChange(reason: reason, paths: resources)
        case let action: kind = .unsupported(method: "permission:\(action ?? "")")
        }
    }

    init?(form value: JSONValue) {
        guard let id = value["id"]?.stringValue, let sessionID = value["sessionID"]?.stringValue else { return nil }
        self.id = id
        self.sessionID = sessionID
        source = .form
        let fields = value["fields"]?.codexArray ?? []
        var questions: [ChatQuestion] = []
        var values: [String: [String: String]] = [:]
        var multiselect: Set<String> = []
        var answerable = value["metadata"]?["kind"]?.stringValue == "question" && !fields.isEmpty
        for field in fields where answerable {
            guard let key = field["key"]?.stringValue,
                  let type = field["type"]?.stringValue, type == "string" || type == "multiselect"
            else { answerable = false; break }
            if type == "multiselect" { multiselect.insert(key) }
            let options = (field["options"]?.codexArray ?? []).compactMap { option -> (String, String, String?)? in
                guard let label = option["label"]?.stringValue ?? option["value"]?.stringValue else { return nil }
                return (label, option["value"]?.stringValue ?? label, option["description"]?.stringValue)
            }
            values[key] = Dictionary(options.map { ($0.0, $0.1) }) { first, _ in first }
            let text = [field["description"], field["title"]].lazy.compactMap { $0?.stringValue }
                .first { !$0.isEmpty } ?? key
            questions.append(ChatQuestion(
                ref: key, text: text, kind: type == "multiselect" ? "multi" : (options.isEmpty ? "text" : "choice"),
                options: options.enumerated().map { offset, option in
                    ChatQuestionOption(key: String(UnicodeScalar(97 + offset % 26) ?? "a"), label: option.0,
                                       detail: option.2, recommended: false)
                }))
        }
        kind = answerable ? .questions(ChatQuestionCard(body: "", questions: questions))
            : .unsupported(method: "form")
        optionValues = answerable ? values : [:]
        self.multiselect = answerable ? multiselect : []
    }

    var pending: AgentPendingRequest { AgentPendingRequest(id: id, kind: kind) }

    /// `POST …/form/{id}/reply`'s answer: a chosen option's value, typed
    /// text, or an array for a multiselect field.
    func formAnswer(_ answers: [String: [String]]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: answers.map { ref, picks -> (String, JSONValue) in
            let values = picks.map { optionValues[ref]?[$0] ?? $0 }
            return (ref, multiselect.contains(ref) ? JSONValue.array(values.map(JSONValue.string))
                : JSONValue.string(values.first ?? ""))
        }))
    }
}

enum OpenCodeSnapshotBuilder {
    static func snapshot(
        sessions: [OpenCodeSession], statuses: [String: AgentStatus], home: String?, version: String
    ) -> SessionSnapshot {
        let sorted = sessions.sorted { $0.id < $1.id }
        let status = { (session: OpenCodeSession) in statuses[session.id] ?? .idle }
        let groups = Dictionary(grouping: sorted, by: \.directory)
        let workspaces = groups.keys.sorted().enumerated().compactMap { offset, directory -> WorkspaceInfo? in
            guard let entries = groups[directory], let first = entries.first else { return nil }
            let rolled = [AgentStatus.blocked, .working, .done, .idle].first { candidate in
                entries.contains { status($0) == candidate }
            } ?? .idle
            return WorkspaceInfo(activeTabID: first.paneID, agentStatus: rolled, focused: false,
                label: directory == home ? "~" : URL(fileURLWithPath: directory).lastPathComponent,
                number: offset + 1, paneCount: entries.count, tabCount: entries.count, workspaceID: first.workspaceID)
        }
        return SessionSnapshot(agents: sorted.map { $0.info(status: status($0)) }, layouts: [], panes: sorted.map {
            PaneInfo(agentStatus: status($0), focused: false, paneID: $0.paneID, revision: 0,
                     tabID: $0.paneID, terminalID: $0.paneID, workspaceID: $0.workspaceID, agent: "opencode",
                     cwd: $0.directory)
        }, protocolVersion: 0, tabs: sorted.enumerated().map { offset, session in
            TabInfo(agentStatus: status(session), focused: false, label: session.displayName,
                    number: offset + 1, paneCount: 1, tabID: session.paneID, workspaceID: session.workspaceID)
        }, version: version, workspaces: workspaces)
    }

    /// `items` arrive newest first (`GET /message`, O15). A turn runs from a
    /// user item to the next; it shows the prompt with its images, one tool
    /// summary, its last text reply, and a failure card for an `idle` whose
    /// outcome is `failed`. Interrupted turns, including a rejected
    /// permission (which writes no `idle`), end quietly.
    static func transcript(
        sessionID: String, items: [JSONValue], truncated: Bool, running: Bool, after: String?
    ) -> ChatTranscriptSnapshot {
        var chronological = Array(items.reversed())
        // A cut history may start mid-turn: drop the orphaned tail of it.
        if truncated, let first = chronological.firstIndex(where: { $0["type"]?.stringValue == "user" }) {
            chronological.removeSubrange(..<first)
        }
        var messages: [ChatTranscriptMessage] = []
        var reply: ChatTranscriptMessage?
        var tools: (id: String, timestamp: Date?, names: [String], counts: [String: Int])?
        var lastError: String?
        func flush() {
            if let tools {
                let summary = tools.names.map { name in
                    let count = tools.counts[name] ?? 0
                    return count > 1 ? "\(name) ×\(count)" : name
                }.joined(separator: ", ")
                messages.append(ChatTranscriptMessage(id: "\(tools.id):tools", role: .assistant, text: "",
                    timestamp: tools.timestamp, card: .toolSteps(ChatToolStepsSummary(
                        count: tools.counts.values.reduce(0, +), summary: summary))))
            }
            if let reply { messages.append(reply) }
            tools = nil
            reply = nil
            lastError = nil
        }
        for item in chronological {
            guard let id = item["id"]?.stringValue else { continue }
            let time = item["time"]
            let created = time?["created"]?.codexNumber.map { Date(timeIntervalSince1970: $0 / 1000) }
            switch item["type"]?.stringValue {
            case "user":
                flush()
                let media = (item["files"]?.codexArray ?? []).enumerated().compactMap { index, file -> ChatMedia? in
                    guard let mime = file["mime"]?.stringValue, mime.hasPrefix("image/"),
                          file["data"]?.stringValue != nil else { return nil }
                    return ChatMedia(id: "\(id):file:\(index)", kind: .image, mime: mime,
                                     source: .sessionInline(session: sessionID, pointer: "/\(id)/files/\(index)/data",
                                                            agentKind: "opencode"),
                                     alt: file["name"]?.stringValue)
                }
                let text = item["text"]?.stringValue ?? ""
                if !text.isEmpty || !media.isEmpty {
                    messages.append(ChatTranscriptMessage(id: id, role: .user, text: text,
                                                          timestamp: created, media: media))
                }
            case "assistant":
                let content = item["content"]?.codexArray ?? []
                let completed = (time?["completed"]?.codexNumber).map { Date(timeIntervalSince1970: $0 / 1000) } ?? created
                for part in content where part["type"]?.stringValue == "tool" {
                    let name = part["name"]?.stringValue ?? "tool"
                    var round = tools ?? (id, completed, [], [:])
                    if round.counts[name] == nil { round.names.append(name) }
                    round.counts[name, default: 0] += 1
                    tools = round
                }
                let text = content.compactMap { part in
                    part["type"]?.stringValue == "text" ? part["text"]?.stringValue : nil
                }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    reply = ChatTranscriptMessage(id: id, role: .assistant, text: text, timestamp: completed)
                }
                if let error = item["error"]?["message"]?.stringValue { lastError = error }
            case "idle":
                let failure = item["outcome"]?.stringValue == "failed"
                let error = lastError
                flush()
                if failure {
                    let text = error ?? "The turn failed."
                    messages.append(ChatTranscriptMessage(id: "\(id):failure", role: .assistant, text: "",
                        timestamp: created, card: .failure(ChatFailureCard(conversationId: nil, title: nil,
                            error: text.components(separatedBy: .newlines).first ?? text, step: nil))))
                }
            default: continue
            }
        }
        flush()
        let index = after.flatMap { id in messages.firstIndex { $0.id == id } }
        return ChatTranscriptSnapshot(header: ChatTranscriptHeader(kind: "opencode", status: .ok, transcript: nil,
            activity: nil, turnOpen: running, truncated: truncated, error: nil,
            afterFound: after == nil || index != nil),
            // A cursor on what can still grow is included again, and the
            // merge replaces it by its stable id: a tool summary's round, or
            // a reply, since OpenCode appends text parts to one assistant
            // message.
            messages: index.map { index in
                let message = messages[index]
                let grows = switch message.card {
                case nil: message.role == .assistant
                case .toolSteps?: true
                default: false
                }
                return Array(messages.suffix(from: grows ? index : index + 1))
            } ?? messages)
    }
}
