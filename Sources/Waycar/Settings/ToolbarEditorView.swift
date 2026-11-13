import SwiftUI

// MARK: - Editing rules

/// Conditions the editor calls out under its list.
enum ToolbarEditorNote: Hashable, Sendable {
    /// The Toolbar has no Enter key.
    case enterRemoved
}

/// The editor's layout edits as pure functions. Every result is normalized;
/// the store normalizes again on write.
enum ToolbarEditing {
    /// Removes a row.
    static func removing(_ id: AgentToolbarItem.ID, from layout: AgentToolbarLayout) -> AgentToolbarLayout {
        var edited = layout
        edited.items.removeAll { $0.id == id }
        return edited.normalized()
    }

    /// Reorders rows (`.onMove` offsets).
    static func moving(
        fromOffsets source: IndexSet, toOffset destination: Int, layout: AgentToolbarLayout
    ) -> AgentToolbarLayout {
        var edited = layout
        edited.items.move(fromOffsets: source, toOffset: destination)
        return edited.normalized()
    }

    /// Moves a row one place up (`by: -1`) or down (`by: 1`): the non-drag
    /// reorder path. Nil at either end.
    static func steppingItem(
        _ id: AgentToolbarItem.ID, by step: Int, layout: AgentToolbarLayout
    ) -> AgentToolbarLayout? {
        guard let index = layout.items.firstIndex(where: { $0.id == id }) else { return nil }
        let neighbor = index + step
        guard layout.items.indices.contains(neighbor) else { return nil }
        // `move(fromOffsets:toOffset:)` inserts before the destination offset.
        let destination = step > 0 ? neighbor + 1 : neighbor
        return moving(fromOffsets: IndexSet(integer: index), toOffset: destination, layout: layout)
    }

    /// Appends `content` to the end of the items, or nil when the bar
    /// already has it.
    static func adding(_ content: AgentToolbarItem.Content, to layout: AgentToolbarLayout) -> AgentToolbarLayout? {
        guard !layout.contains(content) else { return nil }
        var edited = layout
        edited.items.append(AgentToolbarItem(content))
        return edited.normalized()
    }

    static func notes(for layout: AgentToolbarLayout) -> Set<ToolbarEditorNote> {
        layout.contains(.key(AgentToolbarKeyChord(.enter))) ? [] : [.enterRemoved]
    }

    /// The row subtitle: the shared presentation subtitle, with what the bar
    /// adds about the item.
    static func rowSubtitle(
        for content: AgentToolbarItem.Content, presentation: AgentToolbarItemPresentation
    ) -> String {
        switch content {
        case .action(.toolsKeyboard):
            "Action · swaps in the tools keyboard"
        case .action(.skills):
            "Action · Agents only"
        case .modifier:
            "Modifier · applies to the next key"
        case .key(let chord) where chord == AgentToolbarKeyChord(.backspace):
            "Key · repeats while held"
        default:
            presentation.subtitle
        }
    }
}

// MARK: - Editor

/// The Toolbar editor's List sections: a live preview of the single bar,
/// "Your items · scroll" (⊖, drag reorder, Move Up/Down, Add Item…), and the
/// fixed Message Agent, Terminal Keyboard and Dictate to Agent rows. Every
/// edit is written to the store at once; there is no Cancel/Done staging.
///
/// This view is several rows of its host's List, so a modifier on it lands
/// on every lazy row: a sheet attached here would be presented by whichever
/// row won, and dismissed when the List drops that row on scroll (#55). The
/// rows only set `addingItem` and `builder`; the hosting List presents them.
struct ToolbarEditorView: View {
    let store: AgentToolbarLayoutStore
    let snippets: SnippetStore
    /// Items added while the page is open get a "New" tag.
    @Binding var added: Set<AgentToolbarItem.Content>
    @Binding var errorMessage: String?

    /// Set to open the Add Item picker; the hosting List presents it.
    @Binding var addingItem: Bool
    /// Set to open a Custom Key's builder; the hosting List presents it.
    @Binding var builder: CustomKeyBuilderTarget?
    /// The widest row cap measured, so every row's icon column and text line
    /// up without reserving room for caps the bar does not have.
    @State private var capColumnWidth: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The ⊖ / lock column: the symbol's width, as in the system's edit mode.
    private static let leadingControlWidth: CGFloat = 28

    private var layout: AgentToolbarLayout { store.layout }
    private var isReadOnly: Bool { store.isCatalogUnreadable }
    private var source: ToolbarPreviewSource { ToolbarPreviewSource(store: store, snippets: snippets.snippets) }

    var body: some View {
        previewSection
        spacingSection
        itemsSection
        fixedSection
    }

    // MARK: Sections

    private var previewSection: some View {
        Section {
            ToolbarPreviewPanel {
                ToolbarPreviewStatusLine()
                ToolbarBarPreview(source: source, highlighted: added)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview")
        } header: {
            Text("Preview")
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var spacingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Spacing")
                Slider(
                    value: Binding(
                        get: { store.itemSpacing },
                        set: { setItemSpacing($0) }),
                    in: AgentToolbarCatalog.itemSpacingRange,
                    step: AgentToolbarCatalog.itemSpacingStep
                ) {
                    Text("Spacing")
                } minimumValueLabel: {
                    Text("Compact").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Wide").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityValue("\(Int(store.itemSpacing)) points")
                .accessibilityIdentifier("settings.toolbars.editor.spacing")
            }
            .disabled(isReadOnly)
        }
    }

    private var itemsSection: some View {
        let items = layout.items
        var move: ((IndexSet, Int) -> Void)?
        if !isReadOnly {
            move = { source, destination in
                apply(ToolbarEditing.moving(fromOffsets: source, toOffset: destination, layout: layout))
            }
        }
        return Section {
            ForEach(items) { item in
                row(item)
                    .moveDisabled(isReadOnly)
            }
            .onMove(perform: move)
            addItemRow
        } header: {
            HStack {
                Text(ToolbarSettingsCopy.itemsHeader)
                Spacer()
                Text(items.count == 1 ? "1 item" : "\(items.count) items")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(ToolbarSettingsCopy.itemsFooter)
                if ToolbarEditing.notes(for: layout).contains(.enterRemoved) {
                    Label(ToolbarSettingsCopy.enterRemovedWarning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ToolbarSettingsChrome.warning)
                        .accessibilityIdentifier("settings.toolbars.editor.enterRemoved")
                }
            }
        }
    }

    private var fixedSection: some View {
        Section {
            ForEach(ToolbarFixedControl.allCases) { control in
                fixedRow(control)
            }
        } header: {
            HStack {
                Text(ToolbarSettingsCopy.fixedHeader)
                Spacer()
                Text("Can’t be removed")
            }
        } footer: {
            Text(ToolbarSettingsCopy.fixedFooter)
        }
    }

    private var addItemRow: some View {
        Button {
            addingItem = true
        } label: {
            Label {
                Text("Add Item…")
            } icon: {
                Image(systemName: "plus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.title3)
            }
        }
        .disabled(isReadOnly)
        .accessibilityIdentifier("settings.toolbars.editor.add")
    }

    // MARK: Rows

    private func row(_ item: AgentToolbarItem) -> some View {
        let presentation = source.presentation(item.content)
        let movedUp = isReadOnly ? nil : ToolbarEditing.steppingItem(item.id, by: -1, layout: layout)
        let movedDown = isReadOnly ? nil : ToolbarEditing.steppingItem(item.id, by: 1, layout: layout)
        let name = presentation?.name ?? missingName(item.content)
        return HStack(spacing: 10) {
            removeControl(item, name: name)
            rowContent(item, presentation: presentation, name: name)
            if !isReadOnly {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contextMenu {
            if let movedUp {
                Button("Move Up", systemImage: "arrow.up") { apply(movedUp) }
            }
            if let movedDown {
                Button("Move Down", systemImage: "arrow.down") { apply(movedDown) }
            }
            if case .customKey(let id) = item.content, let key = store.customKey(id) {
                Button("Edit Custom Key", systemImage: "pencil") { builder = .existing(key) }
            }
            if !isReadOnly {
                Button("Remove", systemImage: "minus.circle", role: .destructive) { remove(item) }
            }
        }
        .accessibilityActions {
            if let movedUp {
                Button("Move Up") { apply(movedUp) }
            }
            if let movedDown {
                Button("Move Down") { apply(movedDown) }
            }
            if !isReadOnly {
                Button("Remove") { remove(item) }
            }
        }
    }

    @ViewBuilder
    private func removeControl(_ item: AgentToolbarItem, name: String) -> some View {
        if isReadOnly {
            Color.clear.frame(width: Self.leadingControlWidth)
        } else {
            Button {
                remove(item)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .font(.title3)
                    .frame(width: Self.leadingControlWidth, height: InputChromeLayout.minimumHitSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(name)")
        }
    }

    @ViewBuilder
    private func rowContent(
        _ item: AgentToolbarItem, presentation: AgentToolbarItemPresentation?, name: String
    ) -> some View {
        let content = HStack(spacing: 12) {
            capColumn {
                if let presentation {
                    ToolbarPreviewCap(presentation: presentation, isHighlighted: added.contains(item.content))
                } else {
                    Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if presentation?.submits == true { ToolbarTag(.sends) }
                    if added.contains(item.content) { ToolbarTag(.new) }
                }
                subtitleText(subtitle(item.content, presentation: presentation))
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        if case .customKey(let id) = item.content, let key = store.customKey(id) {
            // Tapping a Custom Key row opens its builder; the row reads like
            // every other row rather than as a tinted button.
            content
                .onTapGesture { builder = .existing(key) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Edits this Custom Key")
                .accessibilityAction { builder = .existing(key) }
                .accessibilityIdentifier("settings.toolbars.editor.customKey.\(id.uuidString)")
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }

    private func fixedRow(_ control: ToolbarFixedControl) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: Self.leadingControlWidth)
            HStack(spacing: 12) {
                capColumn {
                    Image(systemName: control.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .frame(minWidth: InputChromeLayout.keyCapMinWidth, minHeight: 30)
                        .background(
                            RoundedRectangle(cornerRadius: ToolbarSettingsChrome.capRadius, style: .continuous)
                                .fill(ToolbarSettingsChrome.capFill))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(control.title).lineLimit(1)
                        ToolbarTag(.fixed)
                    }
                    subtitleText(control.subtitle)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The cap column: as wide as the widest cap on the page.
    private func capColumn<Cap: View>(@ViewBuilder _ cap: () -> Cap) -> some View {
        cap()
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if width > capColumnWidth { capColumnWidth = width }
            }
            .frame(width: max(capColumnWidth, InputChromeLayout.keyCapMinWidth))
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            .accessibilityHidden(true)
    }

    private func subtitleText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(0.85)
    }

    private func subtitle(_ content: AgentToolbarItem.Content, presentation: AgentToolbarItemPresentation?) -> String {
        guard let presentation else { return "Deleted · hidden on the bar" }
        return ToolbarEditing.rowSubtitle(for: content, presentation: presentation)
    }

    private func missingName(_ content: AgentToolbarItem.Content) -> String {
        switch content {
        case .snippet: "Missing Snippet"
        case .customKey: "Missing Custom Key"
        default: "Unknown Item"
        }
    }

    // MARK: Edits

    private func apply(_ edited: AgentToolbarLayout) {
        do {
            try store.setLayout(edited)
            errorMessage = nil
        } catch {
            errorMessage = ToolbarSettingsCopy.message(for: error)
        }
    }

    private func setItemSpacing(_ spacing: Double) {
        do {
            try store.setItemSpacing(spacing)
            errorMessage = nil
        } catch {
            errorMessage = ToolbarSettingsCopy.message(for: error)
        }
    }

    private func remove(_ item: AgentToolbarItem) {
        added.remove(item.content)
        apply(ToolbarEditing.removing(item.id, from: layout))
    }
}
