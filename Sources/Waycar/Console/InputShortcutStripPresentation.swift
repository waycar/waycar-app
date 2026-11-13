import CoreGraphics
import Foundation
import SwiftUI

/// One control on the Toolbar's scrolling group: a layout item and the way
/// the Toolbar draws it. Views project this; they do not decide which items
/// belong on the Toolbar or how each one is driven.
struct InputShortcutStripItem: Hashable, Identifiable, Sendable {
    enum Control: Hashable, Sendable {
        /// Plain Backspace: tap deletes once, hold keeps deleting.
        case repeatingBackspace
        /// The system paste control, so a tap needs no Allow Paste prompt.
        case pasteControl
        /// The Agent actions menu.
        case moreMenu
        /// The terminal's tools keyboard; lit while it is up.
        case toolsKeyboard
        /// A sticky chip that arms these modifiers for the next Key.
        case modifierChip(TerminalKeyModifiers)
        /// Keys, Combos, other actions, Snippets and Custom Keys: a tap runs
        /// the item through the toolbar dispatcher.
        case button
    }

    let item: AgentToolbarItem
    let control: Control

    var id: AgentToolbarItem.ID { item.id }

    init(_ item: AgentToolbarItem) {
        self.item = item
        control = switch item.content {
        case .key(let chord) where chord.key == .backspace && !chord.isCombo:
            .repeatingBackspace
        case .modifier(let modifiers):
            .modifierChip(modifiers)
        case .action(.paste):
            .pasteControl
        case .action(.moreMenu):
            .moreMenu
        case .action(.toolsKeyboard):
            .toolsKeyboard
        case .key, .action, .snippet, .customKey:
            .button
        }
    }
}

/// The Toolbar's user items in layout order: one layout per device type, in
/// every state, with or without a hardware keyboard. They scroll; Message
/// Agent, Terminal Keyboard and Dictate to Agent are fixed beside them and
/// not part of the layout. The view must not recompute this inline.
struct InputShortcutStripPresentation: Equatable, Sendable {
    let items: [InputShortcutStripItem]

    /// `layout` is already resolved for this Agent view
    /// (`AgentToolbarLayoutStore.resolvedLayout(availability:)`), so every
    /// item is runnable here.
    init(layout: AgentToolbarLayout) {
        items = layout.items.map(InputShortcutStripItem.init)
    }
}

/// One toolbar item drawn as a key-cap label: its SF Symbol when it has one,
/// else its single-line cap text, then `AgentToolbarItemPresentation.sendsGlyph`
/// for a Custom Key that submits. Sized to its content; the caller draws the
/// cap fill (armed state included) and owns the 44 pt hit area.
struct AgentToolbarKeyCapLabel: View {
    let presentation: AgentToolbarItemPresentation
    let isArmed: Bool

    init(_ presentation: AgentToolbarItemPresentation, isArmed: Bool = false) {
        self.presentation = presentation
        self.isArmed = isArmed
    }

    var body: some View {
        HStack(spacing: 2) {
            if let systemImage = presentation.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Text(InputChromeLayout.capText(presentation.capLabel))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            if presentation.showsSendsGlyph {
                Text(AgentToolbarItemPresentation.sendsGlyph)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, InputChromeLayout.keyCapHorizontalPadding)
        .frame(minWidth: InputChromeLayout.keyCapMinWidth, minHeight: InputChromeLayout.keyCapHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityAddTraits(isArmed ? .isSelected : [])
    }
}

/// Named layout constants for the five input chromes. Raw pixel widths stay
/// here so the views do not embed magic numbers.
enum InputChromeLayout {
    /// The Toolbar's row and its key caps. Matches the pre-iPad compact height.
    static let shortcutRowHeight: CGFloat = 44

    /// Key caps size to their label; these bound the drawn cap. The drawn
    /// gap between two caps is exactly the user's Toolbar spacing, so caps
    /// can sit 1 pt apart; each cap's tap area still reaches
    /// `minimumHitSide` by overhanging `stripSlotInset` into the gap.
    static let keyCapHorizontalPadding: CGFloat = 7
    static let keyCapMinWidth: CGFloat = minimumHitSide - 2 * stripSlotInset
    static let keyCapHeight: CGFloat = 30
    static let minimumHitSide: CGFloat = 44
    /// How far a Toolbar cap's tap area overhangs each side of the drawn
    /// cap, so a 36 pt cap still takes taps across 44 pt.
    static let stripSlotInset: CGFloat = 4
    /// Longer cap text (a Snippet title, say) is cut to this many
    /// characters, ellipsis included, so one item cannot swallow the strip.
    static let keyCapMaxCharacters = 12

    /// `UIPasteControl` disables itself below this side length, so the
    /// Paste cap is laid out this tall and scaled down to `keyCapHeight`.
    static let pasteControlSide: CGFloat = 34
    /// Room before the Toolbar's first cap; matches the caps' top and
    /// bottom inset against the capsule's curve.
    static let toolbarLeadingInset: CGFloat = 16
    /// Items scrolled past the leading edge dissolve over this width.
    static let toolbarLeadingFadeWidth: CGFloat = 20
    /// Items running on under the fixed controls dissolve over this width…
    static let toolbarFadeWidth: CGFloat = 28
    /// …and are fully gone this far before the hairline.
    static let toolbarFadeClearance: CGFloat = 8
    /// Message Agent, Terminal Keyboard and Dictate to Agent: glyph size
    /// and the lit fill behind an active control, as tall as a key cap.
    static let fixedControlGlyphSize: CGFloat = 17
    static let fixedControlFillWidth: CGFloat = 38
    static let fixedControlFillHeight: CGFloat = keyCapHeight
    static let fixedControlFillCornerRadius: CGFloat = 9
    static let dictationStopDiameter: CGFloat = keyCapHeight

    /// Caps Agent and Skills keyboard wells and centers them in wider windows.
    /// The full Terminal keyboard adapts to the entire dock width separately.
    static let maxKeyboardContentWidth: CGFloat = 768

    /// Context-menu skill preview has no parent width. This is the card cap
    /// so a short description still reads as a card, not a 370 pt iPhone well.
    static let skillPreviewMaxWidth: CGFloat = 420

    /// Page-dot cluster on the Agent tools pager.
    static let keyboardPageIndicatorWidth: CGFloat = 15

    /// `label` as a cap shows it: at most `keyCapMaxCharacters` characters.
    /// A scroll view offers its content unlimited width, so a width cap alone
    /// would not truncate.
    static func capText(_ label: String) -> String {
        guard label.count > keyCapMaxCharacters else { return label }
        return String(label.prefix(keyCapMaxCharacters - 1)) + "…"
    }
}

/// Masks the Toolbar's items: an eased fade at each overflowing edge, then
/// a clear margin before the hairline, so an item running past the edge
/// dissolves instead of being cut off against the fixed controls. The
/// Settings preview draws the same trailing edge.
struct ToolbarOverflowMask: View {
    var leadingFade: CGFloat = 0
    var trailingFade: CGFloat = InputChromeLayout.toolbarFadeWidth

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(stops: Self.fadeStops, startPoint: .trailing, endPoint: .leading)
                .frame(width: leadingFade)
            Color.black
            LinearGradient(stops: Self.fadeStops, startPoint: .leading, endPoint: .trailing)
                .frame(width: trailingFade)
            Color.clear
                .frame(width: InputChromeLayout.toolbarFadeClearance)
        }
    }

    /// Opaque to clear along a smoothstep, so the fade has no hard
    /// shoulder at either end.
    private static var fadeStops: [Gradient.Stop] {
        (0...8).map { step in
            let t = Double(step) / 8
            return Gradient.Stop(color: .black.opacity(1 - t * t * (3 - 2 * t)), location: t)
        }
    }
}
