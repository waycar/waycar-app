import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// The new-agent sheet's Branch and Agent Name fields, typed into through
/// UIKit. A plain SwiftUI `TextField` kept showing raw spaces while focused
/// even though the store had rewritten them to `-`.
@MainActor
@Suite("Normalizing text field")
struct NormalizingTextFieldTests {
    private struct Harness: View {
        @Bindable var store: StartAgentStore
        var body: some View {
            VStack {
                NormalizingTextField(text: $store.worktreeBranch, placeholder: "Branch")
                NormalizingTextField(text: $store.name, placeholder: "Name")
            }
        }
    }

    private static func fields(in view: UIView) -> [UITextField] {
        ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap(fields(in:))
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    private func type(_ text: String, into field: UITextField) async throws {
        for character in text {
            field.insertText(String(character))
            try await settle()
        }
    }

    private func makeFixture() async throws -> (StartAgentStore, UIWindow, UITextField, UITextField) {
        let suite = "normalizing-field-\(UUID().uuidString)"
        let store = StartAgentStore(
            hosts: [Host.fixture()],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            existingAgentNames: { _ in [] },
            discoverAgentKinds: { _ in [.claude] },
            remoteHome: { _ in "/home/you" },
            start: { _, _, _, _ in throw CancellationError() },
            startShell: { _, _, _, _ in throw CancellationError() },
            awaitAgentVisible: { _ in },
            origin: nil,
            recents: RecentWorkspaceStore(defaults: UserDefaults(suiteName: suite + ".w")!),
            selections: RecentSelectionsStore(defaults: UserDefaults(suiteName: suite + ".s")!))
        await store.discoverAgents()
        store.startsInNewWorktree = true
        let controller = UIHostingController(rootView: Harness(store: store))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
        controller.view.layoutIfNeeded()
        try await settle()
        let found = Self.fields(in: controller.view)
        try #require(found.count == 2)
        return (store, window, found[0], found[1])
    }

    @Test func typedSpacesShowAsHyphensInTheFocusedFieldAndTheMirroredName() async throws {
        let (store, window, branch, name) = try await makeFixture()
        defer { window.isHidden = true }

        branch.becomeFirstResponder()
        try await type("Fix Login ", into: branch)
        #expect(branch.text == "Fix-Login-")
        #expect(name.text == "fix-login-")

        // A second space leaves the value unchanged; the field must still drop it.
        try await type(" ", into: branch)
        #expect(branch.text == "Fix-Login-")

        store.worktreeBranch = ""
        store.name = ""
        try await settle()
        name.becomeFirstResponder()
        try await type("My Agent  X", into: name)
        #expect(name.text == "my-agent-x")
        #expect(store.name == "my-agent-x")
    }

    @Test func aRewriteKeepsTheCursorWhereTheUserIsTyping() async throws {
        let (_, window, _, name) = try await makeFixture()
        defer { window.isHidden = true }

        name.becomeFirstResponder()
        try await type("ab", into: name)
        let afterA = try #require(name.position(from: name.beginningOfDocument, offset: 1))
        name.selectedTextRange = name.textRange(from: afterA, to: afterA)
        try await type(" ", into: name)

        #expect(name.text == "a-b")
        let cursor = try #require(name.selectedTextRange)
        #expect(name.offset(from: name.beginningOfDocument, to: cursor.start) == 2)
    }

    @Test func typingInsideAFullNameKeepsTheCursorAfterEachCharacter() async throws {
        let (store, window, _, name) = try await makeFixture()
        defer { window.isHidden = true }
        store.name = String(repeating: "a", count: 32)
        try await settle()

        name.becomeFirstResponder()
        let afterTwo = try #require(name.position(from: name.beginningOfDocument, offset: 2))
        name.selectedTextRange = name.textRange(from: afterTwo, to: afterTwo)
        try await type("xyz", into: name)

        #expect(name.text == "aaxyz" + String(repeating: "a", count: 27))
    }
}
