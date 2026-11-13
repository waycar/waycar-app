import SwiftUI

/// A Host's AI Usage settings on its details page: whether it may be used,
/// how often it is asked, an optional CodexBar path, and what detection
/// found.
struct AIUsageHostSettingsSection: View {
    let store: AIUsageStore
    let hostID: Host.ID
    @State private var pathDraft = ""
    @FocusState private var isEditingPath: Bool

    private var settings: AIUsageHostSettings {
        store.preferences.settings(for: hostID)
    }

    var body: some View {
        Section {
            Toggle("Show AI usage", isOn: Binding(
                get: { settings.isEnabled },
                set: { isEnabled in
                    var updated = settings
                    updated.enabledChoice = isEnabled
                    store.updateSettings(updated, for: hostID)
                }))
            if settings.isEnabled {
                Picker("Refresh", selection: Binding(
                    get: { settings.refreshInterval },
                    set: { interval in
                        var updated = settings
                        updated.refreshInterval = interval
                        store.updateSettings(updated, for: hostID)
                    })
                ) {
                    ForEach(AIUsageRefreshInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                LabeledContent("CodexBar Path") {
                    TextField("Auto-detect", text: $pathDraft)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .submitLabel(.done)
                        .focused($isEditingPath)
                        .onSubmit(commitPath)
                }
                statusRow
            }
        } header: {
            Text("AI Usage")
        } footer: {
            Text(
                "Reads provider usage limits from CodexBar on this Host. "
                    + "A Host starts with AI usage off when another Host already shows it, "
                    + "since each extra Host asks the same AI accounts again. "
                    + "Turn it on to use this Host too. "
                    + "Leave the path blank to auto-detect.")
        }
        .onAppear { pathDraft = settings.customPath ?? "" }
        .onChange(of: isEditingPath) { _, isEditing in
            if !isEditing { commitPath() }
        }
    }

    private var statusRow: some View {
        let (text, systemImage, color) = status
        return HStack {
            Label {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(color)
            }
            .accessibilityElement(children: .combine)
            if canCheckAgain {
                Spacer()
                Button("Check Again") { store.checkAgain(hostID) }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
    }

    /// Not while a check runs, and not before the Host's first connection,
    /// which checks by itself.
    private var canCheckAgain: Bool {
        switch store.detection(for: hostID) {
        case .found, .notFound, .failed: true
        case .unknown, .probing: false
        }
    }

    private var status: (String, String, Color) {
        switch store.detection(for: hostID) {
        case .unknown:
            ("Checked when the Host connects", "circle.dashed", .secondary)
        case .probing:
            ("Looking for CodexBar…", "magnifyingglass", .secondary)
        case .found(let path):
            ("Found at \(path)", "checkmark.circle.fill", .green)
        case .notFound:
            ("CodexBar not found", "xmark.circle", .secondary)
        case .failed(let message):
            ("Error: \(message)", "exclamationmark.triangle.fill", .orange)
        }
    }

    private func commitPath() {
        // The Host may have been turned off while the field was focused.
        guard settings.isEnabled else {
            pathDraft = settings.customPath ?? ""
            return
        }
        let trimmed = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let customPath = trimmed.isEmpty ? nil : trimmed
        guard customPath != settings.customPath else { return }
        var updated = settings
        updated.customPath = customPath
        store.updateSettings(updated, for: hostID)
    }
}
