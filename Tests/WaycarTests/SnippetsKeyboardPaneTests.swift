import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Waycar

@MainActor
@Suite("Snippets keyboard pane", .serialized)
struct SnippetsKeyboardPaneTests {
    @Test func unreadableCatalogShowsUnavailableRatherThanEmpty() async throws {
        guard #available(iOS 27, *) else { return }
        let name = "snippets-pane-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("not json".utf8), forKey: SnippetStore.defaultsKey)
        let store = SnippetStore(defaults: defaults)
        let controller = UIHostingController(rootView: SnippetsKeyboardPane(
            store: store, onSend: { _ in Issue.record("Unavailable Snippets cannot send") }, onManage: {}))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let root = try #require(controller.view)
        try await waitUntil("The keyboard must explain that saved Snippets could not be read") {
            root.layoutIfNeeded()
            return Self.labels(in: root).contains("Snippets Unavailable")
        }
        let labels = Self.labels(in: root)
        #expect(!labels.contains("No Snippets yet"))
        #expect(!labels.contains("New Snippet"))
        #expect(labels.contains("The saved Snippets could not be read. They have been left untouched rather than overwritten, so nothing is lost."))
        let image = UIGraphicsImageRenderer(bounds: root.bounds).image { _ in
            root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
        }
        Attachment.record(image, named: "snippets-keyboard-unavailable", as: .png)
    }

    private static func labels(in root: UIView) -> Set<String> {
        var result: Set<String> = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if let label = node.accessibilityLabel { result.insert(label) }
            if let elements = node.accessibilityElements {
                for case let child as NSObject in elements { visit(child) }
            } else {
                let count = node.accessibilityElementCount()
                if count > 0 && count != NSNotFound {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { visit(child) }
                    }
                }
            }
            if let view = node as? UIView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        return result
    }
}
