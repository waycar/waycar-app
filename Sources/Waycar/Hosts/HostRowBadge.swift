import SwiftUI

/// The small capsule beside a Host's name in the Hosts list and on its
/// details page: the MOSH/SSH transport, CodexBar, tmux. Filled badges are
/// white on their tint; muted ones are their tint on a faint wash of it.
/// Callers own the accessibility label.
struct HostRowBadge: View {
    enum Style {
        case filled
        case muted
    }

    let text: String
    let tint: Color
    var style: Style = .filled

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(style == .filled ? Color.white : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(style == .filled ? tint : tint.opacity(0.15), in: Capsule())
    }
}

/// Marks tmux: on a Host row when tmux is the Host's only backend. A Host
/// running herdr and tmux shows nothing extra; herdr leads there.
struct TmuxBadge: View {
    var accessibilityLabel = "tmux"

    var body: some View {
        HostRowBadge(text: "tmux", tint: .secondary, style: .muted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    /// Whether a Host row carries the badge: tmux-only Hosts, never herdr
    /// or dual ones, and nothing before the backends are known.
    /// `nonisolated`: pure, and called off the main actor (AGENTS.md, Conventions).
    nonisolated static func isShown(for presence: HostBackendPresence?) -> Bool {
        presence?.backends == [.tmux]
    }
}

/// A quiet runtime marker for a Zellij-only Host.
struct ZellijBadge: View {
    var accessibilityLabel = "Zellij"
    var body: some View {
        HostRowBadge(text: "Zellij", tint: .secondary, style: .muted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }
    nonisolated static func isShown(for presence: HostBackendPresence?) -> Bool {
        presence?.backends == [.zellij]
    }
}

/// Marks herdr-core: on a Host row when it is the Host's only backend (ADR
/// 0031). A TUI Host shows nothing extra, and neither does a Host that also
/// runs tmux, where the herdr runtime leads.
struct CoreBadge: View {
    var accessibilityLabel = HostBackend.core.displayName

    var body: some View {
        HostRowBadge(text: HostBackend.core.displayName, tint: .secondary, style: .muted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    /// Whether a Host row carries the badge: `backends` (the Host's
    /// resolution under its pick, nil before detection) are exactly
    /// `[.core]`.
    nonisolated static func isShown(for backends: [HostBackend]?) -> Bool {
        backends == [.core]
    }
}
