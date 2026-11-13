import SwiftUI

// MARK: - Draft

/// What the builder opens on: a new key (added to the Toolbar when saved,
/// unless the user turns that off) or a library key to edit.
enum CustomKeyBuilderTarget: Identifiable, Hashable {
    case new
    case existing(CustomKey)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let key): key.id.uuidString
        }
    }
}

enum CustomKeyDraftError: Error, Equatable {
    /// A key step has no key chosen yet; `step` is 1-based.
    case missingKey(step: Int)
}

/// The builder's editable state. Both shapes are kept while the user flips
/// the segmented control, so switching back loses nothing; only the chosen
/// shape is saved.
struct CustomKeyDraft: Equatable {
    enum Kind: Hashable, Sendable {
        case keys
        case text
    }

    struct Step: Identifiable, Equatable {
        let id: UUID
        var modifiers: TerminalKeyModifiers
        var key: AgentQuickKey?

        init(id: UUID = UUID(), modifiers: TerminalKeyModifiers = [], key: AgentQuickKey? = nil) {
            self.id = id
            self.modifiers = modifiers
            self.key = key
        }

        var chord: AgentToolbarKeyChord? {
            key.map { AgentToolbarKeyChord($0, modifiers: modifiers) }
        }
    }

    let id: UUID
    let isNew: Bool
    var kind: Kind
    var label: String
    var hint: String
    var steps: [Step]
    var text: String
    var pressEnter: Bool
    /// Whether saving puts the key on the Toolbar. On for a new key; an
    /// existing key keeps its place (the builder shows no toggle for it).
    var addToBar: Bool

    init(target: CustomKeyBuilderTarget, isOnBar: Bool = false) {
        switch target {
        case .new:
            id = UUID()
            isNew = true
            kind = .keys
            label = ""
            hint = ""
            steps = [Step()]
            text = ""
            pressEnter = false
            addToBar = true
        case .existing(let key):
            id = key.id
            isNew = false
            label = key.label
            hint = key.hint ?? ""
            addToBar = isOnBar
            switch key.steps {
            case .keys(let chords):
                kind = .keys
                steps = chords.map { Step(modifiers: $0.modifiers, key: $0.key) }
                text = ""
                pressEnter = false
            case .text(let value, let enter):
                kind = .text
                steps = [Step()]
                text = value
                pressEnter = enter
            }
        }
    }

    var canAddStep: Bool { steps.count < CustomKey.maximumKeySteps }

    /// Appends an empty step; returns its index, or nil at the step limit.
    @discardableResult
    mutating func addStep() -> Int? {
        guard canAddStep else { return nil }
        steps.append(Step())
        return steps.count - 1
    }

    /// Removes a step; the last one stays so there is always one to edit.
    mutating func removeStep(at index: Int) {
        guard steps.count > 1, steps.indices.contains(index) else { return }
        steps.remove(at: index)
    }

    /// The key as it would draw now; key steps without a key are skipped.
    var previewKey: CustomKey {
        let shape: CustomKey.Steps = switch kind {
        case .keys: .keys(steps.compactMap(\.chord))
        case .text: .text(text, pressEnter: pressEnter)
        }
        return CustomKey(id: id, label: label, hint: hint.isEmpty ? nil : hint, steps: shape)
    }

    /// "sends ⌃S", "sends ⌃E, then ⌃U", "types “/compact”, then presses Enter".
    var summary: String {
        switch kind {
        case .keys:
            let chords = steps.compactMap(\.chord).map(\.glyphs)
            guard !chords.isEmpty else { return "choose a key" }
            return "sends " + chords.joined(separator: ", then ")
        case .text:
            let line = text.replacingOccurrences(of: "\n", with: " ")
            let typed = line.isEmpty ? "types your text" : "types “\(line)”"
            return pressEnter ? "\(typed), then presses Enter" : typed
        }
    }

    /// The validated key, or why it cannot be saved.
    func makeKey() throws -> CustomKey {
        if kind == .keys, let missing = steps.firstIndex(where: { $0.key == nil }) {
            throw CustomKeyDraftError.missingKey(step: missing + 1)
        }
        return try previewKey.validated()
    }

    /// Whether `makeKey()` would succeed; gates the Add/Save button.
    var canSave: Bool { (try? makeKey()) != nil }
}

// MARK: - Builder

/// Builds or edits one Custom Key: a preview cap, Key Combo or Text, and for
/// a new key an "Add to bar" toggle. Saving validates and writes the library
/// and the layout at once (`upsertCustomKey`).
struct CustomKeyBuilderView: View {
    let store: AgentToolbarLayoutStore
    let target: CustomKeyBuilderTarget
    /// Called after a successful save, before the sheet closes.
    var onSave: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CustomKeyDraft
    @State private var selectedStep = 0
    @State private var showsFunctionKeys = false
    @State private var errorMessage: String?

    init(store: AgentToolbarLayoutStore, target: CustomKeyBuilderTarget, onSave: @escaping () -> Void = {}) {
        self.store = store
        self.target = target
        self.onSave = onSave
        let isOnBar = if case .existing(let key) = target { store.isOnBar(key.id) } else { false }
        _draft = State(initialValue: CustomKeyDraft(target: target, isOnBar: isOnBar))
        if case .existing(let key) = target, case .keys(let chords) = key.steps {
            let usesFunctionKey = chords.contains { chord in
                if case .function = chord.key { return true }
                return false
            }
            _showsFunctionKeys = State(initialValue: usesFunctionKey)
        }
    }

    private static let gridKeys: [AgentQuickKey] = [
        .escape, .tab, .enter, .backspace,
        .up, .down, .left, .right,
        .home, .end, .pageUp, .pageDown,
    ]

    private var step: CustomKeyDraft.Step {
        draft.steps.indices.contains(selectedStep) ? draft.steps[selectedStep] : draft.steps[0]
    }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                kindSection
                labelSection
                switch draft.kind {
                case .keys: keySections
                case .text: textSections
                }
                if draft.isNew { addToBarSection }
                if draft.kind == .keys { addStepSection }
                if let errorMessage {
                    Section {
                        Text(verbatim: errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settings.toolbars.builder.error")
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Custom Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Brand.Colors.quietAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.isNew ? "Add" : "Save") { save() }
                        .modifier(ProminentConfirmation())
                        .disabled(store.isCatalogUnreadable || !draft.canSave)
                        .accessibilityIdentifier("settings.toolbars.builder.save")
                }
            }
            .onChange(of: draft) { errorMessage = nil }
            .onChange(of: draft.label) { _, label in
                // Hard limit while typing, not only at save.
                if label.count > CustomKey.labelCharacterLimit {
                    draft.label = String(label.prefix(CustomKey.labelCharacterLimit))
                }
            }
        }
        // Sheets don't take the app root's tint; Toggles default to green.
        .tint(Brand.Colors.accent)
    }

    // MARK: Sections

    private var previewSection: some View {
        let key = draft.previewKey
        return Section {
            VStack(spacing: 8) {
                previewCap(key)
                Text(verbatim: draft.summary)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(ToolbarSettingsChrome.barFill))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(ToolbarSettingsChrome.barStroke, lineWidth: 0.5))
            .accessibilityElement(children: .combine)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func previewCap(_ key: CustomKey) -> some View {
        if !key.displayLabel.isEmpty,
            let presentation = AgentToolbarItemPresentation(
                .customKey(key.id), customKeys: [key], snippets: [])
        {
            ToolbarPreviewCap(presentation: presentation, isHighlighted: true)
                .font(.system(size: 20, weight: .medium))
        } else {
            Text("Label")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: ToolbarSettingsChrome.capRadius, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])))
        }
    }

    private var kindSection: some View {
        Section {
            Picker("Kind", selection: $draft.kind) {
                Text("Key Combo").tag(CustomKeyDraft.Kind.keys)
                Text("Text").tag(CustomKeyDraft.Kind.text)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("settings.toolbars.builder.kind")
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var labelSection: some View {
        Section {
            LabeledContent("Label") {
                TextField("Label", text: $draft.label, prompt: Text("On the key"))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.toolbars.builder.label")
            }
            LabeledContent("Hint") {
                TextField("Hint", text: $draft.hint, prompt: Text("Optional"))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.toolbars.builder.hint")
            }
        } footer: {
            Text(
                "The label is drawn on the key, up to \(CustomKey.labelCharacterLimit) characters; "
                    + "empty shows the keys or the text. The hint appears in Settings and VoiceOver.")
        }
    }

    // MARK: Key Combo

    @ViewBuilder
    private var keySections: some View {
        if draft.steps.count > 1 { stepsSection }
        Section("Modifiers") {
            HStack(spacing: 8) {
                modifierChip(.control)
                modifierChip(.option)
                modifierChip(.shift)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        Section("Key") {
            VStack(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Self.gridKeys, id: \.self) { key in keyChip(key) }
                }
                HStack(spacing: 8) {
                    functionKeysToggle
                    characterField
                }
                if showsFunctionKeys {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(TerminalFunctionKey.allCases, id: \.self) { key in keyChip(.function(key)) }
                    }
                }
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        if draft.previewKey.submits {
            Section {
                warning(ToolbarSettingsCopy.keyStepSubmitsWarning)
            }
            .listRowBackground(Color.clear)
        }
    }

    private var stepsSection: some View {
        Section {
            ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                Button {
                    selectedStep = index
                } label: {
                    HStack {
                        Text("\(index + 1)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 24, alignment: .leading)
                        Text(verbatim: step.chord?.glyphs ?? "Choose a key")
                            .foregroundStyle(step.chord == nil ? .secondary : .primary)
                        Spacer()
                        if index == selectedStep {
                            Image(systemName: "pencil")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(index + 1), \(step.chord?.accessibilityLabel ?? "no key")")
                .accessibilityAddTraits(index == selectedStep ? .isSelected : [])
            }
            .onDelete { offsets in
                for index in offsets.sorted(by: >) { draft.removeStep(at: index) }
                selectedStep = min(selectedStep, draft.steps.count - 1)
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("Steps are sent in order. The keys below edit the selected step.")
        }
    }

    private func modifierChip(_ modifier: TerminalKeyModifiers) -> some View {
        let isOn = step.modifiers.contains(modifier)
        return Button {
            updateStep { $0.modifiers.formSymmetricDifference(modifier) }
        } label: {
            Text(verbatim: "\(modifier.toolbarGlyphs) \(modifier.toolbarChipTitle)")
                .frame(maxWidth: .infinity)
                .modifier(BuilderChipChrome(isSelected: isOn))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(modifier.toolbarSpokenNames.joined())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func keyChip(_ key: AgentQuickKey) -> some View {
        let isSelected = step.key == key
        return Button {
            updateStep { $0.key = key }
        } label: {
            Group {
                if key == .backspace {
                    Image(systemName: "delete.left")
                } else if let image = key.systemImageName {
                    Image(systemName: image)
                } else {
                    Text(verbatim: key.title ?? key.accessibilityLabel)
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(BuilderChipChrome(isSelected: isSelected))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var functionKeysToggle: some View {
        let isSelected: Bool = if case .function = step.key { true } else { false }
        return Button {
            withAnimation { showsFunctionKeys.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("F1–F12")
                Image(systemName: showsFunctionKeys ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .fixedSize()
            .modifier(BuilderChipChrome(isSelected: isSelected))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(showsFunctionKeys ? "Hide function keys" : "Show function keys")
    }

    private var characterField: some View {
        let character: Character? = if case .character(let value) = step.key { value } else { nil }
        return HStack(spacing: 6) {
            Text("Character:")
                .fixedSize()
                .foregroundStyle(character == nil ? Color.secondary : Color.accentColor)
            TextField(
                "a",
                text: Binding(
                    get: { character.map(String.init) ?? "" },
                    set: { newValue in
                        guard let last = newValue.last else { return }
                        updateStep { $0.key = .character(last) }
                    }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Character key")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: ToolbarSettingsChrome.chipMinSize)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(character == nil ? ToolbarSettingsChrome.chipFill : Color.accentColor.opacity(0.18)))
        .overlay {
            if character != nil {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
    }

    private var addStepSection: some View {
        Section {
            Button {
                if let index = draft.addStep() { selectedStep = index }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Step")
                        Text(draft.canAddStep
                            ? "Another key after this one"
                            : "At most \(CustomKey.maximumKeySteps) steps")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.title3)
                }
            }
            .disabled(!draft.canAddStep)
            .accessibilityIdentifier("settings.toolbars.builder.addStep")
        }
    }

    // MARK: Text

    @ViewBuilder
    private var textSections: some View {
        Section("Text") {
            TextField("/compact", text: $draft.text, axis: .vertical)
                .lineLimit(1...8)
                .fontDesign(.monospaced)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.toolbars.builder.text")
        }
        Section {
            Toggle(isOn: $draft.pressEnter) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Press Enter After")
                    Text("Sends like the Send button")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings.toolbars.builder.pressEnter")
        } footer: {
            if draft.pressEnter {
                warning(ToolbarSettingsCopy.pressEnterWarning)
            } else {
                Text("Inserts the text without sending it, like a Snippet.")
            }
        }
    }

    // MARK: Add to bar

    private var addToBarSection: some View {
        Section {
            Toggle("Add to bar", isOn: $draft.addToBar)
                .accessibilityIdentifier("settings.toolbars.builder.addToBar")
        } footer: {
            Text(ToolbarSettingsCopy.addToBarFooter)
        }
    }

    // MARK: Helpers

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(ToolbarSettingsChrome.warning)
    }

    private func updateStep(_ change: (inout CustomKeyDraft.Step) -> Void) {
        let index = draft.steps.indices.contains(selectedStep) ? selectedStep : 0
        change(&draft.steps[index])
    }

    private func save() {
        do {
            let key = try draft.makeKey()
            try store.upsertCustomKey(key, addToBar: draft.addToBar)
            onSave()
            dismiss()
        } catch {
            errorMessage = ToolbarSettingsCopy.message(for: error)
        }
    }
}

/// The sheet's confirming button: prominent glass on iOS 26, the system's
/// bold confirmation style before it.
private struct ProminentConfirmation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content
        }
    }
}

/// A ≥ 44 pt builder chip; the selected one takes the accent.
private struct BuilderChipChrome: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .font(.body.weight(.medium))
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .frame(minHeight: ToolbarSettingsChrome.chipMinSize)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : ToolbarSettingsChrome.chipFill))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
    }
}
