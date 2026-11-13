import SwiftUI
import Testing
import UIKit

@testable import Waycar

@MainActor
@Suite("Host server runtime section")
struct HostServerRuntimeSectionTests {
    @Test(arguments: ServerChatBackend.allCases)
    func startingNeverSaysNotRunning(server: ServerChatBackend) async throws {
        let controller = UIHostingController(rootView: List {
            HostServerRuntimeSection(server: server, state: .starting, start: {})
        })
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 600, height: 800), rootViewController: controller)
        defer { window.isHidden = true }
        try await waitUntil("starting control should be accessible") {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return Self.labels(in: controller.view).contains("Starting \(server.serverName)")
        }
        #expect(!Self.labels(in: controller.view).contains { $0.contains("not running") })
        Self.record(window, named: "host-server-starting-\(server.rawValue)")
    }

    @Test(arguments: ServerChatBackend.allCases)
    func stoppedSaysNotRunning(server: ServerChatBackend) async throws {
        let controller = UIHostingController(rootView: List {
            HostServerRuntimeSection(server: server, state: .stopped(error: nil), start: {})
        })
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 600, height: 800), rootViewController: controller)
        defer { window.isHidden = true }
        try await waitUntil("stopped state should say so") {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return Self.labels(in: controller.view).contains("\(server.serverName) not running")
        }
        Self.record(window, named: "host-server-stopped-\(server.rawValue)")
    }

    private static func record(_ window: UIWindow, named name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(image, named: name, as: .png)
    }

    private static func labels(in root: UIView) -> Set<String> {
        var labels: Set<String> = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if let label = node.accessibilityLabel { labels.insert(label) }
            for case let child as NSObject in node.accessibilityElements ?? [] { visit(child) }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let child = node.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
            if let view = node as? UIView {
                for child in view.subviews { visit(child) }
            }
        }
        visit(root)
        return labels
    }
}
