import SwiftUI

/// Settings › Toolbar: the single-bar editor (preview, your items, the fixed
/// controls), the Custom Key library, and Reset. Every change is written to
/// the synced catalog at once.
struct ToolbarsSettingsView: View {
    let toolbars: AgentToolbarLayoutStore
    let snippets: SnippetStore

    /// The page's two sheets live on its List, the one host that outlives
    /// scrolling; see `ToolbarEditorView`. The builder serves the Custom Key
    /// library and the Your items rows alike.
    @State private var addingItem = false
    @State private var builder: CustomKeyBuilderTarget?
    @State private var confirmingReset = false
    @State private var errorMessage: String?
    /// Items added while this page is open get a "New" tag.
    @State private var added: Set<AgentToolbarItem.Content> = []

    private var isReadOnly: Bool { toolbars.isCatalogUnreadable }

    var body: some View {
        List {
            if isReadOnly {
                SettingsUnreadableCatalogCard(
                    title: ToolbarSettingsCopy.unreadableTitle, message: ToolbarSettingsCopy.unreadable,
                    resetTitle: ToolbarSettingsCopy.unreadableReset, confirmTitle: "Reset saved toolbar?",
                    confirmMessage: ToolbarSettingsCopy.unreadableResetConfirmation,
                    identifierPrefix: "settings.toolbars"
                ) {
                    toolbars.resetUnreadableCatalog()
                    errorMessage = nil
                }
            }
            if let errorMessage {
                SettingsErrorSection(message: errorMessage, identifier: "settings.toolbars.error")
            }
            ToolbarEditorView(
                store: toolbars, snippets: snippets, added: $added, errorMessage: $errorMessage,
                addingItem: $addingItem, builder: $builder)
            customKeysSection
        }
        .listSectionSpacing(.compact)
        .navigationTitle("Toolbar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { HelpLink(.toolbar) }
            ToolbarItem(placement: .primaryAction) {
                Button("Reset") { confirmingReset = true }
                    .disabled(isReadOnly || !toolbars.isCustomized)
                    .accessibilityIdentifier("settings.toolbars.reset")
            }
        }
        .quietCancelDialog("Reset the Toolbar?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                perform { try toolbars.resetLayout() }
                added = []
            }
            Button("Cancel", role: .cancel) {}.tint(Brand.Colors.quietAction)
        } message: {
            Text(ToolbarSettingsCopy.resetConfirmation)
        }
        .sheet(isPresented: $addingItem) {
            ToolbarItemPicker(store: toolbars, snippets: snippets.snippets) { add($0) }
        }
        .sheet(item: $builder) { target in
            CustomKeyBuilderView(store: toolbars, target: target)
        }
    }

    // MARK: Custom Keys

    /// Every row's leading icon column, so titles share one inset.
    private static let iconColumnWidth: CGFloat = 30
    private static let iconSpacing: CGFloat = 12

    private var customKeysSection: some View {
        Section {
            ForEach(toolbars.customKeys) { key in
                Button {
                    builder = .existing(key)
                } label: {
                    customKeyRow(key)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.toolbars.customKey.\(key.id.uuidString)")
                .deleteDisabled(isReadOnly)
            }
            .onDelete { offsets in
                let ids = offsets.map { toolbars.customKeys[$0].id }
                perform { for id in ids { try toolbars.deleteCustomKey(id) } }
            }
            Button {
                builder = .new
            } label: {
                Label("New Custom Key…", systemImage: "plus")
            }
            .disabled(isReadOnly)
            .accessibilityIdentifier("settings.toolbars.newCustomKey")
        } header: {
            Text("Custom Keys")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(ToolbarSettingsCopy.customKeysFooter)
                Text(ToolbarSettingsCopy.barsFooter)
                Text(ToolbarSettingsCopy.syncFooter)
            }
        }
    }

    private func customKeyRow(_ key: CustomKey) -> some View {
        let isText: Bool = if case .text = key.steps { true } else { false }
        return HStack(spacing: Self.iconSpacing) {
            Image(systemName: isText ? "apple.terminal" : "command")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: Self.iconColumnWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: key.displayLabel)
                        .lineLimit(1)
                    if key.submits { ToolbarTag(.sends) }
                }
                Text(verbatim: ToolbarSettingsCopy.customKeySummary(key))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(toolbars.isOnBar(key.id) ? "On the Toolbar" : "Not on the Toolbar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edits this Custom Key")
    }

    // MARK: Edits

    /// Adds a picked item. Closes the picker after a saved change and after a
    /// refused one, whose message waits on the page; a duplicate keeps it open.
    private func add(_ content: AgentToolbarItem.Content) -> Bool {
        guard let edited = ToolbarEditing.adding(content, to: toolbars.layout) else { return false }
        perform { try toolbars.setLayout(edited) }
        if errorMessage == nil { added.insert(content) }
        return true
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            errorMessage = nil
        } catch {
            errorMessage = ToolbarSettingsCopy.message(for: error)
        }
    }
}
