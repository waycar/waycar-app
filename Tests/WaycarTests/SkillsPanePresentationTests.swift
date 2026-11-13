import SwiftUI
import Testing
import UIKit

@testable import Waycar

@MainActor
@Suite("Skills pane presentation", .serialized)
struct SkillsPanePresentationTests {
    @Test(arguments: [false, true])
    func aRefreshFailureStaysVisibleBesideThePreviousSkills(keyboard: Bool) async throws {
        var fails = false
        let store = SkillsPaneStore { _ in
            if fails { throw TransportError.sshUnreachable(detail: "gone") }
            return [AgentSkill(scope: .global, name: "kept", description: "A saved skill")]
        }
        await store.loadIfNeeded()
        fails = true
        await store.refresh()

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root: AnyView = if keyboard {
            AnyView(SkillsKeyboardPane(store: store, onInsert: { _ in }, onViewContent: { _ in })
                .frame(height: 320))
        } else {
            AnyView(SkillsPickerView(store: store, onInsert: { _ in }, readSkill: { _ in "" }))
        }
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitUntil("the previous skill should remain on screen") {
            Self.labels(in: window).contains("kept")
        }
        try await waitUntil("the failed refresh should show its wording and Retry beside the list") {
            let labels = Self.labels(in: window)
            return labels.contains("The Host is not connected.") && labels.contains("Retry")
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(image, named: keyboard ? "skills-keyboard-refresh-failed" : "skills-picker-refresh-failed", as: .png)
    }

    private static func labels(in window: UIWindow) -> Set<String> {
        var visited = Set<ObjectIdentifier>()
        var stack: [NSObject] = [window]
        var labels = Set<String>()
        while let object = stack.popLast() {
            guard visited.insert(ObjectIdentifier(object)).inserted, visited.count < 40_000 else { continue }
            if let label = object.accessibilityLabel { labels.insert(label) }
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
            if let elements = object.accessibilityElements {
                stack.append(contentsOf: elements.compactMap { $0 as? NSObject })
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let element = object.accessibilityElement(at: index) as? NSObject {
                            stack.append(element)
                        }
                    }
                }
            }
        }
        return labels
    }
}
