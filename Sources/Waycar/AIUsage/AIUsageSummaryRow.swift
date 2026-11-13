import SwiftUI

/// The Console's AI Usage row, atop the Agent list and scrolling with it: an
/// "AI USAGE" caption, then the provider and window(s) Settings › CodexBar
/// chooses (by default the provider with the least left, its session and
/// weekly numbers), each number colored per `AIUsageLevel.numberColor`, and
/// a chevron. Tapping expands
/// `AIUsageSummaryCard` beneath it. The summary is dimmed while out of date,
/// including while its Host cannot answer.
struct AIUsageSummaryRow: View {
    let store: AIUsageStore
    let source: AIUsageSource
    let isExpanded: Bool
    let toggle: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var minHeight: CGFloat = 40

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let isOutOfDate = !source.isLive || store.isStale(source.hostID, at: context.date)
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Text("AI Usage")
                        .textCase(.uppercase)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 8)
                    summary(now: context.date)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .opacity(isOutOfDate ? 0.5 : 1)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("AI Usage")
            .accessibilityValue(accessibilityValue(now: context.date, isOutOfDate: isOutOfDate))
            .accessibilityHint(isExpanded ? "Hides the providers" : "Shows every provider")
        }
    }

    private var options: AIUsageDisplayOptions { store.preferences.display }

    private var selection: AIUsagePillSelection? {
        store.usage[source.hostID]?.snapshot?.report.pillSelection(options)
    }

    /// The longest summary that fits: in full, without the reset, then only
    /// the first window.
    @ViewBuilder
    private func summary(now: Date) -> some View {
        if let selection {
            let numbers = selection.windows.map {
                (AIUsageFormat.percent($0.displayPercent(showsUsed: options.showsUsed)),
                 $0.level.numberColor)
            }
            ViewThatFits(in: .horizontal) {
                ForEach(
                    Array(AIUsageFormat.pillTitles(selection, options: options, now: now).enumerated()),
                    id: \.offset
                ) { _, title in
                    Self.coloredTitle(title, numbers: numbers)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }
            }
        } else {
            Text(placeholder)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var placeholder: String {
        if store.fetchingHostID == source.hostID { return "Loading…" }
        return store.usage[source.hostID]?.lastFailure == nil ? "No data" : "Couldn't refresh"
    }

    /// The title with each window's number in that window's color.
    private static func coloredTitle(_ title: String, numbers: [(String, Color)]) -> Text {
        var text = Text("")
        var rest = Substring(title)
        for (number, color) in numbers {
            guard let range = rest.range(of: number) else { continue }
            text = text + Text(rest[..<range.lowerBound]) + Text(number).foregroundStyle(color)
            rest = rest[range.upperBound...]
        }
        return text + Text(rest)
    }

    private func accessibilityValue(now: Date, isOutOfDate: Bool) -> String {
        var summary = selection.map {
            AIUsageFormat.pillAccessibilityValue($0, options: options, now: now)
        } ?? placeholder
        if isOutOfDate, selection != nil { summary += ", out of date" }
        return "\(summary), \(isExpanded ? "expanded" : "collapsed")"
    }
}

/// The AI Usage row expanded: every provider in the sheet's order, each
/// window a compact gauge with its pace tick and percentage, per Settings ›
/// CodexBar. A provider (or the whole run) that failed offers a retry; All
/// details opens the sheet. Showing counts as opening the usage: expanded,
/// at launch while expanded, back in the foreground, or rescoped, it asks
/// `sheetDidOpen`, which refreshes only under Refresh When Opened.
struct AIUsageSummaryCard: View {
    let store: AIUsageStore
    let source: AIUsageSource
    /// The Host the Console window is scoped to (nil: All Hosts).
    let scope: Host.ID?
    let showDetails: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    /// A retry this card started and is still waiting on; blocks repeats.
    @State private var isRetrying = false

    private struct OpenKey: Equatable {
        let scope: Host.ID?
        let isActive: Bool
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .task(id: OpenKey(scope: scope, isActive: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            await store.sheetDidOpen(scopedTo: scope)
        }
    }

    private var options: AIUsageDisplayOptions { store.preferences.display }
    private var isFetching: Bool { store.fetchingHostID == source.hostID }

    private func content(now: Date) -> some View {
        let state = store.usage[source.hostID]
        let isOutOfDate = !source.isLive || store.isStale(source.hostID, at: now)
        return VStack(alignment: .leading, spacing: 10) {
            if let failure = state?.lastFailure {
                retryRow(accessibilityLabel: "Usage couldn't refresh", detail: failure)
            }
            if let snapshot = state?.snapshot {
                providers(snapshot.report, now: now)
                    .opacity(isOutOfDate ? 0.45 : 1)
            } else if isFetching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading usage…").foregroundStyle(.secondary)
                }
                .font(.footnote)
            } else if state?.lastFailure == nil {
                Text("No usage yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(action: showDetails) {
                HStack(spacing: 2) {
                    Text("All details")
                    Image(systemName: "chevron.right").imageScale(.small)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("All details")
            .accessibilityHint("Opens AI Usage")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AgentCardChrome(isSelected: false))
    }

    /// One grid for every provider, so labels, gauges and percentages line
    /// up down the card.
    private func providers(_ report: AIUsageReport, now: Date) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(report.providers.enumerated()), id: \.element.id) { index, provider in
                header(provider)
                    .padding(.top, index == 0 ? 0 : 6)
                ForEach(provider.windows) { window in
                    windowRow(window, provider: provider, now: now)
                }
                if let problem = report.fixableProblem(provider) {
                    // Retrying cannot help; the sheet offers the Keychain Fix.
                    fixRow(provider, problem: problem)
                } else if let error = provider.errorMessage {
                    retryRow(
                        accessibilityLabel: "\(provider.displayName) couldn't refresh",
                        detail: error)
                }
            }
        }
    }

    private func header(_ provider: AIUsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.displayName)
                .font(.subheadline.weight(.semibold))
            if !options.hidesAccountLabels, let account = provider.account {
                Text(account)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func windowRow(
        _ window: AIUsageWindow, provider: AIUsageProvider, now: Date
    ) -> some View {
        let percent = AIUsageFormat.percent(window.displayPercent(showsUsed: options.showsUsed))
        return GridRow {
            Text(window.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            AIUsageGaugeBar(
                percent: window.displayPercent(showsUsed: options.showsUsed),
                pace: options.showsPace
                    ? window.displayPacePercent(showsUsed: options.showsUsed) : nil,
                color: window.level.color)
                .accessibilityElement()
                .accessibilityLabel(
                    AIUsageFormat.accessibilityLabel(
                        provider: provider, window: window, options: options, now: now))
                .accessibilityValue(percent)
            Text(percent)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(window.level.numberColor)
                .lineLimit(1)
                .gridColumnAlignment(.trailing)
                .accessibilityHidden(true)
        }
    }

    /// "Can't be read over SSH · Fix…" or "Timed out · Fix…": opens the AI
    /// Usage sheet, which explains it and offers the Keychain Fix.
    private func fixRow(
        _ provider: AIUsageProvider, problem: CodexBarKeychainFix.Problem
    ) -> some View {
        Button(action: showDetails) {
            Label(problem.cardLabel, systemImage: problem.systemImage)
                .font(.footnote)
                .foregroundStyle(Color.orange)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(problem.title(providerName: provider.displayName))
        .accessibilityHint("Opens AI Usage to fix it")
    }

    /// "Couldn't refresh · tap to retry": fetches the usage again now.
    /// While its Host is fetching it reads "Refreshing…" with a spinner; while
    /// the Host cannot answer it is dimmed. Either way it ignores taps.
    private func retryRow(accessibilityLabel: String, detail: String) -> some View {
        let isRefreshing = isFetching || isRetrying
        let canRetry = source.isLive && !isRefreshing
        return Button {
            guard canRetry else { return }
            isRetrying = true
            Task {
                await store.refresh(scopedTo: scope)
                isRetrying = false
            }
        } label: {
            Label {
                Text(isRefreshing ? "Refreshing…" : "Couldn't refresh · tap to retry")
            } icon: {
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
            .font(.footnote)
            .foregroundStyle(canRetry ? Color.red : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRetry)
        .accessibilityLabel(isRefreshing ? "Refreshing usage" : accessibilityLabel)
        .accessibilityValue(isRefreshing ? "" : detail)
        .accessibilityHint(
            canRetry ? "Refreshes usage"
                : isRefreshing ? "" : "Unavailable until the Host reconnects")
    }
}
