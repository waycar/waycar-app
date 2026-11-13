import SwiftUI
import Testing
import UIKit

@testable import Waycar

@MainActor
@Suite("Ultimate leader card")
struct UltimateLeaderCardTests {
    @Test("Branches are folded initially, expand accessibly, route to their chat, and collapse")
    func foldedBranches() async throws {
        let hostID = UUID()
        let info = AgentInfo(
            agentStatus: .idle, focused: false, paneID: "ultimate:project:1", revision: 0,
            tabID: "ultimate:project:1", terminalID: "ultimate:project:1", workspaceID: "ultimate:project",
            agent: "ultimate", cwd: "/work/waycar", interactiveReady: true, launchPending: false, name: "@ultimate")
        var leader = ConsoleAgent(hostID: hostID, hostName: "Mac", agent: Agent(info),
                                  workspaceLabel: "Waycar", repositoryCheckout: nil, backend: .ultimate)
        leader.isUltimateLeader = true
        leader.ultimateChildren = [
            .init(conversationId: 2, paneID: "ultimate:project:2", name: "Build Console", busy: true, openQuestions: 1),
            .init(conversationId: 3, paneID: "ultimate:project:3", name: "Review changes", busy: false)
        ]
        leader.ultimateOpenQuestions = 1
        var opened: ConsoleAgent.ID?
        let controller = UIHostingController(rootView: List {
            AgentCardView(agent: leader, isChatMode: true, openUltimateChild: { opened = $0 })
                .modifier(AgentCardChrome(isSelected: false))
                .listRowBackground(Color.clear)
        })
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 440, height: 880), rootViewController: controller)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await DisplayTickMonitor.shared.waitForTicks(20)
        let root = try #require(controller.view)
        #expect(find("Build Console, Blocked, 1 needs you", in: root) == nil)
        #expect(find("Project lead", in: root) != nil)
        #expect(find("@ultimate", in: root) != nil)
        #expect(find("2 branches · 1 working · 1 needs you", in: root) != nil)
        let show = try #require(find("Show branches", in: root))
        #expect(show.accessibilityValue == "Collapsed")
        try #require(show.accessibilityActivate())
        let branch = try #require(await waitFor("Build Console, Blocked, 1 needs you", in: root))
        #expect(branch.accessibilityHint == "Opens branch chat")
        try #require(branch.accessibilityActivate())
        #expect(opened == .init(hostID: hostID, paneID: "ultimate:project:2"))
        let hide = try #require(find("Hide branches", in: root))
        #expect(hide.accessibilityValue == "Expanded")
        try #require(hide.accessibilityActivate())
        _ = await waitFor("Show branches", in: root)
        #expect(find("Build Console, Blocked, 1 needs you", in: root) == nil)
    }

    @Test("Other standing agents have their own title and no lead mark or branch footer")
    func standingCard() async throws {
        let info = AgentInfo(agentStatus: .idle, focused: false, paneID: "ultimate:project:9", revision: 0,
                             tabID: "ultimate:project:9", terminalID: "ultimate:project:9", workspaceID: "ultimate:project",
                             agent: "ultimate", name: "@reviewer")
        let row = ConsoleAgent(hostID: UUID(), hostName: "Mac", agent: Agent(info), workspaceLabel: "Waycar",
                               repositoryCheckout: nil, backend: .ultimate)
        let controller = UIHostingController(rootView: List {
            AgentCardView(agent: row, openUltimateChild: { _ in })
                .modifier(AgentCardChrome(isSelected: false))
                .listRowBackground(Color.clear)
        })
        let window = try await makeTestWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 880), rootViewController: controller)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await DisplayTickMonitor.shared.waitForTicks(20)
        let root = try #require(controller.view)
        #expect(find("@reviewer", in: root) != nil)
        #expect(find("Project lead", in: root) == nil)
        #expect(find("Show branches", in: root) == nil)
        #expect(find("0 branches · 0 working", in: root) == nil)
    }

    private func waitFor(_ label: String, in root: UIView) async -> NSObject? {
        let deadline = ContinuousClock.now + .waitCeiling
        while ContinuousClock.now < deadline {
            root.layoutIfNeeded()
            if let found = find(label, in: root) { return found }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func find(_ label: String, in root: UIView) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.accessibilityLabel == label { return node }
            for case let child as NSObject in node.accessibilityElements ?? [] {
                if let found = walk(child) { return found }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for i in 0..<count {
                    if let child = node.accessibilityElement(at: i) as? NSObject,
                       let found = walk(child) { return found }
                }
            }
            if let view = node as? UIView {
                for child in view.subviews { if let found = walk(child) { return found } }
            }
            return nil
        }
        return walk(root)
    }
}
