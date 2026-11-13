import SwiftUI
import UIKit

/// Settings › iCloud Sync (ADR 0019): the per-device switch, when this device
/// last checked its iCloud Keychain items, and what the user has to do for
/// sync to happen at all. The app cannot see whether iCloud Keychain is on,
/// so the screen says what it needs instead of claiming a sync status.
struct ICloudSyncSettingsView: View {
    let sync: ICloudSyncCoordinator

    private enum KeyKind: Identifiable {
        case device, rsa
        var id: Self { self }
        var title: String { self == .device ? "Device Key" : "RSA Key" }
    }

    @State private var confirmingReplacement: KeyKind?
    @State private var replacement: KeyReplacement?

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Sync with iCloud",
                    isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
                    .accessibilityIdentifier("settings.icloudSync.toggle")
                if let error = sync.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
                if sync.switchOffFailed {
                    Button("Turn Off Anyway", role: .destructive) { sync.turnOffAnyway() }
                }
            } footer: {
                Text(
                    sync.isEnabled
                        ? "Hosts, their passwords, your SSH keys, trusted host fingerprints, "
                            + "Snippets, Closed Sessions and preferences sync to your other devices through "
                            + "iCloud Keychain, end-to-end encrypted. The toolbar syncs separately for "
                            + "iPhone and iPad."
                        : "This device keeps its Hosts, passwords and SSH keys and no longer "
                            + "syncs them; the copies already in iCloud Keychain stay there for "
                            + "your other devices. Turning sync back on publishes this device's "
                            + "Hosts again.")
            }

            if sync.isEnabled {
                Section {
                    LabeledContent("Last Checked") {
                        if let lastPassAt = sync.lastPassAt {
                            Text(lastPassAt, style: .relative)
                        } else {
                            Text("Not yet")
                        }
                    }
                    Button("Check Now") { sync.syncNow() }
                } footer: {
                    Text(
                        "Waycar checks when it opens, when you return to it, and every "
                            + "30 seconds while it is open. Changes from another device arrive "
                            + "once iCloud Keychain delivers them, usually within a minute.")
                }

                Section {
                    Button("Replace Device Key…", role: .destructive) {
                        confirmingReplacement = .device
                    }
                    Button("Replace RSA Key…", role: .destructive) {
                        confirmingReplacement = .rsa
                    }
                    if let replacement {
                        if let oldLine = replacement.oldLine {
                            keyLine("Remove this line from every Host:", oldLine)
                        }
                        keyLine("Add this line:", replacement.newLine)
                        Button("Copy New Public Key") {
                            UIPasteboard.general.string = replacement.newLine
                        }
                    }
                } header: {
                    Text("SSH Keys")
                } footer: {
                    Text(
                        "Your devices share one SSH key of each kind. If a device is lost, "
                            + "remove it from your Apple Account, replace the key here, and on "
                            + "every Host replace the old public key line with the new one. The "
                            + "old key keeps working on a Host until its line is removed.")
                }
            }

            Section {
                Text(
                    "Use the same Apple Account on each device and turn on iCloud Keychain: "
                        + "Settings › [your name] › iCloud › Passwords and Keychain (Passwords "
                        + "on newer iOS). Waycar cannot see that switch, so if your Hosts do not "
                        + "appear on another device, check it there first.")
            } header: {
                Text("Requirements")
            }

            Section {
                Text(
                    "Notifications and Live Activities: each device registers itself with "
                        + "each Host. Also terminal zoom, button positions and Console list "
                        + "layout.")
            } header: {
                Text("Stays on This Device")
            }
        }
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { HelpLink(.icloudSync) } }
        .quietCancelDialog(
            confirmingReplacement.map { "Replace the \($0.title)?" } ?? "",
            isPresented: Binding(
                get: { confirmingReplacement != nil },
                set: { if !$0 { confirmingReplacement = nil } }),
            titleVisibility: .visible,
            presenting: confirmingReplacement
        ) { kind in
            Button("Replace \(kind.title)", role: .destructive) { replace(kind) }
            Button("Cancel", role: .cancel) { confirmingReplacement = nil }
                .tint(Brand.Colors.quietAction)
        } message: { _ in
            Text(
                "Every device switches to a new key. The old key keeps working on each Host "
                    + "until you remove its line there; Waycar shows both lines next.")
        }
    }

    private func keyLine(_ label: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.footnote)
            Text(line)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func replace(_ kind: KeyKind) {
        switch kind {
        case .device: replacement = sync.replaceDeviceKey()
        case .rsa: replacement = sync.replaceRSAKey()
        }
    }
}
