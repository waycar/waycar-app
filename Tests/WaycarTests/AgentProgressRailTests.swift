import Foundation
import SwiftUI
import Testing

@testable import Waycar

/// The Console card's Agent Progress (#189): the rail `AgentCardChrome`
/// draws along the bottom edge and the label on the age line. Blocked rows
/// stand in for Working ones here: Working's solving orb animates, so two
/// renders of one Working card need not match pixel for pixel.
@MainActor
@Suite("Agent progress rail")
struct AgentProgressRailTests {
    @Test func blockedEstimateDrawsTheRailAlongTheCardEdge() throws {
        let agent = try Self.agent(status: .blocked, progress: Self.steps(3, of: 6))
        #expect(
            try pixels(Self.card(agent, progressAgent: agent))
                != pixels(Self.card(agent, progressAgent: nil)),
            "A Blocked estimate must draw its frozen rail")
    }

    @Test func idleAndDoneCardsStayUnchanged() throws {
        // A record that kept its estimate past the turn must not draw a bar.
        for status in [AgentStatus.idle, .done] {
            let agent = try Self.agent(status: status, progress: Self.steps(7, of: 7))
            #expect(
                try pixels(Self.card(agent, progressAgent: agent))
                    == pixels(Self.card(agent, progressAgent: nil)),
                "\(status) must show no rail")
        }
    }

    @Test func estimateLabelJoinsTheAgeLine() throws {
        let estimated = try Self.agent(status: .blocked, progress: Self.steps(3, of: 6))
        let plain = Self.agent(status: .blocked, progress: nil)
        #expect(
            try pixels(AgentCardView(agent: estimated)) != pixels(AgentCardView(agent: plain)),
            "The card must show 3/6 beside the age")
    }

    private static func steps(_ done: Int, of total: Int) throws -> AgentProgress {
        try #require(AgentProgress(steps: .init(done: done, total: total), phase: nil))
    }

    private static func agent(status: AgentStatus, progress: AgentProgress?) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(),
            hostName: "Build Server",
            agent: Agent(
                terminalID: "term_a", kind: "omp", title: "Checkout review",
                status: status, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
                cwd: "/work/storefront", revision: 1),
            workspaceLabel: "Checkout",
            repositoryCheckout: nil,
            summary: AgentSummary(
                paneID: "w1:p1", status: status,
                text: "Waiting for approval to run the checkout UI test suite",
                timestamp: Int64(Date.now.addingTimeInterval(-65).timeIntervalSince1970 * 1000),
                progress: progress))
    }

    private static func card(_ agent: ConsoleAgent, progressAgent: ConsoleAgent?) -> some View {
        AgentCardView(agent: agent)
            .modifier(AgentCardChrome(isSelected: false, progressAgent: progressAgent))
    }

    private func pixels(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(content: view
            .frame(width: 360, height: 160)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        return try #require(renderer.uiImage?.pngData())
    }
}
