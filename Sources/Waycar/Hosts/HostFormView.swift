import SwiftUI

/// Add/edit form for a Host. Device-key auth shows the copyable
/// `authorized_keys` line (generated on device, never exported beyond its
/// public half); the password goes straight to the Keychain via `HostStore`.
/// Duplicating adds a new Host prefilled from an existing one.
struct HostFormView: View {
    let store: HostStore
    var editing: Host?
    /// The Host a new one is being copied from; nil unless duplicating.
    var duplicating: Host?
    var onSaved: ((Host) -> Void)?

    @State private var draft: HostDraft
    @State private var moshTestStore = HostFormMoshTestStore()
    @State private var authorizedKeysLine: String?
    @State private var rsaPublicKeyLine: String?
    @State private var didCopyKeyLine = false
    @State private var saveFailed = false
    @State private var deviceKeyIsCorrupt = false
    @State private var rsaKeyIsCorrupt = false
    @State private var isConfirmingDeviceKeyReplacement = false
    @State private var isConfirmingRSAKeyReplacement = false
    @State private var deviceKeyReplacementError: String?
    @State private var rsaKeyReplacementError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.analytics) private var analytics

    private let credentials = HostCredentialsProvider()

    init(
        store: HostStore, editing: Host? = nil, duplicating: Host? = nil,
        onSaved: ((Host) -> Void)? = nil
    ) {
        self.store = store
        self.editing = editing
        self.duplicating = duplicating
        self.onSaved = onSaved
        let draft =
            if let editing {
                HostDraft(host: editing)
            } else if let duplicating {
                HostDraft(duplicating: duplicating)
            } else {
                HostDraft()
            }
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name (optional)", text: $draft.name)
                    TextField("Address", text: $draft.address)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $draft.port)
                        .keyboardType(.numberPad)
                    TextField("User", text: $draft.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    Picker("Method", selection: $draft.authMethod) {
                        Text("Device Key").tag(Host.AuthMethod.deviceKey)
                        Text("RSA Key").tag(Host.AuthMethod.rsaKey)
                        Text("Password").tag(Host.AuthMethod.password)
                    }
                    .onChange(of: draft.authMethod) {
                        didCopyKeyLine = false
                        if draft.authMethod == .rsaKey,
                           rsaPublicKeyLine == nil,
                           !rsaKeyIsCorrupt
                        {
                            loadRSAKey()
                        }
                    }
                    switch draft.authMethod {
                    case .deviceKey:
                        deviceKeySection
                    case .rsaKey:
                        rsaKeySection
                    case .password:
                        SecureField(
                            editing == nil ? "Password" : "Password (blank keeps current)",
                            text: $draft.password)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    switch draft.authMethod {
                    case .deviceKey:
                        Text("Add this line to ~/.ssh/authorized_keys on the Host. " + Self.privateKeyNote)
                    case .rsaKey:
                        Text(
                            "Register this public key wherever the Host accepts SSH identities. "
                                + Self.privateKeyNote)
                    case .password:
                        EmptyView()
                    }
                }

                Section {
                    TextField("Session name", text: $draft.sessionName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("herdr Session")
                } footer: {
                    Text(
                        "Leave blank for the default herdr session. Herdr TUI only: "
                            + "herdr-core uses its default session.")
                }

                Section {
                    TextField("Jump Host address (optional)", text: $draft.jumpAddress)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if draft.usesJumpHost {
                        TextField("Jump Host port", text: $draft.jumpPort)
                            .keyboardType(.numberPad)
                        TextField("Jump Host user (blank = same as Host)", text: $draft.jumpUsername)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Jump Host")
                } footer: {
                    if draft.usesJumpHost {
                        Text(jumpHostFooter)
                    } else {
                        Text("Leave blank to connect to the Host directly.")
                    }
                }

                Section {
                    moshTestRow
                    Button("Test Mosh on this Host") {
                        Task { await moshTestStore.test(draft: draft, editing: editing) }
                    }
                    // A Disabled Host is never contacted, not even by this test.
                    .disabled(moshTest == .testing || isEditingDisabledHost)
                } header: {
                    Text("Mosh")
                } footer: {
                    if isEditingDisabledHost {
                        Text("This Host is disabled. Turn it on to test mosh.")
                    } else {
                        Text(
                            "Connects with the credentials entered above and runs a real "
                                + "mosh handshake. Sessions fall back to SSH whenever mosh "
                                + "fails, so a failed test does not block saving.")
                    }
                }
            }
            .onChange(of: draft) { moshTestStore.draftChanged(draft) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { HelpLink(.addHostManually) }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Brand.Colors.quietAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.canSave(editing: editing))
                }
            }
            .quietCancelAlert("Could not save the Host", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
                    .tint(Brand.Colors.quietAction)
            }
            .quietCancelAlert(
                "Could not replace the Device Key",
                isPresented: Binding(
                    get: { deviceKeyReplacementError != nil },
                    set: { if !$0 { deviceKeyReplacementError = nil } })
            ) {
                Button("OK", role: .cancel) {}
                    .tint(Brand.Colors.quietAction)
            } message: {
                Text(deviceKeyReplacementError ?? "")
            }
            .quietCancelAlert(
                "Could not replace the RSA Key",
                isPresented: Binding(
                    get: { rsaKeyReplacementError != nil },
                    set: { if !$0 { rsaKeyReplacementError = nil } })
            ) {
                Button("OK", role: .cancel) {}
                    .tint(Brand.Colors.quietAction)
            } message: {
                Text(rsaKeyReplacementError ?? "")
            }
            .quietCancelDialog(
                "Replace the Device Key?",
                isPresented: $isConfirmingDeviceKeyReplacement,
                titleVisibility: .visible
            ) {
                Button("Replace Device Key", role: .destructive) { replaceDeviceKey() }
                Button("Cancel", role: .cancel) {}
                    .tint(Brand.Colors.quietAction)
            } message: {
                Text(
                    "Every Host using Device Key authentication will reject the replacement "
                        + "until you add its new public key to ~/.ssh/authorized_keys.")
            }
            .quietCancelDialog(
                "Replace the RSA Key?",
                isPresented: $isConfirmingRSAKeyReplacement,
                titleVisibility: .visible
            ) {
                Button("Replace RSA Key", role: .destructive) { replaceRSAKey() }
                Button("Cancel", role: .cancel) {}
                    .tint(Brand.Colors.quietAction)
            } message: {
                Text(
                    "Every Host using RSA Key authentication will reject the replacement "
                        + "until you register its new public key on that Host.")
            }
            .task {
                loadDeviceKey()
                if draft.authMethod == .rsaKey {
                    loadRSAKey()
                }
                loadDuplicatedPassword()
            }
        }
    }

    /// Where the private half lives, which iCloud Sync changes (ADR 0019).
    /// With sync off it may still be in iCloud Keychain from an earlier sync,
    /// so the off wording claims no more than the Keychain.
    private static var privateKeyNote: String {
        ICloudSync.isEnabled()
            ? "The private key stays in the Keychain and syncs only to your own devices "
                + "through iCloud Keychain."
            : "The private key stays in the Keychain."
    }

    private var title: String {
        if editing != nil {
            "Edit Host"
        } else if duplicating != nil {
            "Duplicate Host"
        } else {
            "Add Host"
        }
    }

    /// A duplicate keeps its source's saved password, which the Keychain
    /// holds under the source's id; the form saves it again under the new
    /// Host's. Left blank when none was saved or the read fails, and never
    /// over anything already typed.
    private func loadDuplicatedPassword() {
        guard let duplicating, duplicating.authMethod == .password, draft.password.isEmpty,
              let password = try? store.password(for: duplicating)
        else { return }
        draft.password = password
    }

    private var jumpHostFooter: String {
        let credentialRequirement =
            switch draft.authMethod {
            case .deviceKey:
                "Both machines must authorize the Device Key."
            case .rsaKey:
                "Both machines must authorize the RSA Key."
            case .password:
                "Both machines must accept the same password; separate passwords are not supported."
            }
        return "The Host's Address and Port are resolved from the Jump Host, usually through "
            + "a loopback-only reverse tunnel. \(credentialRequirement) You confirm each "
            + "machine's host key fingerprint independently on first connect."
    }

    // MARK: mosh test

    private var moshTest: HostFormMoshTestResult { moshTestStore.result(for: draft) }

    @ViewBuilder
    private var moshTestRow: some View {
        switch moshTest {
        case .idle:
            Label(
                "Not tested yet — sessions use SSH until mosh is proven",
                systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Testing mosh on this Host…")
            }
        case .available:
            Label("Mosh available on this Host", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unavailable:
            Label(
                "Mosh handshake failed — sessions will use SSH",
                systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .couldNotConnect(let reason):
            Label(
                "Could not connect to test. \(reason)",
                systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }

    /// Editing a Disabled Host, which the app never contacts.
    private var isEditingDisabledHost: Bool { editing?.isEnabled == false }

    @ViewBuilder
    private var deviceKeySection: some View {
        if let authorizedKeysLine {
            Text(authorizedKeysLine)
                .font(.caption.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = authorizedKeysLine
                didCopyKeyLine = true
            } label: {
                Label(
                    didCopyKeyLine ? "Copied" : "Copy authorized_keys Line",
                    systemImage: didCopyKeyLine ? "checkmark" : "doc.on.doc")
            }
        } else {
            Label(
                deviceKeyIsCorrupt ? "Device key is corrupted" : "Device key unavailable",
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if deviceKeyIsCorrupt {
                Button("Replace Device Key", role: .destructive) {
                    isConfirmingDeviceKeyReplacement = true
                }
            } else {
                Button("Try Again") { loadDeviceKey() }
            }
        }
    }

    @ViewBuilder
    private var rsaKeySection: some View {
        if let rsaPublicKeyLine {
            Text(rsaPublicKeyLine)
                .font(.caption.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = rsaPublicKeyLine
                didCopyKeyLine = true
            } label: {
                Label(
                    didCopyKeyLine ? "Copied" : "Copy RSA Public Key",
                    systemImage: didCopyKeyLine ? "checkmark" : "doc.on.doc")
            }
        } else {
            Label(
                rsaKeyIsCorrupt ? "RSA Key is corrupted" : "RSA Key unavailable",
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if !rsaKeyIsCorrupt {
                Button("Try Again") { loadRSAKey() }
            } else {
                Button("Replace RSA Key", role: .destructive) {
                    isConfirmingRSAKeyReplacement = true
                }
            }
        }
    }

    private func loadDeviceKey() {
        do {
            let key = try credentials.deviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "waycar")
            deviceKeyIsCorrupt = false
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            authorizedKeysLine = nil
            deviceKeyIsCorrupt = true
        } catch {
            authorizedKeysLine = nil
            deviceKeyIsCorrupt = false
        }
    }

    private func loadRSAKey() {
        do {
            let key = try credentials.rsaKey()
            rsaPublicKeyLine = key.authorizedKeysLine(comment: "waycar rsa")
            rsaKeyIsCorrupt = false
        } catch RSAKeyStoreError.storedKeyCorrupt {
            rsaPublicKeyLine = nil
            rsaKeyIsCorrupt = true
        } catch {
            rsaPublicKeyLine = nil
            rsaKeyIsCorrupt = false
        }
    }

    private func replaceDeviceKey() {
        do {
            let key = try credentials.replaceDeviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "waycar")
            deviceKeyIsCorrupt = false
            didCopyKeyLine = false
        } catch {
            deviceKeyReplacementError = "The replacement could not be saved to the Keychain."
        }
    }

    private func replaceRSAKey() {
        do {
            let key = try credentials.replaceRSAKey()
            rsaPublicKeyLine = key.authorizedKeysLine(comment: "waycar rsa")
            rsaKeyIsCorrupt = false
            didCopyKeyLine = false
        } catch {
            rsaKeyReplacementError = "The replacement could not be saved to the Keychain."
        }
    }

    private func save() {
        guard draft.canSave(editing: editing) else { return }
        guard let host = draft.makeHost(id: editing?.id ?? UUID()) else { return }
        do {
            if editing == nil {
                try store.add(host, password: draft.passwordUpdate)
                analytics?.capture(.hostAdded(method: .manual))
            } else {
                try store.update(host, password: draft.passwordUpdate)
            }
        } catch {
            saveFailed = true
            return
        }
        dismiss()
        onSaved?(host)
    }
}
