import ActivityKit
import SwiftUI
import WidgetKit

/// Progress (#189) drawing shared by the Lock Screen rows, the Dynamic
/// Island, and the `.small` family. Bars are estimates: no percentage, no
/// time left (docs/agents/live-activity-contract.md).
enum AgentActivityProgressMetrics {
    /// The rule inside each Lock Screen / expanded island row; it fits the
    /// existing 28 pt row height so the 160 pt budget holds.
    static let rowRule: CGFloat = 2.5
    /// Gap between the identity text and its rule.
    static let ruleGap: CGFloat = 2
    /// One hairline in the compact island's bar stack.
    static let compactBar: CGFloat = 3
    static let compactBarWidth: CGFloat = 36
    static let compactBarSpacing: CGFloat = 3
    /// The mini bar in each `.small` family row.
    static let smallBar: CGFloat = 3
    /// Below this content width (tile minus padding) the `.small` bar moves
    /// under the name. The 170 pt Dashboard tile leaves ~150 pt and stays
    /// inline; only Watch-narrow tiles stack.
    static let smallInlineMinWidth: CGFloat = 120
    /// Share of an inline `.small` row's width given to the short name;
    /// the bar takes what the name and label leave.
    static let smallNameShare: CGFloat = 0.42
    static let smallBarMinWidth: CGFloat = 16
    static let smallSpacing: CGFloat = 2
}

/// A capsule track in the status wash with the status ink filled to
/// `fraction`; a stale activity dims the fill.
struct AgentActivityProgressRule: View {
    let fraction: Double
    let status: String
    let surface: AgentActivitySurface
    let isStale: Bool
    let thickness: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AgentActivityStatusStyle.wash(for: status, on: surface).opacity(0.35))
                Capsule()
                    .fill(AgentActivityStatusStyle.ink(for: status, on: surface))
                    .opacity(isStale ? AgentActivityProgressCopy.staleFillOpacity : 1)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: thickness)
        .accessibilityHidden(true)
    }
}

/// Compact trailing island for a Working lead: one hairline per top Agent
/// in envelope order. An Agent without an estimate keeps an empty track so
/// the stack's positions still mean "first, second, third".
struct AgentActivityCompactBarStack: View {
    let agents: [AgentActivityDetails.AgentDetail]
    let isStale: Bool

    var body: some View {
        VStack(spacing: AgentActivityProgressMetrics.compactBarSpacing) {
            ForEach(agents, id: \.paneID) { agent in
                AgentActivityProgressRule(
                    fraction: AgentActivityProgressCopy.drawnProgress(for: agent)?.fraction ?? 0,
                    status: agent.status, surface: .island, isStale: isStale,
                    thickness: AgentActivityProgressMetrics.compactBar)
            }
        }
        .frame(width: AgentActivityProgressMetrics.compactBarWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agents.map(AgentActivityNarration.rowLabel(for:)).joined(separator: "; "))
    }
}

/// `.small` family: the Apple Watch Smart Stack and the CarPlay Dashboard.
/// One header line (Host name; lead attention count and "+N" overflow),
/// then up to three one-line Agent rows: short name, inline mini bar
/// (Working/Blocked with an estimate), label. Narrow tiles put the bar
/// under the name. No buttons: the whole tile opens the Console. A stale
/// or update-reduced activity (watch out of range) keeps its layout but
/// drops status inks to secondary and dims its bars. Always dark on its
/// own background (`AgentActivitySurface.small`), whatever the plate and
/// appearance of the watch or car showing it.
struct AgentActivitySmallView: View {
    let presentation: AgentActivityPresentation
    let hostID: String
    let isStale: Bool
    /// True while the watch is out of range and updates are throttled.
    @Environment(\.isActivityUpdateReduced) private var isActivityUpdateReduced

    /// Stale content keeps its layout but loses its status color.
    private var isDimmed: Bool { isStale || isActivityUpdateReduced }

    /// The status ink, or secondary ink while dimmed.
    private func ink(for status: String) -> Color {
        isDimmed
            ? AgentActivitySemanticStyle.secondary(on: .small)
            : AgentActivityStatusStyle.ink(for: status, on: .small)
    }

    var body: some View {
        let agents = Array(presentation.agents.prefix(AgentActivityCopy.smallRowLimit))
        let names = Self.shortNames(for: agents)
        GeometryReader { proxy in
            let inline = proxy.size.width >= AgentActivityProgressMetrics.smallInlineMinWidth
            let nameWidth = proxy.size.width * AgentActivityProgressMetrics.smallNameShare
            // Fewer rows (counted into the header's "+N") rather than
            // clipping, e.g. at the largest Dynamic Type. Explicit
            // variants, largest first (smallRowLimit is 3).
            ViewThatFits(in: .vertical) {
                content(agents.prefix(3), names: names, inline: inline, nameWidth: nameWidth)
                content(agents.prefix(2), names: names, inline: inline, nameWidth: nameWidth)
                content(agents.prefix(1), names: names, inline: inline, nameWidth: nameWidth)
                content(agents.prefix(0), names: names, inline: inline, nameWidth: nameWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(AgentActivitySemanticStyle.primary(on: .small))
        .background(Color(uiColor: AgentActivitySmallChrome.backgroundColor))
        .dynamicTypeSize(...DynamicTypeSize.large)
        .widgetURL(AgentActivityLink.consoleURL(hostID: hostID))
    }

    private func content(
        _ agents: ArraySlice<AgentActivityDetails.AgentDetail>, names: [String],
        inline: Bool, nameWidth: CGFloat
    ) -> some View {
        let overflow = presentation.agents.isEmpty
            ? 0 : max(0, presentation.counts.total - agents.count)
        return VStack(alignment: .leading, spacing: AgentActivityProgressMetrics.smallSpacing) {
            header(overflow: overflow)
            ForEach(Array(agents.enumerated()), id: \.element.paneID) { index, agent in
                if inline {
                    inlineRow(agent, name: names[index], nameWidth: nameWidth)
                } else {
                    stackedRow(agent, name: names[index])
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func header(overflow: Int) -> some View {
        HStack(spacing: 4) {
            if let host = presentation.hostName {
                Text(host)
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                if let lead = presentation.counts.attentionStatusItem {
                    Text("\(lead.count) \(AgentActivityStatusVocabulary.word(for: lead.status))")
                        .foregroundStyle(ink(for: lead.status))
                }
                if overflow > 0 {
                    Text(presentation.counts.attentionStatusItem == nil ? "+\(overflow)" : " · +\(overflow)")
                        .foregroundStyle(AgentActivitySemanticStyle.secondary(on: .small))
                }
            }
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ([presentation.hostName].compactMap { $0 }
                + [AgentActivityNarration.countsLabel(presentation.counts.chipItems)]
                + (overflow > 0 ? ["\(overflow) more"] : []))
                .joined(separator: ", "))
    }

    /// Dashboard layout: [name] [bar] [label] on one line.
    private func inlineRow(
        _ agent: AgentActivityDetails.AgentDetail, name: String, nameWidth: CGFloat
    ) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: nameWidth, alignment: .leading)
            if let progress = AgentActivityProgressCopy.drawnProgress(for: agent) {
                rule(progress, status: agent.status)
                    .frame(minWidth: AgentActivityProgressMetrics.smallBarMinWidth)
            } else {
                Spacer(minLength: 0)
            }
            label(agent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentActivityNarration.rowLabel(for: agent))
    }

    /// Narrow (Watch) layout: name and label, the bar under them.
    private func stackedRow(_ agent: AgentActivityDetails.AgentDetail, name: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                label(agent)
            }
            if let progress = AgentActivityProgressCopy.drawnProgress(for: agent) {
                rule(progress, status: agent.status)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentActivityNarration.rowLabel(for: agent))
    }

    private func rule(_ progress: AgentProgress, status: String) -> some View {
        AgentActivityProgressRule(
            fraction: progress.fraction, status: status, surface: .small,
            isStale: isDimmed, thickness: AgentActivityProgressMetrics.smallBar)
    }

    private func label(_ agent: AgentActivityDetails.AgentDetail) -> some View {
        Text(AgentActivityProgressCopy.trailingLabel(for: agent))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ink(for: agent.status))
            .lineLimit(1)
            .fixedSize()
    }

    /// The tile's per-Agent label: the most specific identity value — the
    /// last value of the drawn identity row after the #190 dedupe
    /// ("waycar · reviewer" → "reviewer"), or the only one. Legacy
    /// producers without configured rows use the herdr name, else the
    /// workspace, else the friendly kind.
    /// Pure text logic: `nonisolated` so it does not inherit the View's
    /// MainActor isolation (callers off the main actor would trap).
    nonisolated static func shortName(for agent: AgentActivityDetails.AgentDetail) -> String {
        if agent.rows != nil,
            let value = AgentActivityFields.rows(for: agent).first?
                .last(where: { !AgentActivityFields.isSeparator($0) })
        {
            let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        if let name = agent.name, !name.isEmpty { return name }
        if let workspace = agent.displayWorkspace { return workspace }
        return AgentNotificationIdentity.kindLabel(agent.kind)
    }

    /// `shortName` per Agent, except that Agents whose short names collide
    /// while their identities differ show their whole identity row instead
    /// (the tile truncates it), so two rows never read the same by accident.
    nonisolated static func shortNames(for agents: [AgentActivityDetails.AgentDetail]) -> [String] {
        let short = agents.map(shortName(for:))
        let identity = agents.map { AgentActivityFields.identityTexts(for: $0).first ?? "" }
        return agents.indices.map { index in
            let collides = agents.indices.contains { other in
                other != index && short[other] == short[index] && identity[other] != identity[index]
            }
            return collides ? identity[index] : short[index]
        }
    }
}
