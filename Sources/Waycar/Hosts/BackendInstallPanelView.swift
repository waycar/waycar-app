import SwiftUI

extension EnvironmentValues {
    /// The app's one install center, injected at each window's root; nil in
    /// previews, where no Host is offered an install.
    @Entry var backendInstallCenter: BackendInstallCenter? = nil
}

/// The install panel (WAY-338): New Agent's card for a Host with no usable
/// backend (frames 1 and 2), the progress row a run shows when New Agent
/// reopens (4c), and the row a run that failed behind a hidden sheet leaves.
/// The sheet its buttons open is `backendInstallSheet`.
struct BackendInstallPanelCard: View {
    let panel: BackendInstallPanelStore

    var body: some View {
        Group {
            if let run = panel.run {
                progressRow(run)
            } else if let screen = panel.outcomeScreen, screen.tone != .found {
                failureRow(screen)
            } else if let gap = panel.gap {
                fullCard(gap)
            }
        }
        // Keyed on the run: a card opened while an install ran reads the Host
        // once that run is over.
        .task(id: panel.run == nil) { await panel.loadPreflight() }
    }

    // MARK: Frames

    private func fullCard(_ gap: HostBackendGap) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(Brand.Colors.warn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(gap.title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(gap.explanation(hostName: panel.host.displayName))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(gap.foundLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            installButtons
            checkAgainButton
            if let note = panel.checkNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Brand.Colors.warn.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Brand.Colors.warn.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var installButtons: some View {
        switch panel.preflight {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking \(panel.host.displayName)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.footnote)
                .foregroundStyle(Brand.Colors.danger)
        case .ready:
            if let plan = panel.herdrPlan {
                InstallButton(
                    title: plan.target.installTitle, detail: plan.target.buttonDetail
                ) { panel.chooseInstall(plan) }
            } else if let reason = panel.herdrUnavailableReason {
                reasonLine(reason)
            }
            if let plan = panel.tmuxPlan {
                InstallButton(
                    title: plan.target.installTitle, detail: plan.target.buttonDetail
                ) { panel.chooseInstall(plan) }
            } else if let reason = panel.tmuxUnavailableReason {
                reasonLine(reason)
            }
            if let plan = panel.corePlan {
                InstallButton(
                    title: plan.target.installTitle, detail: plan.target.buttonDetail
                ) { panel.chooseInstall(plan) }
            } else if let reason = panel.coreUnavailableReason {
                reasonLine(reason)
            }
        }
    }

    private func reasonLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var checkAgainButton: some View {
        Button {
            Task { await panel.checkAgain() }
        } label: {
            HStack(spacing: 8) {
                if panel.isChecking {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text("Check Again")
            }
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(panel.isChecking)
    }

    private func progressRow(_ run: BackendInstallCenter.Run) -> some View {
        let host = panel.host.displayName
        let title =
            switch run.phase {
            case .installing: "Installing \(run.plan.target.name) on \(host)…"
            case .checking: "Checking \(host)…"
            }
        return HStack(spacing: 12) {
            ProgressView()
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                panel.show()
            } label: {
                Text("Show")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.Colors.violetSoft)
            .accessibilityLabel("Show install progress")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// A run that ended in failure while its sheet was hidden.
    private func failureRow(_ screen: BackendInstallOutcomeScreen) -> some View {
        HStack(spacing: 12) {
            Image(
                systemName: screen.tone == .warning
                    ? "exclamationmark.triangle.fill" : "xmark.circle.fill"
            )
            .foregroundStyle(screen.tone == .warning ? Brand.Colors.warn : Brand.Colors.danger)
            .accessibilityHidden(true)
            Text(screen.title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button {
                panel.show()
            } label: {
                Text("Show")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.Colors.violetSoft)
            .accessibilityLabel("Show install result")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// An Install button: 56 pt tall with a second line (frames 1, 2 and 7).
/// Every row is outlined and none leads: the panel recommends nothing
/// (WAY-482).
private struct InstallButton: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Brand.Colors.violetSoft)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Brand.Colors.violetSoft.opacity(0.45), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Sheet

extension View {
    /// The panel's consent, progress and result sheet, and the VoiceOver
    /// announcement of how a run ended. Attach it above whatever shows the
    /// card, so the sheet outlives the card: a found Host takes the card
    /// away while the Found screen is still up.
    func backendInstallSheet(_ panel: BackendInstallPanelStore?) -> some View {
        modifier(BackendInstallSheetModifier(panel: panel))
    }
}

private struct BackendInstallSheetModifier: ViewModifier {
    let panel: BackendInstallPanelStore?

    func body(content: Content) -> some View {
        content
            .sheet(
                isPresented: Binding(
                    get: { panel?.sheet != nil },
                    set: { if !$0 { panel?.hide() } })
            ) {
                if let panel {
                    BackendInstallSheet(panel: panel)
                }
            }
            .onChange(of: panel?.sheet == nil) { _, isGone in
                if isGone { panel?.sheetEnded() }
            }
            // The outcome speaks whether or not its sheet is up: a run the
            // user hid ends on a screen that is not looking at it.
            .onChange(of: panel?.outcomeScreen?.announcement) { _, text in
                if let text { AccessibilityNotification.Announcement(text).post() }
            }
    }
}

/// Consent (frames 3a and 3b), running (4a, 4b) and the result (5a to 6c),
/// in `WaycarPluginUpdateSheet`'s list style. There is no Cancel while the
/// installer runs, as on Plugin Update: Hide leaves it going.
private struct BackendInstallSheet: View {
    let panel: BackendInstallPanelStore
    /// What the sheet last showed, so it keeps its content while it slides
    /// away instead of blanking.
    @State private var lastSheet: BackendInstallPanelStore.Sheet?

    private var current: BackendInstallPanelStore.Sheet? { panel.sheet ?? lastSheet }

    var body: some View {
        NavigationStack {
            List {
                switch current {
                case .consent(let plan):
                    consentSections(BackendInstallConsent(plan: plan))
                case .running(let run):
                    runningSections(run)
                case .outcome(let outcome):
                    outcomeSections(
                        BackendInstallOutcomeScreen(
                            outcome: outcome, hostName: panel.host.displayName),
                        plan: outcome.plan)
                case nil:
                    EmptyView()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .tint(Brand.Colors.accent)
        .onAppear { lastSheet = panel.sheet }
        .onChange(of: panel.sheet) { _, sheet in
            if let sheet { lastSheet = sheet }
        }
    }

    private var title: String {
        switch current {
        case .consent(let plan): plan.target.consentTitle
        case .running(let run):
            switch run.phase {
            case .installing: run.plan.target.runningTitle
            case .checking: "Checking \(panel.host.displayName)…"
            }
        case .outcome(let outcome):
            BackendInstallOutcomeScreen(outcome: outcome, hostName: panel.host.displayName).title
        case nil: ""
        }
    }

    private struct BarButton {
        let title: String
        let isConfirmation: Bool
        let action: () -> Void
    }

    /// The one bar button of each screen: Cancel on the consent, Hide while
    /// running (no Cancel: the installer cannot be stopped from here), Done on
    /// a found Host, Close on a failure.
    private var toolbarButton: BarButton? {
        switch current {
        case .consent:
            return BarButton(title: "Cancel", isConfirmation: false) { panel.cancelConsent() }
        case .running:
            return BarButton(title: "Hide", isConfirmation: false) { panel.hide() }
        case .outcome(let outcome):
            let tone = BackendInstallOutcomeScreen(
                outcome: outcome, hostName: panel.host.displayName
            ).tone
            return BarButton(
                title: tone == .found ? "Done" : "Close", isConfirmation: tone == .found
            ) { panel.finish() }
        case nil:
            return nil
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(
            placement: toolbarButton?.isConfirmation == true
                ? .confirmationAction : .cancellationAction
        ) {
            if let button = toolbarButton {
                Button(button.title, action: button.action)
                    .tint(button.isConfirmation ? Brand.Colors.accent : Brand.Colors.quietAction)
            }
        }
    }

    // MARK: Consent

    @ViewBuilder
    private func consentSections(_ consent: BackendInstallConsent) -> some View {
        Section {
            Label {
                Text(panel.account)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "person").foregroundStyle(Brand.Colors.accent)
            }
        } header: {
            Text("Runs as")
        }

        Section {
            Text(consent.command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        } header: {
            Text("Command")
        }

        Section {
            ForEach(consent.bullets, id: \.text) { bullet in
                Label {
                    Text(bullet.text)
                } icon: {
                    Image(systemName: bullet.symbol).foregroundStyle(Brand.Colors.accent)
                }
            }
        } header: {
            Text("This will")
        }

        Section {
            LabeledContent {
                Text(panel.herdrRowValue)
            } label: {
                Text(HostBackend.herdr.displayName).font(.body.monospaced())
            }
            LabeledContent {
                Text(panel.tmuxRowValue)
            } label: {
                Text(HostBackend.tmux.displayName).font(.body.monospaced())
            }
        } header: {
            Text("On this Host now")
        } footer: {
            Text(consent.sourceNote)
        }

        if let failure = panel.startFailure {
            Section {
                Label(failure, systemImage: "xmark.octagon")
                    .foregroundStyle(Brand.Colors.danger)
            }
        }

        Section {
            Button {
                panel.confirmInstall()
            } label: {
                Text(consent.confirmTitle)
                    .frame(maxWidth: .infinity)
            }
            .bold()
        } footer: {
            Text(BackendInstallConsent.askNote)
        }
    }

    // MARK: Running

    @ViewBuilder
    private func runningSections(_ run: BackendInstallCenter.Run) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(
                    run.phase == .checking
                        ? run.plan.target.lookingTitle : "Installing…")
            }
            .accessibilityElement(children: .combine)
        }

        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("$ \(run.plan.command)")
                    .foregroundStyle(.secondary)
                ForEach(Array(run.output.suffix(Self.visibleLines).enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
            .font(.footnote.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                run.output.last.map { "Installer output. Latest: \($0)" } ?? "Installer output")
        } footer: {
            Text("You can hide this. The install keeps running on \(panel.host.displayName).")
        }
    }

    /// How many of the installer's latest lines the log shows.
    private static let visibleLines = 12

    // MARK: Result

    @ViewBuilder
    private func outcomeSections(
        _ screen: BackendInstallOutcomeScreen, plan: BackendInstallPlan
    ) -> some View {
        switch screen.tone {
        case .found:
            Section {
                Label(screen.reason, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Brand.Colors.done)
                if let note = screen.note {
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if let hint = screen.hint { Text(hint) }
            }
        case .failed, .warning:
            failureSections(screen, plan: plan)
        }
    }

    @ViewBuilder
    private func failureSections(
        _ screen: BackendInstallOutcomeScreen, plan: BackendInstallPlan
    ) -> some View {
        Section {
            if screen.tone == .warning {
                Label(screen.reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.Colors.warn)
            } else {
                Label(screen.reason, systemImage: "xmark.circle.fill")
                    .foregroundStyle(Brand.Colors.danger)
            }
            if let lastLine = screen.lastLine {
                Text(lastLine)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } footer: {
            if let hint = screen.hint { Text(hint) }
        }

        if screen.extra == .installHerdr, panel.herdrPlan != nil {
            Section {
                Button {
                    panel.installHerdr()
                } label: {
                    Text(BackendInstallTarget.herdr.installTitle)
                        .frame(maxWidth: .infinity)
                }
                .bold()
            }
        }

        if let command = screen.command {
            Section {
                Text(command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Button {
                    panel.copy(command)
                } label: {
                    Label(
                        panel.didCopyCommand ? "Copied" : "Copy Command",
                        systemImage: panel.didCopyCommand ? "checkmark" : "doc.on.doc")
                }
            } footer: {
                Text("Or run this in a terminal on the Host.")
            }
        }

        Section {
            if let url = HelpWeb.pageURL("install-tmux-or-herdr") {
                Link(destination: url) {
                    Label("How to install", systemImage: "arrow.up.forward.square")
                }
            }
            Button {
                Task { await panel.checkAgain() }
            } label: {
                HStack {
                    Label("Check Again", systemImage: "arrow.clockwise")
                    if panel.isChecking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(panel.isChecking)
            switch screen.extra {
            case .installHerdrInstead where panel.herdrPlan != nil:
                Button {
                    panel.installHerdr()
                } label: {
                    Label("Install Herdr TUI instead", systemImage: "arrow.down.circle")
                }
            case .retry:
                Button {
                    panel.retry(plan)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            default:
                EmptyView()
            }
        } footer: {
            if let note = panel.checkNote { Text(note) }
        }
    }
}

/// The Console banner's sheet (frame 7): the same panel, titled with the
/// Host, over the Console. It closes once nothing is left to show: the
/// Host has a backend and no sheet of the install is up.
struct BackendInstallHostSheet: View {
    let panel: BackendInstallPanelStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                BackendInstallPanelCard(panel: panel)
                    .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(panel.host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .tint(Brand.Colors.quietAction)
                }
            }
        }
        .backendInstallSheet(panel)
        .tint(Brand.Colors.accent)
        .onChange(of: panel.showsCard || panel.sheet != nil) { _, isShowing in
            if !isShowing { dismiss() }
        }
    }
}
