import Foundation

/// Only the metadata needed by the Console; unknown protocol fields are ignored.
struct CodexThread: Sendable, Equatable {
    let id: String
    let cwd: String
    let createdAt: Double
    var name: String?
    let preview: String
    let source: String?
    let threadSource: String?
    /// Status, Done and whether it has a conversation.
    var activity: CodexThreadActivityMachine

    init?(_ value: JSONValue) {
        let threadSource = value["threadSource"]?.stringValue
        let isSubagent = threadSource.map { $0 == "subagent" }
            ?? (value["source"]?["subAgent"] != nil || value["source"]?.stringValue == "subAgent")
        guard let id = value["id"]?.stringValue, !id.isEmpty,
              let cwd = value["cwd"]?.stringValue,
              value["parentThreadId"] == nil || value["parentThreadId"] == .null,
              value["ephemeral"] == .bool(false),
              !isSubagent,
              let status = value["status"], let type = status["type"]?.stringValue, type != "notLoaded"
        else { return nil }
        self.id = id
        self.cwd = cwd
        source = value["source"]?.stringValue
        self.threadSource = threadSource
        createdAt = value["createdAt"]?.codexNumber ?? 0
        name = value["name"]?.stringValue
        preview = value["preview"]?.stringValue ?? ""
        activity = CodexThreadActivityMachine(status: status, hasTurns: !preview.isEmpty || type == "active")
    }

    var status: JSONValue { activity.status }
    var active: Bool { activity.isActive }
    var hasTurns: Bool { activity.state.hasTurns }
    var agentStatus: AgentStatus { activity.agentStatus }
    var displayName: String {
        if let name { return name }
        let line = preview.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "Codex" : String(line.prefix(48))
    }
    var paneID: String { "codex:\(id)" }
    // The cwd itself is stable and collision-free, unlike Swift's randomized hash.
    var workspaceID: String { "codex:cwd:\(cwd)" }
    /// An unnamed launch with no conversation has nothing to resume after unload.
    var isEmpty: Bool { (name?.isEmpty ?? true) && !hasTurns }

    /// Compare the canonical macOS aliases without resolving paths on this device.
    static func normalizedCwd(_ cwd: String) -> String {
        var path = cwd
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        for prefix in ["/private/tmp", "/private/var"] {
            if path == prefix || path.hasPrefix(prefix + "/") {
                return String(path.dropFirst("/private".count))
            }
        }
        return path
    }

    var info: AgentInfo {
        AgentInfo(agentStatus: agentStatus, focused: false, paneID: paneID, revision: 0,
                  tabID: paneID, terminalID: paneID, workspaceID: workspaceID, agent: "codex",
                  agentSession: isEmpty ? nil : AgentSessionInfo(agent: "codex", kind: .id, source: "codex", value: id), cwd: cwd, interactiveReady: true, launchPending: false, name: displayName)
    }
}

enum CodexSnapshotBuilder {
    static func snapshot(threads: [CodexThread], home: String?, version: String) -> SessionSnapshot {
        let sorted = threads.sorted { $0.id < $1.id }
        let groups = Dictionary(grouping: sorted, by: \.cwd)
        let workspaces = groups.keys.sorted().enumerated().compactMap { offset, cwd -> WorkspaceInfo? in
            guard let entries = groups[cwd], let first = entries.first else { return nil }
            let status = [AgentStatus.blocked, .working, .done, .idle, .unknown].first { status in
                entries.contains { $0.agentStatus == status }
            } ?? .idle
            return WorkspaceInfo(activeTabID: first.paneID, agentStatus: status, focused: false,
                label: cwd == home ? "~" : URL(fileURLWithPath: cwd).lastPathComponent,
                number: offset + 1, paneCount: entries.count, tabCount: entries.count, workspaceID: first.workspaceID)
        }
        return SessionSnapshot(agents: sorted.map(\.info), layouts: [], panes: sorted.map {
            PaneInfo(agentStatus: $0.agentStatus, focused: false, paneID: $0.paneID, revision: 0,
                     tabID: $0.paneID, terminalID: $0.paneID, workspaceID: $0.workspaceID, agent: "codex", cwd: $0.cwd)
        }, protocolVersion: 0, tabs: sorted.enumerated().map { offset, thread in
            TabInfo(agentStatus: thread.agentStatus, focused: false, label: thread.displayName,
                    number: offset + 1, paneCount: 1, tabID: thread.paneID, workspaceID: thread.workspaceID)
        }, version: version, workspaces: workspaces)
    }

    /// Turns arrive newest first; item order within each turn is chronological.
    static func transcript(turns: [JSONValue], truncated: Bool, after: String?) -> ChatTranscriptSnapshot {
        var messages: [ChatTranscriptMessage] = []
        for turn in turns.reversed() {
            let items = turn["items"]?.codexArray ?? []
            let started = turn["startedAt"]?.codexNumber.map(Date.init(timeIntervalSince1970:))
            let completed = turn["completedAt"]?.codexNumber.map(Date.init(timeIntervalSince1970:)) ?? started
            for item in items where item["type"]?.stringValue == "userMessage" {
                guard let id = item["id"]?.stringValue else { continue }
                let text = (item["content"]?.codexArray ?? []).compactMap { part in
                    part["type"]?.stringValue == "text" ? part["text"]?.stringValue : nil
                }.joined(separator: "\n\n")
                if !text.isEmpty { messages.append(ChatTranscriptMessage(id: id, role: .user, text: text, timestamp: started)) }
            }
            if let item = items.last(where: {
                $0["type"]?.stringValue == "agentMessage" && $0["phase"]?.stringValue != "commentary"
            }), let id = item["id"]?.stringValue, let text = item["text"]?.stringValue, !text.isEmpty {
                messages.append(ChatTranscriptMessage(id: id, role: .assistant, text: text, timestamp: completed))
            }
            if ["failed", "interrupted"].contains(turn["status"]?.stringValue ?? ""),
               let error = turn["error"]?["message"]?.stringValue, let id = turn["id"]?.stringValue {
                messages.append(ChatTranscriptMessage(id: "\(id):failure", role: .assistant, text: "", timestamp: completed,
                    card: .failure(ChatFailureCard(conversationId: nil, title: nil,
                        error: error.components(separatedBy: .newlines).first ?? error, step: nil))))
            }
        }
        let index = after.flatMap { id in messages.firstIndex { $0.id == id } }
        return ChatTranscriptSnapshot(header: ChatTranscriptHeader(kind: "codex", status: .ok, transcript: nil,
            activity: nil, turnOpen: turns.first?["status"]?.stringValue == "inProgress", truncated: truncated,
            error: nil, afterFound: after == nil || index != nil),
            messages: index.map { Array(messages.suffix(from: $0 + 1)) } ?? messages)
    }
}
