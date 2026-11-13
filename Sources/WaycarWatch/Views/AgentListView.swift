import SwiftUI

// MARK: - W1 Agents list

/// W1, the root: "Waycar" in accent, then as list content the freshness
/// banner, the count pills, one row per Agent in CarPlay order, and the
/// "Updated …" footer. W6 when nothing has arrived yet or the iPhone has no
/// Hosts.
struct AgentListView: View {
    /// The watch's model.
    let store: WatchStore

    /// The list or the empty state, re-rendered every minute so ages move.
    /// Each tick asks the iPhone for a fresh Watch State once it is older
    /// than a minute, so a quiet but reachable iPhone stays current.
    var body: some View {
        TimelineView(.everyMinute) { context in
            Group {
                if let state = store.state, !state.hosts.isEmpty {
                    list(state, now: context.date)
                } else {
                    WatchEmptyView(notice: store.updateNotice)
                }
            }
            .task(id: context.date) { await refreshIfOld(now: context.date) }
        }
        .navigationTitle("Waycar")
    }

    /// The list for a Watch State. Rows and pills dim only while the iPhone
    /// doesn't answer; a row also dims while its Host isn't confirmed.
    private func list(_ state: WatchState, now: Date) -> some View {
        let isAway = !store.isReachable
        let banner = WatchFreshness.lines(
            for: state, isReachable: store.isReachable, notice: store.updateNotice, now: now)
        let confirmedHosts = Set(state.hosts.filter { $0.condition == .confirmed }.map(\.id))
        let pills = CountPillsView.pills(for: state.counts)
        return List {
            if !banner.isEmpty {
                FreshnessBannerView(lines: banner)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if !pills.isEmpty {
                CountPillsView(counts: state.counts)
                    .opacity(isAway ? 0.5 : 1)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(state.rows) { row in
                NavigationLink(value: Self.route(for: row)) {
                    AgentRowView(row: row, showsHostName: state.showsHostNames, now: now)
                }
                .opacity(isAway || !confirmedHosts.contains(row.id.hostID) ? 0.5 : 1)
            }
            Text("Updated \(WatchFormat.ago(since: state.generatedAt, now: now))")
                .metaFont()
                .foregroundStyle(WatchBrand.Colors.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(Color.clear)
        }
    }

    /// Asks for a fresh Watch State when the iPhone answers and the one on
    /// screen is over a minute old. Runs at most once per timeline tick.
    private func refreshIfOld(now: Date) async {
        guard let state = store.state,
            WatchFreshness.needsRefresh(state, isReachable: store.isReachable, now: now)
        else { return }
        await store.refresh()
    }

    /// Blocked rows open W3; every other status opens W2.
    static func route(for row: WatchAgentRow) -> WatchStore.Route {
        row.status == "blocked" ? .blocked(row.id) : .agent(row.id)
    }
}

// MARK: - Row

/// One W1 row: the title (Headline, wrapped in full, full width) over the status
/// line, then the Agent Progress bar for a Working or Blocked Agent with
/// one. No leading glyph.
struct AgentRowView: View {
    /// The Agent.
    let row: WatchAgentRow
    /// Whether the status line names the Host (more than one Host).
    let showsHostName: Bool
    /// The clock ages and stale estimates are measured against.
    let now: Date

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// Title over status line over bar, read as
    /// "<title>, <Status>, <progress>, <age>, <host>".
    var body: some View {
        let hostName = showsHostName ? row.hostName : nil
        let progress = row.progressDisplay(at: now)
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
                .font(.headline)
                .foregroundStyle(WatchBrand.Colors.text)
                .fixedSize(horizontal: false, vertical: true)
            StatusLineView(
                status: row.status, since: row.statusSince, hostName: hostName, now: now,
                progress: progress)
            if let progress {
                WatchProgressBar(display: progress, status: row.status)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alwaysOnDimmed(isLuminanceReduced)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [
                WatchFormat.spokenTitle(row.title),
                StatusLineView.spokenLabel(
                    status: row.status, since: row.statusSince, hostName: hostName, now: now,
                    progress: progress),
            ]
            .joined(separator: ", "))
    }
}

// MARK: - W6 Empty

/// W6: shown when the iPhone reports no Hosts or nothing has arrived yet.
/// An update notice replaces the hint, since no state arrives until the
/// wire versions match.
struct WatchEmptyView: View {
    /// "Update Waycar on your iPhone" (or Apple Watch), or nil.
    let notice: String?

    /// The iPhone glyph over the centered hint.
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone")
                .font(.title2)
                .foregroundStyle(WatchBrand.Colors.text2)
                .accessibilityHidden(true)
            Text(notice ?? "Open Waycar on your iPhone to add a Host.")
                .font(.footnote)
                .foregroundStyle(WatchBrand.Colors.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, WatchLayout.edgeMargin)
    }
}
