import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// Host detail's Backends section hosted in a real window, read through the
/// accessibility tree: only visibility toggles remain, never launch defaults.
@MainActor
@Suite("Host detail backends section")
struct HostBackendsSectionTests {
    private static let core = CorePresence(
        version: "0.1.14", path: "/home/dev/.local/bin/herdr-core")
    private static let sentinel = "Section sentinel"

    private struct Rig {
        let window: UIWindow
        let root: UIView
        let console: ConsoleStore
        let store: HostOnboardingStore
    }

    private func makeRig(presence: HostBackendPresence) async throws -> Rig {
        let name = "backends-section-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let console = ConsoleStore(
            backendPreferences: HostBackendPreferences(defaults: defaults))
        let host = Host.fixture()
        let store = HostOnboardingStore(
            host: host, knownPresence: presence)
        let view = List {
            HostBackendsSection(store: store, console: console)
            Section { Text(Self.sentinel) }
        }
        let controller = UIHostingController(rootView: view)
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 600, height: 800), rootViewController: controller)
        return Rig(window: window, root: controller.view, console: console, store: store)
    }

    /// Polls until `label` shows, laying the hosted view out between tries.
    private func waitForLabel(_ label: String, in root: UIView) async throws {
        try await waitUntil("\"\(label)\" never appeared") {
            root.setNeedsLayout()
            root.layoutIfNeeded()
            return Self.contains(label: label, in: root)
        }
    }

    private static func contains(label: String? = nil, identifier: String? = nil, in root: UIView)
        -> Bool
    {
        var found = false
        visit(root) { node in
            // A Picker's label reads "<title>, <value>".
            if let label, node.accessibilityLabel?.hasPrefix(label) == true { found = true }
            if let identifier, Self.identifier(of: node) == identifier { found = true }
        }
        return found
    }

    /// SwiftUI's accessibility nodes are not all `UIAccessibilityIdentification`
    /// types, but answer the selector.
    private static func identifier(of node: NSObject) -> String? {
        if let identified = node as? UIAccessibilityIdentification,
            let id = identified.accessibilityIdentifier, !id.isEmpty
        {
            return id
        }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard node.responds(to: selector) else { return nil }
        return node.value(forKey: "accessibilityIdentifier") as? String
    }

    private static func visit(_ root: UIView, body: (NSObject) -> Void) {
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            body(node)
            if let elements = node.accessibilityElements {
                for case let object as NSObject in elements { walk(object) }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject {
                        walk(object)
                    }
                }
            }
            if let view = node as? UIView {
                for subview in view.subviews { walk(subview) }
            }
        }
        walk(root)
    }

    private func hasPicker(in rig: Rig) -> Bool {
        Self.contains(identifier: "host.herdrRuntime.picker", in: rig.root)
            || Self.contains(label: "Lead runtime", in: rig.root)
    }

    /// Every labelled or identified node, to say what the tree held when a
    /// check fails.
    private static func dump(_ root: UIView) -> String {
        var lines: [String] = []
        visit(root) { node in
            let id = Self.identifier(of: node) ?? ""
            if node.accessibilityLabel != nil || !id.isEmpty {
                lines.append("\(type(of: node)) label=\(node.accessibilityLabel ?? "-") id=\(id)")
            }
        }
        return lines.joined(separator: "\n")
    }

    @Test func allBackendsShowOnlyLabelledVisibilityToggles() async throws {
        let rig = try await makeRig(
            presence: HostBackendPresence(herdr: true, tmuxVersion: "3.4", core: Self.core))
        defer { rig.window.isHidden = true }

        try await waitForLabel(Self.sentinel, in: rig.root)
        #expect(!hasPicker(in: rig), "\(Self.dump(rig.root))")
        #expect(!Self.contains(label: "New agents start in", in: rig.root))
        #expect(Self.contains(label: "Show Herdr TUI sessions", in: rig.root))
        #expect(Self.contains(label: "Show Herdr Core sessions", in: rig.root))
        #expect(Self.contains(label: "Show tmux sessions", in: rig.root))
    }

    @Test func zellijVisibilityIsOfferedWithoutANewAgentPicker() async throws {
        let rig = try await makeRig(presence: HostBackendPresence(
            herdr: false, tmuxVersion: nil,
            zellij: ZellijPresence(version: "0.46.0", path: "/opt/zellij")))
        defer { rig.window.isHidden = true }
        try await waitForLabel("Show Zellij sessions", in: rig.root)
        #expect(!hasPicker(in: rig))
        #expect(rig.console.backendPreferences.showsZellij(for: rig.store.host.id))
    }

    @Test func oneRuntimeFoundShowsNoPicker() async throws {
        for presence in [
            HostBackendPresence(herdr: true, tmuxVersion: "3.4"),
            HostBackendPresence(herdr: false, tmuxVersion: "3.4", core: Self.core),
            HostBackendPresence(herdr: true, tmuxVersion: nil),
        ] {
            let rig = try await makeRig(presence: presence)
            defer { rig.window.isHidden = true }

            try await waitForLabel(Self.sentinel, in: rig.root)
            #expect(!hasPicker(in: rig), "\(presence)")
            // tmux's controls are the Host's own, with or without a picker.
            #expect(
                Self.contains(label: "Show tmux sessions", in: rig.root) == presence.tmuxUsable,
                "\(presence)")
        }
    }

}
