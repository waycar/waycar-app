import Foundation

/// A project instance is a Workspace with its lead and standing-agent chats.
/// Branches remain addressable chats through the transport's children payload.
enum UltimateSnapshotBuilder {
    static func workspaceID(_ instance: UltimateInstance) -> String { "ultimate:\(instance.id)" }
    static func paneID(_ conversation: Int, in instance: UltimateInstance) -> String {
        "\(workspaceID(instance)):\(conversation)"
    }

    static func leader(
        in instance: UltimateInstance, conversations: [UltimateConversationSummary]
    ) -> UltimateConversationSummary? {
        let visible = conversations.filter { !isLander($0, in: instance) }
        return visible.filter { $0.label == "agent" && $0.title == "@ultimate" }
            .min { $0.id < $1.id }
            ?? visible.filter(\.isLeader).min { $0.id < $1.id }
    }

    private static func isLander(_ conversation: UltimateConversationSummary, in instance: UltimateInstance) -> Bool {
        guard let cwd = conversation.cwd else { return false }
        let lander = instance.home + "/lander"
        return cwd == lander || cwd.hasPrefix(lander + "/")
    }

    static func children(
        instances: [UltimateInstance], conversations: [String: [UltimateConversationSummary]],
        concluded: [String: Set<Int>] = [:]
    ) -> [String: [UltimateChildInfo]] {
        var result: [String: [UltimateChildInfo]] = [:]
        for instance in instances {
            let summaries = conversations[instance.id] ?? []
            guard let leader = leader(in: instance, conversations: summaries) else { continue }
            var hidden = concluded[instance.id] ?? []
            hidden.formUnion(summaries.filter { $0.concluded == true }.map(\.id))
            // Ultimate concludes a whole subtree, including nested branches.
            var changed = true
            while changed {
                changed = false
                for summary in summaries {
                    if let parent = summary.parentConversationId ?? summary.branchOf?.conversationId,
                       hidden.contains(parent), hidden.insert(summary.id).inserted { changed = true }
                }
            }
            result[paneID(leader.id, in: instance)] = summaries.filter {
                $0.branchOf != nil && !$0.isStandingAgent && $0.id != leader.id
                    && !hidden.contains($0.id) && !isLander($0, in: instance)
            }.map {
                UltimateChildInfo(conversationId: $0.id, paneID: paneID($0.id, in: instance),
                                  name: $0.displayName, busy: $0.busy)
            }
        }
        return result
    }

    static func snapshot(
        instances: [UltimateInstance], conversations: [String: [UltimateConversationSummary]]
    ) -> SessionSnapshot {
        var agents: [AgentInfo] = []
        var panes: [PaneInfo] = []
        var tabs: [TabInfo] = []
        var workspaces: [WorkspaceInfo] = []
        for instance in instances {
            let workspace = workspaceID(instance)
            let summaries = conversations[instance.id] ?? []
            let lead = leader(in: instance, conversations: summaries)
            let standing = summaries.filter {
                $0.isStandingAgent && $0.title != "@ultimate" && $0.id != lead?.id
                    && !isLander($0, in: instance)
            }.sorted { $0.id < $1.id }
            let listed = (lead.map { [$0] } ?? []) + standing
            for (offset, conversation) in listed.enumerated() {
                let id = paneID(conversation.id, in: instance)
                let status: AgentStatus = conversation.busy ? .working : .idle
                let name = conversation.id == lead?.id ? "@ultimate"
                    : conversation.title ?? conversation.displayName
                let cwd = conversation.cwd ?? instance.project
                agents.append(AgentInfo(
                    agentStatus: status, focused: false, paneID: id, revision: 0,
                    tabID: id, terminalID: id, workspaceID: workspace, agent: "ultimate",
                    cwd: cwd, interactiveReady: true, launchPending: false, name: name,
                    terminalTitle: conversation.title))
                panes.append(PaneInfo(
                    agentStatus: status, focused: false, paneID: id, revision: 0,
                    tabID: id, terminalID: id, workspaceID: workspace, agent: "ultimate", cwd: cwd))
                tabs.append(TabInfo(
                    agentStatus: status, focused: false, label: name, number: offset + 1,
                    paneCount: 1, tabID: id, workspaceID: workspace))
            }
            workspaces.append(WorkspaceInfo(
                activeTabID: listed.first.map { paneID($0.id, in: instance) } ?? "",
                agentStatus: listed.contains(where: \.busy) ? .working : .idle,
                focused: false, label: instance.name, number: workspaces.count + 1,
                paneCount: listed.count, tabCount: listed.count, workspaceID: workspace))
        }
        return SessionSnapshot(
            agents: agents, layouts: [], panes: panes, protocolVersion: 0,
            tabs: tabs, version: "Ultimate", workspaces: workspaces)
    }

    /// Ultimate history is newest-first and includes tool/thinking records.
    /// Chat Mode preserves rich outcomes and collapses tool work, oldest first.
    static func transcript(
        _ history: UltimateHistoryResponse, busy: Bool, after: String?
    ) -> ChatTranscriptSnapshot {
        var messages: [ChatTranscriptMessage] = []
        var toolNames: [String] = []
        var toolCounts: [String: Int] = [:]
        var toolEntry: UltimateEntry?
        func flushTools() {
            guard let entry = toolEntry else { return }
            let summary = toolNames.map { name in
                let count = toolCounts[name] ?? 0
                return count > 1 ? "\(name) ×\(count)" : name
            }.joined(separator: ", ")
            messages.append(ChatTranscriptMessage(id: "\(entry.id):tools", role: .assistant,
                text: "", timestamp: entry.timestamp,
                card: .toolSteps(ChatToolStepsSummary(count: toolCounts.values.reduce(0, +), summary: summary))))
            toolNames.removeAll()
            toolCounts.removeAll()
            toolEntry = nil
        }
        for entry in history.entries.reversed() {
            if let card = entry.storedCard {
                flushTools()
                messages.append(ChatTranscriptMessage(id: String(entry.id), role: .assistant,
                    text: "", timestamp: entry.timestamp, card: card))
                continue
            }
            let questions = entry.questionCards
            for call in entry.toolCalls {
                guard let name = call["name"]?.stringValue else { continue }
                if name == "message", call["arguments"]?["to"]?.stringValue == "user",
                   case .array(let values) = call["arguments"]?["questions"],
                   values.contains(where: { $0["text"]?.stringValue != nil }) { continue }
                if toolCounts[name] == nil { toolNames.append(name) }
                toolCounts[name, default: 0] += 1
                // Key the summary on the round's first entry: its id must stay
                // stable while the round grows, or a reader's `after` cursor
                // pointing at the summary never matches the next read.
                if toolEntry == nil { toolEntry = entry }
            }
            if !questions.isEmpty {
                flushTools()
                for (index, card) in questions.enumerated() {
                    messages.append(ChatTranscriptMessage(id: "\(entry.id):question:\(index)", role: .assistant,
                        text: "", timestamp: entry.timestamp, card: .questions(card)))
                }
            }
            guard let message = entry.model?.first else { continue }
            let role: ChatTranscriptMessage.Role
            switch (entry.kind, message["role"]?.stringValue) {
            case ("pi.user", "user"): role = .user
            case ("pi.assistant", "assistant"): role = .assistant
            default: continue
            }
            let text: String
            if role == .assistant, message["stopReason"]?.stringValue == "error" {
                let error = message["errorMessage"]?.stringValue ?? "The turn failed."
                flushTools()
                messages.append(ChatTranscriptMessage(id: String(entry.id), role: .assistant,
                    text: "", timestamp: entry.timestamp,
                    card: .failure(ChatFailureCard(conversationId: nil, title: nil, error: error, step: nil))))
                continue
            } else {
                // Tool-use narration is not the turn's final answer.
                guard role == .user || message["stopReason"]?.stringValue == "stop"
                    || !questions.isEmpty else { continue }
                if let content = message["content"]?.stringValue { text = content }
                else if case .array(let blocks) = message["content"] {
                    text = blocks.compactMap { block in
                        block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
                    }.joined(separator: "\n\n")
                } else { continue }
            }
            guard !text.isEmpty else { continue }
            flushTools()
            messages.append(ChatTranscriptMessage(
                id: String(entry.id), role: role,
                text: text, timestamp: entry.timestamp))
        }
        flushTools()
        let afterIndex = after.flatMap { id in messages.firstIndex { $0.id == id } }
        return ChatTranscriptSnapshot(
            header: ChatTranscriptHeader(
                kind: "ultimate", status: .ok, transcript: nil, activity: nil,
                turnOpen: busy, truncated: history.before != nil, error: nil,
                afterFound: after == nil || afterIndex != nil),
            // A cursor on a tool summary includes it again: the round may
            // have grown, and the merge replaces the card by its stable id.
            messages: afterIndex.map { index in
                let from = messages[index].card.map { card in
                    if case .toolSteps = card { return index } else { return index + 1 }
                } ?? (index + 1)
                return Array(messages.suffix(from: from))
            } ?? messages)
    }
}
