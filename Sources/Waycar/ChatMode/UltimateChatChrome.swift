import SwiftUI

/// The Hybrid chat's run status, pinned above the input bar while the
/// conversation works: a pulsing dot, the elapsed time, and the reminder
/// that typing steers rather than interrupts.
struct ChatWorkingPill: View {
    let activity: String?
    @State private var startedAt = Date()
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Brand.Colors.working)
                .frame(width: 7, height: 7)
                .opacity(pulsing && !reduceMotion ? 0.35 : 1)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(),
                    value: pulsing)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(line(at: context.date))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Brand.Colors.working)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Brand.Colors.working.opacity(0.1), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(
            Brand.Colors.working.opacity(0.3), lineWidth: 1))
        .onAppear { pulsing = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func line(at now: Date) -> String {
        var parts = ["working", elapsed(at: now)]
        if let activity, !activity.isEmpty {
            parts.append(activity)
        } else {
            parts.append("steering lands mid-run")
        }
        return parts.joined(separator: " · ")
    }

    private func elapsed(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private var spoken: String {
        activity.map { "Working: \($0)" } ?? "Working. Messages steer the run."
    }
}

/// The iPad leader chat's left rail: this project's lead chat on top, its
/// branches under it, each tappable into its own chat.
struct UltimateBranchRail: View {
    let context: UltimateChatContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header("This project")
                leaderRow
                header("Branches")
                    .padding(.top, 8)
                ForEach(context.children, id: \.conversationId) { child in
                    branchRow(child)
                }
            }
            .padding(12)
        }
        .background(Brand.Colors.bg)
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .monospaced))
            .kerning(1)
            .foregroundStyle(Brand.Colors.text3)
            .padding(.horizontal, 4)
    }

    /// The chat on show: marked, not tappable.
    private var leaderRow: some View {
        HStack(spacing: 10) {
            Text("@")
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .foregroundStyle(Brand.Colors.violetSoft)
                .frame(width: 28, height: 28)
                .background(
                    Brand.Colors.violet.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.keycap, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(context.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.Colors.text)
                HStack(spacing: 5) {
                    Circle()
                        .fill(context.busy ? Brand.Colors.working : Brand.Colors.idle)
                        .frame(width: 6, height: 6)
                    Text("leader · \(context.busy ? "working" : "idle")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Brand.Colors.text3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            Brand.Colors.violet.opacity(0.1),
            in: RoundedRectangle(cornerRadius: Brand.Radius.controlLg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.controlLg, style: .continuous)
                .strokeBorder(Brand.Colors.violet.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(context.name), leader, \(context.busy ? "working" : "idle"), this chat")
    }

    private func branchRow(_ child: UltimateChildInfo) -> some View {
        Button {
            context.openConversation(child.conversationId)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(child.busy ? Brand.Colors.working : Brand.Colors.idle)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(child.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.Colors.text)
                        .lineLimit(1)
                    Text(subtitle(child))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(
                            child.needsUser ? Brand.Colors.violetSoft : Brand.Colors.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.Colors.text3)
            }
            .padding(10)
            .background(
                Brand.Colors.surface2,
                in: RoundedRectangle(cornerRadius: Brand.Radius.controlLg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.controlLg, style: .continuous)
                    .strokeBorder(
                        child.needsUser ? Brand.Colors.violet.opacity(0.45) : Brand.Colors.line,
                        lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(child.name), \(child.busy ? "working" : "idle")"
                + (child.needsUser ? ", needs your answer" : ""))
        .accessibilityHint("Opens its chat")
    }

    private func subtitle(_ child: UltimateChildInfo) -> String {
        var parts = ["#\(child.conversationId)", child.busy ? "working" : "idle"]
        if child.needsUser { parts.append("needs you") }
        return parts.joined(separator: " · ")
    }
}
