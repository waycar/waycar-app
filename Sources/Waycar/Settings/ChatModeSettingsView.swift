import SwiftUI

/// Settings › Chat Mode, on the same identity/metatype convention as the
/// other Settings routes.
enum SettingsChatModeDestination: String, Sendable {
    case chatMode = "settings.chatMode"

    var destinationTypeName: String { String(reflecting: ChatModeSettingsView.self) }

    @MainActor
    func destinationView(
        settings: ChatModeSettings, console: ConsoleStore, hosts: [Host]
    ) -> ChatModeSettingsView {
        ChatModeSettingsView(settings: settings, console: console, hosts: hosts)
    }
}

/// Settings › Chat Mode: the New Chat defaults, each harness's model, Quick
/// thinking and the Chat Prompt editor. Every edit is saved at once; blank
/// text or the default itself stores no override.
struct ChatModeSettingsView: View {
    let settings: ChatModeSettings
    let console: ConsoleStore
    let hosts: [Host]

    @State private var text = ""
    @State private var modelDrafts: [SupportedAgentKind: String] = [:]
    /// Kinds whose draft the user changed and hasn't saved yet; only these
    /// are saved on leaving, and only the others follow iCloud Sync.
    @State private var editedKinds: Set<SupportedAgentKind> = []

    private static let chatKinds = SupportedAgentKind.allCases.filter(\.supportsChatMode)

    static let footnote =
        "Sent to every Chat Mode Agent when it starts, except Cline: Cline can only replace its own "
        + "system prompt, so its chats start without this one. Line breaks are sent as spaces. "
        + "Running chats keep the prompt they started with. OpenCode and Kilo Code get the prompt "
        + "through the Waycar plugin, not a launch flag; their models are provider/model. Quick "
        + "thinking does not apply to OpenCode, Kilo Code, Gemini CLI or Qwen Code. OMP starts "
        + "with no model when it doesn't know the one set here."

    static let newChatFootnote =
        "Touch and hold the Waycar icon and choose New Chat to start one right away. "
        + "Last Used follows your most recent chat."

    var body: some View {
        Form {
            Section {
                Picker("Host", selection: hostSelection) {
                    Text("Last Used").tag(Host.ID?.none)
                    ForEach(destinationHosts) { host in
                        Text(verbatim: host.displayName).tag(Host.ID?.some(host.id))
                    }
                }
                .accessibilityIdentifier("settings.chatMode.newChat.host")
                if let destination = chosenDestination {
                    workspaceRow(for: destination)
                }
                Picker("Agent", selection: kindSelection) {
                    Text("Last Used").tag(SupportedAgentKind?.none)
                    ForEach(Self.chatKinds, id: \.self) { kind in
                        Text(kind.displayName).tag(SupportedAgentKind?.some(kind))
                    }
                }
                .accessibilityIdentifier("settings.chatMode.newChat.kind")
            } header: {
                Text("New Chat")
            } footer: {
                Text(Self.newChatFootnote)
            }
            Section {
                ForEach(Self.chatKinds, id: \.self) { kind in
                    LabeledContent(kind.displayName) {
                        TextField(
                            "\(kind.displayName) Model", text: modelBinding(for: kind), prompt: Text("Default"))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { commitModel(for: kind) }
                            .accessibilityIdentifier("settings.chatMode.model.\(kind.rawValue)")
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text(
                    "Chat Mode Agents start with this model. Leave it blank for the harness's own default. "
                        + "A model in New Agent's Arguments wins."
                )
            }
            Section {
                Toggle("Quick thinking", isOn: Binding(
                    get: { settings.quickThinking },
                    set: { settings.setQuickThinking($0) }
                ))
                .accessibilityIdentifier("settings.chatMode.quickThinking")
            } footer: {
                Text("Asks for less reasoning so replies come back faster. Turn it off for harder questions.")
            }
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 200)
                    .accessibilityIdentifier("settings.chatMode.prompt")
            } header: {
                Text("Chat Prompt")
            } footer: {
                Text("Chat Mode Agents get this prompt at launch so their replies read like texts.")
            }
            Section {
                Button("Reset to Default") {
                    settings.resetToDefault()
                    text = settings.promptText
                }
                .disabled(settings.isDefault)
                .accessibilityIdentifier("settings.chatMode.reset")
            } footer: {
                Text(Self.footnote)
            }
        }
        .navigationTitle("Chat Mode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { HelpLink(.chatMode) } }
        .onAppear {
            settings.reload()
            text = settings.promptText
            reloadModelDrafts()
        }
        .onDisappear {
            editedKinds.forEach(commitModel(for:))
        }
        // Another device changed a model through iCloud Sync.
        .onChange(of: settings.models) { _, _ in
            reloadModelDrafts()
        }
        .onChange(of: text) { _, newValue in
            settings.setPrompt(newValue)
        }
        // Another device changed the prompt through iCloud Sync.
        .onChange(of: settings.customPrompt) { _, _ in
            if text != settings.promptText, !(settings.isDefault && text.allSatisfy(\.isWhitespace)) {
                text = settings.promptText
            }
        }
    }

    /// The Hosts New Chat can launch on. New Chat resolves only against
    /// enabled Hosts, so a Disabled Host is treated here exactly like a
    /// removed one: not offered, and a saved destination on it reads as
    /// Last Used. The stored preference is kept, so it shows again once
    /// the Host is turned back on.
    private var destinationHosts: [Host] { hosts.filter(\.isEnabled) }

    /// The saved destination while its Host is listed; a removed or
    /// disabled Host reads as Last Used here until another is picked.
    private var chosenDestination: ChatDestination? {
        guard let destination = settings.newChatDestination,
            destinationHosts.contains(where: { $0.id == destination.hostID })
        else { return nil }
        return destination
    }

    private var hostSelection: Binding<Host.ID?> {
        Binding(
            get: { chosenDestination?.hostID },
            set: { hostID in
                // Compare with the stored Host, not the shown one: picking
                // Last Used must also clear a fixed Host that was removed.
                guard hostID != settings.newChatDestination?.hostID else { return }
                guard let hostID else {
                    settings.setNewChatDestination(nil)
                    return
                }
                // A new Host starts on its first listed workspace.
                let first = console.workspaces(for: hostID).first
                settings.setNewChatDestination(destination(hostID: hostID, workspace: first))
            }
        )
    }

    private var kindSelection: Binding<SupportedAgentKind?> {
        Binding(
            get: { settings.newChatKind },
            set: { settings.setNewChatKind($0) }
        )
    }

    /// The Host's live workspaces to pick from. While it is offline the saved
    /// label stays on show, read-only; connected with none, New Chat uses the
    /// Host's first or last chat workspace once one exists.
    @ViewBuilder
    private func workspaceRow(for destination: ChatDestination) -> some View {
        let workspaces = console.workspaces(for: destination.hostID)
        let isConnected = console.hostStatuses[destination.hostID] == .connected
        if isConnected, !workspaces.isEmpty {
            let current = Self.liveWorkspaceID(for: destination, in: workspaces)
            Picker("Workspace", selection: workspaceSelection(for: destination, in: workspaces)) {
                if current == nil {
                    Text(verbatim: destination.workspaceLabel ?? "Last Used").tag(String?.none)
                }
                ForEach(workspaces) { workspace in
                    Text(verbatim: workspace.label).tag(String?.some(workspace.id))
                }
            }
            .accessibilityIdentifier("settings.chatMode.newChat.workspace")
        } else {
            LabeledContent {
                Text(verbatim: destination.workspaceLabel ?? "")
            } label: {
                Text("Workspace")
                Text(isConnected ? "No workspaces yet" : "Connect to change")
            }
            .accessibilityIdentifier("settings.chatMode.newChat.workspace")
        }
    }

    private func workspaceSelection(
        for destination: ChatDestination, in workspaces: [ConsoleWorkspace]
    ) -> Binding<String?> {
        Binding(
            get: { Self.liveWorkspaceID(for: destination, in: workspaces) },
            set: { workspaceID in
                guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
                settings.setNewChatDestination(
                    self.destination(hostID: destination.hostID, workspace: workspace))
            }
        )
    }

    /// The live workspace New Chat would use: the saved id, else the one
    /// workspace carrying the saved label.
    private static func liveWorkspaceID(
        for destination: ChatDestination, in workspaces: [ConsoleWorkspace]
    ) -> String? {
        if let id = destination.workspaceID, workspaces.contains(where: { $0.id == id }) {
            return id
        }
        guard let label = destination.workspaceLabel, !label.isEmpty else { return nil }
        let matches = workspaces.filter { $0.label == label }
        return matches.count == 1 ? matches.first?.id : nil
    }

    /// The cwd is a listed row's directory in that workspace, so New Chat can
    /// recreate the workspace once it is gone; nil when no row is listed.
    private func destination(hostID: Host.ID, workspace: ConsoleWorkspace?) -> ChatDestination {
        guard let workspace else {
            return ChatDestination(hostID: hostID, workspaceID: nil, workspaceLabel: nil, cwd: nil)
        }
        let cwd = console.agents.first {
            $0.hostID == hostID && $0.agent.workspaceID == workspace.id && $0.agent.cwd.hasPrefix("/")
        }?.agent.cwd
        return ChatDestination(
            hostID: hostID, workspaceID: workspace.id, workspaceLabel: workspace.label, cwd: cwd)
    }

    private func modelBinding(for kind: SupportedAgentKind) -> Binding<String> {
        Binding(
            get: { modelDrafts[kind] ?? "" },
            set: {
                modelDrafts[kind] = $0
                editedKinds.insert(kind)
            }
        )
    }

    private func commitModel(for kind: SupportedAgentKind) {
        settings.setModel(modelDrafts[kind] ?? "", for: kind)
        modelDrafts[kind] = settings.model(for: kind) ?? ""
        editedKinds.remove(kind)
    }

    private func reloadModelDrafts() {
        for kind in Self.chatKinds where !editedKinds.contains(kind) {
            modelDrafts[kind] = settings.model(for: kind) ?? ""
        }
    }
}
