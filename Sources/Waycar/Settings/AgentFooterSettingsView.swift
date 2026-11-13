import SwiftUI

/// Settings › Agent Footer copy, phrased once.
enum AgentFooterSettingsCopy {
    static let sizeFooter = "Fewer lines allow larger text. In landscape, iPhone shows the first line only."
    static let usageFooter = "Model, Context, Cost and Tokens/s shown here leave the strip at the top."
    static let resetConfirmation = "The Agent Footer goes back to one line with the Agent name and directory."
    static let unreadableTitle = "Saved Agent Footer can’t be read"
    static let unreadable =
        "Waycar kept the saved data untouched. The Agent Footer shows its default, and editing is "
        + "paused until you reset."
    static let unreadableReset = "Reset Saved Agent Footer"
    static let unreadableResetConfirmation =
        "The unreadable saved Agent Footer is deleted. It returns to its default and can be edited again."
    @MainActor static var noRoom: String {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return "This \(device) has no room below the Toolbar, so the footer doesn’t show."
    }

    @MainActor static var appliesTo: String {
        let device = AgentToolbarDeviceKind.current == .phone ? "iPhone" : "iPad"
        let plural = AgentToolbarDeviceKind.current == .phone ? "iPhones" : "iPads"
        return "Applies to this \(device). Syncs with your other \(plural) through iCloud."
    }

    static func message(for error: any Error) -> String {
        switch error {
        case AgentFooterLayoutStoreError.catalogUnreadable:
            "The saved Agent Footer could not be read, so nothing was changed. \(unreadableReset) to edit again."
        default:
            String(describing: error)
        }
    }
}

/// Settings › Agent Footer: the metadata under the terminal's Toolbar. Every
/// edit is written to the synced store at once; there is no Cancel/Done staging.
struct AgentFooterSettingsView: View {
    let store: AgentFooterLayoutStore

    @State private var errorMessage: String?
    @State private var confirmingReset = false
    /// The line a Custom Field… prompt adds to; nil while no prompt is open.
    @State private var customLine: Int?
    @State private var customName = ""

    private var layout: AgentFooterLayout { store.layout }
    private var isReadOnly: Bool { store.isCatalogUnreadable }

    /// Deterministic sample values, from the Agent List preview's sample Agent.
    private static let sampleContext = AgentFooterContext(
        agent: AgentListFieldsPreview.sampleAgent(hostName: "studio"),
        branch: "main", model: "claude-opus-4", contextText: "42%",
        costText: "$1.20", rateText: "58 tok/s", transport: .mosh,
        progress: AgentProgress(steps: .init(done: 3, total: 7), phase: nil)
            .map { AgentProgressDisplay.estimate($0, isStale: false) })

    var body: some View {
        List {
            if isReadOnly {
                SettingsUnreadableCatalogCard(
                    title: AgentFooterSettingsCopy.unreadableTitle, message: AgentFooterSettingsCopy.unreadable,
                    resetTitle: AgentFooterSettingsCopy.unreadableReset, confirmTitle: "Reset saved Agent Footer?",
                    confirmMessage: AgentFooterSettingsCopy.unreadableResetConfirmation,
                    identifierPrefix: "settings.agentFooter"
                ) {
                    store.resetUnreadableCatalog()
                    errorMessage = nil
                }
            }
            if let errorMessage {
                SettingsErrorSection(message: errorMessage, identifier: "settings.agentFooter.error")
            }
            enabledSection
            previewSection
            sizeSection
            ForEach(layout.lines.indices, id: \.self) { index in
                lineSection(index)
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("Agent Footer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { HelpLink(.agentFooter) }
            ToolbarItem(placement: .primaryAction) {
                Button("Reset") { confirmingReset = true }
                    .disabled(isReadOnly || !store.isCustomized)
                    .accessibilityIdentifier("settings.agentFooter.reset")
            }
        }
        .quietCancelDialog("Reset the Agent Footer?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset to Default", role: .destructive) { perform { try store.resetLayout() } }
            Button("Cancel", role: .cancel) {}.tint(Brand.Colors.quietAction)
        } message: {
            Text(AgentFooterSettingsCopy.resetConfirmation)
        }
        .alert(
            "Custom Field",
            isPresented: Binding(get: { customLine != nil }, set: { if !$0 { customLine = nil } })
        ) {
            TextField("$custom_name", text: $customName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { addCustomField() }
                .disabled(customField == nil)
            Button("Cancel", role: .cancel) {}.tint(Brand.Colors.quietAction)
        } message: {
            Text(AgentLayoutTokensEditing.customFieldHelp)
        }
    }

    // MARK: Sections

    private var enabledSection: some View {
        Section {
            Toggle(
                "Show Agent Footer",
                isOn: Binding(get: { layout.isEnabled }, set: { enabled in edit { $0.isEnabled = enabled } }))
                .accessibilityIdentifier("settings.agentFooter.enabled")
        } footer: {
            if Self.hasNoBottomInset {
                Text(AgentFooterSettingsCopy.appliesTo + "\n\n" + AgentFooterSettingsCopy.noRoom)
            } else {
                Text(AgentFooterSettingsCopy.appliesTo)
            }
        }
        .disabled(isReadOnly)
    }

    /// Home-button devices have no bottom safe area, so the footer never draws there.
    private static var hasNoBottomInset: Bool {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        return window.map { $0.safeAreaInsets.bottom == 0 } ?? false
    }

    private var previewSection: some View {
        let lines = AgentFooterRenderer.render(layout: layout, context: Self.sampleContext)
        let lineCount = layout.shownLines(maximumLines: AgentFooterLayout.maximumLines).count
        return Section {
            AgentFooterStrip(
                lines: lines,
                pointSize: AgentFooterLayout.pointSize(layout.textSize, lineCount: max(1, lineCount)))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .environment(\.colorScheme, .dark)
                .allowsHitTesting(false)
        } header: {
            Text("Preview")
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var sizeSection: some View {
        Section {
            LabeledContent("Lines") {
                Picker(
                    "Lines",
                    selection: Binding(get: { layout.lineCount }, set: { count in edit { $0.setLineCount(count) } })
                ) {
                    ForEach(1...AgentFooterLayout.maximumLines, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("settings.agentFooter.lines")
            }
            LabeledContent("Text Size") {
                Picker(
                    "Text Size",
                    selection: Binding(get: { layout.textSize }, set: { size in edit { $0.textSize = size } })
                ) {
                    ForEach(AgentFooterTextSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("settings.agentFooter.textSize")
            }
        } header: {
            Text("Size")
        } footer: {
            Text(AgentFooterSettingsCopy.sizeFooter)
        }
        .disabled(isReadOnly)
    }

    private func lineSection(_ index: Int) -> some View {
        let fields = layout.lines[index]
        var move: ((IndexSet, Int) -> Void)?
        var delete: ((IndexSet) -> Void)?
        if !isReadOnly {
            move = { source, destination in edit { $0.lines[index].move(fromOffsets: source, toOffset: destination) } }
            delete = { offsets in edit { $0.lines[index].remove(atOffsets: offsets) } }
        }
        return Section {
            ForEach(Array(fields.enumerated()), id: \.element) { position, field in
                fieldRow(field, line: index, position: position, count: fields.count)
            }
            .onMove(perform: move)
            .onDelete(perform: delete)
            addMenu(line: index, isFull: fields.count >= AgentFooterLayout.maximumFieldsPerLine)
        } header: {
            Text("Line \(index + 1)")
        } footer: {
            if fields.contains(where: \.isUsage) {
                Text(AgentFooterSettingsCopy.usageFooter)
            }
        }
    }

    /// One field row with the Toolbar editor's handle, context menu and VoiceOver actions.
    private func fieldRow(_ field: AgentFooterField, line: Int, position: Int, count: Int) -> some View {
        let canMoveUp = !isReadOnly && position > 0
        let canMoveDown = !isReadOnly && position < count - 1
        let moveUp = { edit { $0.lines[line].swapAt(position, position - 1) } }
        let moveDown = { edit { $0.lines[line].swapAt(position, position + 1) } }
        let remove = { edit { $0.lines[line].remove(at: position) } }
        return HStack {
            Label(field.title, systemImage: field.systemImage)
            Spacer()
            if !isReadOnly {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .moveDisabled(isReadOnly)
        .deleteDisabled(isReadOnly)
        .contextMenu {
            if canMoveUp { Button("Move Up", systemImage: "arrow.up", action: moveUp) }
            if canMoveDown { Button("Move Down", systemImage: "arrow.down", action: moveDown) }
            if !isReadOnly { Button("Remove", systemImage: "minus.circle", role: .destructive, action: remove) }
        }
        .accessibilityActions {
            if canMoveUp { Button("Move Up", action: moveUp) }
            if canMoveDown { Button("Move Down", action: moveDown) }
            if !isReadOnly { Button("Remove", action: remove) }
        }
    }

    private func addMenu(line: Int, isFull: Bool) -> some View {
        Menu {
            ForEach(AgentFooterField.offered.filter { !layout.contains($0) }, id: \.self) { field in
                Button(field.title, systemImage: field.systemImage) { edit { $0.lines[line].append(field) } }
            }
            Divider()
            Button("Custom Field…", systemImage: "dollarsign") {
                customName = ""
                customLine = line
            }
        } label: {
            Label {
                Text("Add Field")
            } icon: {
                Image(systemName: "plus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.title3)
            }
        }
        .disabled(isReadOnly || isFull)
        .accessibilityIdentifier("settings.agentFooter.line\(line + 1).add")
    }

    // MARK: Edits

    /// The typed custom field; nil when invalid or already in the layout.
    private var customField: AgentFooterField? {
        guard let token = AgentLayoutTokensEditing.customToken(named: customName) else { return nil }
        let field = AgentFooterField.row(token)
        return layout.contains(field) ? nil : field
    }

    private func addCustomField() {
        guard let line = customLine, let field = customField, line < layout.lineCount else { return }
        edit { $0.lines[line].append(field) }
    }

    private func edit(_ change: (inout AgentFooterLayout) -> Void) {
        var edited = layout
        change(&edited)
        perform { try store.setLayout(edited) }
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            errorMessage = nil
        } catch {
            errorMessage = AgentFooterSettingsCopy.message(for: error)
        }
    }
}
