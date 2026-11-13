#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import Observation
    import Testing

    @testable import Waycar

    @MainActor
    @Suite("Demo screenshot mode", .timeLimit(.minutes(1)))
    struct DemoScreenshotModeTests {
        @Test func launchArgumentIsExactAndOptIn() {
            #expect(!DemoScreenshotMode.isEnabled(arguments: []))
            #expect(!DemoScreenshotMode.isEnabled(arguments: ["--demo-screenshot"]))
            #expect(
                DemoScreenshotMode.isEnabled(
                    arguments: ["Waycar", "--demo-screenshots"]))
        }

        @Test func fixtureIsStablePrivateAndCoversProductStates() {
            let hosts = DemoScreenshotFixture.hosts
            let profiles = DemoScreenshotFixture.profiles
            let agents = hosts.flatMap { profiles[$0.id]?.snapshot.agents ?? [] }

            #expect(hosts.map(\.displayName) == ["Studio Mac", "Build Server"])
            #expect(
                hosts.map(\.id) == [
                    DemoScreenshotFixture.studioHostID,
                    DemoScreenshotFixture.buildHostID,
                ])
            #expect(Set(agents.map(\.agentStatus)) == [.blocked, .working, .done, .idle])
            #expect(
                Set(agents.compactMap(\.agent))
                    == ["claude", "codex", "gemini", "omp", "opencode"])
            #expect(agents.map(\.paneID).contains("checkout:p3"))
            #expect(hosts.allSatisfy { $0.address.hasSuffix(".demo.invalid") })
            // Every card carries a summary line within the plugin's cap, and
            // at least one reads stale (written in another status).
            let summaries = hosts.flatMap { profiles[$0.id]?.summaries ?? [] }
            #expect(Set(summaries.map(\.paneID)) == Set(agents.map(\.paneID)))
            #expect(summaries.allSatisfy { $0.text.count <= 100 })
            let statuses = Dictionary(uniqueKeysWithValues: agents.map { ($0.paneID, $0.agentStatus) })
            #expect(summaries.contains { statuses[$0.paneID] != $0.status })
        }

        @Test func compositionLoadsTheProductionConsolePipeline() async throws {
            let composition = DemoScreenshotComposition.make()
            composition.console.setHosts(composition.hosts.hosts)
            await composition.console.resume()
            defer { composition.console.setHosts([]) }

            while composition.console.agents.count != 6
                || composition.hosts.hosts.contains(where: {
                    composition.console.sidebarSnapshots.snapshot(for: $0.id) == nil
                })
            {
                let changes = AsyncStream<Void>.makeStream()
                withObservationTracking {
                    _ = composition.console.agents
                    _ = composition.console.sidebarSnapshots.states
                } onChange: {
                    changes.continuation.yield(())
                }
                for await _ in changes.stream { break }
                changes.continuation.finish()
            }

            #expect(composition.console.agents.count == 6)
            #expect(composition.console.agents.first?.agent.status == .blocked)
            #expect(composition.console.agents.first?.hostName == "Build Server")
            #expect(composition.console.hostStatuses.values.allSatisfy { $0 == .connected })

            for host in composition.hosts.hosts {
                let bytes = try await composition.console.withNotificationTransport(for: host.id) {
                    try await $0.readSidebarLayout()
                }
                #expect(bytes == DemoScreenshotFixture.sidebarLayoutData)
                #expect(composition.console.rowLayout(for: host.id)
                    == AgentRowLayout(rows: [
                        [.init(.workspace)], [.init(.terminalTitleStripped)], [.init(.directory)],
                    ]))
            }
            let row = try #require(composition.console.agents.first)
            let card = AgentCardPresentation(agent: row, layout: composition.console.rowLayout(for: row.hostID))
            #expect(card.headline == row.workspaceLabel)
            #expect(card.additionalRows.first == row.agent.terminalTitleStripped)

            // Agent Progress (#189): the cards show every rail the Console
            // draws — steps and a phase while Working, steps frozen on
            // Blocked, the dotted Working rail with no estimate yet — and
            // nothing on Idle or Done.
            let progress = Dictionary(uniqueKeysWithValues: composition.console.agents.compactMap {
                agent in agent.progressDisplay(at: .now).map { (agent.agent.paneID, $0) }
            })
            let steps67 = try #require(AgentProgress(steps: .init(done: 6, total: 7), phase: nil))
            let exploring = try #require(AgentProgress(steps: nil, phase: .exploring))
            let steps36 = try #require(AgentProgress(steps: .init(done: 3, total: 6), phase: nil))
            #expect(progress["api:p7"] == .estimate(steps67, isStale: false))
            #expect(progress["mobile:p1"] == .estimate(exploring, isStale: false))
            #expect(
                progress[DemoScreenshotFixture.checkoutAgentPaneID] == .estimate(steps36, isStale: false))
            #expect(progress[DemoScreenshotFixture.chatAgentPaneID] == .pending)
            let settled = composition.console.agents.filter {
                $0.agent.status == .idle || $0.agent.status == .done
            }
            #expect(!settled.isEmpty)
            #expect(settled.allSatisfy { $0.progressDisplay(at: .now) == nil })
        }
    }
#endif
