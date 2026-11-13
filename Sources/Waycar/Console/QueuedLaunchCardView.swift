import SwiftUI

/// One Queued Launch's card content in the Console list (CONTEXT.md
/// **Queued Launch**), drawn like a Closed Session's (`ClosedSessionCardView`):
/// the kind's initial, kind and Host over the name, where it starts beneath,
/// and in the trailing corner where it stands and since when. Under them the
/// first message it carries and a line saying what happens next, in the
/// Queued Message's glyph and colours: waiting for the Host, starting,
/// failed with the reason, or interrupted, which may have started. Failed
/// and interrupted cards offer Retry and Delete (the Console asks before
/// retrying an interrupted one). The surface is the list's
/// `AgentCardChrome`, which the Console outlines like a Queued Message
/// (`QueuedMessageOutline`): dashed while the launch is on this device.
struct QueuedLaunchCardView: View {
    let presentation: QueuedLaunchPresentation
    let state: QueuedLaunch.State
    let createdAt: Date
    let retry: () -> Void
    let delete: () -> Void
    var showsFirstMessage: Bool = true
    var showsActions: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if showsFirstMessage, let message = presentation.firstMessage {
                firstMessage(message)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                QueuedMessageStatusIcon(state: state.deliveryState)
                Text(verbatim: presentation.detail)
                    .foregroundStyle(detailTint)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .font(.footnote)
            if showsActions, state.awaitsUser {
                HStack(spacing: 8) {
                    Button("Retry", action: retry)
                    Button("Delete", role: .destructive, action: delete)
                        .accessibilityHint("Deletes this launch without starting it")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .transition(QueuedMessageMotion.detailTransition(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(QueuedMessageMotion.state(reduceMotion: reduceMotion), value: state)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            glyph
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: presentation.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: presentation.headline)
                    .font(.headline)
                    .lineLimit(1)
                Text(verbatim: presentation.location)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if state == .starting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Starting")
                } else {
                    Text(verbatim: presentation.statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusTint)
                }
                // Re-read every minute, as the Closed Session card's age.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var glyph: some View {
        ZStack {
            Circle().fill(Color(uiColor: .tertiarySystemFill))
            switch presentation.glyph {
            case .shell:
                Image(systemName: "terminal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            case .agent(let monogram):
                Text(verbatim: monogram)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .overlay(alignment: .bottomTrailing) {
            if presentation.isChatMode {
                ChatModeBadge()
                    .offset(x: 4, y: 4)
            }
        }
        .accessibilityHidden(true)
    }

    /// The first message, one line, with how many images and files ride
    /// along.
    private func firstMessage(_ message: QueuedLaunchPresentation.FirstMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(verbatim: message.preview)
                .foregroundStyle(
                    message.text.isEmpty ? HierarchicalShapeStyle.tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let summary = message.summary {
                Spacer(minLength: 4)
                Text(verbatim: summary)
                    .font(.system(.caption, design: Brand.Fonts.monoDesign, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.accessibilityLabel)
    }

    private var statusTint: Color {
        switch state {
        case .failed: Brand.Colors.danger
        case .waiting, .starting, .uncertain: Color.secondary
        }
    }

    private var detailTint: Color {
        if case .failed = state { return Brand.Colors.danger }
        return Color.secondary
    }
}

/// What a Queued Launch's card says, from the launch as Start kept it and
/// what the Console knows of its Host now (name, account, Workspaces).
struct QueuedLaunchPresentation: Equatable {
    enum Glyph: Equatable {
        case agent(monogram: String)
        case shell
    }

    struct FirstMessage: Equatable {
        /// What the user typed, on one line; empty when only items ride.
        let text: String
        /// "1 image", "2 files", "3 items"; nil with none.
        let attachments: String?
        let furtherMessageCount: Int

        var summary: String? {
            let parts = [attachments, furtherMessageCount > 0 ? "+\(furtherMessageCount) more" : nil]
                .compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        var preview: String { text.isEmpty ? "Images and files" : text }

        var accessibilityLabel: String {
            let lead = text.isEmpty ? "First message" : "First message: \(text)"
            return summary.map { "\(lead), \($0)" } ?? lead
        }
    }

    let glyph: Glyph
    let isChatMode: Bool
    /// The kind and Host, like an Agent card's caption.
    let caption: String
    /// The name it starts with, else the kind's name.
    let headline: String
    /// Where it starts: the Workspace, a new worktree of it, or a new
    /// Workspace and its folder.
    let location: String
    /// The trailing status word.
    let statusTitle: String
    /// What happens next, or why it stopped.
    let detail: String
    let firstMessage: FirstMessage?

    init(
        _ launch: QueuedLaunch, hostName: String?, hostUsername: String?,
        workspaces: [ConsoleWorkspace], pendingMessages: [AgentComposerStore.Message] = []
    ) {
        let draft = launch.draft
        let host = hostName ?? "the Host"
        switch draft.dispatch.launch {
        case .agent(let kind):
            glyph = .agent(monogram: AgentNotificationIdentity.monogram(forKind: kind.rawValue))
            isChatMode = draft.chatMode && kind.supportsChatMode
            caption = Self.joined([kind.rawValue, hostName])
            headline = draft.name ?? draft.suggestedName ?? kind.displayName
        case .shell:
            glyph = .shell
            isChatMode = false
            caption = Self.joined([Agent.shellKind, hostName])
            headline = draft.name ?? "Default Shell"
        }
        let workspace = draft.workspaceID.flatMap { id in workspaces.first { $0.id == id }?.label }
        let originPath = draft.originCwd.map {
            ConsoleAgent.displayPath($0, hostUsername: hostUsername)
        }
        switch draft.dispatch.destination {
        case .existingWorkspace:
            location = Self.joined([workspace ?? "Workspace", originPath])
        case .newWorktree(let spec):
            let branch = spec.branchIsGenerated ? nil : spec.branch
            location = Self.joined([
                workspace ?? "Workspace", ["New worktree", branch].compactMap { $0 }.joined(separator: " "),
            ])
        case .newWorkspace(let spec):
            let isFolder = draft.dispatch.backend == .core
            let name = isFolder ? "Folder" : spec.label.map { "New Workspace \($0)" } ?? "New Workspace"
            let path = spec.directory.isEmpty
                ? "Home" : ConsoleAgent.displayPath(spec.directory, hostUsername: hostUsername)
            location = Self.joined([name, path])
        }
        switch launch.state {
        case .waiting, .uncertain:
            statusTitle = "Waiting"
            detail = "Starts when \(host) connects."
        case .starting:
            statusTitle = "Starting"
            detail = "Starting on \(host)…"
        case .failed(let message):
            statusTitle = "Failed"
            detail = message
        }
        let waiting = pendingMessages.filter(\.isWaiting).sorted { $0.sentAt < $1.sentAt }
        firstMessage = waiting.first.flatMap {
            Self.firstMessage($0, furtherMessageCount: waiting.count - 1)
        }
    }

    private static func firstMessage(
        _ message: AgentComposerStore.Message, furtherMessageCount: Int
    ) -> FirstMessage? {
        let text = message.draftText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let items = message.queued?.attachments ?? []
        let images = items.count { $0.kind == .image }
        let files = items.count - images
        let attachments: String? =
            switch (images, files) {
            case (0, 0): nil
            case (let count, 0): count == 1 ? "1 image" : "\(count) images"
            case (0, let count): count == 1 ? "1 file" : "\(count) files"
            default: "\(images + files) items"
            }
        guard !text.isEmpty || attachments != nil else { return nil }
        return FirstMessage(
            text: text, attachments: attachments, furtherMessageCount: furtherMessageCount)
    }

    private static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension QueuedLaunch.State {
    /// The Queued Message state that draws the same: waiting has not left
    /// the phone, starting is going out. Legacy uncertain records wait too.
    var deliveryState: AgentComposerStore.DeliveryState {
        switch self {
        case .waiting: .queued
        case .starting: .sending
        case .failed(let message): .failed(message)
        case .uncertain: .queued
        }
    }

    /// Only failed launches wait for the user's Retry or Delete.
    var awaitsUser: Bool {
        switch self {
        case .failed: true
        case .waiting, .starting, .uncertain: false
        }
    }
}
