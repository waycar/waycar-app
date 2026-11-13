import SwiftUI

/// The AI Usage sheet: every provider CodexBar reports, least remaining
/// first, one gauge bar per rate-limit window showing what is left. A
/// provider CodexBar cannot read over SSH, or its helper gave up on, offers
/// the Keychain Fix.
struct AIUsageView: View {
    let store: AIUsageStore
    /// The Host the presenting Console window is scoped to (nil: All Hosts).
    let scope: Host.ID?
    /// Starts the confirmed Keychain Fix on a Host; the owner dismisses
    /// this sheet and opens the fix's Agent.
    let fixKeychain: (CodexBarKeychainFix.Request) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The Keychain Fix awaiting the user's confirmation.
    @State private var confirmingFix: CodexBarKeychainFix.Request? = nil

    private var source: AIUsageSource? { store.source(scopedTo: scope) }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
            .confirmationDialog(
                CodexBarKeychainFix.confirmationTitle(
                    hostName: confirmingFix.flatMap { store.hostName($0.hostID) }),
                isPresented: Binding(
                    get: { confirmingFix != nil },
                    set: { if !$0 { confirmingFix = nil } }),
                titleVisibility: .visible,
                presenting: confirmingFix
            ) { request in
                Button(CodexBarKeychainFix.confirmButtonTitle) { fixKeychain(request) }
                Button("Cancel", role: .cancel) {}.tint(Brand.Colors.quietAction)
            } message: { request in
                Text(CodexBarKeychainFix.confirmationMessage(hostName: store.hostName(request.hostID)))
            }
            .navigationTitle("AI Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let source, store.fetchingHostID == source.hostID {
                        ProgressView()
                    } else {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await store.refresh(scopedTo: scope) }
                        }
                        .disabled(source?.isLive != true)
                    }
                }
            }
        }
        // Sheets don't take the app root's tint; Toggles default to green.
        .tint(Brand.Colors.accent)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let source = source
        let state = source.flatMap { store.usage[$0.hostID] }
        let isOutOfDate = source.map { !$0.isLive || store.isStale($0.hostID, at: now) } ?? false
        List {
            if let failure = state?.lastFailure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }
            if let source, let snapshot = state?.snapshot {
                let report = snapshot.report
                ForEach(report.providers) { provider in
                    let problem = report.fixableProblem(provider)
                    AIUsageProviderSection(
                        provider: provider, options: store.preferences.display, now: now,
                        fixableProblem: problem,
                        hostName: store.hostName(source.hostID),
                        canFix: source.isLive,
                        fix: {
                            guard let problem else { return }
                            confirmingFix = CodexBarKeychainFix.Request(
                                hostID: source.hostID, problem: problem,
                                providers: report.fixableProviders)
                        })
                        .opacity(isOutOfDate ? 0.45 : 1)
                }
                Section {
                } footer: {
                    footer(snapshot: snapshot, source: source, isOutOfDate: isOutOfDate)
                }
            } else if let source, store.fetchingHostID == source.hostID {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading usage…").foregroundStyle(.secondary)
                }
            } else if state?.lastFailure == nil {
                ContentUnavailableView(
                    "No Usage Yet",
                    systemImage: "gauge.with.dots.needle.33percent",
                    description: Text("Pull to refresh."))
            }
        }
        .refreshable { await store.refresh(scopedTo: scope) }
        .task { await store.sheetDidOpen(scopedTo: scope) }
    }

    private func footer(
        snapshot: AIUsageSnapshot, source: AIUsageSource, isOutOfDate: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Updated \(snapshot.fetchedAt, format: .relative(presentation: .named))")
                if isOutOfDate { Text("· Stale") }
            }
            if let hostName = store.hostName(source.hostID) {
                Text("From CodexBar on \(hostName)")
            }
        }
        .font(.footnote)
        .foregroundStyle(isOutOfDate ? Color.orange : Color.secondary)
    }
}

/// One provider: a gauge per window (what is left, or what is used), drawn
/// like the Console card's, or the error CodexBar gave — in plain words with
/// the Keychain Fix when that fix helps.
private struct AIUsageProviderSection: View {
    let provider: AIUsageProvider
    let options: AIUsageDisplayOptions
    let now: Date
    /// What the Keychain Fix would fix in this row; nil when it can't help.
    let fixableProblem: CodexBarKeychainFix.Problem?
    /// The Host CodexBar ran on.
    let hostName: String?
    /// Whether that Host can take the fix's Agent now.
    let canFix: Bool
    let fix: () -> Void

    var body: some View {
        Section {
            ForEach(provider.windows) { window in
                windowRow(window)
            }
            if let fixableProblem {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        fixableProblem.title(providerName: provider.displayName),
                        systemImage: fixableProblem.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(fixableProblem.explanation(hostName: hostName))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Button(CodexBarKeychainFix.fixButtonTitle, systemImage: "wrench.and.screwdriver", action: fix)
                    .disabled(!canFix)
                    .accessibilityHint(canFix ? "" : "Unavailable until the Host reconnects")
            } else if let error = provider.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                if !options.hidesAccountLabels, let account = provider.account {
                    Text(account)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .textCase(nil)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    private func windowRow(_ window: AIUsageWindow) -> some View {
        let shown = window.displayPercent(showsUsed: options.showsUsed)
        let percent = AIUsageFormat.percent(shown)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                    .font(.subheadline)
                Spacer()
                Text(percent)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(window.level.numberColor)
            }
            AIUsageGaugeBar(
                percent: shown,
                pace: options.showsPace ? window.displayPacePercent(showsUsed: options.showsUsed) : nil,
                color: window.level.color,
                barHeight: 12)
            if options.showsPace,
                let pace = window.pace?.paceText(
                    usesSessionWording: window.usesSessionPaceWording, now: now)
            {
                Text(pace)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let reset = AIUsageFormat.resetText(
                window.resetsAt, now: now, style: options.resetStyle)
            {
                Text(reset)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AIUsageFormat.accessibilityLabel(
                provider: provider, window: window, options: options, now: now))
        .accessibilityValue(percent)
    }
}

/// Marks a Host where CodexBar was found, beside its name in the Hosts list.
struct CodexBarBadge: View {
    var body: some View {
        HostRowBadge(text: "CodexBar", tint: .teal)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("CodexBar installed")
    }
}
