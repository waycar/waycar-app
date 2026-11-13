import SwiftUI

/// What a transcript card can do: answer a question with "1a"-style text
/// through the Composer, and open another conversation's chat (a branch
/// pointer, a failure's branch). Nil actions render the card inert.
struct ChatCardActions {
    /// Sends answer text ("1a") as if typed, through the existing submit.
    var submitText: QuestionCardDeliveryStore.Submit? = nil
    /// Opens the chat of another Ultimate conversation by its id.
    var openConversation: (@MainActor (Int) -> Void)? = nil
}

/// One rich transcript entry (Hybrid Chat Mode): a question card, branch
/// pointer, failure, context divider, or collapsed tool steps.
struct ChatTranscriptCardView: View {
    let card: ChatTranscriptCard
    let actions: ChatCardActions

    var body: some View {
        switch card {
        case .questions(let questions):
            ChatQuestionCardView(card: questions, submit: actions.submitText)
        case .branch(let branch):
            ChatBranchCardView(branch: branch, open: actions.openConversation)
        case .failure(let failure):
            ChatFailureCardView(failure: failure, open: actions.openConversation)
        case .divider(_, let label):
            ChatContextDivider(label: label)
        case .toolSteps(let steps):
            ChatToolStepsLine(steps: steps)
        }
    }
}

/// "Needs your answer": numbered questions with lettered, tappable options.
/// Tapping an option submits its reference ("1a"); the card then shows the
/// pick and stops taking taps until the transcript moves on.
struct ChatQuestionCardView: View {
    let card: ChatQuestionCard
    let submit: QuestionCardDeliveryStore.Submit?
    /// Native server requests submit all answers together, keyed by the
    /// server's question ref, with option labels rather than chat shorthand.
    var submitAnswers: (@MainActor ([String: [String]]) -> Void)? = nil
    var answersEnabled = true
    /// Native picks per question ref, in option order: one for a single
    /// pick, any number for a `multi` question, whose taps toggle.
    @State private var picks: [String: [String]] = [:]
    @State private var textAnswers: [String: String] = [:]
    @State private var delivery = QuestionCardDeliveryStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Needs your answer", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.Colors.violetSoft)
            if !card.body.isEmpty {
                ChatMessageText(text: card.body)
            }
            ForEach(Array(card.questions.enumerated()), id: \.offset) { index, question in
                questionView(question, number: index + 1, isOnly: card.questions.count == 1)
            }
            if let submitAnswers {
                Button("Submit answers") { submitAnswers(nativeAnswers) }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.Colors.chatUser)
                    .disabled(!answersEnabled || nativeAnswers.count != card.questions.count)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Brand.Colors.chatAgent,
            in: RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
                .strokeBorder(Brand.Colors.violet.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .onChange(of: card.questions, initial: true) { _, questions in
            delivery.show(questions)
        }
    }

    private func questionView(_ question: ChatQuestion, number: Int, isOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isOnly ? question.text : "\(number) · \(question.text)")
                .font(.subheadline)
                .foregroundStyle(Brand.Colors.text)
            ForEach(question.options, id: \.key) { option in
                optionRow(option, of: question)
            }
            if submitAnswers != nil {
                let placeholder = question.options.isEmpty ? "Your answer" : "Or type an answer"
                TextField(
                    placeholder,
                    text: Binding(
                        get: { textAnswers[question.ref] ?? "" },
                        set: { textAnswers[question.ref] = $0; picks[question.ref] = nil }),
                    prompt: Text(placeholder).foregroundStyle(Brand.Colors.text3))
                    .font(.subheadline)
                    .foregroundStyle(Brand.Colors.text)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(
                        Brand.Colors.ink,
                        in: RoundedRectangle(cornerRadius: Brand.Radius.keycap, style: .continuous))
                    .disabled(!answersEnabled)
            } else if question.options.isEmpty || !Self.tapAnswers(question) {
                // Multi-select, scale and free-text answers are typed into the
                // composer ("1a 1c", "2: 7"); a tap cannot carry them.
                Text("Reply below.")
                    .font(.caption)
                    .foregroundStyle(Brand.Colors.text3)
            }
        }
    }

    private func optionRow(_ option: ChatQuestionOption, of question: ChatQuestion) -> some View {
        let native = submitAnswers != nil
        // A one-tap answer stays highlighted from the tap on; its checkmark
        // (and "Sent") waits for the delivery acknowledgement.
        let isPicked = native ? picks[question.ref]?.contains(option.label) == true : delivery.pickedKey(for: question) == option.key
        let isConfirmed = native ? isPicked : delivery.sentKey(for: question) == option.key
        let questionAnswered = !native && delivery.isAnswered(question)
        return Button {
            if native {
                picks[question.ref] = Self.picking(option, in: question, after: picks[question.ref] ?? [])
                textAnswers[question.ref] = nil
                return
            }
            guard let submit, !questionAnswered, Self.tapAnswers(question) else { return }
            delivery.pick(option.key, for: question, submit: submit)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(option.key)
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Brand.Colors.violetSoft)
                    .frame(width: 22, height: 22)
                    .background(
                        Brand.Colors.violet.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: Brand.Radius.chip, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.Colors.text)
                        .multilineTextAlignment(.leading)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Brand.Colors.text3)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                if isConfirmed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Brand.Colors.violetSoft)
                } else if option.recommended {
                    Text("recommended")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Brand.Colors.violetSoft)
                }
            }
            .padding(10)
            .background(
                option.recommended || isPicked
                    ? Brand.Colors.violet.opacity(0.12) : Brand.Colors.surface2,
                in: RoundedRectangle(cornerRadius: Brand.Radius.controlLg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.controlLg, style: .continuous)
                    .strokeBorder(
                        option.recommended || isPicked
                            ? Brand.Colors.violet.opacity(0.5) : Brand.Colors.line,
                        lineWidth: 1))
            .opacity(questionAnswered && !isPicked ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(native ? !answersEnabled : submit == nil || questionAnswered || !Self.tapAnswers(question))
        .accessibilityLabel(accessibilityText(option, isPicked: isConfirmed))
        .accessibilityHint(questionAnswered ? "" : "Answers question \(question.ref)")
    }

    private var nativeAnswers: [String: [String]] {
        var result: [String: [String]] = [:]
        for question in card.questions {
            if let text = textAnswers[question.ref]?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if !text.isEmpty { result[question.ref] = [text] }
            } else if let chosen = picks[question.ref], !chosen.isEmpty {
                result[question.ref] = chosen
            }
        }
        return result
    }

    /// A tap on `option`: a `multi` question toggles it among the picks,
    /// kept in option order; any other question picks it alone.
    nonisolated static func picking(
        _ option: ChatQuestionOption, in question: ChatQuestion, after picks: [String]
    ) -> [String] {
        guard question.kind == "multi" else { return [option.label] }
        var chosen = Set(picks)
        if chosen.remove(option.label) == nil { chosen.insert(option.label) }
        return question.options.map(\.label).filter { chosen.contains($0) }
    }

    /// One tap can only carry a single pick: multi, scale and text answers
    /// go through the composer instead. Unknown kinds stay tappable, since a
    /// newer server's single-pick kind should not lose its one-tap answer.
    nonisolated static func tapAnswers(_ question: ChatQuestion) -> Bool {
        QuestionCardDeliveryMachine.tapAnswers(question)
    }

    private func accessibilityText(_ option: ChatQuestionOption, isPicked: Bool) -> String {
        var parts = ["Option \(option.key): \(option.label)"]
        if let detail = option.detail, !detail.isEmpty { parts.append(detail) }
        if isPicked { parts.append(submitAnswers == nil ? "Sent" : "Selected") }
        else if option.recommended { parts.append("Recommended") }
        return parts.joined(separator: ". ")
    }
}

/// A branch the leader started, as a tappable pointer into its own chat.
struct ChatBranchCardView: View {
    let branch: ChatBranchPointer
    let open: (@MainActor (Int) -> Void)?

    var body: some View {
        Button {
            open?(branch.conversationId)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.Colors.cyan)
                    .frame(width: 28, height: 28)
                    .background(
                        Brand.Colors.cyan.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Brand.Radius.keycap, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(branch.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.Colors.text)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Brand.Colors.text3)
                }
                Spacer(minLength: 0)
                if open != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.Colors.text3)
                }
            }
            .padding(12)
            .background(
                Brand.Colors.surface2,
                in: RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
                    .strokeBorder(Brand.Colors.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        .accessibilityLabel("Branch: \(branch.title)")
        .accessibilityHint(open == nil ? "" : "Opens its chat")
    }

    private var subtitle: String {
        var parts = ["#\(branch.conversationId)"]
        if let at = branch.at {
            parts.append(AgentSummaryLine.shortAge(Date().timeIntervalSince(at)))
        }
        return parts.joined(separator: " · ")
    }
}

/// A failed run (a watchdog failure, an errored turn). Tappable into the
/// failing branch's chat when the failure names one.
struct ChatFailureCardView: View {
    let failure: ChatFailureCard
    let open: (@MainActor (Int) -> Void)?

    private var opens: Bool { failure.conversationId != nil && open != nil }

    var body: some View {
        Button {
            guard let id = failure.conversationId else { return }
            open?(id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Brand.Colors.danger)
                    .frame(width: 28, height: 28)
                    .background(
                        Brand.Colors.danger.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Brand.Radius.keycap, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.title ?? "Run failed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.Colors.text)
                        .multilineTextAlignment(.leading)
                    Text(detailLine)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Brand.Colors.text2)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
                if opens {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.Colors.text3)
                }
            }
            .padding(12)
            .background(
                Brand.Colors.chatAgent,
                in: RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
                    .strokeBorder(Brand.Colors.danger.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!opens)
        .accessibilityLabel("Failed: \(failure.title ?? failure.error)")
        .accessibilityHint(opens ? "Opens the failing chat" : "")
    }

    private var detailLine: String {
        let error = failure.error.components(separatedBy: .newlines).first ?? failure.error
        guard let step = failure.step, !step.isEmpty else { return error }
        return "step: \(step) · \(error)"
    }
}

/// A compaction or reset marker: the context changed shape here.
struct ChatContextDivider: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            line
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .kerning(1)
                .foregroundStyle(Brand.Colors.text3)
                .lineLimit(1)
                .layoutPriority(1)
            line
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var line: some View {
        Rectangle()
            .fill(Brand.Colors.line2)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// One quiet line for a turn's collapsed tool work: "6 tool steps · rg,
/// read ×3, edit ×2".
struct ChatToolStepsLine: View {
    let steps: ChatToolStepsSummary

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Brand.Colors.text3)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Brand.Colors.surface2,
                in: Capsule(style: .continuous))
            .accessibilityLabel(text)
    }

    private var text: String {
        let count = steps.count == 1 ? "1 tool step" : "\(steps.count) tool steps"
        return steps.summary.isEmpty ? count : "\(count) · \(steps.summary)"
    }
}
