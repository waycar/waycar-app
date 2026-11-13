import SwiftUI

// MARK: - Freshness banner

/// What the W1 banner says (§4 W1, §6.3): an update notice when the wire
/// versions differ, the iPhone line when the iPhone doesn't answer,
/// otherwise one line per Host that isn't confirmed. The Watch State's age
/// alone never shows the banner; it shows in the "Updated …" footer.
enum WatchFreshness {
    /// A Watch State older than this is asked for again while the iPhone
    /// answers; the iPhone only publishes when something changed.
    static let refreshAfter: TimeInterval = 60

    /// One banner line.
    enum Line: Hashable {
        /// "Update Waycar on your iPhone": the iPhone and the watch speak
        /// different wire versions.
        case notice(String)
        /// "iPhone not reachable" over "3m ago".
        case phone(ago: String)
        /// "studio is still connecting".
        case connecting(host: String)
        /// "Can't reach studio".
        case unreachable(host: String)
    }

    /// Whether the watch should ask the iPhone for a fresh Watch State: it
    /// answers, and the one on screen is older than `refreshAfter`.
    static func needsRefresh(_ state: WatchState, isReachable: Bool, now: Date) -> Bool {
        isReachable && now.timeIntervalSince(state.generatedAt) > refreshAfter
    }

    /// The banner's lines; empty when everything is fine.
    static func lines(for state: WatchState, isReachable: Bool, notice: String?, now: Date) -> [Line] {
        if let notice {
            return [.notice(notice)]
        }
        guard isReachable else {
            return [.phone(ago: WatchFormat.ago(since: state.generatedAt, now: now))]
        }
        return state.hosts.compactMap { host -> Line? in
            switch host.condition {
            case .confirmed: nil
            case .connecting: .connecting(host: host.name)
            case .unreachable: .unreachable(host: host.name)
            }
        }
    }
}

/// The W1 banner: the first list content, under the "Waycar" title and
/// above the count pills.
struct FreshnessBannerView: View {
    /// The lines to show; the caller hides the banner when empty.
    let lines: [WatchFreshness.Line]

    /// The stacked lines.
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { line in
                lineView(line)
            }
        }
        .metaFont()
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// One line with its glyph.
    @ViewBuilder
    private func lineView(_ line: WatchFreshness.Line) -> some View {
        switch line {
        case .notice(let text):
            Text(text)
                .foregroundStyle(WatchBrand.Colors.danger)
        case .phone(let ago):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "iphone")
                    .foregroundStyle(WatchBrand.Colors.danger)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(WatchStore.unreachableCopy)
                        .foregroundStyle(WatchBrand.Colors.danger)
                    Text(ago)
                        .foregroundStyle(WatchBrand.Colors.text2)
                }
            }
        case .connecting(let host):
            Text("\(host) is still connecting")
                .foregroundStyle(WatchBrand.Colors.text2)
        case .unreachable(let host):
            Text("Can't reach \(host)")
                .foregroundStyle(WatchBrand.Colors.danger)
        }
    }
}

// MARK: - Count pills

/// The W1 count pills: Blocked, Done, Working, then Idle. `ViewThatFits`
/// drops the Idle pill first, then everything but Blocked, when the row is
/// too narrow. Zero counts show no pill.
struct CountPillsView: View {
    /// The counts across every Host.
    let counts: WatchCounts

    /// The widest set of pills that fits.
    var body: some View {
        let all = Self.pills(for: counts)
        ViewThatFits(in: .horizontal) {
            pillRow(all)
            pillRow(all.filter { $0.status != "idle" })
            pillRow(all.filter { $0.status == "blocked" })
        }
    }

    /// One pill's status and count.
    struct Pill: Hashable {
        /// The raw wire status.
        let status: String
        /// How many Agents have it.
        let count: Int
    }

    /// The non-zero pills in display order.
    static func pills(for counts: WatchCounts) -> [Pill] {
        [
            Pill(status: "blocked", count: counts.blocked),
            Pill(status: "done", count: counts.done),
            Pill(status: "working", count: counts.working),
            Pill(status: "idle", count: counts.idle),
        ]
        .filter { $0.count > 0 }
    }

    /// The pills side by side at their natural width.
    private func pillRow(_ pills: [Pill]) -> some View {
        HStack(spacing: WatchLayout.pillGap) {
            ForEach(pills, id: \.self) { pill in
                CountPillView(pill: pill)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// One count pill: glyph + SF Mono digit on a 15% status wash.
private struct CountPillView: View {
    /// The status and count.
    let pill: CountPillsView.Pill

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// The capsule.
    var body: some View {
        let ink = WatchBrand.Status.ink(for: pill.status)
        HStack(spacing: 3) {
            Image(systemName: WatchStatusGlyph.name(for: pill.status, outline: isLuminanceReduced))
            Text("\(pill.count)")
                .font(.system(.footnote, design: .monospaced, weight: .semibold))
        }
        .font(.footnote)
        .foregroundStyle(ink)
        .padding(.horizontal, WatchLayout.pillPadding)
        .frame(height: WatchLayout.pillHeight)
        .background {
            Capsule().fill(WatchBrand.Status.wash(for: pill.status).opacity(isLuminanceReduced ? 0 : 0.15))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pill.count) \(AgentActivityStatusVocabulary.word(for: pill.status))")
    }
}
