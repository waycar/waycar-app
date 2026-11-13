import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Waycar

@MainActor
@Suite("Agent Composer toolbar", .serialized)
struct AgentComposerToolbarTests {
    // MARK: Row

    /// The Composer card's row is fixed: `+` and More lead, Send trails.
    @Test func addAndMoreLeadTheRowAndSendTrailsIt() async throws {
        // Hosted SwiftUI accessibility only materializes on iOS 27; CI runs 26.2.
        guard #available(iOS 27, *) else { return }
        let (window, root) = Self.host(Self.composer())
        defer { window.isHidden = true }

        let add = try #require(try await Self.waitForFrame(labeled: "Add", in: root))
        let more = try #require(try await Self.waitForFrame(labeled: "More", in: root))
        let send = try #require(try await Self.waitForFrame(labeled: "Send", in: root))

        #expect(add.maxX < more.minX)
        #expect(more.maxX < send.minX)
        // More sits beside `+`; the spacer separates both from Send.
        #expect(more.minX - add.maxX < 40)
        #expect(send.minX - more.maxX > 150)
        #expect(abs(add.midY - more.midY) < 4)
        #expect(abs(more.midY - send.midY) < 4)
    }

    // MARK: Fixtures

    private static func actions(canAdd: Bool) -> AgentComposerActions {
        AgentComposerActions(
            canAdd: canAdd,
            addImage: {},
            addFile: {},
            openTerminal: nil,
            isOpeningTerminal: false,
            startAgent: {},
            manageSnippets: {},
            showSkills: {},
            showWorktreeDetails: nil,
            renameAgent: {},
            renameWorkspace: {},
            markUnread: nil,
            closeAgent: {})
    }

    private static func composer() -> AgentComposerView {
        let store = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        return AgentComposerView(
            store: store,
            agentID: ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1"),
            actions: actions(canAdd: true),
            skills: nil,
            keyboardPresentation: .constant(.hidden),
            prepareKeyboardPresentation: { _ in },
            focusRequested: .constant(false))
    }

    private static func host(_ view: AgentComposerView) -> (UIWindow, UIView) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return (window, controller.view)
    }

    private static func waitForFrame(labeled label: String, in root: UIView) async throws -> CGRect? {
        let deadline = ContinuousClock.now + .waitCeiling
        while ContinuousClock.now < deadline {
            root.setNeedsLayout()
            root.layoutIfNeeded()
            if let frame = firstAccessibleFrame(labeled: label, in: root) {
                return frame
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private static func firstAccessibleFrame(labeled label: String, in root: UIView) -> CGRect? {
        var match: CGRect?
        visitAccessible(in: root) { node in
            guard match == nil, node.accessibilityLabel == label else { return }
            if let view = node as? UIView {
                guard view.bounds.width > 0, view.bounds.height > 0, view.window != nil else { return }
                match = view.convert(view.bounds, to: root)
            } else {
                let frame = node.accessibilityFrame
                guard frame.width > 0, frame.height > 0 else { return }
                match = root.convert(frame, from: nil)
            }
        }
        return match
    }

    /// Walks views and SwiftUI accessibility containers (array and indexed
    /// APIs), visiting each element once.
    private static func visitAccessible(in root: UIView, body: (NSObject) -> Void) {
        var visited = Set<ObjectIdentifier>()

        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            body(node)
            if let elements = node.accessibilityElements {
                for case let object as NSObject in elements {
                    visit(object)
                }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject {
                        visit(object)
                    }
                }
            }
            if let view = node as? UIView {
                for subview in view.subviews {
                    visit(subview)
                }
            }
        }
        visit(root)
    }
}
