import SwiftUI

// MARK: - Copy

/// Every string the Toolbar screens share, so the page, the picker and the
/// Custom Key builder never phrase the same thing twice.
enum ToolbarSettingsCopy {
    static let itemsHeader = "Your Items · Scroll"
    static let itemsFooter = "Drag ≡ to reorder · ⊖ removes. Long-press a row to move it up or down."
    static let fixedHeader = "Always on the Right"
    static let fixedFooter =
        "Message Agent and Terminal Keyboard are exclusive: opening one closes the other."
    static let barsFooter =
        "One Toolbar for each device type. Items an Agent cannot use (Skills on a Shell, "
        + "Dictate to Agent before iOS 26) are hidden there."
    static let customKeysFooter =
        "Keys you build yourself. Presets like ⌃C live under Combos. A Custom Key that ends in "
        + "Enter submits like Send — unlike a Snippet, which only inserts. Deleting one removes it "
        + "from the Toolbar."
    static let syncFooter =
        "The Toolbar syncs with iCloud Sync separately for iPhone and iPad, so a reinstall restores it."
    static let resetConfirmation =
        "The Toolbar goes back to its default items and spacing. Your Custom Keys stay in the library but come off the bar."
    static let unreadableTitle = "Saved toolbar can’t be read"
    static let unreadable =
        "Waycar kept the saved data untouched. The Toolbar shows its default, and editing is "
        + "paused until you reset."
    static let unreadableReset = "Reset Saved Toolbar"
    static let unreadableResetConfirmation =
        "The unreadable saved Toolbar and Custom Keys are deleted. The Toolbar returns to its "
        + "default and can be edited again."
    static let enterRemovedWarning =
        "Enter is off the bar. Return on the system keyboard and Enter on the tools keyboard still send it."
    static let addToBarFooter = "Adds the key to the end of the Toolbar. You can move it in the list."

    static let pressEnterWarning =
        "With Enter on, this key submits like Send, without review. If the Agent is Blocked it "
        + "inserts the text without Enter, and it waits until the Agent is ready. Snippets never "
        + "press Enter."
    static let keyStepSubmitsWarning =
        "A step sends Enter, so this key submits whatever is typed in the terminal."

    /// What a Custom Key does, for its Custom Keys row: "“/compact” then
    /// Enter", "⌃E then ⌃U".
    static func customKeySummary(_ key: CustomKey) -> String {
        switch key.steps {
        case .keys(let chords):
            return chords.map(\.glyphs).joined(separator: " then ")
        case .text(let text, let pressEnter):
            let quoted = "“\(text.replacingOccurrences(of: "\n", with: " "))”"
            return pressEnter ? "\(quoted) then Enter" : quoted
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case AgentToolbarLayoutStoreError.catalogUnreadable:
            "The saved toolbar could not be read, so nothing was changed. Reset Saved Toolbar to edit again."
        case AgentToolbarLayoutStoreError.duplicateItem:
            "That item is already on the bar."
        case CustomKeyValidationError.labelTooLong(let limit):
            "A label can be at most \(limit) characters."
        case CustomKeyValidationError.unsupportedLabelCharacters:
            "The label and hint must be one line, without tabs or control characters."
        case CustomKeyValidationError.noSteps:
            "Choose a key."
        case CustomKeyValidationError.tooManySteps(let limit):
            "A Custom Key can have at most \(limit) steps."
        case CustomKeyValidationError.unsupportedKeyCharacter:
            "That character can’t be sent as a key. Use the Esc, Tab or Enter keys instead."
        case CustomKeyValidationError.emptyText:
            "Type the text this key sends."
        case CustomKeyValidationError.textTooLong(let limit):
            "The text can be at most \(limit) characters."
        case CustomKeyValidationError.unsupportedControlCharacters:
            "This text contains control characters a terminal would read as commands. Remove them and try again."
        case CustomKeyDraftError.missingKey(let step):
            "Choose a key for step \(step)."
        default:
            "The change could not be saved."
        }
    }
}

// MARK: - Chrome

enum ToolbarSettingsChrome {
    static let capRadius: CGFloat = 7
    static let capFill = Color(uiColor: .tertiarySystemFill)
    /// The preview panel on the page background.
    static let barFill = Color(uiColor: .secondarySystemGroupedBackground)
    static let barStroke = Color(uiColor: .separator)
    static let highlight = Color.accentColor
    static let chipMinSize: CGFloat = 44
    static let chipFill = Color(uiColor: .secondarySystemGroupedBackground)
    static let warning = Color(uiColor: .systemYellow)
}

/// A small tinted word after a row title: "Fixed", "Sends", "New".
struct ToolbarTag: View {
    enum Kind {
        case fixed
        case sends
        case new

        var title: String {
            switch self {
            case .fixed: "Fixed"
            case .sends: "Sends"
            case .new: "New"
            }
        }

        var tint: Color {
            switch self {
            case .new: .accentColor
            case .fixed: .secondary
            case .sends: ToolbarSettingsChrome.warning
            }
        }
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    var body: some View {
        Text(kind.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(kind.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(kind.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .lineLimit(1)
            .fixedSize()
    }
}

/// One item as the Toolbar draws it: the shared `AgentToolbarKeyCapLabel`
/// on the bar's cap fill.
struct ToolbarPreviewCap: View {
    let presentation: AgentToolbarItemPresentation
    var isHighlighted = false

    var body: some View {
        AgentToolbarKeyCapLabel(presentation)
            .background(
                RoundedRectangle(cornerRadius: ToolbarSettingsChrome.capRadius, style: .continuous)
                    .fill(ToolbarSettingsChrome.capFill))
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: ToolbarSettingsChrome.capRadius, style: .continuous)
                        .strokeBorder(ToolbarSettingsChrome.highlight, lineWidth: 1.5)
                }
            }
    }
}

/// Wraps chips in order, left to right, onto as many lines as they need.
struct ToolbarChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Fixed controls

/// The Toolbar's trailing controls, fixed in this order and not part of the
/// layout: they cannot be removed or moved.
enum ToolbarFixedControl: CaseIterable, Identifiable {
    case messageAgent
    case terminalKeyboard
    case dictateToAgent

    var id: Self { self }

    var title: String {
        switch self {
        case .messageAgent: "Message Agent"
        case .terminalKeyboard: "Terminal Keyboard"
        case .dictateToAgent: "Dictate to Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .messageAgent: "text.bubble"
        case .terminalKeyboard: "keyboard"
        case .dictateToAgent: "mic"
        }
    }

    /// The Settings row subtitle.
    var subtitle: String {
        switch self {
        case .messageAgent: "Composer · keyboard stays down"
        case .terminalKeyboard: "Toggles the keyboard"
        case .dictateToAgent: "Sends when you stop · iOS 26 and later"
        }
    }
}

// MARK: - Bar preview

/// Resolves items to what the preview draws. Settings shows every stored
/// item; only references to deleted Snippets and Custom Keys drop out, as
/// they do on the real bar.
@MainActor
struct ToolbarPreviewSource {
    let store: AgentToolbarLayoutStore
    let snippets: [Snippet]

    func presentation(_ content: AgentToolbarItem.Content) -> AgentToolbarItemPresentation? {
        AgentToolbarItemPresentation(content, customKeys: store.customKeys, snippets: snippets)
    }

    func drawn(_ items: [AgentToolbarItem]) -> [ToolbarDrawnItem] {
        items.compactMap { item in
            presentation(item.content).map { ToolbarDrawnItem(item: item, presentation: $0) }
        }
    }
}

struct ToolbarDrawnItem: Identifiable {
    let item: AgentToolbarItem
    let presentation: AgentToolbarItemPresentation

    var id: AgentToolbarItem.ID { item.id }
}

/// A hairline between the user's items and the fixed controls.
private struct ToolbarPreviewHairline: View {
    var body: some View {
        Rectangle()
            .fill(ToolbarSettingsChrome.barStroke)
            .frame(width: 1, height: 22)
    }
}

/// The user's items. The preview does not scroll, so the group draws its
/// items at full size from the leading edge and takes the room left before
/// the fixed controls; when they run past that room, the last ones dissolve
/// as on the real bar's overflowing edge.
private struct ToolbarPreviewScrollingGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row.frame(maxWidth: .infinity, alignment: .leading)
            row.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .mask { ToolbarOverflowMask() }
        }
    }

    private var row: some View {
        HStack(spacing: spacing) { content }
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// The single Toolbar: the user's items, a hairline, then Message Agent,
/// Terminal Keyboard and Dictate to Agent.
struct ToolbarBarPreview: View {
    let source: ToolbarPreviewSource
    var highlighted: Set<AgentToolbarItem.Content> = []

    var body: some View {
        HStack(spacing: 6) {
            // Caps sit as far apart as on the real bar: the spacing is the
            // whole drawn gap.
            ToolbarPreviewScrollingGroup(
                spacing: CGFloat(source.store.itemSpacing)
            ) {
                ForEach(source.drawn(source.store.layout.items)) { drawn in
                    ToolbarPreviewCap(
                        presentation: drawn.presentation,
                        isHighlighted: highlighted.contains(drawn.item.content))
                }
            }
            ToolbarPreviewHairline()
            HStack(spacing: 14) {
                ForEach(ToolbarFixedControl.allCases) { control in
                    Image(systemName: control.systemImage)
                        .font(.system(size: 17, weight: .medium))
                        .frame(minWidth: 26, minHeight: 30)
                        .accessibilityLabel(control.title)
                }
            }
            .padding(.horizontal, 6)
            .fixedSize()
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.leading, 10)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 1))
    }
}

/// The dark panel the preview sits in.
struct ToolbarPreviewPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(ToolbarSettingsChrome.barFill))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(ToolbarSettingsChrome.barStroke, lineWidth: 0.5))
            .allowsHitTesting(false)
    }
}

/// "● Working" above the preview, standing in for the Agent header.
struct ToolbarPreviewStatusLine: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.yellow.opacity(0.8)).frame(width: 7, height: 7)
            Text("Working").foregroundStyle(Color.yellow.opacity(0.9))
        }
        .font(.subheadline)
        .accessibilityHidden(true)
    }
}
