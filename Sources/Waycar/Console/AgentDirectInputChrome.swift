import SwiftUI
import UIKit

/// Cohesive seam between Agent detail and its input chrome. Groups the live
/// presentation gates from the interaction handlers so call sites pass one
/// typed model instead of a flat argument surface.
@MainActor
struct AgentInputChromeContext {
    struct Presentation {
        let status: AgentStatus
        let hostTelemetry: HostTelemetryPresentation?
        let chromeColorScheme: ColorScheme
        /// 💬 is lit: the Composer card is open and authored text goes to
        /// its draft.
        let isMessageAgentOpen: Bool
        /// ⌨ is lit: the terminal keyboard (system or tools) is up.
        let isTerminalKeyboardUp: Bool
        /// Lights the Tools Keyboard item.
        let isToolsKeyboardPresented: Bool
        /// True while a sheet, alert, or picker covers the screen: the
        /// microphone must not stay live behind it.
        let isCovered: Bool
        /// The Toolbar layout, already resolved for this Agent.
        let toolbarLayout: AgentToolbarLayout
        /// Gap between the scrolling Toolbar items, in points (user setting).
        let toolbarItemSpacing: CGFloat
        /// One-shot modifiers armed for the next Key; lights sticky chips.
        let armedModifiers: TerminalKeyModifiers
        /// 💬's Composer Tray count while Message Agent is closed; nil while
        /// it is open or the tray is empty.
        let messageAgentTrayBadge: MessageAgentTrayBadge?
        /// The Agent whose progress the status row shows while Working;
        /// nil shows none.
        var progressAgent: ConsoleAgent? = nil
        /// The terminal's connection state; nil draws no dot.
        var connection: TerminalConnectionIndicator? = nil
        /// Whole-session terminals have no Composer or pane actions.
        var paneActionsAvailable = true

        /// Whether Keys that write to the Attach's PTY can reach it. With no
        /// dot there is no state to wait on.
        var terminalAttached: Bool { connection?.acceptsAttachKeys ?? true }
    }

    struct Interactions {
        /// What More offers: the row's Agent actions.
        let actions: AgentComposerActions
        /// 💬: opens Message Agent (keyboard down), or closes it.
        let tapMessageAgent: () -> Void
        /// ⌨: raises or dismisses the terminal keyboard, closing Message
        /// Agent first when it is open.
        let tapTerminalKeyboard: () -> Void
        /// Plain Backspace on the Toolbar, so hold-to-repeat sends each press.
        let sendQuickKey: (AgentQuickKey) -> Void
        /// The Paste item's text: the draft while Message Agent is open,
        /// Attach otherwise.
        let paste: (String) -> Void
        /// Opens Message Agent for a Dictation outcome to review. Does
        /// nothing once this screen left the stage.
        let showComposerForDictation: () -> Void
        /// More's draft-owned actions open Message Agent first.
        let openMessageAgentThen: (@escaping () -> Void) -> Void
        /// Dictate to Agent's recorder, owned by Agent detail for the life of
        /// the view: opening or closing Message Agent never interrupts it.
        let dictation: DictationSender
        /// 🎤: starts, stops-and-sends, or cancels a startup.
        let toggleDictation: () -> Void
        /// The Composer an interrupted recording's words are kept in.
        let composer: AgentComposerStore
        /// Cap strings for an item; nil hides it (a deleted Snippet or
        /// Custom Key).
        let itemPresentation: (AgentToolbarItem) -> AgentToolbarItemPresentation?
        /// Runs an item through the dispatcher.
        let performToolbarItem: (AgentToolbarItem) -> Void
        /// The dot's popover: reattaches a detached terminal.
        let reattach: () -> Void
        /// The dot's popover: reattaches over SSH after a mosh failure.
        let useSSHInstead: () -> Void
        /// The dot's popover: opens the saved conversation; nil offers none
        /// (no copy is kept).
        let readSaved: (() -> Void)?
    }

    let presentation: Presentation
    let interactions: Interactions
}

/// Agent detail's input chrome, bottom-up: the Toolbar (the same single bar
/// in every state), Message Agent's Composer card when open, the listening
/// card while Dictate to Agent records, and the status row. App content
/// rather than a keyboard accessory, so UIKit's candidate-row teardown cannot
/// tear it down or leave a hollow gap.
struct AgentInputChrome<Composer: View>: View {
    let context: AgentInputChromeContext
    /// The status row's preview bar of files and links; nil shows none.
    let mediaStrip: TerminalMediaStrip?
    /// The Composer card while Message Agent is open; empty otherwise.
    let composer: Composer
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    init(
        context: AgentInputChromeContext, mediaStrip: TerminalMediaStrip? = nil,
        @ViewBuilder composer: () -> Composer
    ) {
        self.context = context
        self.mediaStrip = mediaStrip
        self.composer = composer()
    }

    private var presentation: AgentInputChromeContext.Presentation {
        context.presentation
    }

    private var interactions: AgentInputChromeContext.Interactions {
        context.interactions
    }

    private var dictationSender: DictationSender {
        interactions.dictation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsDictation, let failure = dictationSender.dictation.failure {
                DictationFailureRow(
                    failure: failure,
                    dismiss: { dictationSender.dictation.dismissFailure() })
                .padding(.horizontal, 12)
            }

            AgentDetailStatusChrome(
                status: presentation.status,
                hostTelemetry: presentation.hostTelemetry,
                chromeColorScheme: presentation.chromeColorScheme,
                mediaStrip: mediaStrip,
                progressAgent: presentation.progressAgent)

            composer

            if showsDictation, dictationSender.dictation.isActive {
                listeningCard
                    .padding(.horizontal, 12)
            }

            toolbar
        }
        .padding(.top, 8)
        .onDisappear {
            // Never leave the microphone live behind another screen.
            dictationSender.cancel()
        }
        .onChange(of: ObjectIdentifier(interactions.composer)) { _, _ in
            dictationSender.cancel()
            // A failure belongs to the previous Agent.
            dictationSender.dictation.dismissFailure()
        }
        .onChange(of: presentation.isCovered) { _, covered in
            if covered {
                dictationSender.cancel()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                dictationSender.cancel()
            }
        }
        .onChange(of: dictationSender.dictation.phase) { oldPhase, newPhase in
            // The engine ended the session on its own (an audio interruption
            // or route change): keep what was heard for review rather than
            // send it unasked. Teardown has already discarded it.
            guard oldPhase == .listening, newPhase == .idle,
                dictationSender.keepInterrupted(in: interactions.composer)
            else { return }
            interactions.showComposerForDictation()
        }
    }

    // MARK: Dictate to Agent

    /// Agents take natural language; a Shell's commands stay typed.
    private var showsDictation: Bool {
        presentation.paneActionsAvailable && AgentDirectInputPresentation.showsDictateToAgent(
            dictation: dictationSender.dictation, composer: interactions.composer)
    }

    /// Only the waveform, in a box above the Toolbar: no title, dot, timer or transcript.
    private var listeningCard: some View {
        Group {
            if case .downloadingModel(let fraction) = dictationSender.dictation.phase {
                Text("Downloading speech model… \(Int((fraction * 100).rounded()))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                DictationWaveform(dictation: dictationSender.dictation, tint: .red)
                    .frame(height: 24)
                    .accessibilityElement()
                    .accessibilityLabel("Listening")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
        }
        .environment(\.colorScheme, presentation.chromeColorScheme)
        .accessibilityElement(children: .combine)
    }

    // MARK: Toolbar

    private var hairline: CGFloat { 1 / max(displayScale, 1) }

    /// Your items scroll on the left and dissolve before the fixed controls;
    /// Message Agent, Terminal Keyboard and Dictate to Agent never move.
    private var toolbar: some View {
        let strip = InputShortcutStripPresentation(layout: presentation.toolbarLayout)
        return HStack(spacing: 0) {
            ToolbarScrollingItems {
                HStack(spacing: presentation.toolbarItemSpacing) {
                    ForEach(strip.items.filter(isShown)) { item in
                        stripItem(item)
                            .frame(height: InputChromeLayout.shortcutRowHeight)
                    }
                }
            }

            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: hairline, height: 24)
                .accessibilityHidden(true)

            fixedControls
        }
        .frame(height: InputChromeLayout.shortcutRowHeight + 8)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                .accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var fixedControls: some View {
        HStack(spacing: 0) {
            if let connection = presentation.connection {
                TerminalConnectionDot(
                    indicator: connection,
                    reattach: interactions.reattach,
                    useSSHInstead: interactions.useSSHInstead,
                    readSaved: interactions.readSaved)
            }
            if presentation.paneActionsAvailable {
                fixedToggle(
                    .messageAgent,
                    isOn: presentation.isMessageAgentOpen,
                    hint: presentation.isMessageAgentOpen
                        ? AgentDirectInputPresentation.closeMessageAgentAccessibilityHint
                        : AgentDirectInputPresentation.openMessageAgentAccessibilityHint,
                    badge: presentation.messageAgentTrayBadge,
                    action: interactions.tapMessageAgent)
            }
            fixedToggle(
                .terminalKeyboard,
                isOn: presentation.isTerminalKeyboardUp,
                hint: AgentDirectInputPresentation.terminalKeyboardAccessibilityHint(
                    isKeyboardUp: presentation.isTerminalKeyboardUp,
                    isMessageAgentOpen: presentation.isMessageAgentOpen),
                action: interactions.tapTerminalKeyboard)
            if showsDictation {
                dictationControl
            }
        }
        .padding(.trailing, 8)
    }

    /// 💬 and ⌨: a glyph, on an accent fill while on. 💬 carries the Composer
    /// Tray's count while Message Agent is closed.
    private func fixedToggle(
        _ control: ToolbarFixedControl,
        isOn: Bool,
        hint: String,
        badge: MessageAgentTrayBadge? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            playKeyFeedback()
            action()
        } label: {
            Image(
                systemName: control == .terminalKeyboard && isOn
                    // A lit ⌨ shows that a tap dismisses.
                    ? "keyboard.chevron.compact.down" : control.systemImage)
                .font(.system(size: InputChromeLayout.fixedControlGlyphSize, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Color(uiColor: .label))
                .frame(
                    width: InputChromeLayout.fixedControlFillWidth,
                    height: InputChromeLayout.fixedControlFillHeight)
                .background {
                    if isOn {
                        RoundedRectangle(
                            cornerRadius: InputChromeLayout.fixedControlFillCornerRadius,
                            style: .continuous)
                        .fill(Color.accentColor)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        TrayCountBadge(badge: badge)
                    }
                }
                .frame(
                    minWidth: InputChromeLayout.minimumHitSide,
                    minHeight: InputChromeLayout.minimumHitSide)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control.title)
        .accessibilityHint(hint)
        .accessibilityValue(badge?.accessibilityValue ?? "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// 🎤: a mic while idle, a spinner that cancels until the microphone is
    /// live, then a red circle with a stop square.
    @ViewBuilder
    private var dictationControl: some View {
        let phase = dictationSender.dictation.phase
        let button = Button(action: interactions.toggleDictation) {
            Group {
                switch phase {
                case .idle:
                    Image(systemName: ToolbarFixedControl.dictateToAgent.systemImage)
                        .font(.system(size: InputChromeLayout.fixedControlGlyphSize, weight: .medium))
                        .foregroundStyle(Color(uiColor: .label))
                case .starting, .downloadingModel:
                    ProgressView()
                        .controlSize(.small)
                case .listening, .finishing:
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(
                            width: InputChromeLayout.dictationStopDiameter,
                            height: InputChromeLayout.dictationStopDiameter)
                        .background(Circle().fill(.red))
                }
            }
            .frame(
                minWidth: InputChromeLayout.minimumHitSide,
                minHeight: InputChromeLayout.minimumHitSide)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Message Agent's mic holds the one speech session.
        .disabled(phase == .finishing || dictationSender.dictation.isBlockedByOtherSession)
        switch phase {
        case .idle:
            button
                .accessibilityLabel(ToolbarFixedControl.dictateToAgent.title)
                .accessibilityHint(AgentDirectInputPresentation.dictateToAgentAccessibilityHint)
        case .starting, .downloadingModel:
            button.accessibilityLabel("Cancel dictation")
        case .listening, .finishing:
            button
                .accessibilityLabel("Stop and Send")
                .accessibilityHint("Sends what you said to the Agent")
        }
    }

    // MARK: Items

    /// Hidden items take no slot: a Snippet or Custom Key that no longer
    /// exists.
    private func isShown(_ entry: InputShortcutStripItem) -> Bool {
        switch entry.control {
        case .moreMenu, .pasteControl:
            true
        case .repeatingBackspace, .toolsKeyboard, .modifierChip, .button:
            capPresentation(for: entry.item) != nil
        }
    }

    @ViewBuilder
    private func stripItem(_ entry: InputShortcutStripItem) -> some View {
        switch entry.control {
        case .moreMenu:
            moreMenu
        case .pasteControl:
            pasteKeyButton
        case .repeatingBackspace:
            if let cap = capPresentation(for: entry.item) {
                backspaceKey(cap)
            }
        case .toolsKeyboard:
            if let cap = capPresentation(for: entry.item) {
                toolsKeyboardKey(entry.item, cap: cap)
            }
        case .modifierChip(let modifiers):
            if let cap = capPresentation(for: entry.item) {
                modifierChip(entry.item, modifiers: modifiers, cap: cap)
            }
        case .button:
            if let cap = capPresentation(for: entry.item) {
                itemButton(entry.item, cap: cap)
            }
        }
    }

    /// Nil for a Snippet or Custom Key that no longer exists: it hides.
    private func capPresentation(for item: AgentToolbarItem) -> AgentToolbarItemPresentation? {
        interactions.itemPresentation(item)
    }

    /// Hidden cap text sizes the cap like every other; the repeating UIKit
    /// button fills it, full row height, and draws its own 30 pt cap.
    private func backspaceKey(_ cap: AgentToolbarItemPresentation) -> some View {
        AgentToolbarKeyCapLabel(cap)
            .hidden()
            .frame(maxHeight: .infinity)
            .overlay {
                TerminalBackspaceButton(isToolbar: true) {
                    playKeyFeedback()
                    interactions.sendQuickKey(.backspace)
                }
                .frame(
                    minWidth: InputChromeLayout.keyCapMinWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity)
                // A UIKit control: `disabled` alone would not stop it.
                .allowsHitTesting(presentation.terminalAttached)
            }
            .opacity(presentation.terminalAttached ? 1 : 0.45)
            .disabled(!presentation.terminalAttached)
            .accessibilityHint(presentation.terminalAttached ? "" : detachedKeyHint)
            .stripHitSlot(spacing: presentation.toolbarItemSpacing)
    }

    private func itemButton(_ item: AgentToolbarItem, cap: AgentToolbarItemPresentation) -> some View {
        let enabled = isEnabled(item)
        return Button {
            perform(item)
        } label: {
            AgentToolbarKeyCapLabel(cap)
        }
        .stripHitSlot(spacing: presentation.toolbarItemSpacing)
        .buttonStyle(TerminalKeyboardButtonStyle())
        .disabled(!enabled)
        // The key-cap style keeps its colors when disabled; dim as
        // `TerminalKeyboardKeyCap` does.
        .opacity(enabled ? 1 : 0.45)
        .accessibilityHint(hint(for: item))
    }

    /// Lit while the terminal's tools keyboard is up.
    private func toolsKeyboardKey(
        _ item: AgentToolbarItem,
        cap: AgentToolbarItemPresentation
    ) -> some View {
        let isPresented = presentation.isToolsKeyboardPresented
        return Button {
            perform(item)
        } label: {
            AgentToolbarKeyCapLabel(cap, isArmed: isPresented)
        }
        .stripHitSlot(spacing: presentation.toolbarItemSpacing)
        .buttonStyle(TerminalKeyboardButtonStyle(isSelected: isPresented))
        .accessibilityHint(
            isPresented ? "Shows the iOS keyboard" : "Shows the terminal's tools keyboard")
    }

    /// Arms the modifiers for the next Key, as the full keyboard's
    /// modifier keys do; lit while armed.
    private func modifierChip(
        _ item: AgentToolbarItem,
        modifiers: TerminalKeyModifiers,
        cap: AgentToolbarItemPresentation
    ) -> some View {
        let isArmed = presentation.armedModifiers.isSuperset(of: modifiers)
        return Button {
            perform(item)
        } label: {
            AgentToolbarKeyCapLabel(cap, isArmed: isArmed)
        }
        .stripHitSlot(spacing: presentation.toolbarItemSpacing)
        .buttonStyle(TerminalKeyboardButtonStyle(isSelected: isArmed))
        .disabled(!isEnabled(item))
        .opacity(isEnabled(item) ? 1 : 0.45)
        .accessibilityValue(isArmed ? "Armed" : "Not armed")
        .accessibilityHint(
            needsAttach(item)
                ? detachedKeyHint : "Applies to the next remote key; tap again to cancel")
    }

    /// Menu-backed actions keep the More menu's disabled rules (Add Image
    /// while a Send is running, Open Terminal while it opens).
    private func isEnabled(_ item: AgentToolbarItem) -> Bool {
        AgentActionMenuPolicy.isEnabled(item.content, actions: interactions.actions)
            && (presentation.terminalAttached
                || !AgentActionMenuPolicy.writesToAttach(item.content))
    }

    private var detachedKeyHint: String { "Unavailable while the terminal is detached" }

    /// Whether `item` is held back only because the terminal has no attach.
    private func needsAttach(_ item: AgentToolbarItem) -> Bool {
        !presentation.terminalAttached && AgentActionMenuPolicy.writesToAttach(item.content)
    }

    private func hint(for item: AgentToolbarItem) -> String {
        if needsAttach(item) { return detachedKeyHint }
        switch item.content {
        case .key: return "Sends this key directly to the Agent"
        case .snippet:
            return presentation.isMessageAgentOpen
                ? "Inserts this Snippet into the draft" : "Inserts this Snippet"
        case .customKey, .action, .modifier: return ""
        }
    }

    private func perform(_ item: AgentToolbarItem) {
        playKeyFeedback()
        interactions.performToolbarItem(item)
    }

    private func paste(_ text: String) {
        playKeyFeedback()
        interactions.paste(text)
    }

    private func playKeyFeedback() {
        UIDevice.current.playInputClick()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var pasteKeyButton: some View {
        KeyCapPasteSlot(spacing: presentation.toolbarItemSpacing, onPaste: paste)
            .accessibilityHint(
                presentation.isMessageAgentOpen
                    ? "Pastes the clipboard into the draft"
                    : "Pastes the clipboard into the Agent")
    }

    /// The Agent actions, Add Image and Add File included. With Message
    /// Agent closed, draft-owned entries open it first.
    private var moreMenu: some View {
        Menu {
            AgentActionMenuContent(
                actions: interactions.actions,
                sections: AgentActionMenuPolicy.toolbarMoreSections,
                restoreComposerThen: presentation.isMessageAgentOpen
                    ? nil : interactions.openMessageAgentThen)
        } label: {
            Image(systemName: AgentToolbarAction.moreMenu.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(
                    minWidth: InputChromeLayout.keyCapMinWidth,
                    minHeight: InputChromeLayout.keyCapHeight)
        }
        .stripHitSlot(spacing: presentation.toolbarItemSpacing)
        .buttonStyle(TerminalKeyboardButtonStyle())
        .accessibilityLabel("More")
        .accessibilityHint("Opens Agent actions")
    }
}

/// The Composer Tray's item count over 💬's corner: red when an item
/// failed, the accent otherwise. VoiceOver reads it from 💬's value.
private struct TrayCountBadge: View {
    let badge: MessageAgentTrayBadge

    private static let side: CGFloat = 16
    /// Lifts the badge onto the glyph fill's corner; it still clears the
    /// Toolbar capsule's top edge.
    private static let overhang: CGFloat = 5

    var body: some View {
        Text("\(badge.count)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            // Ink on danger (#0A0A0D on #F87171) is about 7.2:1; white on
            // the accent fill stays.
            .foregroundStyle(badge.hasFailure ? Brand.Colors.ink : Brand.Colors.white)
            .padding(.horizontal, 4)
            .frame(minWidth: Self.side, minHeight: Self.side)
            .background(
                Capsule().fill(badge.hasFailure ? Brand.Colors.danger : Brand.Colors.accent))
            .offset(x: Self.overhang, y: -Self.overhang)
            .accessibilityHidden(true)
    }
}

/// The Toolbar's scrolling items. An edge with items past it dissolves
/// over an eased fade instead of cutting a cap against the capsule or the
/// hairline; each fade narrows away as the scroll reaches its edge, so the
/// first and last items rest fully drawn.
private struct ToolbarScrollingItems<Content: View>: View {
    @ViewBuilder let content: Content
    /// How far items run past each edge, capped at that edge's fade.
    @State private var overflow = Overflow()

    private struct Overflow: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
                .padding(.leading, InputChromeLayout.toolbarLeadingInset)
                // The last cap scrolls clear of the hairline's margin and
                // the tap shield over it.
                .padding(.trailing, InputChromeLayout.toolbarFadeClearance + InputChromeLayout.stripSlotInset)
        }
        .onScrollGeometryChange(for: Overflow.self) { geometry in
            let visible = geometry.visibleRect
            return Overflow(
                leading: min(max(visible.minX, 0), InputChromeLayout.toolbarLeadingFadeWidth)
                    .rounded(),
                trailing: min(
                    max(geometry.contentSize.width - visible.maxX, 0),
                    InputChromeLayout.toolbarFadeWidth
                ).rounded())
        } action: { _, new in
            overflow = new
        }
        .mask {
            ToolbarOverflowMask(leadingFade: overflow.leading, trailingFade: overflow.trailing)
        }
        // Keys under the cleared margin, and the fade's near-invisible tail,
        // are masked out but would still take taps; this band absorbs them.
        .overlay(alignment: .trailing) {
            Color.clear
                .frame(width: Self.trailingTapShieldWidth)
                .contentShape(.rect)
                .onTapGesture {}
                .accessibilityHidden(true)
        }
    }

    /// The clear margin plus the fade's last few points, where a key is
    /// already too faint to read.
    private static var trailingTapShieldWidth: CGFloat {
        InputChromeLayout.toolbarFadeClearance + 5
    }
}

private extension View {
    /// A strip control's slot: exactly as wide as its cap (so the user's
    /// spacing is the whole drawn gap) and the row's full height. Its tap
    /// area overhangs each side by up to `stripSlotInset`, but never more
    /// than half the gap, so neighbours' areas meet without overlapping and
    /// reach 44 pt once the spacing is 8 pt or more.
    func stripHitSlot(spacing: CGFloat) -> some View {
        frame(minWidth: InputChromeLayout.keyCapMinWidth, maxHeight: .infinity)
            .contentShape(
                Rectangle().inset(by: -min(InputChromeLayout.stripSlotInset, max(spacing, 0) / 2)))
    }
}

/// The Paste key cap in its Toolbar slot. The system paste control
/// disables itself below 34 pt, so it is laid out `pasteControlSide` tall
/// and scaled down to a narrow key cap's size; it only takes touches on its
/// drawn cap.
struct KeyCapPasteSlot: View {
    private let onPaste: (String) -> Void
    private let spacing: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(spacing: CGFloat = InputChromeLayout.stripSlotInset * 2, onPaste: @escaping (String) -> Void) {
        self.spacing = spacing
        self.onPaste = onPaste
    }

    var body: some View {
        let scale = InputChromeLayout.keyCapHeight / InputChromeLayout.pasteControlSide
        KeyCapPasteControl(onPaste: onPaste)
            // The control resolves its colors once, when it is created.
            .id(colorScheme)
            .frame(
                width: InputChromeLayout.keyCapMinWidth / scale,
                height: InputChromeLayout.pasteControlSide)
            .scaleEffect(scale)
            .frame(width: InputChromeLayout.keyCapMinWidth, height: InputChromeLayout.keyCapHeight)
            .stripHitSlot(spacing: spacing)
    }
}

/// UIKit's paste control dressed as a toolbar key cap. SwiftUI's
/// `PasteButton` cannot be: its glyph is always white, and in light mode iOS
/// darkens a light tint behind it. Draws the Toolbar's Paste item; the
/// caller lays it out at least `InputChromeLayout.pasteControlSide` square,
/// below which it disables itself.
struct KeyCapPasteControl: UIViewRepresentable {
    let onPaste: (String) -> Void

    func makeUIView(context: Context) -> KeyCapPasteView {
        KeyCapPasteView(paste: onPaste)
    }

    func updateUIView(_ view: KeyCapPasteView, context: Context) {
        view.onPaste = onPaste
    }
}

final class KeyCapPasteView: UIView {
    var onPaste: (String) -> Void
    private let control: UIPasteControl
    private let fallbackKey = KeyCapPasteView.makeFallbackKey()
    /// The pending fallback check; tests await it.
    private(set) var contentCheck: Task<Void, Never>?
    /// Reads the control's size; a zero size means the system never drew it.
    private let contentSize: @MainActor (UIPasteControl) -> CGSize
    /// How long a control on screen may stay unsized before the fallback
    /// key covers it; a running service sizes it well within that.
    private let contentTimeout: Duration

    /// The largest text size the control is drawn at. Its glyph grows with
    /// Dynamic Type, and from Extra Large up the system draws nothing in a
    /// `pasteControlSide` slot (SecureControlService logs "Cannot create
    /// local content from empty drawing"), which left a blank gap.
    private static let maxContentSizeCategory = UIContentSizeCategory.large

    /// The key caps' translucent `secondarySystemFill` flattened onto the
    /// row's `secondarySystemBackground`, because the control paints its
    /// background opaque.
    private static let keyCapFill = UIColor { traits in
        let fill = UIColor.secondarySystemFill.resolvedColor(with: traits)
        let base = UIColor.secondarySystemBackground.resolvedColor(with: traits)
        var (fillRed, fillGreen, fillBlue, fillAlpha): (CGFloat, CGFloat, CGFloat, CGFloat) =
            (0, 0, 0, 0)
        var (baseRed, baseGreen, baseBlue, baseAlpha): (CGFloat, CGFloat, CGFloat, CGFloat) =
            (0, 0, 0, 0)
        fill.getRed(&fillRed, green: &fillGreen, blue: &fillBlue, alpha: &fillAlpha)
        base.getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha)
        let blend = { (top: CGFloat, bottom: CGFloat) in
            top * fillAlpha + bottom * (1 - fillAlpha)
        }
        return UIColor(
            red: blend(fillRed, baseRed),
            green: blend(fillGreen, baseGreen),
            blue: blend(fillBlue, baseBlue),
            alpha: 1)
    }

    init(
        paste: @escaping (String) -> Void,
        contentSize: @escaping @MainActor (UIPasteControl) -> CGSize = { $0.intrinsicContentSize },
        contentTimeout: Duration = .seconds(1)
    ) {
        onPaste = paste
        self.contentSize = contentSize
        self.contentTimeout = contentTimeout
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = 7
        configuration.baseForegroundColor = .label
        configuration.baseBackgroundColor = Self.keyCapFill
        control = UIPasteControl(configuration: configuration)
        super.init(frame: .zero)
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        control.target = self
        fallbackKey.addAction(
            UIAction { [weak self] _ in
                guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
                self?.onPaste(text)
            }, for: .primaryActionTriggered)
        for key in [control, fallbackKey] {
            key.translatesAutoresizingMaskIntoConstraints = false
            addSubview(key)
            NSLayoutConstraint.activate([
                key.topAnchor.constraint(equalTo: topAnchor),
                key.leadingAnchor.constraint(equalTo: leadingAnchor),
                key.trailingAnchor.constraint(equalTo: trailingAnchor),
                key.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        clampContentSizeCategory()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: KeyCapPasteView, _: UITraitCollection) in
            view.clampContentSizeCategory()
        }
    }

    /// Follows the user's text size up to `maxContentSizeCategory`.
    private func clampContentSizeCategory() {
        control.traitOverrides.preferredContentSizeCategory = min(
            traitCollection.preferredContentSizeCategory, Self.maxContentSizeCategory)
    }

    /// The control sizes and draws itself through the system's
    /// SecureControlService. Once that process has exited, UIKit never
    /// relaunches it for this app, so a control created afterwards stays
    /// blank (zero intrinsic size) until the app relaunches.
    ///
    /// The check runs only when this view enters a window, so it catches
    /// controls created after the service died; a control already on screen
    /// when the service dies is not rechecked.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        contentCheck?.cancel()
        guard window != nil, contentSize(control) == .zero else { return }
        contentCheck = Task { [weak self, contentTimeout] in
            try? await Task.sleep(for: contentTimeout)
            guard !Task.isCancelled, let self, self.window != nil,
                self.contentSize(self.control) == .zero
            else { return }
            // The fallback key covers the control, and VoiceOver finds only it.
            self.fallbackKey.isHidden = false
            self.control.accessibilityElementsHidden = true
        }
    }

    /// A plain key cap pasting `UIPasteboard.general`, so iOS asks to allow
    /// the paste the way it does for any app reading the clipboard.
    private static func makeFallbackKey() -> UIButton {
        var configuration = UIButton.Configuration.filled()
        // The other icon caps' 12 pt semibold glyph, before the slot scales
        // this view down to `keyCapHeight`; small scale, since this symbol
        // is taller than theirs.
        let glyphSize = 12 * InputChromeLayout.pasteControlSide / InputChromeLayout.keyCapHeight
        configuration.image = UIImage(
            systemName: "doc.on.clipboard",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: glyphSize, weight: .semibold, scale: .small))
        configuration.baseForegroundColor = .label
        configuration.baseBackgroundColor = keyCapFill
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 7
        let key = UIButton(configuration: configuration)
        key.accessibilityLabel = "Paste"
        key.isHidden = true
        return key
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) })
        else { return }
        _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
            guard let text, !text.isEmpty else { return }
            Task { @MainActor in self?.onPaste(text) }
        }
    }
}
