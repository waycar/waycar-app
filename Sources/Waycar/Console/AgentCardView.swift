import SwiftUI
import UIKit

/// One Console Agent's card content: a status-tinted kind glyph, the
/// Agent's kind and Host as a caption over the Row 1 headline, the status in
/// its own colour at the top trailing corner with the summary's age under
/// it (led by the Agent Progress label, `3/7 · 1m`, while there is an
/// estimate), the Agent Summary line across
/// the full card width beneath them, and any further layout rows below a
/// hairline. Fields retain their emphasis using accessible semantic
/// colors; plugin colors and weights do not replace app typography. The
/// surface around it belongs to the host view: the Console list applies
/// `AgentCardChrome`, which also draws the progress rail, and the Settings
/// preview sits on its own section card.
/// A Chat Mode Agent (`isChatMode`) wears `ChatModeBadge` on its glyph's
/// bottom-trailing edge; a plain shell never does. A Working or Blocked
/// Agent whose Host's plugin is too old for Agent Progress offers the
/// plugin update under its summary (`updatePluginForProgress`).
struct AgentCardView: View {
    let agent: ConsoleAgent
    var layout: AgentRowLayout = .waycarDefault
    var isPinned: Bool = false
    var isChatMode: Bool = false
    /// The Agent's Queued Messages (queued and held) on this device; a
    /// badge under the status shows any.
    var queuedCount: Int = 0
    var openUltimateChild: ((ConsoleAgent.ID) -> Void)? = nil
    @State private var showsUltimateChildren = false
    /// Set while the Agent's Host runs a plugin too old to send Agent
    /// Progress (#209, `ConsoleAgent.showsPluginProgressHint`): the card
    /// offers "Update plugin for progress", which opens the update sheet.
    var updatePluginForProgress: (() -> Void)? = nil
    @Environment(\.waycarPluginUpdateActivity) private var pluginUpdateActivity

    private var isUpdatingPlugin: Bool {
        pluginUpdateActivity?.runningHosts.contains(agent.hostID) == true
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Below this content width (an iPad sidebar card at its narrowest) a
    /// fresh progress label stands in for the age beside it, so the headline
    /// keeps room to read.
    @ScaledMetric(relativeTo: .headline) private var narrowContentWidth: CGFloat = 300
    @State private var contentWidth: CGFloat = .infinity

    private var presentation: AgentCardPresentation {
        AgentCardPresentation(agent: agent, layout: layout)
    }

    private var shellActivity: ShellActivityPresentation? {
        ShellActivityPresentation(agent: agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                AgentKindGlyph(agent: agent)
                    .overlay(alignment: .bottomTrailing) {
                        if isChatMode && !agent.isShell {
                            ChatModeBadge()
                                .offset(x: 4, y: 4)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(verbatim: presentation.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if agent.isUltimateLeader {
                            Text("lead")
                                .font(.system(.caption2, design: Brand.Fonts.monoDesign))
                                .foregroundStyle(Brand.Colors.text3)
                                .accessibilityLabel("Project lead")
                        }
                    }
                    AgentRowText(tokens: presentation.rows.first ?? [])
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    if let shellActivity {
                        Text(verbatim: shellActivity.statusText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)
                    } else {
                        // A stale estimate is spoken with its age, which
                        // moves on a clock: the card's 15 s cadence.
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            AgentStatusLabel(
                                status: agent.agent.status,
                                spokenProgress: agent.spokenProgress(at: context.date))
                        }
                    }
                    AgentSummaryAgeView(agent: agent, isNarrow: contentWidth < narrowContentWidth)
                    if queuedCount > 0 {
                        QueuedMessagesBadge(count: queuedCount)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
                    }
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Pinned")
                    }
                }
                // The badge springs in and out; its count rolls over.
                .animation(
                    QueuedMessageMotion.arrival(reduceMotion: reduceMotion), value: queuedCount)
                .layoutPriority(1)
            }
            // Full card width, under the headline row: the headline column
            // between the glyph and the status label clipped a summary after
            // ~30 characters.
            if let shellActivity {
                ShellActivityLine(presentation: shellActivity)
            } else if agent.summaryLine(at: .now) != nil {
                AgentSummaryLineView(agent: agent)
            }
            if let updatePluginForProgress {
                Button(action: updatePluginForProgress) {
                    Text(verbatim: isUpdatingPlugin ? "Updating plugin…" : "Update plugin for progress ›")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isUpdatingPlugin ? Brand.Colors.text3 : Brand.Colors.accent)
                }
                .buttonStyle(.borderless)
                .hoverEffect(.highlight)
                .accessibilityLabel("Update the Waycar plugin to see progress")
                .disabled(isUpdatingPlugin)
                .accessibilityHint(isUpdatingPlugin ? "An update is already running on this Host" : "")
            }
            let additionalRows = Array(presentation.rows.dropFirst())
            if !additionalRows.isEmpty {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(additionalRows.enumerated()), id: \.offset) { _, row in
                        AgentRowText(tokens: row, isSecondary: true)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if agent.isUltimateLeader, let openUltimateChild {
                Divider()
                HStack {
                    Text(verbatim: agent.ultimateBranchSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(agent.ultimateBranchSummary)
                    Spacer(minLength: 4)
                    if !agent.ultimateChildren.isEmpty {
                        Button(showsUltimateChildren ? "Hide" : "Show") {
                            showsUltimateChildren.toggle()
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showsUltimateChildren ? "Hide branches" : "Show branches")
                        .accessibilityValue(showsUltimateChildren ? "Expanded" : "Collapsed")
                    }
                }
                if showsUltimateChildren {
                    ForEach(agent.ultimateChildren, id: \.paneID) { child in
                        Button {
                            openUltimateChild(.init(hostID: agent.hostID, paneID: child.paneID))
                        } label: {
                            HStack {
                                Text(verbatim: child.name)
                                    .foregroundStyle(Color.primary)
                                    .fontWeight(child.needsUser ? .semibold : .regular)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                AgentStatusLabel(status: child.needsUser ? .blocked : child.status)
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("\(child.name), \(child.needsUser ? "Blocked" : child.status.rawValue.capitalized)\(child.needsUser ? ", \(child.openQuestions) needs you" : "")")
                        .accessibilityHint("Opens branch chat")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
    }
}

/// The card's count of Queued Messages waiting on this device for the
/// Agent's Host (CONTEXT.md **Queued Message**): a small mono pill in the
/// app's accent.
struct QueuedMessagesBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
            Text("\(count)")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
        }
        .font(.system(.caption2, design: Brand.Fonts.monoDesign, weight: .semibold))
        .foregroundStyle(Brand.Colors.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Brand.Colors.accent.opacity(0.14),
            in: RoundedRectangle(cornerRadius: Brand.Radius.pill, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "1 queued message" : "\(count) queued messages")
    }
}

/// The Console list's card surface: rounded grouped fill, padding, the
/// Agent Progress rail along the bottom edge, and the selection ring, which
/// is how the iPad sidebar marks the open Agent. The
/// clear row background hides the system selection fill, but the cell still
/// draws UIKit's rectangular focus halo, so `agentRow` clears it on the
/// selected row only, leaving this ring alone. Other rows keep the halo since
/// focus can sit on a row that is not selected (Full Keyboard Access,
/// selection-disabled rows). Selection Mode's checked outline is neutral,
/// not the accent ring of the open Agent. The AI Usage, closed-session and
/// Host cards share this surface and carry no progress.
struct AgentCardChrome: ViewModifier {
    var isSelected: Bool
    var isChecked: Bool = false
    /// The Agent whose progress rail runs along the bottom edge.
    var progressAgent: ConsoleAgent? = nil

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    /// The widest outline drawn over the card, which the rail sits inside.
    private var outlineWidth: CGFloat {
        max(isSelected ? 2 : 0, isChecked ? 1.5 : 0)
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
            .overlay(alignment: .bottom) {
                if let progressAgent {
                    AgentCardProgressEdge(agent: progressAgent, shape: shape, inset: outlineWidth)
                }
            }
            .overlay {
                if isSelected {
                    shape.strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .overlay {
                if isChecked {
                    shape.strokeBorder(Color(uiColor: .tertiaryLabel), lineWidth: 1.5)
                }
            }
            .contentShape(shape)
    }
}

/// Row chrome shared by every card list (the Console, the Hosts sheet): the
/// card draws its own background, so the row shows the grouped backdrop
/// between cards.
struct ConsoleCardRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// The Agent Row Layout's gap between entries, outside the card so what
/// the row draws beside the card (the swipe's disc) centres on the card
/// alone. Terminal blank rows become bounded extra card spacing on a phone.
struct AgentRowGap: ViewModifier {
    var rowGap: Int

    func body(content: Content) -> some View {
        content.padding(.bottom, CGFloat(min(rowGap, 3)) * 8)
    }
}

/// The card's leading mark: the kind's initial on the status wash, or a
/// terminal glyph for a plain shell, which has no Agent Status to show.
private struct AgentKindGlyph: View {
    let agent: ConsoleAgent

    var body: some View {
        ZStack {
            Circle()
                .fill(agent.isShell
                    ? Color(uiColor: .tertiarySystemFill)
                    : Color(agent.agent.status.tintUIColor).opacity(0.18))
            if agent.isShell {
                Image(systemName: "terminal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: monogram)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(Color(agent.agent.status.inkUIColor))
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    private var monogram: String {
        AgentNotificationIdentity.monogram(forKind: agent.agent.kind)
    }
}

/// The Agent Summary under the headline: the sentence in secondary text,
/// up to two lines. A stale one dims; the first one on its way shows two
/// placeholder bars. Its age sits under the status (`AgentSummaryAgeView`).
/// Re-evaluated every 15 s so the switch to stale keeps up without a new read.
private struct AgentSummaryLineView: View {
    let agent: ConsoleAgent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let line = agent.summaryLine(at: context.date) {
                content(line)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(line.accessibilityLabel)
            }
        }
    }

    @ViewBuilder
    private func content(_ line: AgentSummaryLine) -> some View {
        switch line {
        case .loading:
            AgentSummarySkeleton()
        case .summary(let text, _, let isStale):
            Text(verbatim: text)
                .foregroundStyle(isStale ? HierarchicalShapeStyle.tertiary : .secondary)
                .font(.subheadline)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The summary's age under the status: a clock and "now", "2m", "3d". No
/// "updated" wording; the clock carries it. Brighter when stale, since then
/// the age is the point. An Agent Progress estimate leads it in the status
/// ink (`3/7 · 1m`, `Exploring · 1m`), and shows without the age when there
/// is none. On a narrow card a fresh estimate drops the age: it only matters
/// once stale, and the rail dims then. VoiceOver hears the age on the
/// summary line and the estimate on the status label instead.
private struct AgentSummaryAgeView: View {
    let agent: ConsoleAgent
    var isNarrow = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            content(at: context.date)
        }
    }

    @ViewBuilder
    private func content(at now: Date) -> some View {
        let estimate = estimateState(at: now)
        let age = isNarrow && estimate?.isStale == false ? nil : ageState(at: now)
        if estimate != nil || age != nil {
            HStack(spacing: 4) {
                if let estimate {
                    Text(verbatim: estimate.progress.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(agent.agent.status.inkUIColor))
                }
                if estimate != nil && age != nil {
                    Text(verbatim: "·")
                }
                if let age {
                    Label(AgentSummaryLine.shortAge(age.age), systemImage: "clock")
                        .labelStyle(AgentSummaryAgeLabelStyle())
                }
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(age?.isStale == true ? HierarchicalShapeStyle.secondary : .tertiary)
            .lineLimit(1)
            .accessibilityHidden(true)
        }
    }

    private func estimateState(at now: Date) -> (progress: AgentProgress, isStale: Bool)? {
        guard case .estimate(let progress, let isStale) = agent.progressDisplay(at: now) else {
            return nil
        }
        return (progress, isStale)
    }

    private func ageState(at now: Date) -> (age: TimeInterval, isStale: Bool)? {
        guard case .summary(_, let age, let isStale) = agent.summaryLine(at: now) else { return nil }
        return (age, isStale)
    }
}

private struct AgentSummaryAgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// Two placeholder bars (92% and 58% wide) while an Agent's first summary
/// is on its way. A gentle pulse, held still under Reduce Motion.
private struct AgentSummarySkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// On iPad the list stays mounted under the Agent screen; an invisible
    /// repeatForever pulse would still cost a main-thread frame every tick.
    @Environment(\.consoleListIsCovered) private var isCovered
    @State private var isDimmed = false

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 7) {
                bar(width: proxy.size.width * 0.92)
                bar(width: proxy.size.width * 0.58)
            }
        }
        .frame(height: 11 * 2 + 7)
        .padding(.top, 3)
        .padding(.bottom, 2)
        .opacity(isDimmed ? 0.55 : 1)
        .onAppear { syncPulse() }
        .onChange(of: reduceMotion) { _, _ in syncPulse() }
        .onChange(of: isCovered) { _, _ in syncPulse() }
    }

    /// Starts the pulse when it may run, otherwise settles at full opacity
    /// without animating, which also cancels the repeating animation.
    private func syncPulse() {
        if reduceMotion || isCovered {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isDimmed = false }
        } else {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isDimmed = true
            }
        }
    }

    private func bar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(uiColor: .tertiarySystemFill))
            .frame(width: width, height: 11)
    }
}

/// Status as coloured text at the card's trailing corner. Working keeps a
/// live solving orb beside it — still text cannot tell a busy Agent from a
/// finished one at a glance. VoiceOver hears an Agent Progress estimate as
/// the value (`ConsoleAgent.spokenProgress(at:)`: "Working, 3 of 7 steps
/// done"), never a percent.
struct AgentStatusLabel: View {
    let status: AgentStatus
    var spokenProgress: String?

    var body: some View {
        HStack(spacing: 4) {
            if status == .working {
                SolvingOrbView(size: 12)
                    .accessibilityHidden(true)
            }
            Text(status.rawValue.capitalized)
                .font(.subheadline.weight(.semibold))
                .accessibilityValue(spokenProgress ?? "")
        }
        .foregroundStyle(Color(status.inkUIColor))
    }
}

/// A running Shell's foreground command across the card's summary slot.
/// Neutral text: Shell Activity is never an Agent Status, so no status ink.
struct ShellActivityLine: View {
    let presentation: ShellActivityPresentation

    var body: some View {
        Text(verbatim: presentation.commandText)
            .font(.system(.footnote, design: Brand.Fonts.monoDesign))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
    }
}

/// What a Shell row's card shows for its Shell Activity. nil for Agent rows
/// and for idle or unknown shells, whose card stays exactly "Shell".
struct ShellActivityPresentation: Equatable, Sendable {
    let statusText: String
    let commandText: String
    let accessibilityLabel: String

    init?(agent: ConsoleAgent) {
        guard agent.isShell, case .running(let command) = agent.shellActivity else { return nil }
        statusText = "Running"
        commandText = command
        accessibilityLabel = "Running \(command)"
    }
}

/// Keep per-field emphasis through the final Text instead of flattening the
/// rendered tokens into a String. Separators retain the row's base emphasis.
struct AgentRowText: View {
    let tokens: [RenderedToken]
    var isSecondary = false

    var body: some View {
        Text(attributedText)
    }

    private var attributedText: AttributedString {
        var result = AttributedString()
        for token in tokens {
            var span = AttributedString(token.text)
            let color: UIColor = if token.dim == true {
                isSecondary ? .tertiaryLabel : .secondaryLabel
            } else {
                isSecondary ? .secondaryLabel : .label
            }
            span.foregroundColor = Color(uiColor: color)
            result.append(span)
        }
        return result
    }
}

struct AgentCardPresentation: Equatable, Sendable {
    let rows: [[RenderedToken]]
    /// The line over the headline: the Agent's kind, then its Host.
    let caption: String

    var headline: String { rows.first?.map(\.text).joined() ?? "Agent" }
    var additionalRows: [String] { rows.dropFirst().map { $0.map(\.text).joined() } }

    init(agent: ConsoleAgent, layout: AgentRowLayout = .waycarDefault) {
        // Conversations have no terminal/tab fields to combine. Keep their
        // title alone, with project + Host in the same quiet caption slot.
        let fields = agent.backend == .ultimate
            ? AgentRowLayout(rows: [[.init(.agent)], [.init(.directory)]], rowGap: layout.rowGap)
            : layout
        let rendered = AgentRowRenderer.render(layout: fields, agent: agent)
        if rendered.isEmpty {
            let name = agent.agent.displayName
            rows = [[RenderedToken(
                token: .agent,
                text: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Agent" : name,
                fg: nil, bold: nil, dim: nil)]]
        } else {
            rows = rendered
        }
        caption = [agent.backend == .ultimate ? (agent.workspaceLabel ?? "Ultimate") : agent.agent.kind, agent.hostName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

#Preview {
    // Blocked mid-plan: the rail holds still in blue at 3/6.
    let blocked = ConsoleAgent(
        hostID: UUID(),
        hostName: "devbox",
        agent: Agent(
            terminalID: "term_a", kind: "claude", title: "Fix the flaky test",
            status: .blocked, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
            cwd: "/work/proj", revision: 3),
        workspaceLabel: "proj",
        repositoryCheckout: RepositoryCheckout(
            repoKey: "/work/proj/.git",
            repoName: "proj",
            repoRoot: "/work/proj",
            checkoutPath: "/work/proj-wt",
            isLinkedWorktree: true),
        summary: AgentSummary(
            paneID: "w1:p1", status: .blocked,
            text: "Waiting for approval to run the checkout UI test suite on the iPhone 17 simulator",
            timestamp: Int64(Date.now.addingTimeInterval(-70).timeIntervalSince1970 * 1000),
            progress: AgentProgress(steps: .init(done: 3, total: 6), phase: nil)))
    // No workspace in the snapshot: the Agent's own name takes the lead.
    // Its first summary is on its way, so the rail is dotted.
    let pending = ConsoleAgent(
        hostID: UUID(),
        hostName: "devbox",
        agent: Agent(
            terminalID: "term_b", kind: "claude", title: "Draft the release notes",
            status: .working, workspaceID: "w2", tabID: "w2:t1", paneID: "w2:p1",
            cwd: "/tmp", revision: 1),
        workspaceLabel: nil,
        repositoryCheckout: nil,
        isSummaryPending: true)
    List {
        AgentCardView(agent: blocked)
            .modifier(AgentCardChrome(isSelected: false, progressAgent: blocked))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        AgentCardView(agent: pending)
            .modifier(AgentCardChrome(isSelected: true, progressAgent: pending))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        // A plain shell running a foreground command.
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_c", kind: Agent.shellKind, title: "zsh",
                    status: .shellTerminal, workspaceID: "w3", tabID: "w3:t1", paneID: "w3:p1",
                    cwd: "/srv", revision: 1),
                workspaceLabel: "server",
                repositoryCheckout: nil,
                shellActivity: .running(command: "sudo apt update")))
        .modifier(AgentCardChrome(isSelected: false))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color(uiColor: .systemGroupedBackground))
}
