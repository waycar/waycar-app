import SwiftUI

/// An approval names the exact operation being allowed, never a terminal
/// key that could accidentally answer a different prompt.
struct AgentRequestCardView: View {
    let request: AgentPendingRequest
    let canAnswer: Bool
    let answer: (AgentRequestAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs your OK", systemImage: "hand.raised")
                .font(.headline)
                .foregroundStyle(Brand.Colors.blocked)
            switch request.kind {
            case .command(let command, let cwd, let reason):
                code(command)
                if let cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Brand.Colors.text3)
                        .textSelection(.enabled)
                }
                explanation(reason)
                buttons(allowsApproval: true)
            case .fileChange(let reason, let paths):
                explanation(reason)
                if paths.isEmpty {
                    Text("Review this change on the Host.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.Colors.text2)
                } else {
                    code(paths.prefix(4).joined(separator: "\n"))
                    if paths.count > 4 {
                        Text("and \(paths.count - 4) more")
                            .font(.caption)
                            .foregroundStyle(Brand.Colors.text3)
                    }
                }
                buttons(allowsApproval: !paths.isEmpty)
            case .unsupported:
                Text("Answer this on the Host.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.Colors.text2)
            case .questions:
                EmptyView() // ChatQuestionCardView owns questions.
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Brand.Colors.chatAgent,
            in: RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous)
                .strokeBorder(Brand.Colors.blocked.opacity(0.4), lineWidth: 1))
    }

    @ViewBuilder
    private func explanation(_ reason: String?) -> some View {
        if let reason, !reason.isEmpty {
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(Brand.Colors.text2)
        }
    }

    private func code(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Brand.Colors.termText)
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
                .padding(10)
        }
        .background(
            Brand.Colors.ink,
            in: RoundedRectangle(cornerRadius: Brand.Radius.keycap, style: .continuous))
    }

    private func buttons(allowsApproval: Bool) -> some View {
        HStack(spacing: 8) {
            if allowsApproval {
                Button("Allow") { answer(.allow) }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.Colors.chatUser)
            }
            Button("Cancel") { answer(.cancel) }
                .buttonStyle(.bordered)
                .tint(Brand.Colors.text2)
        }
        .disabled(!canAnswer)
    }
}
