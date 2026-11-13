import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The local screen for an Agent that has not started on its Host yet.
/// Its real Composer holds every message on this device until handover.
struct QueuedLaunchDetailView: View {
    let launch: QueuedLaunch
    let console: ConsoleStore
    let host: Host?
    @State private var keyboardPresentation: AgentComposerKeyboardPresentation = .hidden
    @State private var focusRequested = false
    @State private var isSelectingPhoto = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isSelectingFile = false
    @State private var isConfirmingDelete = false
    @Environment(\.consoleDetailIsCovered) private var isCovered

    private var composer: AgentComposerStore? { console.pendingComposer(for: launch.id) }

    private var presentation: QueuedLaunchPresentation {
        QueuedLaunchPresentation(
            launch, hostName: host?.displayName, hostUsername: host?.username,
            workspaces: console.workspacesByHost[launch.hostID] ?? [],
            pendingMessages: composer?.messages ?? [])
    }

    private var isPresenting: Bool {
        isSelectingPhoto || isSelectingFile || isConfirmingDelete
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    QueuedLaunchCardView(
                        presentation: presentation, state: launch.state,
                        createdAt: launch.createdAt, retry: requestRetry, delete: requestDelete,
                        showsFirstMessage: false, showsActions: false)
                        .modifier(AgentCardChrome(isSelected: false))
                    Text(composer == nil
                         ? "The terminal opens once this shell starts."
                         : "Messages below go out in order once the agent starts.")
                        .font(Brand.Fonts.body)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let composer {
                    VStack(spacing: 8) {
                        AgentComposerView(
                            store: composer, agentID: launch.pendingAgentID,
                            actions: composerActions(composer), skills: nil,
                            keyboardPresentation: $keyboardPresentation,
                            prepareKeyboardPresentation: { _ in },
                            focusRequested: $focusRequested,
                            isCovered: isCovered || isPresenting || launch.state == .starting,
                            showsMoreMenu: false,
                            isSendDisabled: launch.state == .starting,
                            queueMaxHeight: geometry.size.height * 0.45)
                        VStack(spacing: 4) {
                            Button("Direct Input", systemImage: "keyboard") {}
                                .disabled(true)
                            Text("Keyboard input opens once the agent starts.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(presentation.headline)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if launch.state.awaitsUser {
                        Button("Retry", systemImage: "arrow.clockwise", action: requestRetry)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive, action: requestDelete)
                        .disabled(launch.state == .starting)
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel("Launch actions")
                }
            }
        }
        .photosPicker(
            isPresented: $isSelectingPhoto, selection: $selectedPhotos,
            maxSelectionCount: max(1, composer?.tray.remainingCapacity ?? 1),
            selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current)
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            composer?.tray.add(items.map { .photo(PhotosPickerImageSelection(item: $0)) })
        }
        .fileImporter(
            isPresented: $isSelectingFile, allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            composer?.tray.add(urls.map { .file($0) })
        }
        .alert("Delete Launch and Messages?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) { console.cancelQueuedLaunch(launch.id) }
            Button("Cancel", role: .cancel) {}.tint(Brand.Colors.quietAction)
        } message: {
            Text("This deletes the launch and its queued messages from this device.")
        }
        .modifier(ConsoleDetailPresentationRegistration(
            agentID: launch.pendingAgentID, isPresenting: isPresenting))
    }

    private func requestDelete() {
        guard launch.state != .starting else { return }
        if composer?.messages.isEmpty == false {
            isConfirmingDelete = true
        } else {
            console.cancelQueuedLaunch(launch.id)
        }
    }

    private func requestRetry() {
        console.retryQueuedLaunch(launch.id)
    }

    private func composerActions(_ composer: AgentComposerStore) -> AgentComposerActions {
        // Only Add is shown here. The Agent's Host actions become available
        // on the real Agent screen after handover.
        AgentComposerActions(
            canAdd: composer.tray.canAdd,
            addImage: { isSelectingPhoto = true }, addFile: { isSelectingFile = true },
            openTerminal: nil, isOpeningTerminal: false, startAgent: {}, manageSnippets: {},
            showSkills: nil, showWorktreeDetails: nil, renameAgent: {}, renameWorkspace: {},
            markUnread: nil, closeAgent: {})
    }
}
