import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// A throwaway defaults suite and the cleanup that removes it.
private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
    let suiteName = "hm-toolbar-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
}

@MainActor
@Suite("Toolbar settings editing")
struct ToolbarSettingsTests {
    private static let enter = AgentToolbarItem.Content.key(AgentToolbarKeyChord(.enter))
    private static let escape = AgentToolbarItem.Content.key(AgentToolbarKeyChord(.escape))
    private static let tab = AgentToolbarItem.Content.key(AgentToolbarKeyChord(.tab))
    private static let interrupt = AgentToolbarItem.Content.key(
        AgentToolbarKeyChord(.character("c"), modifiers: .control))
    private static let more = AgentToolbarItem.Content.action(.moreMenu)
    private static let tools = AgentToolbarItem.Content.action(.toolsKeyboard)

    private func item(_ content: AgentToolbarItem.Content, in layout: AgentToolbarLayout) throws -> AgentToolbarItem {
        try #require(layout.items.first { $0.content == content })
    }

    // MARK: Move / remove / add

    @Test func moveUpAndDownStepOneRowAndStopAtTheEnds() throws {
        let layout = AgentToolbarLayout.default
        let escape = try item(Self.escape, in: layout)
        #expect(ToolbarEditing.steppingItem(escape.id, by: -1, layout: layout) == nil)
        let down = try #require(ToolbarEditing.steppingItem(escape.id, by: 1, layout: layout))
        #expect(down.items.prefix(2).map(\.content) == [Self.tab, Self.escape])
        let up = try #require(ToolbarEditing.steppingItem(escape.id, by: -1, layout: down))
        #expect(up.hasSameContents(as: layout))

        let last = try #require(layout.items.last)
        #expect(ToolbarEditing.steppingItem(last.id, by: 1, layout: layout) == nil)
    }

    @Test func draggingMovesAnyItemIncludingMoreAndTools() throws {
        let layout = AgentToolbarLayout.default
        let toolsIndex = try #require(layout.items.firstIndex { $0.content == Self.tools })
        let moved = ToolbarEditing.moving(fromOffsets: IndexSet(integer: toolsIndex), toOffset: 0, layout: layout)
        #expect(moved.items.first?.content == Self.tools)
        #expect(moved.items.count == layout.items.count)
    }

    @Test func removingAnyItemWorksAndRemovingEnterRaisesTheWarning() throws {
        let layout = AgentToolbarLayout.default
        #expect(ToolbarEditing.notes(for: layout).isEmpty)
        let withoutMore = ToolbarEditing.removing(try item(Self.more, in: layout).id, from: layout)
        #expect(!withoutMore.contains(Self.more))
        let withoutEnter = ToolbarEditing.removing(try item(Self.enter, in: layout).id, from: layout)
        #expect(!withoutEnter.contains(Self.enter))
        #expect(ToolbarEditing.notes(for: withoutEnter) == [.enterRemoved])
    }

    @Test func addingAppendsToTheEndAndRefusesDuplicates() throws {
        let layout = AgentToolbarLayout.default
        let added = try #require(ToolbarEditing.adding(Self.interrupt, to: layout))
        #expect(added.items.last?.content == Self.interrupt)
        #expect(ToolbarEditing.adding(Self.interrupt, to: added) == nil)
        #expect(ToolbarEditing.adding(Self.escape, to: layout) == nil)
    }

    // MARK: Picker

    @Test func pickerOffersEveryItemKindAndMarksThoseOnTheBar() throws {
        let key = CustomKey(label: "compact", steps: .text("/compact", pressEnter: true))
        let snippet = try Snippet.make(title: "Run the tests", body: "make test")
        let catalog = ToolbarPickerCatalog(layout: .default, customKeys: [key], snippets: [snippet])
        #expect(catalog.modifiers.map(\.content) == [.modifier(.control), .modifier(.option), .modifier(.shift)])
        #expect(catalog.keys.first { $0.content == Self.escape }?.isOnBar == true)
        #expect(catalog.keys.first { $0.content == .key(AgentToolbarKeyChord(.home)) }?.isOnBar == false)
        #expect(catalog.functionKeys.count == TerminalFunctionKey.allCases.count)
        #expect(catalog.combos.map(\.content).contains(Self.interrupt))
        #expect(catalog.customKeys.map(\.content) == [.customKey(key.id)])
        #expect(catalog.snippets.map(\.content) == [.snippet(snippet.id)])
        #expect(catalog.actions.map(\.content) == AgentToolbarAction.allCases.map { .action($0) })
        #expect(catalog.actions.first { $0.content == Self.more }?.isOnBar == true)
    }

    @Test func pickerSearchNarrowsEverySection() {
        let catalog = ToolbarPickerCatalog(layout: .default, customKeys: [], snippets: [], query: "interrupt")
        #expect(catalog.combos.map(\.content) == [Self.interrupt])
        #expect(catalog.keys.isEmpty && catalog.actions.isEmpty && catalog.modifiers.isEmpty)

        let nothing = ToolbarPickerCatalog(
            layout: .default, customKeys: [], snippets: [], query: "zzzz-no-such-item")
        #expect(nothing.isEmpty)
    }

    // MARK: Custom Key builder

    @Test func keyStepsWithoutAKeyAreRefusedByStep() throws {
        var draft = CustomKeyDraft(target: .new)
        #expect(throws: CustomKeyDraftError.missingKey(step: 1)) { try draft.makeKey() }

        draft.steps[0] = CustomKeyDraft.Step(modifiers: .control, key: .character("e"))
        draft.addStep()
        #expect(throws: CustomKeyDraftError.missingKey(step: 2)) { try draft.makeKey() }

        draft.steps[1] = CustomKeyDraft.Step(modifiers: .control, key: .character("u"))
        let key = try draft.makeKey()
        #expect(key.steps == .keys([
            AgentToolbarKeyChord(.character("e"), modifiers: .control),
            AgentToolbarKeyChord(.character("u"), modifiers: .control),
        ]))
        #expect(!key.submits)
    }

    @Test func stepsStopAtTheLimitAndTheLastStepStays() {
        var draft = CustomKeyDraft(target: .new)
        while draft.addStep() != nil {}
        #expect(draft.steps.count == CustomKey.maximumKeySteps)
        #expect(!draft.canAddStep)

        for _ in 0..<(CustomKey.maximumKeySteps + 2) { draft.removeStep(at: 0) }
        #expect(draft.steps.count == 1)
    }

    @Test func textKeysValidateAndOnlyTheEnterToggleSubmits() throws {
        var draft = CustomKeyDraft(target: .new)
        draft.kind = .text
        #expect(throws: CustomKeyValidationError.emptyText) { try draft.makeKey() }

        draft.label = "compact"
        draft.text = "/compact\r\n"
        #expect(try !draft.makeKey().submits)
        #expect(!draft.previewKey.submits)

        draft.pressEnter = true
        let key = try draft.makeKey()
        #expect(key.submits)
        #expect(key.steps == .text("/compact\n", pressEnter: true))

        draft.label = String(repeating: "x", count: CustomKey.labelCharacterLimit + 1)
        #expect(throws: CustomKeyValidationError.labelTooLong(limit: CustomKey.labelCharacterLimit)) {
            try draft.makeKey()
        }
    }

    @Test func switchingShapeKeepsTheOtherShapeAndSavesOnlyTheChosenOne() throws {
        var draft = CustomKeyDraft(target: .new)
        draft.steps[0] = CustomKeyDraft.Step(modifiers: .control, key: .character("s"))
        draft.kind = .text
        draft.text = "/review"
        #expect(try draft.makeKey().steps == .text("/review", pressEnter: false))
        draft.kind = .keys
        #expect(try draft.makeKey().steps == .keys([AgentToolbarKeyChord(.character("s"), modifiers: .control)]))
    }

    @Test func aNewKeyIsAddedToTheBarByDefault() {
        #expect(CustomKeyDraft(target: .new).addToBar)
    }

    @Test func editingAnExistingKeyKeepsItsIdentityShapeAndPlace() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        let original = CustomKey(label: "save", hint: "Save file", steps: .keys([
            AgentToolbarKeyChord(.character("s"), modifiers: .control),
        ]))
        try store.upsertCustomKey(original, addToBar: true)
        let stored = try #require(store.customKey(original.id))

        var draft = CustomKeyDraft(target: .existing(stored), isOnBar: store.isOnBar(stored.id))
        #expect(!draft.isNew)
        #expect(draft.addToBar)
        #expect(try draft.makeKey() == stored)

        draft.label = "write"
        try store.upsertCustomKey(try draft.makeKey(), addToBar: draft.addToBar)
        #expect(store.customKeys.map(\.id) == [original.id])
        #expect(store.customKey(original.id)?.label == "write")
        #expect(store.isOnBar(original.id))
    }
}

/// The Toolbar page's sheets, presented from the real page in a window after
/// scrolling it down (#55): the Add Item picker and a Custom Key's builder
/// used to close by themselves about half a second after opening.
@MainActor
@Suite("Toolbar settings presentations", .serialized)
struct ToolbarSettingsPresentationTests {
    enum Opener: CaseIterable, CustomTestStringConvertible {
        /// "Add Item…" under Your items.
        case addItem
        /// A Custom Key row in Your items.
        case customKeyRow

        var testDescription: String {
            switch self {
            case .addItem: "Add Item…"
            case .customKeyRow: "Custom Key row"
            }
        }

        /// An element only the opened sheet shows.
        var sheetMarker: String {
            switch self {
            case .addItem: "settings.toolbars.picker.newCustomKey"
            case .customKeyRow: "settings.toolbars.builder.label"
            }
        }
    }

    @Test(arguments: Opener.allCases)
    func aSheetOpenedAfterScrollingDownStaysOpen(_ opener: Opener) async throws {
        // Hosted SwiftUI accessibility only materializes on iOS 27 and later.
        guard #available(iOS 27, *) else { return }
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let toolbars = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        let key = CustomKey(label: "Clear", hint: "", steps: .keys([
            AgentToolbarKeyChord(.character("u"), modifiers: .control),
        ]))
        if opener == .customKeyRow {
            try toolbars.upsertCustomKey(key, addToBar: true)
        }
        let controller = UIHostingController(rootView: NavigationStack {
            ToolbarsSettingsView(toolbars: toolbars, snippets: SnippetStore(defaults: defaults))
        })
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
        defer {
            controller.dismiss(animated: false)
            window.isHidden = true
        }

        let list = try #require(try await Self.waitFor { Self.firstScrollingCollection(in: controller.view) })
        let openerID = switch opener {
        case .addItem: "settings.toolbars.editor.add"
        case .customKeyRow: "settings.toolbars.editor.customKey.\(key.id.uuidString)"
        }
        let findOpener = {
            list.layoutIfNeeded()
            return Self.firstVisible(in: list) { Self.identifier(of: $0) == openerID }
        }
        // Scroll to the bottom so the page's top rows leave the screen, then
        // back up until the opener is on screen, as a user scrolling would.
        let bottom = list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
        list.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        var element = try await Self.waitFor(timeout: .milliseconds(500), findOpener)
        while element == nil, list.contentOffset.y > -list.adjustedContentInset.top {
            let offset = max(list.contentOffset.y - 150, -list.adjustedContentInset.top)
            list.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            element = try await Self.waitFor(timeout: .milliseconds(500), findOpener)
        }
        let target = try #require(element, "\(opener.testDescription) should be on the page")
        try #require(
            Self.firstVisible(in: list) { $0.accessibilityLabel == "Preview" } == nil,
            "the page's top rows should be off screen before the sheet opens")

        try #require(target.accessibilityActivate())
        try #require(
            try await Self.waitFor { Self.presentedSheet(over: controller, marker: opener.sheetMarker) },
            "\(opener.testDescription) should open its sheet")

        // Watch the whole window: any close fails, even one followed by a reopen.
        let deadline = ContinuousClock.now + .milliseconds(1_500)
        while ContinuousClock.now < deadline {
            try #require(
                Self.presentedSheet(over: controller, marker: opener.sheetMarker) != nil,
                "\(opener.testDescription)'s sheet closed by itself after the page was scrolled down (#55)")
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Helpers

    private static func waitFor<T>(
        timeout: Duration = .waitCeiling, _ probe: () -> T?
    ) async throws -> T? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = probe() { return value }
            try await Task.sleep(for: .milliseconds(25))
        }
        return probe()
    }

    /// The page's List, once it is taller than the screen.
    private static func firstScrollingCollection(in root: UIView) -> UICollectionView? {
        root.layoutIfNeeded()
        func find(_ view: UIView) -> UICollectionView? {
            if let list = view as? UICollectionView, list.contentSize.height > list.bounds.height + 200 {
                return list
            }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(root)
    }

    /// The first element matching `predicate` wholly inside the list's
    /// visible area, below the navigation bar.
    private static func firstVisible(in list: UICollectionView, where predicate: (NSObject) -> Bool) -> NSObject? {
        let visible = list.bounds.inset(by: list.adjustedContentInset)
        return firstAccessible(in: list) {
            predicate($0) && visible.contains(list.convert($0.accessibilityFrame, from: nil))
        }
    }

    /// SwiftUI's accessibility nodes answer `accessibilityIdentifier`
    /// without declaring `UIAccessibilityIdentification`, so ask by selector.
    private static func identifier(of node: NSObject) -> String? {
        let getter = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        guard node.responds(to: getter) else { return nil }
        return node.value(forKey: "accessibilityIdentifier") as? String
    }

    /// The sheet presented over the page, when it shows `marker`.
    private static func presentedSheet(over page: UIViewController, marker: String) -> UIViewController? {
        guard let sheet = page.presentedViewController, !sheet.isBeingDismissed else { return nil }
        let found = firstAccessible(in: sheet.view) {
            Self.identifier(of: $0) == marker
        }
        return found == nil ? nil : sheet
    }

    /// Walks views and SwiftUI accessibility containers (array and indexed
    /// APIs) for the first on-screen element matching `predicate`.
    private static func firstAccessible(in root: UIView, where predicate: (NSObject) -> Bool) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func visit(_ node: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if predicate(node) {
                let frame = node.accessibilityFrame
                let onScreen = (node as? UIView).map { $0.window != nil && !$0.isHidden }
                    ?? (frame.width > 0 && frame.height > 0)
                if onScreen { return node }
            }
            for case let object as NSObject in node.accessibilityElements ?? [] {
                if let match = visit(object) { return match }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject, let match = visit(object) {
                        return match
                    }
                }
            }
            if let view = node as? UIView {
                for subview in view.subviews {
                    if let match = visit(subview) { return match }
                }
            }
            return nil
        }
        return visit(root)
    }
}
