import Foundation

// MARK: - Modifiers

/// The coding name, glyph and spoken name of each toolbar modifier, in the
/// macOS order (⌃⌥⇧) every surface draws and speaks them in.
private enum AgentToolbarModifierToken: String, CaseIterable {
    case control
    case option
    case shift

    var modifier: TerminalKeyModifiers {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        }
    }

    var glyph: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        }
    }

    var spokenName: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .shift: "Shift"
        }
    }

    /// Matches the full keyboard's sticky chips (`TerminalFullKeyboard`).
    var chipTitle: String {
        switch self {
        case .control: "Ctrl"
        case .option: "Alt"
        case .shift: "Shift"
        }
    }
}

extension TerminalKeyModifiers {
    private var toolbarTokens: [AgentToolbarModifierToken] {
        AgentToolbarModifierToken.allCases.filter { contains($0.modifier) }
    }

    /// `["control", "option", "shift"]` subset, always in that order.
    var toolbarCodingNames: [String] { toolbarTokens.map(\.rawValue) }

    /// Nil when any name is unknown, so junk never decodes as "no modifier".
    init?(toolbarCodingNames names: [String]) {
        var modifiers: TerminalKeyModifiers = []
        for name in names {
            guard let token = AgentToolbarModifierToken(rawValue: name) else { return nil }
            modifiers.insert(token.modifier)
        }
        self = modifiers
    }

    /// `⌃⌥⇧` subset.
    var toolbarGlyphs: String { toolbarTokens.map(\.glyph).joined() }

    /// `["Control", "Option", "Shift"]` subset, for VoiceOver.
    var toolbarSpokenNames: [String] { toolbarTokens.map(\.spokenName) }

    /// Sticky-chip title: "Ctrl", "Alt", "Shift" (joined with "+" for a set).
    var toolbarChipTitle: String { toolbarTokens.map(\.chipTitle).joined(separator: "+") }
}

// MARK: - Key chord

/// One key plus the modifiers it is sent with. With no modifiers it is a
/// plain Key; with any modifier it is a Combo, which is sent as exactly this
/// chord and ignores armed sticky modifiers.
///
/// Persisted as an explicit JSON object (`AgentQuickKey` and
/// `TerminalKeyModifiers` are not Codable):
/// `{"key":"tab","mods":["shift"]}`, `{"key":"char","char":"c","mods":["control"]}`,
/// `{"key":"f","n":12,"mods":["option"]}`. There is no string grammar, so
/// `.tab + [.shift]` and `.shiftTab` stay distinct and characters need no
/// escaping.
struct AgentToolbarKeyChord: Hashable, Sendable, Codable {
    let key: AgentQuickKey
    let modifiers: TerminalKeyModifiers

    init(_ key: AgentQuickKey, modifiers: TerminalKeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// A Combo carries at least one modifier; a plain Key carries none.
    var isCombo: Bool { !modifiers.isEmpty }

    /// Whether sending this chord submits a line: it encodes CR (`0D`).
    /// Enter does (Shift-Enter is Ctrl-J), and so does ⌃M.
    var submits: Bool {
        switch key {
        case .enter:
            !modifiers.contains(.shift)
        case .character(let character):
            modifiers.contains(.control) && (character == "m" || character == "M")
        default:
            false
        }
    }

    /// Canonical glyph string: "Esc", "↑", "⌃C", "⌥↵", "⌥F12".
    var glyphs: String {
        guard isCombo else { return Self.plainGlyph(key) }
        return modifiers.toolbarGlyphs + Self.comboKeyGlyph(key)
    }

    /// "Escape", "Control C", "Option F12".
    var accessibilityLabel: String {
        let keyName: String = switch key {
        case .character(let character) where character != " ":
            String(character).uppercased()
        default:
            key.accessibilityLabel
        }
        return (modifiers.toolbarSpokenNames + [keyName]).joined(separator: " ")
    }

    private static func plainGlyph(_ key: AgentQuickKey) -> String {
        switch key {
        case .left: "←"
        case .up: "↑"
        case .down: "↓"
        case .right: "→"
        case .forwardDelete: "Del"
        default: key.title ?? key.accessibilityLabel
        }
    }

    private static func comboKeyGlyph(_ key: AgentQuickKey) -> String {
        switch key {
        case .enter: "↵"
        case .backspace: "⌫"
        case .forwardDelete: "⌦"
        case .character(let character) where character != " ":
            String(character).uppercased()
        default: plainGlyph(key)
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case key
        case char
        case n
        case mods
    }

    private static let characterKeyName = "char"
    private static let functionKeyName = "f"

    private static func name(of key: AgentQuickKey) -> String {
        switch key {
        case .escape: "escape"
        case .tab: "tab"
        case .shiftTab: "shiftTab"
        case .shiftEnter: "shiftEnter"
        case .left: "left"
        case .up: "up"
        case .down: "down"
        case .right: "right"
        case .enter: "enter"
        case .backspace: "backspace"
        case .home: "home"
        case .end: "end"
        case .insert: "insert"
        case .forwardDelete: "forwardDelete"
        case .pageUp: "pageUp"
        case .pageDown: "pageDown"
        case .function: functionKeyName
        case .character: characterKeyName
        }
    }

    private static func namedKey(_ name: String) -> AgentQuickKey? {
        switch name {
        case "escape": .escape
        case "tab": .tab
        case "shiftTab": .shiftTab
        case "shiftEnter": .shiftEnter
        case "left": .left
        case "up": .up
        case "down": .down
        case "right": .right
        case "enter": .enter
        case "backspace": .backspace
        case "home": .home
        case "end": .end
        case "insert": .insert
        case "forwardDelete": .forwardDelete
        case "pageUp": .pageUp
        case "pageDown": .pageDown
        default: nil
        }
    }

    /// A character key types one printable character. Control characters
    /// (Tab, CR, LF, Escape…) have dedicated keys and are rejected, so a
    /// stored character can never smuggle a control byte.
    static func isSendableCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .key)
        let names = try container.decodeIfPresent([String].self, forKey: .mods) ?? []
        guard let modifiers = TerminalKeyModifiers(toolbarCodingNames: names) else {
            throw DecodingError.dataCorruptedError(
                forKey: .mods, in: container, debugDescription: "Unknown modifier in \(names)")
        }
        let key: AgentQuickKey
        switch name {
        case Self.characterKeyName:
            let text = try container.decode(String.self, forKey: .char)
            guard text.count == 1, let character = text.first, Self.isSendableCharacter(character)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .char, in: container, debugDescription: "Not one printable character")
            }
            key = .character(character)
        case Self.functionKeyName:
            let number = try container.decode(Int.self, forKey: .n)
            guard let function = TerminalFunctionKey(rawValue: number) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .n, in: container, debugDescription: "No function key F\(number)")
            }
            key = .function(function)
        default:
            guard let named = Self.namedKey(name) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .key, in: container, debugDescription: "Unknown key \(name)")
            }
            key = named
        }
        self.init(key, modifiers: modifiers)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.name(of: key), forKey: .key)
        switch key {
        case .character(let character):
            try container.encode(String(character), forKey: .char)
        case .function(let function):
            try container.encode(function.rawValue, forKey: .n)
        default:
            break
        }
        try container.encode(modifiers.toolbarCodingNames, forKey: .mods)
    }
}

/// A Combo the Add Item picker offers ready-made. Presets are data, not code
/// paths: picking one adds an ordinary `.key(chord)` item. The strings here
/// are canonical for caps, editor rows, the picker and VoiceOver.
struct AgentToolbarComboPreset: Hashable, Sendable, Identifiable {
    let chord: AgentToolbarKeyChord
    let cap: String
    let name: String
    let hint: String?

    var id: AgentToolbarKeyChord { chord }

    private init(_ key: AgentQuickKey, _ modifiers: TerminalKeyModifiers, cap: String, name: String, hint: String? = nil) {
        chord = AgentToolbarKeyChord(key, modifiers: modifiers)
        self.cap = cap
        self.name = name
        self.hint = hint
    }

    /// No ⌃B "Prefix" preset: a mismatched multiplexer prefix feels like a
    /// dead key, and herdr actions are bound semantically instead.
    static let all: [AgentToolbarComboPreset] = [
        .init(.character("c"), .control, cap: "⌃C", name: "Interrupt", hint: "Stops the running command"),
        .init(.character("d"), .control, cap: "⌃D", name: "End input"),
        .init(.character("z"), .control, cap: "⌃Z", name: "Suspend"),
        .init(.character("l"), .control, cap: "⌃L", name: "Clear screen"),
        .init(.character("r"), .control, cap: "⌃R", name: "Search history"),
        .init(.character("t"), .control, cap: "⌃T", name: "Transcript",
              hint: "Codex prints \"ctrl + t to view transcript\""),
        .init(.character("o"), .control, cap: "⌃O", name: "Expand"),
        .init(.character("u"), .control, cap: "⌃U", name: "Clear line"),
        .init(.character("w"), .control, cap: "⌃W", name: "Delete word"),
        .init(.character("a"), .control, cap: "⌃A", name: "Line start"),
        .init(.character("e"), .control, cap: "⌃E", name: "Line end"),
        .init(.enter, .option, cap: "⌥↵", name: "Option-Return"),
    ]

    static func preset(for chord: AgentToolbarKeyChord) -> AgentToolbarComboPreset? {
        all.first { $0.chord == chord }
    }
}

// MARK: - Actions

/// App actions a toolbar can hold. Close Agent is deliberately absent: a
/// destructive one-tap button stays menu-only.
enum AgentToolbarAction: String, Codable, CaseIterable, Sendable {
    case paste
    case moreMenu
    case toolsKeyboard
    case addImage
    case addFile
    case openTerminal
    case newAgent
    case skills
    case snippets
    case worktreeDetails
    case renameAgent
    case renameWorkspace

    /// The More-menu entry this action runs, for the menu-backed actions.
    var menuItem: AgentActionMenuItem? {
        switch self {
        case .addImage: .addImage
        case .addFile: .addFile
        case .openTerminal: .openTerminal
        case .newAgent: .newAgent
        case .skills: .skills
        case .snippets: .snippets
        case .worktreeDetails: .worktreeDetails
        case .renameAgent: .renameAgent
        case .renameWorkspace: .renameWorkspace
        case .paste, .moreMenu, .toolsKeyboard:
            nil
        }
    }

    var title: String {
        switch self {
        case .paste: "Paste"
        case .moreMenu: "More"
        case .toolsKeyboard: "Tools Keyboard"
        case .addImage, .addFile, .openTerminal, .newAgent, .skills, .snippets,
            .worktreeDetails, .renameAgent, .renameWorkspace:
            menuItem?.title ?? rawValue
        }
    }

    /// Menu-backed actions reuse their menu symbol.
    var systemImage: String {
        switch self {
        case .paste: "doc.on.clipboard"
        case .moreMenu: "ellipsis"
        case .toolsKeyboard: "wrench.and.screwdriver"
        case .addImage, .addFile, .openTerminal, .newAgent, .skills, .snippets,
            .worktreeDetails, .renameAgent, .renameWorkspace:
            menuItem?.systemImage ?? "questionmark"
        }
    }
}

// MARK: - Custom Keys

enum CustomKeyValidationError: Error, Equatable {
    case labelTooLong(limit: Int)
    /// Labels and hints are single-line and carry no control characters.
    case unsupportedLabelCharacters
    case noSteps
    case tooManySteps(limit: Int)
    case unsupportedKeyCharacter
    case emptyText
    case textTooLong(limit: Int)
    case unsupportedControlCharacters
}

/// A user-authored toolbar key, stored once in the catalog's library and
/// referenced from layouts by id (`.customKey(id)`).
struct CustomKey: Hashable, Identifiable, Sendable, Codable {
    static let labelCharacterLimit = 12
    static let maximumKeySteps = 8
    static let textCharacterLimit = Snippet.bodyCharacterLimit

    let id: UUID
    /// Drawn on the cap; at most `labelCharacterLimit` characters. Empty
    /// falls back to the chord glyphs, else the text.
    var label: String
    /// Settings rows and VoiceOver only.
    var hint: String?
    var steps: Steps

    enum Steps: Hashable, Sendable {
        /// 1…`maximumKeySteps` chords, sent to Attach in order like Combos.
        case keys([AgentToolbarKeyChord])
        /// Text for the Composer's delivery owner, optionally followed by one
        /// Enter (which submits like Send).
        case text(String, pressEnter: Bool)
    }

    init(id: UUID = UUID(), label: String, hint: String? = nil, steps: Steps) {
        self.id = id
        self.label = label
        self.hint = hint
        self.steps = steps
    }

    /// Text + Enter, or any key step that encodes CR (Enter, ⌃M). The Sends
    /// tag, the builder warning, the cap's ⏎ and VoiceOver all read this.
    var submits: Bool {
        switch steps {
        case .keys(let chords): chords.contains(where: \.submits)
        case .text(_, let pressEnter): pressEnter
        }
    }

    /// What the cap and rows show when the label is empty.
    var fallbackLabel: String {
        switch steps {
        case .keys(let chords):
            chords.map(\.glyphs).joined(separator: " ")
        case .text(let text, _):
            text.replacingOccurrences(of: "\n", with: " ")
        }
    }

    var displayLabel: String { label.isEmpty ? fallbackLabel : label }

    /// What VoiceOver says for the key itself: the label, else the chords
    /// spelled out ("Control E, Control U"), else the text.
    var spokenLabel: String {
        guard label.isEmpty else { return label }
        return switch steps {
        case .keys(let chords): chords.map(\.accessibilityLabel).joined(separator: ", ")
        case .text: fallbackLabel
        }
    }

    /// The normalized key, or the reason it cannot be saved. Text follows
    /// `Snippet.make`: CR/LF normalized to LF (so only the explicit Enter
    /// toggle can submit), safe scalars only, the Snippet length limit.
    func validated() throws -> CustomKey {
        let label = self.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count <= Self.labelCharacterLimit else {
            throw CustomKeyValidationError.labelTooLong(limit: Self.labelCharacterLimit)
        }
        let hint = self.hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in [label, hint ?? ""] {
            guard TerminalTextSafety.containsOnlySafeScalars(line), !TerminalTextSafety.isMultiline(line),
                !line.contains("\t")
            else { throw CustomKeyValidationError.unsupportedLabelCharacters }
        }
        let steps: Steps
        switch self.steps {
        case .keys(let chords):
            guard !chords.isEmpty else { throw CustomKeyValidationError.noSteps }
            guard chords.count <= Self.maximumKeySteps else {
                throw CustomKeyValidationError.tooManySteps(limit: Self.maximumKeySteps)
            }
            for chord in chords {
                if case .character(let character) = chord.key,
                    !AgentToolbarKeyChord.isSendableCharacter(character)
                {
                    throw CustomKeyValidationError.unsupportedKeyCharacter
                }
            }
            steps = .keys(chords)
        case .text(let text, let pressEnter):
            let normalized = TerminalTextSafety.normalizingNewlines(text)
            guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CustomKeyValidationError.emptyText
            }
            guard normalized.count <= Self.textCharacterLimit else {
                throw CustomKeyValidationError.textTooLong(limit: Self.textCharacterLimit)
            }
            guard TerminalTextSafety.containsOnlySafeScalars(normalized) else {
                throw CustomKeyValidationError.unsupportedControlCharacters
            }
            steps = .text(normalized, pressEnter: pressEnter)
        }
        return CustomKey(id: id, label: label, hint: hint?.isEmpty == false ? hint : nil, steps: steps)
    }

    // MARK: Codable
    // {"id":…,"label":"compact","hint":…,"steps":{"kind":"text","text":"/compact","pressEnter":true}}
    // {"id":…,"label":"clear","steps":{"kind":"keys","keys":[{…},{…}]}}

    private enum CodingKeys: String, CodingKey {
        case id, label, hint, steps
    }

    private enum StepsCodingKeys: String, CodingKey {
        case kind, keys, text, pressEnter
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        let stepsContainer = try container.nestedContainer(keyedBy: StepsCodingKeys.self, forKey: .steps)
        let kind = try stepsContainer.decode(String.self, forKey: .kind)
        switch kind {
        case "keys":
            steps = .keys(try stepsContainer.decode([AgentToolbarKeyChord].self, forKey: .keys))
        case "text":
            steps = .text(
                try stepsContainer.decode(String.self, forKey: .text),
                pressEnter: try stepsContainer.decodeIfPresent(Bool.self, forKey: .pressEnter) ?? false)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: stepsContainer, debugDescription: "Unknown steps kind \(kind)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(hint, forKey: .hint)
        var stepsContainer = container.nestedContainer(keyedBy: StepsCodingKeys.self, forKey: .steps)
        switch steps {
        case .keys(let chords):
            try stepsContainer.encode("keys", forKey: .kind)
            try stepsContainer.encode(chords, forKey: .keys)
        case .text(let text, let pressEnter):
            try stepsContainer.encode("text", forKey: .kind)
            try stepsContainer.encode(text, forKey: .text)
            try stepsContainer.encode(pressEnter, forKey: .pressEnter)
        }
    }
}

// MARK: - Items and layouts

/// One entry on a toolbar. `id` is row identity for lists; the item's
/// identity for duplicate checks is `content` (what it refers to).
struct AgentToolbarItem: Hashable, Identifiable, Sendable, Codable {
    let id: UUID
    var content: Content

    init(id: UUID = UUID(), _ content: Content) {
        self.id = id
        self.content = content
    }

    enum Content: Hashable, Sendable {
        /// These controls write only to the live PTY. Tools Keyboard is excluded:
        /// its History, Skills and Snippets tabs belong to an inventory pane.
        var isTerminalOnlyControl: Bool {
            switch self {
            case .key, .modifier, .action(.paste): true
            default: false
            }
        }

        /// A plain Key (no modifiers) or a Combo.
        case key(AgentToolbarKeyChord)
        /// A sticky modifier chip.
        case modifier(TerminalKeyModifiers)
        case action(AgentToolbarAction)
        /// Insert-only reference; hidden when the Snippet is gone.
        case snippet(Snippet.ID)
        /// Library reference; hidden when the Custom Key is gone.
        case customKey(CustomKey.ID)
    }

    // MARK: Codable
    // {"id":…,"content":{"kind":"key","chord":{…}}}; kinds: key, modifier
    // ("mods"), action ("action"), snippet ("id"), customKey ("id").

    private enum CodingKeys: String, CodingKey {
        case id, content
    }

    private enum ContentCodingKeys: String, CodingKey {
        case kind, chord, mods, action, id
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let content = try container.nestedContainer(keyedBy: ContentCodingKeys.self, forKey: .content)
        let kind = try content.decode(String.self, forKey: .kind)
        switch kind {
        case "key":
            self.content = .key(try content.decode(AgentToolbarKeyChord.self, forKey: .chord))
        case "modifier":
            let names = try content.decode([String].self, forKey: .mods)
            guard let modifiers = TerminalKeyModifiers(toolbarCodingNames: names), !modifiers.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mods, in: content, debugDescription: "Unknown or empty modifier chip")
            }
            self.content = .modifier(modifiers)
        case "action":
            self.content = .action(try content.decode(AgentToolbarAction.self, forKey: .action))
        case "snippet":
            self.content = .snippet(try content.decode(UUID.self, forKey: .id))
        case "customKey":
            self.content = .customKey(try content.decode(UUID.self, forKey: .id))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: content, debugDescription: "Unknown item kind \(kind)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        var content = container.nestedContainer(keyedBy: ContentCodingKeys.self, forKey: .content)
        switch self.content {
        case .key(let chord):
            try content.encode("key", forKey: .kind)
            try content.encode(chord, forKey: .chord)
        case .modifier(let modifiers):
            try content.encode("modifier", forKey: .kind)
            try content.encode(modifiers.toolbarCodingNames, forKey: .mods)
        case .action(let action):
            try content.encode("action", forKey: .kind)
            try content.encode(action, forKey: .action)
        case .snippet(let id):
            try content.encode("snippet", forKey: .kind)
            try content.encode(id, forKey: .id)
        case .customKey(let id):
            try content.encode("customKey", forKey: .kind)
            try content.encode(id, forKey: .id)
        }
    }
}

/// Decodes `Value` or nothing, so one unknown element is dropped without
/// failing the collection around it (#320).
private struct LenientElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// The Toolbar's user items, left to right; they scroll with an edge fade.
/// Message Agent, Terminal Keyboard and Dictate to Agent are fixed at the
/// trailing edge and are not part of the model.
struct AgentToolbarLayout: Hashable, Sendable, Codable {
    var items: [AgentToolbarItem]

    init(items: [AgentToolbarItem]) {
        self.items = items
    }

    func contains(_ content: AgentToolbarItem.Content) -> Bool {
        items.contains { $0.content == content }
    }

    /// Removes every item referring to `content`.
    mutating func remove(_ content: AgentToolbarItem.Content) {
        items.removeAll { $0.content == content }
    }

    /// Same contents in the same order, ignoring row ids.
    func hasSameContents(as other: AgentToolbarLayout) -> Bool {
        items.map(\.content) == other.items.map(\.content)
    }

    /// Drops empty modifier chips and later duplicates (first wins). Applied
    /// on read and on write.
    func normalized() -> AgentToolbarLayout {
        var seen = Set<AgentToolbarItem.Content>()
        return AgentToolbarLayout(items: items.filter { item in
            if case .modifier(let modifiers) = item.content, modifiers.isEmpty { return false }
            return seen.insert(item.content).inserted
        })
    }

    // MARK: Codable
    // {"items":[item…]}; an unknown item is dropped alone.

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try container.decodeIfPresent([LenientElement<AgentToolbarItem>].self, forKey: .items)
            ?? []).compactMap(\.value)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
    }
}

extension AgentToolbarLayout {
    /// Stable, process-independent row ids for the code default.
    private static func defaultItem(_ index: UInt8, _ content: AgentToolbarItem.Content) -> AgentToolbarItem {
        AgentToolbarItem(
            id: UUID(uuid: (
                0x7B, 0x1D, 0xA0, 0x0C, 0x5E, 0x77, 0x40, 0x16,
                0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, index)),
            content)
    }

    private static func key(_ index: UInt8, _ key: AgentQuickKey) -> AgentToolbarItem {
        defaultItem(index, .key(AgentToolbarKeyChord(key)))
    }

    /// The code default. Nothing is stored for a user who never customizes,
    /// so improved defaults reach them for free:
    /// `Esc Tab ⇧Tab ↑ ↓ ← → ⌫ ⇧Enter Paste Enter More Tools`.
    static let `default` = AgentToolbarLayout(items: [
        key(1, .escape), key(2, .tab), key(3, .shiftTab),
        key(4, .up), key(5, .down), key(6, .left), key(7, .right),
        key(8, .backspace), key(9, .shiftEnter),
        defaultItem(10, .action(.paste)),
        key(11, .enter),
        defaultItem(12, .action(.moreMenu)),
        defaultItem(13, .action(.toolsKeyboard)),
    ])
}

// MARK: - Catalog

/// Everything persisted under `AgentToolbarLayoutStore.defaultsKey(for:)`:
/// `{"version":1,"layout":{"items":[…]},"customKeys":[…],"itemSpacing":4}`.
/// A missing layout means "use the code default"; a missing `itemSpacing`
/// means the default spacing. Decoding is lenient per item and per Custom
/// Key: unknown items, actions and invalid keys are dropped on this build;
/// an unreadable spacing falls back to the default.
/// Only an unknown `version` or undecodable JSON fails.
struct AgentToolbarCatalog: Hashable, Sendable, Codable {
    static let version = 1
    static let empty = AgentToolbarCatalog(layout: nil, customKeys: [])

    /// The drawn gap between two Toolbar caps. 12 matches the look before
    /// the gap became the whole setting; 1 lets caps nearly touch.
    static let defaultItemSpacing: Double = 12
    static let itemSpacingRange: ClosedRange<Double> = 1...24
    static let itemSpacingStep: Double = 1

    /// Normalized; nil follows the code default.
    private(set) var layout: AgentToolbarLayout?
    var customKeys: [CustomKey]
    /// Clamped and snapped to the step; nil follows the default.
    private(set) var storedItemSpacing: Double?

    init(layout: AgentToolbarLayout?, customKeys: [CustomKey], itemSpacing: Double? = nil) {
        self.layout = nil
        self.customKeys = customKeys
        self.storedItemSpacing = nil
        setLayout(layout)
        setItemSpacing(itemSpacing)
    }

    var isEmpty: Bool { layout == nil && customKeys.isEmpty && storedItemSpacing == nil }

    var itemSpacing: Double { storedItemSpacing ?? Self.defaultItemSpacing }

    /// Clamps to `itemSpacingRange` and snaps to `itemSpacingStep`;
    /// non-finite becomes the default.
    static func normalizedItemSpacing(_ spacing: Double) -> Double {
        guard spacing.isFinite else { return defaultItemSpacing }
        let snapped = (spacing / itemSpacingStep).rounded() * itemSpacingStep
        return min(max(snapped, itemSpacingRange.lowerBound), itemSpacingRange.upperBound)
    }

    mutating func setItemSpacing(_ spacing: Double?) {
        guard let spacing, spacing.isFinite else {
            storedItemSpacing = nil
            return
        }
        let normalized = Self.normalizedItemSpacing(spacing)
        storedItemSpacing = normalized == Self.defaultItemSpacing ? nil : normalized
    }

    func customKey(_ id: CustomKey.ID) -> CustomKey? {
        customKeys.first { $0.id == id }
    }

    /// Stores `layout` normalized; nil, or a layout equal to the default,
    /// removes the stored one so the Toolbar follows the code default again.
    mutating func setLayout(_ layout: AgentToolbarLayout?) {
        guard let normalized = layout?.normalized(),
            !normalized.hasSameContents(as: .default)
        else {
            self.layout = nil
            return
        }
        self.layout = normalized
    }

    private enum CodingKeys: String, CodingKey {
        case version, layout, customKeys, itemSpacing
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.version else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Unknown catalog version \(version)")
        }
        let layout = try container.decodeIfPresent(LenientElement<AgentToolbarLayout>.self, forKey: .layout)?.value
        var seenKeys = Set<CustomKey.ID>()
        let customKeys = (try container.decodeIfPresent(
            [LenientElement<CustomKey>].self, forKey: .customKeys) ?? [])
            .compactMap { try? $0.value?.validated() }
            .filter { seenKeys.insert($0.id).inserted }
        let itemSpacing = try? container.decodeIfPresent(Double.self, forKey: .itemSpacing)
        self.init(layout: layout, customKeys: customKeys, itemSpacing: itemSpacing)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encode(customKeys, forKey: .customKeys)
        try container.encodeIfPresent(storedItemSpacing, forKey: .itemSpacing)
    }
}

// MARK: - Availability

/// What the current Agent view can run. Resolving a layout against it hides
/// items that would be dead here (never renders a broken item).
/// Disabled-but-visible rules (`canAdd`, opening a Terminal) stay with
/// `AgentActionMenuPolicy.isEnabled`.
struct AgentToolbarAvailability: Equatable, Sendable {
    /// `AgentComposerActions.showSkills != nil`.
    var skillsAvailable: Bool
    /// `AgentComposerActions.showWorktreeDetails != nil`.
    var worktreeDetailsAvailable: Bool
    var snippetIDs: Set<Snippet.ID>
    var customKeyIDs: Set<CustomKey.ID>
    var paneActionsAvailable = true

    func isVisible(_ content: AgentToolbarItem.Content) -> Bool {
        guard paneActionsAvailable || content.isTerminalOnlyControl else { return false }
        switch content {
        case .key:
            return true
        case .modifier(let modifiers):
            return !modifiers.isEmpty
        case .snippet(let id):
            return snippetIDs.contains(id)
        case .customKey(let id):
            return customKeyIDs.contains(id)
        case .action(let action):
            switch action {
            case .skills: return skillsAvailable
            case .worktreeDetails: return worktreeDetailsAvailable
            default: return true
            }
        }
    }

    /// `layout` normalized (duplicates gone) with every item this Agent
    /// cannot run removed.
    func resolve(_ layout: AgentToolbarLayout) -> AgentToolbarLayout {
        AgentToolbarLayout(items: layout.normalized().items.filter { isVisible($0.content) })
    }

    /// Everything the Add Item picker may offer, in picker order: Keys (every
    /// non-character `AgentQuickKey`), Combos (presets), sticky modifier
    /// chips, Actions, Custom Keys, Snippets.
    static func validItems(
        snippetIDs: [Snippet.ID] = [],
        customKeyIDs: [CustomKey.ID] = []
    ) -> [AgentToolbarItem.Content] {
        var keys: [AgentQuickKey] = [
            .escape, .tab, .shiftTab, .enter, .shiftEnter, .backspace,
            .up, .down, .left, .right,
            .home, .end, .pageUp, .pageDown, .insert, .forwardDelete,
        ]
        keys += TerminalFunctionKey.allCases.map { AgentQuickKey.function($0) }
        var contents: [AgentToolbarItem.Content] = keys.map { AgentToolbarItem.Content.key(AgentToolbarKeyChord($0)) }
        contents += AgentToolbarComboPreset.all.map { AgentToolbarItem.Content.key($0.chord) }
        let chips: [TerminalKeyModifiers] = [.control, .option, .shift]
        contents += chips.map { AgentToolbarItem.Content.modifier($0) }
        contents += AgentToolbarAction.allCases.map { AgentToolbarItem.Content.action($0) }
        contents += customKeyIDs.map { AgentToolbarItem.Content.customKey($0) }
        contents += snippetIDs.map { AgentToolbarItem.Content.snippet($0) }
        return contents
    }
}

// MARK: - Presentation

/// UI-agnostic strings for one item, shared by the bars, the editors, the
/// picker and VoiceOver so no surface re-derives them.
struct AgentToolbarItemPresentation: Equatable, Sendable {
    /// Appended after `capLabel` on a Custom Key cap whose `submits` is set.
    static let sendsGlyph = "⏎"

    /// Single-line text for the cap ("Esc", "⌃C", "compact"); arrows carry
    /// a glyph here and a `systemImage` to prefer.
    let capLabel: String
    /// Preferred over `capLabel` when present.
    let systemImage: String?
    /// Editor row / picker title ("Esc", "Interrupt", "Add Image").
    let name: String
    /// "Key", "Combo · ⌃C", "Custom Key · text + Enter", "Custom Key · 2
    /// steps", "Modifier", "Action", "Snippet · inserts".
    let subtitle: String
    /// Preset or Custom Key hint; Settings rows and VoiceOver only.
    let hint: String?
    let accessibilityLabel: String
    /// Sending this item submits a line (drives the "Sends" tag).
    let submits: Bool
    /// Custom Keys that submit draw `sendsGlyph` after the label on the cap.
    let showsSendsGlyph: Bool

    /// Nil when `content` refers to a Snippet or Custom Key that no longer
    /// exists; such items are hidden.
    init?(
        _ content: AgentToolbarItem.Content,
        customKeys: [CustomKey],
        snippets: [Snippet]
    ) {
        switch content {
        case .key(let chord):
            submits = chord.submits
            showsSendsGlyph = false
            if chord.isCombo {
                let preset = AgentToolbarComboPreset.preset(for: chord)
                capLabel = preset?.cap ?? chord.glyphs
                systemImage = nil
                name = preset?.name ?? chord.glyphs
                subtitle = "Combo · \(chord.glyphs)"
                hint = preset?.hint
                accessibilityLabel = preset.map { "\($0.name), \(chord.accessibilityLabel)" }
                    ?? chord.accessibilityLabel
            } else if chord.key == .enter {
                // Two Enters sit side by side in the picker (Enter, ⇧Enter);
                // the one that submits reads as what it does.
                capLabel = "Send"
                systemImage = nil
                name = "Send"
                subtitle = "Key · Enter"
                hint = "Presses Enter, submitting the line"
                accessibilityLabel = "Send, Enter"
            } else {
                capLabel = chord.glyphs
                systemImage = chord.key.systemImageName
                name = chord.key.title ?? chord.key.accessibilityLabel
                subtitle = "Key"
                hint = nil
                accessibilityLabel = chord.key.accessibilityLabel
            }
        case .modifier(let modifiers):
            let spoken = modifiers.toolbarSpokenNames.joined(separator: " ")
            submits = false
            showsSendsGlyph = false
            capLabel = modifiers.toolbarChipTitle
            systemImage = modifiers == .shift ? "shift" : nil
            name = spoken
            subtitle = "Modifier"
            hint = nil
            accessibilityLabel = "\(spoken) modifier"
        case .action(let action):
            submits = false
            showsSendsGlyph = false
            capLabel = action.title
            systemImage = action.systemImage
            name = action.title
            subtitle = "Action"
            hint = nil
            accessibilityLabel = action.title
        case .snippet(let id):
            guard let snippet = snippets.first(where: { $0.id == id }) else { return nil }
            let title = snippet.displayTitle.replacingOccurrences(of: "\n", with: " ")
            submits = false
            showsSendsGlyph = false
            capLabel = title
            systemImage = nil
            name = title
            subtitle = "Snippet · inserts"
            hint = nil
            accessibilityLabel = "Snippet, \(title)"
        case .customKey(let id):
            guard let key = customKeys.first(where: { $0.id == id }) else { return nil }
            submits = key.submits
            showsSendsGlyph = key.submits
            capLabel = key.displayLabel
            systemImage = nil
            name = key.displayLabel
            subtitle = switch key.steps {
            case .text(_, let pressEnter):
                pressEnter ? "Custom Key · text + Enter" : "Custom Key · text"
            case .keys(let chords):
                chords.count == 1 ? "Custom Key · 1 step" : "Custom Key · \(chords.count) steps"
            }
            hint = key.hint
            let parts: [String?] = [key.spokenLabel, key.hint, key.submits ? "sends" : nil]
            accessibilityLabel = parts.compactMap { $0 }.joined(separator: ", ")
        }
    }
}
