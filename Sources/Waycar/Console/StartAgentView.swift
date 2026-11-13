import PhotosUI
import SwiftUI

/// The new-agent sheet (#12, User Story 8): pick a Host and a launch target
/// (an existing Workspace or a new one at a remote directory), choose
/// Default Shell or an installed Agent with its native arguments and an
/// optional first message with images and files, and dispatch it through
/// the Transport launch flow. On success the sheet dismisses and hands the
/// launched pane's identity to `onStarted`; the owner opens it, so a fresh
/// launch lands in its terminal instead of back on the list.
///
/// With no verified connection to the Host, a strip under the title says
/// Start keeps the launch on this device until the Host connects (CONTEXT.md
/// **Queued Launch**); the Agent picker offers the kinds last detected, and
/// browsing the Host's folders, which needs the Host, says so. Start then
/// dismisses, and the Console shows the launch's card.
///
/// Opened by the New Chat quick action (`quickChat`), the same sheet is
/// titled "New Chat": it presets itself from the New Chat defaults, with
/// Chat Mode on, and starts on its own once they resolve. A started chat
/// raises its Chat Prompt keyboard when it opens. Opened with a `preset`
/// (Help's Ask an Agent, the Keychain Fix), it takes the preset's title,
/// shows what the Agent is handed, and is prefilled but waits for Start;
/// it is never in Chat Mode: the user sees every command the Agent runs.
struct StartAgentView: View {
    @State private var store: StartAgentStore
    @State private var directoryBrowser: RemoteDirectoryBrowser?
    /// The first message's Add Image and Add File pickers.
    @State private var isPickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var isPickingFiles = false
    private let onStarted: (ConsoleAgent.ID) -> Void
    private let console: ConsoleStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.analytics) private var analytics
    @Environment(\.askAgent) private var askAgent
    @Environment(\.backendInstallCenter) private var backendInstall
    /// The selected Host's install panel (WAY-338): its card shows while the
    /// Host has no usable backend or an install runs; nil without an
    /// install center (previews).
    @State private var installPanel: BackendInstallPanelStore?

    init(
        hosts: [Host], console: ConsoleStore,
        origin: StartAgentStore.LaunchOrigin? = nil,
        quickChat: NewChatPreferences? = nil,
        preset: AgentLaunchPreset? = nil,
        onStarted: @escaping (ConsoleAgent.ID) -> Void
    ) {
        self.onStarted = onStarted
        self.console = console
        _store = State(
            initialValue: console.makeStartAgentStore(
                hosts: hosts, origin: origin, quickChat: quickChat, preset: preset))
    }

    /// Inject the same form model for hosted previews and UI verification.
    init(store: StartAgentStore, console: ConsoleStore, onStarted: @escaping (ConsoleAgent.ID) -> Void) {
        self.onStarted = onStarted
        self.console = console
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack {
            // Rows name themselves (Host, Workspace, Agent, Name), so sections
            // carry no headers that would repeat them; footers only explain.
            Form {
                if let preset = store.preset {
                    Section {
                        Label(preset.attachmentTitle, systemImage: "doc.text")
                    } header: {
                        Text("Attached")
                    } footer: {
                        Text("The Agent reads this when it starts.")
                    }
                }

                if let origin = store.origin {
                    Section {
                        LabeledContent("Directory") {
                            Text(origin.cwd)
                                .font(.callout.monospaced())
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.trailing)
                        }
                    } footer: {
                        Text(store.launchingServerChat.map {
                            "Starts a \($0.sessionDescription) in this folder on the Host."
                        } ?? "The Agent starts in a new tab here, next to the one you opened this from.")
                    }
                } else {
                    Section {
                        Picker("Host", selection: store.hostSelection) {
                            if store.selectedHostID == nil {
                                Text("Select a Host").tag(Host.ID?.none)
                            }
                            ForEach(store.hosts) { host in
                                Text(host.displayName).tag(Host.ID?.some(host.id))
                            }
                        }
                        .disabled(store.locksHost)
                        StartWorkspacePicker(
                            workspaces: store.workspaces,
                            tmuxWorkspaceIDs: Set(
                                store.workspaces.filter { store.marksAsTmux($0) }.map(\.id)),
                            emptyTitle: store.backendGap == nil
                                ? StartWorkspacePicker.noneReportedTitle : HostBackendGap.noWorkspaceValue,
                            selectedWorkspaceID: store.launchTarget == .existingWorkspace
                                ? store.selectedWorkspaceID : nil,
                            newDirectory: store.newWorkspaceDirectory.isEmpty
                                ? nil : store.newWorkspaceDirectory,
                            isNewWorkspaceSelected: store.launchTarget == .newWorkspace,
                            canBrowse: store.selectedHostID != nil && store.backendGap == nil,
                            onSelect: store.selectExistingWorkspace,
                            onSelectNewWorkspace: store.selectNewWorkspace,
                            onNewWorkspace: openDirectoryBrowser,
                            startsInFolder: store.launchesIntoFolder,
                            browsesFolders: !store.startsWhenHostConnects)
                        if store.offersBackendChoice {
                            LabeledContent("Runtime") {
                                Picker("Runtime", selection: $store.newWorkspaceBackend) {
                                    ForEach(store.launchableBackends, id: \.self) { backend in
                                        Text(backend.displayName).tag(backend)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .accessibilityLabel("Runtime")
                            }
                        }
                        if store.launchTarget == .newWorkspace {
                            if !store.launchesIntoFolder {
                                LabeledContent("Name") {
                                    TextField(
                                        "Workspace Name", text: $store.newWorkspaceLabel,
                                        prompt: Text(newWorkspaceDefaultName ?? "Optional"))
                                        .multilineTextAlignment(.trailing)
                                        .autocorrectionDisabled()
                                }
                            }
                            Button("Change Directory…", systemImage: "folder") {
                                openDirectoryBrowser()
                            }
                            // Browsing lists the Host's folders live.
                            .disabled(store.startsWhenHostConnects)
                        }
                    } footer: {
                        if let footer = hostSectionFooter {
                            Text(footer)
                        }
                    }
                }

                if let panel = installPanel, panel.showsCard {
                    Section {
                        BackendInstallPanelCard(panel: panel)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                if let server = store.launchingServerChat {
                    HostServerRuntimeSection(server: server, state: store.selectedServerRuntimeState) {
                        Task { await store.startServerRuntime() }
                    }
                }

                if store.offersWorktree && !store.launchesServerChat && store.backendGap == nil {
                    Section {
                        Toggle("New Worktree", isOn: $store.startsInNewWorktree)
                            .disabled(store.selectedWorkspaceID == nil)
                        if store.startsInNewWorktree {
                            LabeledContent("Branch") {
                                NormalizingTextField(
                                    text: $store.worktreeBranch,
                                    placeholder: "Generated",
                                    font: Self.worktreeRefFont,
                                    accessibilityLabel: "Branch")
                            }
                            Toggle(
                                StartAgentStore.latestMainToggleTitle,
                                isOn: $store.startsFromLatestMain)
                            if !store.startsFromLatestMain {
                                LabeledContent("Base") {
                                    TextField("Base", text: $store.worktreeBase, prompt: Text("HEAD"))
                                        .worktreeRefField()
                                }
                            }
                        }
                    } footer: {
                        if let message = store.worktreeBranchErrorMessage {
                            Text(message)
                                .foregroundStyle(.red)
                        } else {
                            Text(worktreeFooter)
                        }
                    }
                }

                if store.backendGap != nil {
                    // No backend to open a tab in: Default Shell is shown, off,
                    // with its reason, and says when Start turns on.
                    Section {
                        Picker(
                            "Agent",
                            selection: .constant(StartAgentStore.LaunchSelection?.some(.shell))
                        ) {
                            Text("Default Shell")
                                .tag(StartAgentStore.LaunchSelection?.some(.shell))
                        }
                        .disabled(true)
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(HostBackendGap.shellUnavailableReason)
                            Text(HostBackendGap.startGateHint)
                        }
                    }
                } else {
                    Section {
                        if !store.launchesServerChat {
                            Picker("Agent", selection: store.launchSelection) {
                                if store.offersShell {
                                    Text("Default Shell")
                                        .tag(StartAgentStore.LaunchSelection?.some(.shell))
                                }
                                ForEach(store.availableAgentKinds) { kind in
                                    Text("\(kind.displayName) (\(kind.executable))")
                                        .tag(StartAgentStore.LaunchSelection?.some(.agent(kind)))
                                }
                            }
                            switch store.agentDiscoveryState {
                            case .idle:
                                Text("Select a Host to detect installed Agents.")
                                    .foregroundStyle(.secondary)
                            case .loading:
                                HStack {
                                    ProgressView()
                                    Text("Detecting installed Agents…")
                                }
                            case .loaded where store.availableAgentKinds.isEmpty:
                                // No Agent CLI detected. With Default Shell on
                                // offer it is preselected, so a quiet note says
                                // why, not an error card; without it (a preset
                                // launch) the full empty state remains.
                                if store.selectedLaunchIsShell {
                                    Label {
                                        Text("No Agent CLI found on this Host. Start opens its default shell; install a supported Agent to use one here.")
                                    } icon: {
                                        Image(systemName: "info.circle")
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                } else {
                                    ContentUnavailableView(
                                        "No Agents Found",
                                        systemImage: "magnifyingglass",
                                        description: Text(
                                            store.offersShell
                                                ? "Install a supported Agent CLI on this Host, then try again. Or choose Default Shell."
                                                : "Install a supported Agent CLI on this Host, then try again."))
                                }
                                Button("Detect Again", systemImage: "arrow.clockwise") {
                                    Task { await store.discoverAgents() }
                                }
                            case .loaded:
                                // Agents were found, or Default Shell is chosen;
                                // reopening the sheet or switching Host detects again.
                                EmptyView()
                            case .failed(let message):
                                // A real detection failure stays visible even
                                // while the empty-detection fallback holds the
                                // picker on Default Shell; only a user's own
                                // Shell choice quiets it.
                                if !store.selectedLaunchIsShell
                                    || store.shellAutoSelectedForEmptyDetection
                                {
                                    Label(message, systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.red)
                                    Button("Retry", systemImage: "arrow.clockwise") {
                                        Task { await store.discoverAgents() }
                                    }
                                }
                            }
                        }
                        LabeledContent("Name") {
                            if store.selectedLaunchIsShell && !store.launchesServerChat {
                                TextField(
                                    "Tab Name", text: $store.name,
                                    prompt: Text(store.defaultShellName ?? "Default Shell"))
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                            } else {
                                NormalizingTextField(
                                    text: $store.name,
                                    placeholder: store.defaultAgentName ?? "Optional",
                                    accessibilityLabel: "Agent Name")
                            }
                        }
                    } footer: {
                        if let message = store.nameErrorMessage {
                            Text(message)
                                .foregroundStyle(.red)
                        } else if let backend = store.foundBackend {
                            Text(Self.foundBackendFooter(backend))
                        } else if store.selectedLaunchIsShell {
                            Text("Opens a plain terminal running the Host's default shell. The name labels its tab.")
                        } else if store.agentKindsAreCached, store.startsWhenHostConnects,
                            let seenAt = store.agentKindsSeenAt
                        {
                            Text("Agents last detected \(seenAt, format: .relative(presentation: .named)).")
                        }
                    }
                }

                // What the Agent is told, ahead of how it runs.
                if (store.launchesServerChat || !store.selectedLaunchIsShell) && store.backendGap == nil {
                    Section {
                        StartAgentFirstMessageEditor(store: store)
                        StartAgentFirstMessageAddMenu(
                            canAdd: store.firstMessageTray.canAdd,
                            addImage: { isPickingPhotos = true },
                            addFile: { isPickingFiles = true })
                    } header: {
                        Text("First Message")
                    } footer: {
                        Text("Sent once the Agent is ready. Paste or add images and files to send with it.")
                    }
                }

                if store.showsChatModeToggle {
                    Section {
                        Toggle("Chat Mode", isOn: $store.chatMode)
                    } footer: {
                        Text(store.launchingServerChat == .codex
                            ? "Uses the Chat Prompt, Codex model and Quick thinking from Settings."
                            : "Shows replies as a chat instead of the terminal. Uses the Chat Prompt from Settings.")
                    }
                }

                if !store.launchesServerChat && !store.selectedLaunchIsShell && store.backendGap == nil {
                    Section {
                        AgentArgumentsField(
                            text: $store.arguments,
                            placeholder: #"e.g. --model "gpt 5" --continue"#)
                    } header: {
                        Text("Arguments")
                    } footer: {
                        if let message = store.argumentErrorMessage {
                            Text(message)
                                .foregroundStyle(.red)
                        } else {
                            Text("Quotes and backslash escapes are supported.")
                        }
                    }
                }
            }
            // The first message's Return breaks the line, so a drag down is
            // how its keyboard goes away.
            .scrollDismissesKeyboard(.interactively)
            // Pinned under the navigation bar, so the keyboard can't hide it.
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsLaunchBanner {
                    LaunchStatusBanner(
                        step: store.launchSteps.last, failure: failureMessage,
                        failedTitle: store.startKeepsLaunch ? "Couldn't Save" : "Couldn't Start")
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if let hostName = queuedHostName {
                    QueuedStartNotice(hostName: hostName)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.4), value: showsLaunchBanner)
            .animation(.smooth(duration: 0.4), value: queuedHostName)
            .photosPicker(
                isPresented: $isPickingPhotos,
                selection: $pickedPhotos,
                maxSelectionCount: max(1, store.firstMessageTray.remainingCapacity),
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .current)
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                pickedPhotos = []
                store.addFirstMessageAttachments(
                    items.map { .photo(PhotosPickerImageSelection(item: $0)) })
            }
            .fileImporter(
                isPresented: $isPickingFiles,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                store.addFirstMessageAttachments(urls.map { .file($0) })
            }
            .navigationTitle(
                store.preset?.title ?? (store.isQuickChat ? "New Chat" : "New Agent"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Ask an Agent closes this sheet, so hide it while a
                    // launch is in flight and the sheet can't be dismissed.
                    HelpLink(.newAgent)
                        .environment(\.askAgent, store.canDismiss ? askAgent : nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.stopQuickChat()
                        dismiss()
                    }
                    .tint(Brand.Colors.quietAction)
                    .disabled(!store.canDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.state == .starting {
                        ProgressView()
                    } else {
                        Button("Start") {
                            Task { await store.submit() }
                        }
                        .disabled(!store.canSubmit)
                    }
                }
            }
            .onChange(of: store.state) {
                switch store.state {
                case .started(let launched):
                    if let kind = store.launchedAgentKind {
                        analytics?.capture(.agentLaunched(kind: kind))
                    }
                    // A new chat opens ready to type; a terminal echoes its
                    // launch in Ignition (#96).
                    if store.launchedChat {
                        console.requestChatInputFocus(launched)
                    } else {
                        console.noteAgentLaunch(
                            launched, AgentLaunchNote(lastStep: store.launchSteps.last?.title))
                    }
                    dismiss()
                    onStarted(launched)
                case .queued:
                    // Kept on the device: the Console starts it once the
                    // Host is back.
                    dismiss()
                case .editing, .starting, .failed:
                    break
                }
            }
            .task(id: store.selectedHostID) {
                installPanel = makeInstallPanel(for: store.selectedHostID)
                await store.discoverAgents()
            }
            // An install or Check Again found a backend on the same Host:
            // detect Agents again and let Start work with no restart. Moving
            // to another Host that has a backend is no find.
            .onChange(of: GapKey(hostID: store.selectedHostID, gap: store.backendGap)) { old, new in
                if old.hostID == new.hostID, old.gap != nil, new.gap == nil {
                    Task { await store.backendFound() }
                }
            }
            .backendInstallSheet(installPanel)
            // Quick chat starts on its own once its Host is ready.
            .task {
                await store.runQuickChat()
            }
            // Cancel, a swipe down, or a Start: the tray's file copies go.
            .onDisappear {
                store.stopQuickChat()
                store.discardFirstMessageAttachments()
            }
            // The presented item also supplies the content, so the first
            // presentation cannot capture an empty browser from an older view.
            .sheet(item: $directoryBrowser) { browser in
                RemoteDirectoryBrowserView(browser: browser) { path in
                    store.applyBrowsedDirectory(path)
                    directoryBrowser = nil
                }
            }
            .interactiveDismissDisabled(!store.canDismiss)
        }
        // Sheets don't take the app root's tint; Toggles default to green.
        .tint(Brand.Colors.accent)
    }

    /// The label herdr gives an unnamed new Workspace: its directory's name,
    /// split as `StartWorkspacePicker` titles the same directory. Nil for the
    /// still-unresolved home directory and for `/`, where "Optional" shows.
    private var newWorkspaceDefaultName: String? {
        store.newWorkspaceDirectory.split(separator: "/").last.map(String.init)
    }

    /// What a New Workspace launch creates. With the herdr | tmux switch on
    /// tmux, the Workspace is a tmux session; on herdr-core it is a folder.
    private var newWorkspaceFooter: String {
        if store.launchesIntoFolder { return "Starts the agent in this folder on the Host." }
        return store.offersBackendChoice && store.newWorkspaceBackend == .tmux
            ? "Creates a tmux session on the Host. An empty name uses the directory's name."
            : "Creates a Workspace on the Host. An empty name uses the directory's name."
    }

    /// The Host Section's footer: the Host a preset locks, then what a New
    /// Workspace launch creates, and offline that its folder can't be
    /// browsed; nil when none applies.
    private var hostSectionFooter: String? {
        let isNewWorkspace = store.launchTarget == .newWorkspace
        let lines = [
            store.lockedHost.map { "This Agent runs on \($0.displayName)." },
            isNewWorkspace ? newWorkspaceFooter : nil,
            isNewWorkspace && store.startsWhenHostConnects
                ? "Choosing a folder needs a connection to the Host." : nil,
        ].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// The launch banner shows from Start until the sheet closes, and with a
    /// failure. Staying up across a retry and the closing success keeps the
    /// Form from sliding under it. Keeping a launch for later is no launch:
    /// the toolbar's spinner covers its moment, under the offline strip.
    private var showsLaunchBanner: Bool {
        switch store.state {
        case .starting: !store.startKeepsLaunch || !store.launchSteps.isEmpty
        case .started, .failed: true
        case .editing, .queued: false
        }
    }

    /// The selected Host's name while Start would keep the launch for later.
    private var queuedHostName: String? {
        guard store.startsWhenHostConnects, let hostID = store.selectedHostID else { return nil }
        return store.hosts.first { $0.id == hostID }?.displayName
    }

    private var failureMessage: String? {
        if case .failed(let message) = store.state { message } else { nil }
    }

    /// The worktree Section's footer: what New Worktree does, then where the
    /// new branch starts once it is on.
    private var worktreeFooter: String {
        let checkout = "Runs in a clean checkout of the workspace's repository."
        guard store.startsInNewWorktree else { return checkout }
        return store.startsFromLatestMain
            ? checkout + " Starts from the newest default branch on origin, usually main."
            : checkout + " Starts from the workspace's current checkout, or from Base if set."
    }

    /// The Host's install panel (WAY-338); nil when no install center is
    /// injected or no Host is picked.
    private func makeInstallPanel(for hostID: Host.ID?) -> BackendInstallPanelStore? {
        guard let center = backendInstall, let hostID,
            let host = store.hosts.first(where: { $0.id == hostID })
        else { return nil }
        return BackendInstallPanelStore(host: host, center: center, console: console)
    }

    /// The selected Host and its gap, observed together so a change of Host
    /// is never mistaken for a gap that closed.
    private struct GapKey: Equatable {
        let hostID: Host.ID?
        let gap: HostBackendGap?
    }

    /// What the Agent section says once an install or Check Again found
    /// `backend`, with a New Workspace as the launch target.
    private static func foundBackendFooter(_ backend: HostBackend) -> String {
        switch backend {
        case .ultimate:
            "Waycar found Ultimate on this Host. Open a conversation in the Console."
        case .codex:
            "Waycar found Codex's server on this Host. New Agent starts a Codex thread in a folder."
        case .opencode:
            "Waycar found OpenCode's server on this Host. New Agent starts an OpenCode session in a folder."
        case .herdr:
            "Waycar found herdr on this Host. New Workspace starts in your home folder."
        case .core:
            "Waycar found herdr-core on this Host. New Agent starts in your home folder."
        case .zellij:
            "Waycar found Zellij on this Host. Its sessions appear in the Console."
        case .tmux:
            "Waycar found tmux on this Host. New Workspace starts a tmux session in your home folder."
        }
    }

    private func openDirectoryBrowser() {
        // Choosing a directory is the user's pick; quick chat must not start.
        store.stopQuickChat()
        guard let hostID = store.selectedHostID else { return }
        directoryBrowser = RemoteDirectoryBrowser(
            resolveHome: { try await console.remoteHomeDirectory(on: hostID) },
            list: { try await console.listRemoteDirectories(at: $0, on: hostID) })
    }

    /// UIKit twin of `worktreeRefField()`'s font, for the Branch field. The
    /// base size is callout at the default (Large) category, so
    /// `UIFontMetrics` scales it exactly once.
    private static var worktreeRefFont: UIFont {
        let size = UIFont.preferredFont(
            forTextStyle: .callout,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        return UIFontMetrics(forTextStyle: .callout).scaledFont(
            for: .monospacedSystemFont(ofSize: size, weight: .regular))
    }
}

private extension View {
    /// Git refs are case-sensitive identifiers typed verbatim.
    func worktreeRefField() -> some View {
        font(.callout.monospaced())
            .multilineTextAlignment(.trailing)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
}

/// Keeps the latest browsed directory as the final menu option, even when an
/// existing Workspace is selected. Browsing only updates the launch draft.
/// On a Host running herdr and tmux, tmux sessions carry a `tmux` mark.
/// While the Host is out of reach (`browsesFolders` off), New Workspace
/// picks the home folder instead of browsing, and says so.
struct StartWorkspacePicker: View {
    private enum Selection: Hashable {
        case existing(String)
        case newWorkspace
    }

    /// The row's value on a Host that reports no Workspace.
    static let noneReportedTitle = "None reported"

    let workspaces: [ConsoleWorkspace]
    /// The Workspaces marked `tmux`; empty unless the Host runs both.
    var tmuxWorkspaceIDs: Set<String> = []
    /// The row's value while the Host reports no Workspace.
    var emptyTitle = StartWorkspacePicker.noneReportedTitle
    let selectedWorkspaceID: String?
    let newDirectory: String?
    let isNewWorkspaceSelected: Bool
    let canBrowse: Bool
    let onSelect: (String) -> Void
    let onSelectNewWorkspace: () -> Void
    let onNewWorkspace: () -> Void
    /// herdr-core: a Workspace is a folder, so the picker says so.
    var startsInFolder = false
    /// Whether New Workspace can browse the Host's folders; off while the
    /// Host has no verified connection.
    var browsesFolders = true

    private var directoryName: String {
        newDirectory?.split(separator: "/").last.map(String.init) ?? "/"
    }

    private var newWorkspaceTitle: String {
        startsInFolder ? "Other Folder…" : "New Workspace"
    }

    private var selectedTitle: String {
        if isNewWorkspaceSelected {
            return newDirectory == nil ? "Home" : directoryName
        }
        return workspaces.first { $0.id == selectedWorkspaceID }?.label ?? emptyTitle
    }

    private var selectedIsTmux: Bool {
        guard !isNewWorkspaceSelected, let selectedWorkspaceID else { return false }
        return tmuxWorkspaceIDs.contains(selectedWorkspaceID)
    }

    private var selection: Binding<Selection?> {
        Binding(
            get: {
                isNewWorkspaceSelected ? .newWorkspace : selectedWorkspaceID.map(Selection.existing)
            },
            set: { value in
                switch value {
                case .existing(let id): onSelect(id)
                case .newWorkspace: onSelectNewWorkspace()
                case nil: break
                }
            })
    }

    var body: some View {
        Menu {
            Picker("Workspace", selection: selection) {
                if selectedWorkspaceID == nil && !isNewWorkspaceSelected {
                    Text(emptyTitle).tag(Selection?.none)
                }
                ForEach(workspaces) { workspace in
                    Text(StartWorkspacePicker.menuTitle(
                        workspace, isTmux: tmuxWorkspaceIDs.contains(workspace.id)))
                        .tag(Selection?.some(.existing(workspace.id)))
                }
                if newDirectory != nil {
                    Text(directoryName).tag(Selection?.some(.newWorkspace))
                } else if isNewWorkspaceSelected {
                    Text("Home").tag(Selection?.some(.newWorkspace))
                }
            }
            .disabled(workspaces.isEmpty && newDirectory == nil)

            Divider()
            Group {
                if browsesFolders {
                    Button(action: onNewWorkspace) {
                        Label(newWorkspaceTitle, systemImage: "folder.badge.plus")
                    }
                } else {
                    // A menu draws a second Text as the item's subtitle.
                    Button(action: onSelectNewWorkspace) {
                        Text(startsInFolder ? "Home Folder" : "New Workspace")
                        Text(
                            startsInFolder
                                ? "Other folders need a connection."
                                : "In Home. Other folders need a connection.")
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .accessibilityIdentifier("new-workspace")
        } label: {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 12) {
                    Text(startsInFolder ? "Folder" : "Workspace")
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 12)
                    Text(selectedTitle)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.trailing)
                    if selectedIsTmux {
                        TmuxBadge(accessibilityLabel: "tmux session")
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .accessibilityHidden(true)
                }
                if isNewWorkspaceSelected, let newDirectory {
                    Text(newDirectory)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .disabled(!canBrowse)
        .accessibilityIdentifier("start-workspace-picker")
    }

    /// A menu entry: the Workspace's label, then "· tmux" for a marked one.
    static func menuTitle(_ workspace: ConsoleWorkspace, isTmux: Bool) -> String {
        isTmux ? "\(workspace.label) · \(HostBackend.tmux.displayName)" : workspace.label
    }
}

/// The launch status strip: one line naming the current step, which blurs
/// and drifts into the next as the launch moves on; on failure, the step
/// that failed and why, the reason scrolling past a few lines.
private struct LaunchStatusBanner: View {
    let step: StartAgentStore.LaunchStepProgress?
    let failure: String?
    /// The headline of a failure no step names.
    var failedTitle = "Couldn't Start"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Git's stderr can run long; past this the reason scrolls in place.
    @ScaledMetric(relativeTo: .footnote) private var maxDetailHeight: CGFloat = 80
    @State private var detailHeight: CGFloat = 0

    private var headline: String {
        step?.title ?? (isFailed ? failedTitle : "Starting…")
    }
    private var isFailed: Bool { failure != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                indicator
                    .frame(width: 20, height: 20)
                    .transition(.opacity)
                    .id(isFailed)
                ZStack(alignment: .leading) {
                    Text(headline)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .id(headline)
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let step, step.status == .running {
                    ElapsedSeconds(since: step.startedAt)
                        .id(step.startedAt)
                }
            }
            if let failure {
                ScrollView {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            detailHeight = $0
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(detailHeight, maxDetailHeight))
                .padding(.leading, 32)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .animation(
            reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.55),
            value: headline)
        .animation(.easeInOut(duration: 0.25), value: isFailed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        // The banner sits away from VoiceOver focus, so it speaks each change.
        .onChange(of: accessibilityLabel, initial: true) { _, label in
            AccessibilityNotification.Announcement(label).post()
        }
    }

    @ViewBuilder private var indicator: some View {
        if isFailed {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// The old line blurs out rising; the new one blurs in from below.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: AnyTransition(.blurReplace).combined(with: .offset(y: 8)),
            removal: AnyTransition(.blurReplace).combined(with: .offset(y: -8)))
    }

    private var accessibilityLabel: String {
        guard let failure else { return "In progress: \(headline)" }
        guard step != nil else { return "Couldn't start: \(failure)" }
        return "Failed: \(headline). \(failure)"
    }
}

/// The strip under the title while the selected Host has no verified
/// connection: Start keeps the launch on this device, and it starts once the
/// Host connects (CONTEXT.md **Queued Launch**). Drawn like the launch
/// banner, which takes its place from Start on; the clock is the Queued
/// Message's.
private struct QueuedStartNotice: View {
    let hostName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "clock")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Starts when \(hostName) connects")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text("Kept on this \(UIDevice.current.model) until then.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

/// Seconds spent on the running step, once it has taken 3 s or more.
private struct ElapsedSeconds: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(since))
            if elapsed >= 3 {
                Text("\(elapsed)s")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
