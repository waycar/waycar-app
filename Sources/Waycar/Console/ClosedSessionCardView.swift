import SwiftUI

/// One Closed Session's card content in the Console list, drawn like an
/// Agent card (`AgentCardView`): the kind's initial, kind and Host over the
/// headline, the directory beneath, and in the trailing corner that it is
/// closed and since when — or progress while it resumes. The surface is the
/// list's `AgentCardChrome`. A Chat Mode session wears `ChatModeBadge` on
/// its glyph, as a live Chat Mode Agent's card does.
struct ClosedSessionCardView: View {
    let session: ClosedSession
    /// The Host's name now, which a rename may have changed since.
    var hostName: String?
    /// The Host's SSH account, to print its home directory as `~`.
    var hostUsername: String?
    var isResuming = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(Color(uiColor: .tertiarySystemFill))
                Text(verbatim: monogram)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            .overlay(alignment: .bottomTrailing) {
                if session.chatMode {
                    ChatModeBadge()
                        .offset(x: 4, y: 4)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: headline)
                    .font(.headline)
                    .lineLimit(1)
                Text(verbatim: location)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if isResuming {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Resuming")
                } else {
                    Text("Closed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                // Re-read every minute, like AI Usage's "Updated" line: a
                // self-updating `.relative` Text ticks every second and
                // reflows the card as its width changes.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(session.closedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var monogram: String {
        session.kind.rawValue.first.map { String($0).uppercased() } ?? "A"
    }

    /// The kind and Host, like an Agent card's caption.
    private var caption: String {
        [session.kind.rawValue, hostName ?? session.hostName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// herdr's name for the Agent, else the title it last showed.
    private var headline: String {
        session.agentName ?? session.title ?? session.kind.displayName
    }

    private var location: String {
        let path = ConsoleAgent.displayPath(session.cwd, hostUsername: hostUsername)
        return [session.workspaceLabel, path.isEmpty ? nil : path]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
