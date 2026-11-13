import SwiftUI

/// Find Computers: computers on this Wi-Fi that have
/// SSH on. Tapping one asks for a username and password; saving it hands the
/// Host to the same Host page every added Host opens, which asks the user to
/// trust the host key and then shows the agents.
struct FindComputersView: View {
    let catalog: HostStore
    /// A form to open once this sheet is gone: the manual form, or the
    /// manual form with a found computer's address for a user who chose a
    /// key over a password.
    let onFollowUp: (HostAddition) -> Void
    let onAdded: (Host) -> Void

    @State private var store = FindComputersStore.makeForPresentation()
    @Environment(\.analytics) private var analytics
    @State private var path: [FoundComputer] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Find Computers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .tint(Brand.Colors.quietAction)
                    }
                }
                .navigationDestination(for: FoundComputer.self) { computer in
                    FindComputerSignInView(
                        computer: computer, catalog: catalog,
                        onUseKey: { draft in
                            dismiss()
                            onFollowUp(.prefilled(draft))
                        },
                        onAdded: { host in
                            dismiss()
                            onAdded(host)
                        })
                }
        }
        .task { store.start { analytics?.milestone($0) } }
        .onDisappear { store.stop() }
        // Back from Settings with the permission on: look again.
        .onChange(of: scenePhase) {
            if scenePhase == .active, store.isDenied { store.search() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isDenied { denied } else { results }
    }

    private var denied: some View {
        ContentUnavailableView {
            Label("Waycar Can't See Your Network", systemImage: "wifi.slash")
        } description: {
            Text(
                "Turn on Local Network for Waycar in Settings, or add a computer by its address."
            )
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Add Manually") {
                dismiss()
                onFollowUp(.manual)
            }
        }
    }

    private var results: some View {
        List {
            Section {
                ForEach(store.computers) { computer in
                    Button {
                        path.append(computer)
                    } label: {
                        FoundComputerRow(computer: computer)
                    }
                    .buttonStyle(.plain)
                }
                if store.computers.isEmpty {
                    emptyRow
                }
            } header: {
                Text("Computers with SSH on")
            } footer: {
                Text("Waycar learns what runs on a computer after you sign in.")
            }
            Section {
                sweepRow
            } footer: {
                sweepFooter
            }
            #if DEBUG || WAYCAR_ADMIN
                // Internal builds only: what each search saw and when, for the
                // device checks (first search after Allow, a Linux server with
                // no avahi).
                Section("Diagnostics (internal)") {
                    ForEach(Array(store.diagnostics.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            #endif
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    @ViewBuilder
    private var emptyRow: some View {
        if store.hasSettled {
            VStack(alignment: .leading, spacing: 8) {
                Text("No computers found")
                    .font(.headline)
                Text("Turn on SSH (on a Mac, Remote Login) and join the same Wi-Fi.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Search Again") { store.search() }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking for computers…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sweepRow: some View {
        switch store.sweep {
        case .running:
            HStack(spacing: 10) {
                ProgressView()
                Text("Scanning…")
                    .foregroundStyle(.secondary)
            }
        case .idle, .finished, .unavailable:
            Button("Check Every Address") { store.scanNetwork() }
                .disabled(store.sweep == .unavailable)
        }
    }

    @ViewBuilder
    private var sweepFooter: some View {
        switch store.sweep {
        case .idle:
            Text(
                "Finds computers that don't announce themselves by trying port 22 on every address on this Wi-Fi."
            )
        case .running:
            EmptyView()
        case .finished:
            Text("Checked every address.")
        case .unavailable:
            Text("Join a home or office Wi-Fi to check every address.")
        }
    }
}

private struct FoundComputerRow: View {
    let computer: FoundComputer

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(computer.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let subtitle = computer.subtitle {
                    Text(subtitle)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let software = computer.software {
                    Text(software)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }
}

/// The username and password for a found computer. A key is one tap away:
/// the manual form opens with the address filled in.
struct FindComputerSignInView: View {
    let computer: FoundComputer
    let catalog: HostStore
    let onUseKey: (HostDraft) -> Void
    let onAdded: (Host) -> Void

    @State private var draft: HostDraft
    @State private var saveFailed = false
    @FocusState private var focusedField: Field?
    @Environment(\.analytics) private var analytics

    private enum Field { case username, password }

    init(
        computer: FoundComputer, catalog: HostStore,
        onUseKey: @escaping (HostDraft) -> Void, onAdded: @escaping (Host) -> Void
    ) {
        self.computer = computer
        self.catalog = catalog
        self.onUseKey = onUseKey
        self.onAdded = onAdded
        var draft = HostDraft()
        draft.name = computer.serviceName ?? ""
        draft.address = computer.address
        draft.port = String(computer.port)
        // Password first: the user has no key line to paste yet.
        draft.authMethod = .password
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $draft.name)
                LabeledContent("Address", value: "\(computer.address):\(computer.port)")
            }
            Section {
                TextField("User", text: $draft.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                SecureField("Password", text: $draft.password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { save() }
            } header: {
                Text("Sign In")
            } footer: {
                Text(Self.passwordNote)
            }
            Section {
                Button("Use a Key Instead") {
                    var keyDraft = draft
                    keyDraft.authMethod = .deviceKey
                    keyDraft.password = ""
                    onUseKey(keyDraft)
                }
            } footer: {
                Text("Sign in with a Device Key. Waycar shows the line to add on the computer.")
            }
        }
        .navigationTitle(computer.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { save() }
                    .disabled(!draft.canSave(editing: nil))
            }
        }
        .quietCancelAlert("Could not save the Host", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
                .tint(Brand.Colors.quietAction)
        }
        .task { focusedField = .username }
    }

    /// Where the password lives, which iCloud Sync changes (ADR 0019): the
    /// same facts the Host form states for keys.
    private static var passwordNote: String {
        ICloudSync.isEnabled()
            ? "The password stays in the Keychain and syncs only to your own devices through iCloud Keychain."
            : "The password stays in the Keychain."
    }

    private func save() {
        guard draft.canSave(editing: nil), let host = draft.makeHost() else { return }
        do {
            try catalog.add(host, password: draft.passwordUpdate)
            analytics?.capture(.hostAdded(method: .discovered))
        } catch {
            saveFailed = true
            return
        }
        onAdded(host)
    }
}
