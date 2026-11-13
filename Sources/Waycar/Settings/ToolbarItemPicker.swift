import SwiftUI

// MARK: - Catalog

/// One item the picker offers, with whether the bar already has it.
struct ToolbarPickerEntry: Identifiable, Equatable {
    let content: AgentToolbarItem.Content
    let presentation: AgentToolbarItemPresentation
    let isOnBar: Bool

    var id: AgentToolbarItem.Content { content }
}

/// What the Add Item picker lists, grouped into its sections. Built only
/// from `AgentToolbarAvailability.validItems`.
struct ToolbarPickerCatalog: Equatable {
    /// Plain keys other than F1–F12.
    var keys: [ToolbarPickerEntry] = []
    var functionKeys: [ToolbarPickerEntry] = []
    /// Sticky chips.
    var modifiers: [ToolbarPickerEntry] = []
    var combos: [ToolbarPickerEntry] = []
    var customKeys: [ToolbarPickerEntry] = []
    var actions: [ToolbarPickerEntry] = []
    var snippets: [ToolbarPickerEntry] = []

    init(
        layout: AgentToolbarLayout,
        customKeys library: [CustomKey],
        snippets catalog: [Snippet],
        query: String = ""
    ) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let contents = AgentToolbarAvailability.validItems(
            snippetIDs: catalog.map(\.id), customKeyIDs: library.map(\.id))
        for content in contents {
            guard let presentation = AgentToolbarItemPresentation(content, customKeys: library, snippets: catalog)
            else { continue }
            guard Self.matches(presentation, query: query) else { continue }
            let entry = ToolbarPickerEntry(content: content, presentation: presentation, isOnBar: layout.contains(content))
            switch content {
            case .key(let chord) where chord.isCombo:
                combos.append(entry)
            case .key(let chord):
                if case .function = chord.key {
                    functionKeys.append(entry)
                } else {
                    keys.append(entry)
                }
            case .modifier:
                modifiers.append(entry)
            case .action:
                actions.append(entry)
            case .customKey:
                customKeys.append(entry)
            case .snippet:
                snippets.append(entry)
            }
        }
    }

    var isEmpty: Bool {
        keys.isEmpty && functionKeys.isEmpty && modifiers.isEmpty && combos.isEmpty
            && customKeys.isEmpty && actions.isEmpty && snippets.isEmpty
    }

    private static func matches(_ presentation: AgentToolbarItemPresentation, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [presentation.name, presentation.capLabel, presentation.subtitle, presentation.hint ?? "",
                presentation.accessibilityLabel]
            .contains { $0.localizedStandardContains(query) }
    }
}

// MARK: - Picker

/// The Add Item sheet. Items already on the bar show ✓ and do nothing when
/// tapped again (no duplicates). Adding closes the sheet.
struct ToolbarItemPicker: View {
    let store: AgentToolbarLayoutStore
    let snippets: [Snippet]
    /// Adds `content`; true when the sheet should close.
    let add: (AgentToolbarItem.Content) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showsFunctionKeys = false
    @State private var builder: CustomKeyBuilderTarget?

    private var catalog: ToolbarPickerCatalog {
        ToolbarPickerCatalog(
            layout: store.layout, customKeys: store.customKeys, snippets: snippets, query: query)
    }

    private var title: String { "Add to Toolbar" }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search keys, combos, actions")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.tint(Brand.Colors.quietAction)
                    }
                }
                .sheet(item: $builder) { target in
                    CustomKeyBuilderView(store: store, target: target) {
                        // The builder placed the new key on this bar.
                        dismiss()
                    }
                }
        }
    }

    @ViewBuilder
    private var list: some View {
        let offered = catalog
        let showsFunctionKeyChips = showsFunctionKeys || !query.isEmpty
        let shownKeys = offered.keys + (showsFunctionKeyChips ? offered.functionKeys : [])
        List {
            Section {
                Button {
                    builder = .new
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New Custom Key…")
                            Text("A key combo, or text with optional Enter")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .disabled(store.isCatalogUnreadable)
                .accessibilityIdentifier("settings.toolbars.picker.newCustomKey")
            }

            if offered.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }

            if !offered.keys.isEmpty || !offered.functionKeys.isEmpty {
                Section {
                    ToolbarChipFlow {
                        ForEach(offered.keys) { entry in chip(entry) }
                        if query.isEmpty, !offered.functionKeys.isEmpty {
                            functionKeysChip
                        }
                        if showsFunctionKeyChips {
                            ForEach(offered.functionKeys) { entry in chip(entry) }
                        }
                    }
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    .listRowBackground(Color.clear)
                } header: {
                    // The ✓ legend only when a shown key carries one.
                    Text(shownKeys.contains(where: \.isOnBar) ? "Keys · ✓ already on this bar" : "Keys")
                }
            }

            if !offered.modifiers.isEmpty {
                Section("Sticky modifiers") {
                    ToolbarChipFlow {
                        ForEach(offered.modifiers) { entry in chip(entry) }
                    }
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    .listRowBackground(Color.clear)
                }
            }

            rowsSection("Combos", offered.combos)
            rowsSection("Custom Keys", offered.customKeys)
            rowsSection("Actions", offered.actions)
            rowsSection("Snippets · insert only", offered.snippets)
        }
    }

    // MARK: Chips

    private var functionKeysChip: some View {
        Button {
            withAnimation { showsFunctionKeys.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("F1…F12")
                Image(systemName: showsFunctionKeys ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .modifier(ToolbarPickerChipChrome(isOnBar: false))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(showsFunctionKeys ? "Hide function keys" : "Show function keys F1 to F12")
    }

    private func chip(_ entry: ToolbarPickerEntry) -> some View {
        Button {
            pick(entry)
        } label: {
            HStack(spacing: 2) {
                AgentToolbarKeyCapLabel(entry.presentation)
                if entry.isOnBar {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.trailing, 6)
                        .accessibilityHidden(true)
                }
            }
            .modifier(ToolbarPickerChipChrome(isOnBar: entry.isOnBar))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(entry.presentation.accessibilityLabel)
        .accessibilityAddTraits(entry.isOnBar ? .isSelected : [])
        .accessibilityHint(entry.isOnBar ? "Already on this bar" : "Adds it to the bar")
    }

    // MARK: Rows

    @ViewBuilder
    private func rowsSection(_ title: String, _ entries: [ToolbarPickerEntry]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in row(entry) }
            }
        }
    }

    private func row(_ entry: ToolbarPickerEntry) -> some View {
        Button {
            pick(entry)
        } label: {
            HStack(spacing: 12) {
                cap(entry)
                    .frame(width: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.presentation.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(verbatim: subtitle(entry))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if entry.isOnBar {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.presentation.accessibilityLabel)
        .accessibilityAddTraits(entry.isOnBar ? .isSelected : [])
        .accessibilityHint(entry.isOnBar ? "Already on this bar" : "Adds it to the bar")
        .contextMenu {
            if case .customKey(let id) = entry.content, let key = store.customKey(id) {
                Button("Edit Custom Key", systemImage: "pencil") { builder = .existing(key) }
            }
        }
    }

    @ViewBuilder
    private func cap(_ entry: ToolbarPickerEntry) -> some View {
        if case .action = entry.content, let systemImage = entry.presentation.systemImage {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Color.accentColor)
        } else {
            ToolbarPreviewCap(presentation: entry.presentation)
                .font(.system(size: 13, weight: .medium))
        }
    }

    private func subtitle(_ entry: ToolbarPickerEntry) -> String {
        [entry.presentation.subtitle, entry.presentation.hint].compactMap { $0 }.joined(separator: " · ")
    }

    private func pick(_ entry: ToolbarPickerEntry) {
        guard !entry.isOnBar else { return }
        if add(entry.content) { dismiss() }
    }
}

/// A ≥ 44 pt chip; items already on the bar get an accent outline.
private struct ToolbarPickerChipChrome: ViewModifier {
    let isOnBar: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .frame(minWidth: ToolbarSettingsChrome.chipMinSize, minHeight: ToolbarSettingsChrome.chipMinSize)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ToolbarSettingsChrome.chipFill))
            .overlay {
                if isOnBar {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
    }
}
