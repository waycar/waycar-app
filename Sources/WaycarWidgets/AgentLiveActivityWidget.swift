import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// Live Activity for one Host. A status header answers "does anything need
/// me?" at a glance; below it each visible Agent gets one Console-style line
/// (kind monogram, configured identity, status word). Rows arrive in the
/// sender's pin-aware order and are rendered as given. Agent rows deep-link
/// to their detail while the surrounding chrome opens the Console.
struct AgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityLockScreenContainer(
                presentation: AgentActivityDecryptor.presentation(for: context.state),
                hostID: context.attributes.hostID,
                isStale: context.isStale
            )
        } dynamicIsland: { context in
            AgentActivityIsland.make(
                presentation: AgentActivityDecryptor.presentation(for: context.state),
                hostID: context.attributes.hostID,
                isStale: context.isStale)
        }
        // The Apple Watch Smart Stack and the CarPlay Dashboard draw
        // `.small`; the container branches on `activityFamily`.
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Surface seam

enum AgentActivitySurface {
    /// Lock Screen banner. Status colors remain dynamic so ActivityKit can
    /// resolve Latte in Light appearance and Mocha in Dark appearance.
    case lockScreen
    /// Compact, minimal, and expanded Dynamic Island. Always Mocha,
    /// resolved against a dark trait collection, ignoring ambient Light Mode.
    case island
    /// The `.small` family: the Apple Watch Smart Stack and the CarPlay
    /// Dashboard. Always dark, on its own background, every color resolved
    /// before drawing: iOS renders this tile once and the watch shows that
    /// render on a Smart Stack that turns light or dark by itself, so no
    /// color may be left to the appearance of the device showing it.
    case small

    /// `color` as this surface draws it: dynamic on the Lock Screen, which
    /// iOS redraws for each appearance, and resolved dark everywhere else.
    func resolved(_ color: UIColor) -> UIColor {
        switch self {
        case .lockScreen:
            color
        case .island, .small:
            color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        }
    }
}

enum AgentActivityStatusStyle {
    static func ink(for status: String, on surface: AgentActivitySurface) -> Color {
        Color(uiColor: resolvedUIColor(for: status, role: .ink, on: surface))
    }

    static func wash(for status: String, on surface: AgentActivitySurface) -> Color {
        Color(uiColor: resolvedUIColor(for: status, role: .wash, on: surface))
    }

    private enum Role { case ink, wash }

    private static func resolvedUIColor(
        for status: String, role: Role, on surface: AgentActivitySurface
    ) -> UIColor {
        let agentStatus = paletteStatus(for: status)
        switch role {
        case .ink: return surface.resolved(agentStatus.inkUIColor)
        case .wash: return surface.resolved(agentStatus.tintUIColor)
        }
    }

    private static func paletteStatus(for status: String) -> AgentStatus {
        switch status {
        case "blocked", "done", "working", "idle":
            return AgentStatus(rawValue: status)
        default:
            return .unknown
        }
    }
}

enum AgentActivitySemanticStyle {
    static func primary(on surface: AgentActivitySurface) -> Color {
        switch surface {
        case .lockScreen, .small:
            Color(uiColor: surface.resolved(.label))
        case .island:
            Color.primary
        }
    }

    static func secondary(on surface: AgentActivitySurface) -> Color {
        switch surface {
        case .lockScreen, .small:
            Color(uiColor: surface.resolved(.secondaryLabel))
        case .island:
            Color.secondary
        }
    }
}

// MARK: - Lock screen

private struct AgentActivityLockScreenContainer: View {
    let presentation: AgentActivityPresentation
    let hostID: String
    let isStale: Bool
    @Environment(\.activityFamily) private var activityFamily

    var body: some View {
        if activityFamily == .small {
            AgentActivitySmallView(
                presentation: presentation, hostID: hostID, isStale: isStale)
                .activityBackgroundTint(Color(uiColor: AgentActivitySmallChrome.backgroundColor))
                .activitySystemActionForegroundColor(
                    AgentActivitySemanticStyle.primary(on: .small))
        } else {
            AgentActivityLockScreenView(
                presentation: presentation,
                hostID: hostID,
                isStale: isStale
            )
            .foregroundStyle(AgentActivitySemanticStyle.primary(on: .lockScreen))
            .activityBackgroundTint(Color(uiColor: AgentActivityLockScreenChrome.backgroundColor))
            .activitySystemActionForegroundColor(
                Color(uiColor: AgentActivityLockScreenChrome.actionColor))
        }
    }
}

enum AgentActivityLockScreenChrome {
    /// Keep these semantic colors unresolved so ActivityKit can apply the
    /// system appearance when its host provides the correct trait collection.
    static let backgroundColor = UIColor.systemBackground
    static let actionColor = UIColor.label
}

enum AgentActivitySmallChrome {
    /// The system background resolved dark: black, the watchOS background.
    static let backgroundColor = AgentActivitySurface.small.resolved(.systemBackground)
}

struct AgentActivityLockScreenView: View {
    let presentation: AgentActivityPresentation
    let hostID: String
    let isStale: Bool

    var body: some View {
        let agents = presentation.lockScreenAgents(isStale: isStale)
        ZStack {
            Color(uiColor: AgentActivityLockScreenChrome.backgroundColor)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: AgentActivityLockScreenMetrics.sectionSpacing) {
                AgentActivityStatusHeader(counts: presentation.counts, surface: .lockScreen)
                if !agents.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(agents, id: \.paneID) { agent in
                            AgentActivityLinkedRow(
                                hostID: hostID, agent: agent, surface: .lockScreen,
                                isStale: isStale)
                        }
                    }
                }
                if let caption = presentation.lockScreenTrailingCaption(isStale: isStale) {
                    AgentActivityFooter(text: caption, surface: .lockScreen)
                }
                #if DEBUG
                    if let reason = AgentActivityDecryptor.lastFailureReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(
                                AgentActivitySemanticStyle.secondary(on: .lockScreen)
                            )
                            .lineLimit(3)
                    }
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AgentActivityLockScreenMetrics.horizontalPadding)
            .padding(.vertical, AgentActivityLockScreenMetrics.verticalPadding)
        }
        // Hard 160 pt ActivityKit limit: larger text would push rows out.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .widgetURL(AgentActivityLink.consoleURL(hostID: hostID))
    }
}

// MARK: - Dynamic Island

enum AgentActivityIsland {
    static func make(
        presentation: AgentActivityPresentation, hostID: String, isStale: Bool
    ) -> DynamicIsland {
        let counts = presentation.counts
        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                // Scales down instead of moving below the camera, which
                // would add height and clip the rows.
                AgentActivityStatusLead(counts: counts, surface: .island)
                    .minimumScaleFactor(0.75)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
            DynamicIslandExpandedRegion(.trailing) {
                // The expanded island clips content to rounded corners
                // inset from its edge; keep the last count clear of them.
                AgentActivityStatusOthers(counts: counts, surface: .island)
                    .padding(.trailing, 10)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
            DynamicIslandExpandedRegion(.bottom) {
                AgentActivityExpandedRows(
                    presentation: presentation, hostID: hostID, isStale: isStale)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
        } compactLeading: {
            AgentActivityCompactLeading(counts: counts)
                .dynamicTypeSize(...DynamicTypeSize.large)
        } compactTrailing: {
            AgentActivityCompactTrailing(presentation: presentation, isStale: isStale)
                .dynamicTypeSize(...DynamicTypeSize.large)
        } minimal: {
            AgentActivityMinimal(counts: counts)
                .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .keylineTint(
            AgentActivityStatusStyle.ink(
                for: counts.attentionStatusItem?.status ?? "idle", on: .island))
        .widgetURL(AgentActivityLink.consoleURL(hostID: hostID))
    }
}

private struct AgentActivityExpandedRows: View {
    let presentation: AgentActivityPresentation
    let hostID: String
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentation.islandAgents, id: \.paneID) { agent in
                AgentActivityLinkedRow(
                    hostID: hostID, agent: agent, surface: .island, isStale: isStale)
            }
            if presentation.islandOverflowCount > 0 {
                AgentActivityFooter(
                    text: "+\(presentation.islandOverflowCount) more", surface: .island)
            }
        }
    }
}

private struct AgentActivityCompactLeading: View {
    let counts: AgentActivityAttributes.ContentState.Counts

    var body: some View {
        if let lead = counts.attentionStatusItem {
            Image(systemName: AgentActivityStatusVocabulary.symbol(for: lead.status))
                .font(.body.weight(.semibold))
                .foregroundStyle(AgentActivityStatusStyle.ink(for: lead.status, on: .island))
                .accessibilityLabel(AgentActivityNarration.countsLabel([lead]))
        }
    }
}

/// The lead count, or, when the lead is Working and a top Agent has an
/// estimate, one hairline bar per top Agent in envelope order.
private struct AgentActivityCompactTrailing: View {
    let presentation: AgentActivityPresentation
    let isStale: Bool

    var body: some View {
        if let agents = presentation.compactProgressAgents {
            AgentActivityCompactBarStack(agents: agents, isStale: isStale)
        } else if let lead = presentation.counts.attentionStatusItem {
            // The leading symbol already narrates "N status".
            Text("\(lead.count)")
                .font(.body.weight(.bold).monospacedDigit())
                .foregroundStyle(AgentActivityStatusStyle.ink(for: lead.status, on: .island))
                .accessibilityHidden(true)
        }
    }
}

private struct AgentActivityMinimal: View {
    let counts: AgentActivityAttributes.ContentState.Counts

    var body: some View {
        if let lead = counts.attentionStatusItem {
            HStack(spacing: 1) {
                Image(systemName: AgentActivityStatusVocabulary.symbol(for: lead.status))
                    .font(.caption.weight(.bold))
                Text("\(lead.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
            }
            .foregroundStyle(AgentActivityStatusStyle.ink(for: lead.status, on: .island))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AgentActivityNarration.countsLabel([lead]))
        }
    }
}

enum AgentActivityNarration {
    /// "primary, secondary, status" from the drawn identity texts plus the
    /// lowercase wire status, then the spoken estimate when a bar is drawn
    /// ("…, working, 3 of 7 steps done").
    static func rowLabel(for agent: AgentActivityDetails.AgentDetail) -> String {
        var parts = AgentActivityFields.identityTexts(for: agent) + [agent.status]
        if let progress = AgentActivityProgressCopy.drawnProgress(for: agent) {
            parts.append(progress.spokenLabel)
        }
        return parts.joined(separator: ", ")
    }

    /// "1 blocked, 1 done, 2 working".
    static func countsLabel(_ items: [(status: String, count: Int)]) -> String {
        items.map { "\($0.count) \($0.status)" }.joined(separator: ", ")
    }
}

// MARK: - Status header

/// Lead attention count and the other counts on one line; shared by the Lock
/// Screen and the expanded island preview. The island places the two halves
/// in its leading and trailing regions instead.
struct AgentActivityStatusHeader: View {
    let counts: AgentActivityAttributes.ContentState.Counts
    let surface: AgentActivitySurface

    var body: some View {
        HStack(spacing: 8) {
            AgentActivityStatusLead(counts: counts, surface: surface)
            Spacer(minLength: 8)
            AgentActivityStatusOthers(counts: counts, surface: surface)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentActivityNarration.countsLabel(counts.chipItems))
    }
}

/// "✋ 1 Blocked": the first non-zero status in attention order. Draws
/// nothing when only idle Agents remain.
private struct AgentActivityStatusLead: View {
    let counts: AgentActivityAttributes.ContentState.Counts
    let surface: AgentActivitySurface

    var body: some View {
        if let lead = counts.attentionStatusItem {
            HStack(spacing: 6) {
                Image(systemName: AgentActivityStatusVocabulary.symbol(for: lead.status))
                Text("\(lead.count) \(AgentActivityStatusVocabulary.word(for: lead.status))")
            }
            .font(.headline)
            .foregroundStyle(AgentActivityStatusStyle.ink(for: lead.status, on: surface))
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AgentActivityNarration.countsLabel([lead]))
        }
    }
}

/// Every other non-zero status as symbol + count: idle last on the Lock
/// Screen, never on the island (whose compact totals exclude idle too).
/// Never compresses; identity text truncates instead. Draws nothing when
/// there is nothing to count.
private struct AgentActivityStatusOthers: View {
    let counts: AgentActivityAttributes.ContentState.Counts
    let surface: AgentActivitySurface

    var body: some View {
        let items = surface == .island ? counts.islandOtherStatusItems : counts.otherStatusItems
        if !items.isEmpty {
            HStack(spacing: 12) {
                ForEach(items, id: \.status) { item in
                    HStack(spacing: 3) {
                        Image(systemName: AgentActivityStatusVocabulary.symbol(for: item.status))
                            .font(.footnote.weight(.semibold))
                        Text("\(item.count)")
                            .monospacedDigit()
                    }
                    .foregroundStyle(AgentActivityStatusStyle.ink(for: item.status, on: surface))
                }
            }
            .font(.subheadline.weight(.semibold))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AgentActivityNarration.countsLabel(items))
        }
    }
}

// MARK: - Agent rows

/// Deep-links the row to that Agent's detail. The outer widgetURL remains
/// the fallback for taps on the surrounding chrome.
private struct AgentActivityLinkedRow: View {
    let hostID: String
    let agent: AgentActivityDetails.AgentDetail
    let surface: AgentActivitySurface
    let isStale: Bool

    var body: some View {
        if let url = AgentActivityLink.agentURL(hostID: hostID, paneID: agent.paneID) {
            Link(destination: url) {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(AgentActivitySemanticStyle.primary(on: surface))
            .accessibilityLabel(AgentActivityNarration.rowLabel(for: agent))
            .accessibilityHint("Opens this Agent in Waycar")
        } else {
            row
        }
    }

    private var row: some View {
        AgentActivityRowView(agent: agent, surface: surface, isStale: isStale)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentActivityFooter: View {
    let text: String
    let surface: AgentActivitySurface

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(AgentActivitySemanticStyle.secondary(on: surface))
            .lineLimit(1)
            .padding(.leading,
                AgentActivityLockScreenMetrics.monogramSize
                    + AgentActivityLockScreenMetrics.monogramSpacing)
    }
}

/// The Console's configured Agent List Fields, reduced to the two rows a
/// one-line Live Activity row draws.
enum AgentActivityFields {
    /// Configured rows 1 and 2, or the legacy
    /// workspace / kind identity. Rows 3+ are never drawn. An explicitly
    /// empty layout falls back to the Agent kind.
    static func rows(for agent: AgentActivityDetails.AgentDetail) -> [[AgentActivityDetails.Field]] {
        let kind = AgentNotificationIdentity.kindLabel(agent.kind)
        if let configured = agent.rows {
            let drawable = dedupedLine(Array(configured.prefix(2)))
            return drawable.isEmpty ? [[.init(text: kind)]] : drawable
        }
        if let workspace = agent.displayWorkspace {
            return [[.init(text: workspace)], [.init(text: kind)]]
        }
        return [[.init(text: kind)]]
    }

    /// Rows 1 and 2 share one drawn line, so a value equal (whitespace-
    /// trimmed, case-sensitive) to one already on that line is dropped with
    /// its separator (#190): a herdr worktree's Workspace, tab and Agent name
    /// all carry the branch. Separators are recognised by content, not
    /// position, so rows without them (or with several in a row) still
    /// dedupe; a separator is kept only between two kept values.
    static func dedupedLine(_ rows: [[AgentActivityDetails.Field]]) -> [[AgentActivityDetails.Field]] {
        var shown: Set<String> = []
        return rows.compactMap { row in
            var kept: [AgentActivityDetails.Field] = []
            var pendingSeparator: AgentActivityDetails.Field?
            for field in row {
                let text = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if isSeparator(text) {
                    if !kept.isEmpty { pendingSeparator = field }
                    continue
                }
                guard shown.insert(text).inserted else { continue }
                if let separator = pendingSeparator { kept.append(separator) }
                pendingSeparator = nil
                kept.append(field)
            }
            return kept.isEmpty ? nil : kept
        }
    }

    /// The renderers' joiner (`" · "`), or a whitespace-only spacer.
    static func isSeparator(_ field: AgentActivityDetails.Field) -> Bool {
        isSeparator(field.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isSeparator(_ trimmed: String) -> Bool {
        trimmed.isEmpty || trimmed == "·"
    }

    /// Drawn identity rows as plain text.
    static func identityTexts(for agent: AgentActivityDetails.AgentDetail) -> [String] {
        rows(for: agent).map { $0.map(\.text).joined() }
    }

    static func attributedText(
        _ fields: [AgentActivityDetails.Field], rowIndex: Int, surface: AgentActivitySurface
    ) -> AttributedString {
        var result = AttributedString()
        for field in fields {
            var span = AttributedString(field.text)
            let weight: Font.Weight = if let bold = field.bold {
                bold ? .bold : .regular
            } else {
                rowIndex == 0 ? .semibold : .regular
            }
            span.font = Font.subheadline.weight(weight)
            span.foregroundColor = foreground(for: field, rowIndex: rowIndex, surface: surface)
            result.append(span)
        }
        return result
    }

    static func foreground(
        for field: AgentActivityDetails.Field, rowIndex: Int, surface: AgentActivitySurface
    ) -> Color {
        if let hex = field.fg, let color = hexColor(hex) {
            return Color(uiColor: color).opacity(field.dim == true ? 0.6 : 1)
        }
        if field.dim == true {
            return Color(uiColor: surface.resolved(rowIndex == 0 ? .secondaryLabel : .tertiaryLabel))
        }
        return rowIndex == 0
            ? AgentActivitySemanticStyle.primary(on: surface)
            : AgentActivitySemanticStyle.secondary(on: surface)
    }

    private static func hexColor(_ value: String) -> UIColor? {
        guard value.first == "#", value.utf8.count == 4 || value.utf8.count == 7 else { return nil }
        let digits = value.dropFirst()
        guard digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : String(digits)
        guard let rgb = UInt32(expanded, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

/// One Console-style line: kind monogram, configured identity (row 1 as
/// headline, row 2 secondary), and the status in words — or the estimate
/// when Working — with a progress rule under the text inside the same
/// row height.
struct AgentActivityRowView: View {
    let agent: AgentActivityDetails.AgentDetail
    let surface: AgentActivitySurface
    var isStale: Bool = false

    var body: some View {
        let rows = AgentActivityFields.rows(for: agent)
        HStack(spacing: AgentActivityLockScreenMetrics.monogramSpacing) {
            AgentActivityKindMonogram(agent: agent, surface: surface)
            VStack(alignment: .leading, spacing: AgentActivityProgressMetrics.ruleGap) {
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(AgentActivityFields.attributedText(
                            rows.first ?? [], rowIndex: 0, surface: surface))
                            .lineLimit(1)
                            .layoutPriority(1)
                        if agent.kind != "ultimate", let secondary = rows.dropFirst().first {
                            Text(AgentActivityFields.attributedText(
                                secondary, rowIndex: 1, surface: surface))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(AgentActivityProgressCopy.trailingLabel(for: agent))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AgentActivityStatusStyle.ink(for: agent.status, on: surface))
                        .fixedSize()
                }
                if agent.kind == "ultimate", let secondary = rows.dropFirst().first {
                    Text(AgentActivityFields.attributedText(secondary, rowIndex: 1, surface: surface))
                        .lineLimit(2)
                }
                if let progress = AgentActivityProgressCopy.drawnProgress(for: agent) {
                    AgentActivityProgressRule(
                        fraction: progress.fraction, status: agent.status, surface: surface,
                        isStale: isStale, thickness: AgentActivityProgressMetrics.rowRule)
                }
            }
        }
        .frame(minHeight: AgentActivityLockScreenMetrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentActivityNarration.rowLabel(for: agent))
    }
}

/// The Console's kind glyph: first letter of the Agent kind on a status wash.
private struct AgentActivityKindMonogram: View {
    let agent: AgentActivityDetails.AgentDetail
    let surface: AgentActivitySurface

    var body: some View {
        Text(verbatim: AgentNotificationIdentity.monogram(forKind: agent.kind))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(AgentActivityStatusStyle.ink(for: agent.status, on: surface))
            .frame(
                width: AgentActivityLockScreenMetrics.monogramSize,
                height: AgentActivityLockScreenMetrics.monogramSize)
            .background(
                Circle().fill(
                    AgentActivityStatusStyle.wash(for: agent.status, on: surface)
                        .opacity(surface == .island ? 0.28 : 0.18)))
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

/// Style gallery: every lock-screen and island state without a device, a
/// push, or a live agent. Open this file's canvas in Xcode to review.
#if DEBUG
    /// Configured fields as the app's default layout renders them:
    /// workspace · tab, Agent kind, directory (row 3 is never drawn).
    private func previewAgent(
        _ status: String, kind: String, workspace: String, tab: String? = nil,
        secondary: String? = nil, pane: String
    ) -> AgentActivityDetails.AgentDetail {
        var identity: [AgentActivityDetails.Field] = [.init(text: workspace)]
        if let tab {
            identity += [.init(text: " · ", dim: true), .init(text: tab)]
        }
        return AgentActivityDetails.AgentDetail(
            paneID: pane, kind: kind, workspace: workspace, status: status, title: nil,
            rows: [
                identity,
                [.init(text: secondary ?? AgentNotificationIdentity.kindLabel(kind))],
                [.init(text: "~/Projects/\(workspace)", dim: true)],
            ])
    }

    private enum AgentActivityPreviewFixtures {
        static func detailed(
            _ agents: [AgentActivityDetails.AgentDetail],
            _ counts: AgentActivityAttributes.ContentState.Counts
        ) -> AgentActivityPresentation {
            .detailed(details: .init(hostName: "mbp", agents: agents), counts: counts)
        }

        static var mixedOverflow: AgentActivityPresentation {
            detailed(
                [
                    previewAgent("blocked", kind: "claude", workspace: "waycar", tab: "live-activity", pane: "w1:p1"),
                    previewAgent("blocked", kind: "codex", workspace: "shapekit", pane: "w4:p1"),
                    previewAgent("done", kind: "codex", workspace: "herdr-plugin", pane: "w2:p1"),
                    previewAgent("working", kind: "omp", workspace: "waycar", tab: "relay", pane: "w1:p2"),
                    previewAgent("working", kind: "claude", workspace: "shapekit", tab: "canvas", pane: "w4:p2"),
                ],
                .init(working: 4, blocked: 2, done: 1, idle: 1))
        }

        static var fourRows: AgentActivityPresentation {
            detailed(
                [
                    previewAgent("blocked", kind: "claude", workspace: "waycar", tab: "live-activity", pane: "w1:p1"),
                    previewAgent("working", kind: "codex", workspace: "herdr-plugin", pane: "w2:p1"),
                    previewAgent("working", kind: "omp", workspace: "shapekit", tab: "canvas", pane: "w4:p1"),
                    previewAgent("working", kind: "claude", workspace: "waycar", tab: "relay", pane: "w1:p2"),
                ],
                .init(working: 3, blocked: 1, done: 0, idle: 2))
        }

        /// Legacy producer (no configured rows): workspace / kind identity.
        static var singleAgent: AgentActivityPresentation {
            detailed(
                [.init(paneID: "w4:p1", kind: "omp", workspace: "shapekit", status: "done", title: nil)],
                .init(working: 0, blocked: 0, done: 1))
        }

        static var countsOnly: AgentActivityPresentation {
            .countsOnly(counts: .init(working: 2, blocked: 1, done: 0, idle: 1))
        }

        static var longIdentity: AgentActivityPresentation {
            detailed(
                [
                    previewAgent(
                        "blocked", kind: "claude", workspace: String(repeating: "锁", count: 80),
                        pane: "w1:p1"),
                    previewAgent(
                        "working", kind: "codex", workspace: "waycar",
                        secondary: String(repeating: "屏", count: 80), pane: "w1:p2"),
                ],
                .init(working: 1, blocked: 1, done: 0))
        }

        static var staleMaxHeight: AgentActivityPresentation {
            detailed(
                [
                    previewAgent("blocked", kind: "claude", workspace: "waycar", tab: "live-activity", pane: "w1:p1"),
                    previewAgent("done", kind: "codex", workspace: "herdr-plugin", pane: "w2:p1"),
                    previewAgent("working", kind: "omp", workspace: "shapekit", tab: "canvas", pane: "w4:p1"),
                    previewAgent("working", kind: "claude", workspace: "waycar", tab: "relay", pane: "w1:p2"),
                    previewAgent("working", kind: "codex", workspace: "shapekit", pane: "w4:p2"),
                ],
                .init(working: 3, blocked: 1, done: 1))
        }

        static var workingProgress: AgentActivityPresentation {
            func with(
                _ agent: AgentActivityDetails.AgentDetail, _ progress: AgentProgress?
            ) -> AgentActivityDetails.AgentDetail {
                var agent = agent
                agent.progress = progress
                return agent
            }
            return detailed(
                [
                    with(
                        previewAgent("working", kind: "codex", workspace: "waycar", tab: "api", pane: "w1:p1"),
                        AgentProgress(steps: .init(done: 3, total: 7), phase: nil)),
                    with(
                        previewAgent("working", kind: "omp", workspace: "mobile", tab: "p1", pane: "w2:p1"),
                        AgentProgress(steps: nil, phase: .verifying)),
                    previewAgent("working", kind: "gemini", workspace: "docs", tab: "site", pane: "w3:p1"),
                ],
                .init(working: 3, blocked: 0, done: 0))
        }
    }

    private func previewLockScreenBanner(
        _ presentation: AgentActivityPresentation,
        colorScheme: ColorScheme,
        isStale: Bool = false
    ) -> some View {
        AgentActivityLockScreenView(
            presentation: presentation,
            hostID: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E",
            isStale: isStale
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, colorScheme)
        .padding()
    }

    /// Island previews run in a Light environment on purpose: the island
    /// must still resolve Mocha.
    private func previewIsland(_ content: some View) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black, in: Capsule())
            .environment(\.colorScheme, .light)
            .padding()
    }

    private func previewIslandCompact(_ presentation: AgentActivityPresentation) -> some View {
        previewIsland(HStack {
            AgentActivityCompactLeading(counts: presentation.counts)
            Spacer(minLength: 120)
            AgentActivityCompactTrailing(presentation: presentation, isStale: false)
        }.fixedSize())
    }

    private func previewIslandExpanded(_ presentation: AgentActivityPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentActivityStatusHeader(counts: presentation.counts, surface: .island)
            AgentActivityExpandedRows(
                presentation: presentation, hostID: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E",
                isStale: false)
        }
        .padding(18)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .environment(\.colorScheme, .light)
        .padding()
    }

    #Preview("Mixed + overflow (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.mixedOverflow, colorScheme: .light)
    }

    #Preview("Mixed + overflow (Dark)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.mixedOverflow, colorScheme: .dark)
    }

    #Preview("Four rows (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.fourRows, colorScheme: .light)
    }

    #Preview("Four rows (Dark)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.fourRows, colorScheme: .dark)
    }

    #Preview("Single agent (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.singleAgent, colorScheme: .light)
    }

    #Preview("Single agent (Dark)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.singleAgent, colorScheme: .dark)
    }

    #Preview("Counts only (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.countsOnly, colorScheme: .light)
    }

    #Preview("Counts only (Dark)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.countsOnly, colorScheme: .dark)
    }

    #Preview("80-grapheme identity (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.longIdentity, colorScheme: .light)
    }

    #Preview("80-grapheme identity (Dark)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.longIdentity, colorScheme: .dark)
    }

    #Preview("Stale max height (Light)") {
        previewLockScreenBanner(
            AgentActivityPreviewFixtures.staleMaxHeight, colorScheme: .light, isStale: true)
    }

    #Preview("Stale max height (Dark)") {
        previewLockScreenBanner(
            AgentActivityPreviewFixtures.staleMaxHeight, colorScheme: .dark, isStale: true)
    }

    #Preview("Compact blocked (Light island)") {
        previewIslandCompact(.countsOnly(counts: .init(working: 2, blocked: 1, done: 0)))
    }

    #Preview("Compact done (Light island)") {
        previewIslandCompact(.countsOnly(counts: .init(working: 2, blocked: 0, done: 1)))
    }

    #Preview("Compact working (Light island)") {
        previewIslandCompact(.countsOnly(counts: .init(working: 3, blocked: 0, done: 0)))
    }

    #Preview("Compact working progress (Light island)") {
        previewIslandCompact(AgentActivityPreviewFixtures.workingProgress)
    }

    #Preview("Progress rows (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.workingProgress, colorScheme: .light)
    }

    #Preview("Minimal blocked (Light island)") {
        previewIsland(AgentActivityMinimal(counts: .init(working: 2, blocked: 2, done: 1)))
    }

    #Preview("Expanded mixed (Light island)") {
        previewIslandExpanded(AgentActivityPreviewFixtures.mixedOverflow)
    }

    /// `.small` at the watch's smallest Smart Stack size and CarPlay's
    /// narrowest Dashboard size, on a Smart Stack of either appearance.
    private func previewSmall(
        _ presentation: AgentActivityPresentation, width: CGFloat, height: CGFloat,
        isStale: Bool = false, colorScheme: ColorScheme = .dark
    ) -> some View {
        AgentActivitySmallView(
            presentation: presentation, hostID: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E",
            isStale: isStale)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding()
            .background(colorScheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, colorScheme)
    }

    #Preview("Small 40mm watch") {
        previewSmall(AgentActivityPreviewFixtures.workingProgress, width: 152, height: 69.5)
    }

    #Preview("Small 40mm watch, light Smart Stack") {
        previewSmall(
            AgentActivityPreviewFixtures.workingProgress, width: 152, height: 69.5,
            colorScheme: .light)
    }

    #Preview("Small CarPlay 170×78") {
        previewSmall(AgentActivityPreviewFixtures.workingProgress, width: 170, height: 78)
    }

    #Preview("Small idle only, stale") {
        previewSmall(
            .countsOnly(counts: .init(working: 0, blocked: 0, done: 0, idle: 3)),
            width: 152, height: 69.5, isStale: true)
    }
#endif
