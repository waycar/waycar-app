import SwiftUI

struct ZellijSessionDeleteConfirmation: ViewModifier {
    @Binding var pending: ClosedZellijSession?
    let delete: (ClosedZellijSession) -> Void

    func body(content: Content) -> some View {
        content.alert(pending?.deleteTitle ?? "Delete Zellij session?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { row in
            Button("Delete", role: .destructive) { confirm(row) }
            Button("Cancel", role: .cancel) { cancel() }
        } message: { _ in Text(ClosedZellijSession.deleteMessage) }
    }

    func confirm(_ row: ClosedZellijSession) {
        pending = nil
        delete(row)
    }

    func cancel() { pending = nil }
}

struct ClosedZellijSessionCardView: View {
    let row: ClosedZellijSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x3")
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.hostName).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: row.session.name).font(.headline).lineLimit(1)
                Text("Zellij session").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text("Closed").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let age = row.session.age {
                    Text(verbatim: age).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A saved layout has a whole-session PTY, not an inventory pane. Keep the shared Attach
/// lifecycle, but give its unused Composer no pane-RPC capability.
@MainActor
struct ClosedZellijSessionTerminal {
    let composer: AgentComposerStore
    let attach: AgentAttachStore

    init(
        row: ClosedZellijSession, transportGeneration: UInt64?,
        isPresented: @escaping () -> Bool, runTerminal: @escaping TerminalSessionRunner
    ) {
        let composer = AgentComposerStore(shellPaneID: row.session.terminalID) { _ in
            throw ZellijTransport.unsupported("Use the terminal keyboard for a saved session")
        }
        self.composer = composer
        attach = AgentAttachStore(
            target: .terminal(row.session.terminalID), transportGeneration: transportGeneration,
            recordsNetworkTelemetry: false, isOnStage: isPresented, runTerminal: runTerminal,
            stageImage: { _, _ in throw ZellijTransport.unsupported("Saved session attachments") },
            stageFile: { _, _ in throw ZellijTransport.unsupported("Saved session attachments") },
            composer: composer,
            closePane: { throw ZellijTransport.unsupported("Close saved session") })
    }
}

/// Only explicit Resume mints this target. Its terminal keyboard is available, but no
/// Composer, pane lifecycle, history, or message-jump controls address the saved layout.
struct ClosedZellijSessionTerminalView: View {
    let row: ClosedZellijSession
    let console: ConsoleStore
    let terminal: TerminalSettings
    let hosts: [Host]
    let activity: AppActivityCoordinator
    let keyboardHandoff: TerminalKeyboardHandoff
    let keyboardInset: TerminalKeyboardInset
    let isPresented: () -> Bool
    let dismiss: () -> Void
    @State private var session: ClosedZellijSessionTerminal

    init(
        row: ClosedZellijSession, console: ConsoleStore, terminal: TerminalSettings,
        hosts: [Host], activity: AppActivityCoordinator, keyboardHandoff: TerminalKeyboardHandoff,
        keyboardInset: TerminalKeyboardInset, isPresented: @escaping () -> Bool,
        dismiss: @escaping () -> Void
    ) {
        self.row = row
        self.console = console
        self.terminal = terminal
        self.hosts = hosts
        self.activity = activity
        self.keyboardHandoff = keyboardHandoff
        self.keyboardInset = keyboardInset
        self.isPresented = isPresented
        self.dismiss = dismiss
        _session = State(initialValue: ClosedZellijSessionTerminal(
            row: row, transportGeneration: console.connectionGeneration(for: row.terminalRow),
            isPresented: isPresented,
            runTerminal: console.terminalRunner(for: row.hostID, backend: .zellij)))
    }

    var body: some View {
        NavigationStack {
            AgentTerminalView(
                agent: row.terminalRow, console: console, terminal: terminal, hosts: hosts,
                activity: activity, keyboardHandoff: keyboardHandoff, keyboardInset: keyboardInset,
                isOnStage: isPresented, onSwitch: { _ in }, onClosed: dismiss,
                composer: session.composer, attachStore: session.attach, paneActionsAvailable: false)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: dismiss) } }
        }
    }
}
