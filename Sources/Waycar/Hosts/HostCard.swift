import SwiftUI

/// One Host in the Hosts sheet, drawn as its own card like the Console's
/// Agent cards: the identity and switch, the address and connection, and —
/// while the Host is connected and sampled — its CPU / MEMORY / SWAP band.
struct HostCard: View {
    let host: Host
    let connectionStatus: EventsSessionStatus?
    let standingFailure: TransportError?
    let latency: Duration?
    let moshState: ConsoleStore.MoshHostCapsuleState?
    let resources: HostResourcePresentation?
    let hasCodexBar: Bool
    let showsTmuxBadge: Bool
    /// The Host's only backend is herdr-core (`CoreBadge.isShown`).
    var showsCoreBadge = false
    var showsZellijBadge = false
    /// The catalog, for the card's switch.
    let catalog: HostStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The narrowest the name may get before the badges move under it: a
    /// long name truncates in the compact header rather than switching one
    /// card to the stacked layout at the default size.
    @ScaledMetric(relativeTo: .headline) private var minimumNameWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if typeSize.isAccessibilitySize {
                stackedHeader
            } else {
                // The badges move under the name whenever the name, badges
                // and switch do not fit on one line.
                ViewThatFits(in: .horizontal) {
                    header
                    stackedHeader
                }
            }
            if let resources {
                HostResourceBand(presentation: resources)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .snappy, value: host.isEnabled)
        .animation(reduceMotion ? nil : .snappy, value: resources == nil)
    }

    /// The identity and switch on one line across the card; below it the
    /// address and the chip share a baseline, the chip right-aligned. The
    /// address asks for no width of its own (it truncates in the middle), so
    /// only the first line decides whether this header fits.
    private var header: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow(alignment: .center) {
                HStack(spacing: 12) {
                    identity
                        .frame(maxWidth: .infinity, alignment: .leading)
                    toggle
                }
                .gridCellColumns(2)
            }
            GridRow(alignment: .firstTextBaseline) {
                address
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                // Never squeezed by a long address: the chip would truncate
                // to "…".
                status
                    .fixedSize()
                    .gridColumnAlignment(.trailing)
            }
        }
    }

    /// Used at accessibility sizes, and whenever the first line of `header`
    /// does not fit: a trailing column would leave the name a few characters
    /// wide, so the badges and status move under it.
    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                name
                    .lineLimit(2)
                    .opacity(dimming)
                    .frame(maxWidth: .infinity, alignment: .leading)
                toggle
            }
            badges
                .opacity(dimming)
            address
            status
        }
    }

    private var identity: some View {
        HStack(spacing: 6) {
            name
                .lineLimit(1)
                .frame(minWidth: 0, idealWidth: minimumNameWidth, alignment: .leading)
            badges
        }
        // Dimmed as a whole, badges included: a Disabled Host is kept but
        // not in use.
        .opacity(dimming)
    }

    private var name: some View {
        Text(host.displayName)
            .font(.headline)
    }

    @ViewBuilder private var badges: some View {
        if showsCoreBadge || showsTmuxBadge || showsZellijBadge || hasCodexBar {
            HStack(spacing: 6) {
                if showsCoreBadge {
                    CoreBadge(accessibilityLabel: "herdr-core Host")
                        .fixedSize()
                }
                if showsZellijBadge {
                    ZellijBadge(accessibilityLabel: "Zellij Host")
                        .layoutPriority(1)
                }
                if showsTmuxBadge {
                    TmuxBadge(accessibilityLabel: "tmux Host")
                        .fixedSize()
                }
                if hasCodexBar {
                    CodexBarBadge()
                        .fixedSize()
                }
            }
        }
    }

    private var address: some View {
        Text(subtitle)
            .font(Brand.Fonts.code)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(dimming)
    }

    /// Hidden from VoiceOver: the card is one element whose activation
    /// opens the Host page; the list gives it a named action that flips
    /// enablement, and the Disabled caption announces the state.
    private var toggle: some View {
        HostEnabledToggle(host: host, catalog: catalog)
            .labelsHidden()
            .accessibilityHidden(true)
    }

    /// Light enough to read (the address stays legible), and none at all
    /// when the user asked for increased contrast.
    private var dimming: Double {
        host.isEnabled || contrast == .increased ? 1 : 0.6
    }

    /// The transport badge and status chip, or the Disabled caption. A
    /// Disabled Host has no transport or connection to report; a nil status
    /// here would otherwise read "Connecting…".
    @ViewBuilder private var status: some View {
        if host.isEnabled {
            HStack(spacing: 12) {
                if let moshState {
                    MoshTransportBadge(state: moshState)
                }
                HostConnectionIndicator(
                    presentation: HostConnectionPresentation(
                        status: connectionStatus,
                        standingFailure: standingFailure,
                        latency: latency))
            }
        } else {
            Text("Disabled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var text = "\(host.username)@\(host.address)"
        if host.port != 22 { text += ":\(host.port)" }
        if case .namedSession(let session) = host.socketLocation {
            text += " · session \(session)"
        }
        return text
    }
}

/// The status dot and text on a Host card. The connected dot glows softly in
/// its own green.
struct HostConnectionIndicator: View {
    let presentation: HostConnectionPresentation

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(tint)
                .shadow(color: presentation.tone == .connected ? .green : .clear, radius: 3)
                .accessibilityHidden(true)
            Text(presentation.title)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var tint: Color {
        switch presentation.tone {
        case .connected: .green
        case .pending: .secondary
        case .warning: .orange
        case .unavailable: .red
        }
    }
}

extension HostResourceLevel {
    /// Neutral until it warns, as AI Usage's gauges are.
    var barColor: Color {
        switch self {
        case .normal: Color.primary.opacity(0.85)
        case .high: .orange
        case .critical: .red
        }
    }

    var numberColor: Color {
        switch self {
        case .normal: .primary
        case .high: .orange
        case .critical: .red
        }
    }
}

/// CPU, MEMORY and SWAP side by side, each a label, a big number and a thin
/// meter; where three columns do not fit, one row per metric
/// (`LABEL ── meter ── 41%`), as the AI Usage card lays out its windows; and
/// narrowest, per metric the label and number on one line over a full-width
/// meter. Only that last layout is drawn without its whole width fitting,
/// and in it only the label gives way, so a number is never cut. One
/// VoiceOver element reading the spoken form.
struct HostResourceBand: View {
    let presentation: HostResourcePresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(presentation.metrics) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        HostResourceLabel(metric: metric)
                        HostResourceValue(metric: metric)
                        HostResourceMeter(metric: metric)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(presentation.metrics) { metric in
                    GridRow(alignment: .center) {
                        HostResourceLabel(metric: metric)
                        HostResourceMeter(metric: metric)
                            .frame(minWidth: 32)
                        HostResourceValue(metric: metric)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(presentation.metrics) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            HostResourceLabel(metric: metric, givesWay: true)
                            Spacer(minLength: 8)
                            HostResourceValue(metric: metric)
                        }
                        HostResourceMeter(metric: metric)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: presentation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

private struct HostResourceLabel: View {
    let metric: HostResourcePresentation.Metric
    /// Shrinks to fit rather than holding its natural width, for the one
    /// layout drawn whether or not it fits.
    var givesWay = false

    var body: some View {
        Text(metric.label)
            .font(Brand.Fonts.label)
            .tracking(Brand.Tracking.label)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(givesWay ? 0.5 : 1)
            .fixedSize(horizontal: !givesWay, vertical: false)
    }
}

/// The number, then a smaller "%"; "None" for a Host without swap. Rolls
/// between samples.
private struct HostResourceValue: View {
    let metric: HostResourcePresentation.Metric

    var body: some View {
        Group {
            if let percent = metric.percent {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(percent)")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(metric.level.numberColor)
                        .contentTransition(.numericText(value: Double(percent)))
                    Text("%")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("None")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

private struct HostResourceMeter: View {
    let metric: HostResourcePresentation.Metric

    var body: some View {
        AIUsageGaugeBar(
            percent: Double(metric.percent ?? 0), pace: nil,
            color: metric.level.barColor, barHeight: 4)
    }
}
